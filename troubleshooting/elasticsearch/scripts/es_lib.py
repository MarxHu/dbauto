#!/usr/bin/env python3
"""Parse ES 7.x collector JSON and run cleanse cross-compare.

Used by bash collectors and cleanse_artifacts.sh. No HTTP. Diagnose only.
"""
from __future__ import annotations

import json
import os
import sys
from collections import Counter
from pathlib import Path
from typing import Any


def _load(text: str) -> Any:
    text = (text or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def parse_cat_master(text: str) -> dict[str, Any]:
    data = _load(text)
    out = {
        "http_ok": False,
        "auth_fail": False,
        "local_master": "",
        "local_master_ip": "",
        "local_master_id": "",
        "is_elected": False,
    }
    if data is None:
        return out
    out["http_ok"] = True
    row = None
    if isinstance(data, list) and data:
        row = data[0] if isinstance(data[0], dict) else None
    elif isinstance(data, dict):
        row = data
    if not row:
        return out
    out["local_master"] = str(row.get("node") or row.get("name") or "")
    out["local_master_ip"] = str(row.get("ip") or row.get("host") or "")
    out["local_master_id"] = str(row.get("id") or "")
    return out


def parse_cat_nodes(text: str, local_ip: str = "") -> dict[str, Any]:
    data = _load(text)
    out = {"nodes": [], "elected": "", "elected_ip": "", "self_elected": False}
    if not isinstance(data, list):
        return out
    for row in data:
        if not isinstance(row, dict):
            continue
        name = str(row.get("name") or row.get("node") or "")
        ip = str(row.get("ip") or "")
        master = str(row.get("master") or "")
        roles = str(row.get("node.role") or row.get("nodeRole") or "")
        out["nodes"].append({"name": name, "ip": ip, "master": master, "roles": roles})
        if master == "*":
            out["elected"] = name
            out["elected_ip"] = ip
            if local_ip and (ip == local_ip):
                out["self_elected"] = True
    return out


def parse_local_stats(text: str) -> dict[str, Any]:
    data = _load(text)
    out = {
        "heap_pct": None,
        "write_rejected": None,
        "search_rejected": None,
        "write_pool": "",
        "breaker_parent_pct": None,
        "breaker_tripped": 0,
        "disk_total": None,
        "disk_free": None,
        "disk_used_pct": None,
        "index_total": None,
        "index_time_ms": None,
        "query_total": None,
        "query_time_ms": None,
        "cpu_percent": None,
        "gc_young_ms": None,
        "gc_old_ms": None,
        "node_name": "",
    }
    if not isinstance(data, dict):
        return out
    nodes = data.get("nodes") or {}
    if not isinstance(nodes, dict) or not nodes:
        return out
    n = next(iter(nodes.values()))
    if not isinstance(n, dict):
        return out
    out["node_name"] = str(n.get("name") or "")
    jvm = n.get("jvm") or {}
    mem = jvm.get("mem") or {}
    if "heap_used_percent" in mem:
        out["heap_pct"] = int(mem["heap_used_percent"])
    collectors = (jvm.get("gc") or {}).get("collectors") or {}
    young = collectors.get("young") or collectors.get("ParNew") or {}
    old = collectors.get("old") or collectors.get("ConcurrentMarkSweep") or collectors.get("G1 Old Generation") or {}
    if "collection_time_in_millis" in young:
        out["gc_young_ms"] = int(young["collection_time_in_millis"])
    if "collection_time_in_millis" in old:
        out["gc_old_ms"] = int(old["collection_time_in_millis"])
    tp = n.get("thread_pool") or {}
    write = tp.get("write") if isinstance(tp.get("write"), dict) else None
    if write is None and isinstance(tp.get("index"), dict):
        write = tp["index"]
        out["write_pool"] = "index_legacy"
    else:
        out["write_pool"] = "write"
    if write:
        out["write_rejected"] = int(write.get("rejected") or 0)
    search = tp.get("search") if isinstance(tp.get("search"), dict) else {}
    if search:
        out["search_rejected"] = int(search.get("rejected") or 0)
    breakers = n.get("breakers") or {}
    parent = breakers.get("parent") or {}
    if parent.get("limit_size_in_bytes") and parent.get("estimated_size_in_bytes") is not None:
        lim = int(parent["limit_size_in_bytes"]) or 1
        out["breaker_parent_pct"] = int(int(parent["estimated_size_in_bytes"]) * 100 / lim)
    tripped = 0
    for b in breakers.values():
        if isinstance(b, dict):
            tripped += int(b.get("tripped") or 0)
    out["breaker_tripped"] = tripped
    fs = (n.get("fs") or {}).get("total") or {}
    if fs.get("total_in_bytes"):
        total = int(fs["total_in_bytes"])
        free = int(fs.get("available_in_bytes") or fs.get("free_in_bytes") or 0)
        out["disk_total"] = total
        out["disk_free"] = free
        out["disk_used_pct"] = int((total - free) * 100 / total) if total else None
    idx = (n.get("indices") or {}).get("indexing") or {}
    if "index_total" in idx:
        out["index_total"] = int(idx["index_total"])
        out["index_time_ms"] = int(idx.get("index_time_in_millis") or 0)
    search_m = (n.get("indices") or {}).get("search") or {}
    if "query_total" in search_m:
        out["query_total"] = int(search_m["query_total"])
        out["query_time_ms"] = int(search_m.get("query_time_in_millis") or 0)
    cpu = (n.get("os") or {}).get("cpu") or {}
    if "percent" in cpu:
        out["cpu_percent"] = int(cpu["percent"])
    return out


def parse_cluster_health(text: str) -> dict[str, Any]:
    data = _load(text)
    if not isinstance(data, dict):
        return {}
    keys = (
        "status",
        "number_of_nodes",
        "number_of_data_nodes",
        "active_primary_shards",
        "active_shards",
        "relocating_shards",
        "initializing_shards",
        "unassigned_shards",
        "delayed_unassigned_shards",
        "number_of_pending_tasks",
        "task_max_waiting_in_queue_millis",
        "active_shards_percent_as_number",
        "timed_out",
    )
    out: dict[str, Any] = {}
    for k in keys:
        if k in data:
            out[k] = data[k]
    return out


def merge_facts(path: str, updates: dict[str, Any]) -> dict[str, Any]:
    p = Path(path)
    cur: dict[str, Any] = {}
    if p.is_file():
        try:
            cur = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            cur = {}
    cur.update({k: v for k, v in updates.items() if v is not None})
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(cur, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return cur


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _read_signals(base: Path) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    for p in sorted(base.glob("*.signals")):
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            parts = line.split("\t", 2)
            if len(parts) >= 3 and parts[0].startswith("ES"):
                rows.append((parts[0], parts[1], parts[2]))
    return rows


def _sev_rank(sev: str) -> int:
    return {"high": 3, "medium": 2, "low": 1, "warning": 2}.get(sev, 0)


def _dedup(rows: list[tuple[str, str, str]]) -> list[tuple[str, str, str]]:
    best: dict[str, tuple[str, str, str]] = {}
    order: list[str] = []
    for sid, sev, note in rows:
        if sid not in best:
            order.append(sid)
            best[sid] = (sid, sev, note)
            continue
        old = best[sid]
        if _sev_rank(sev) > _sev_rank(old[1]):
            best[sid] = (sid, sev, f"{old[2]} | {note}")
        elif note not in old[2]:
            best[sid] = (sid, old[1], f"{old[2]} | {note}")
    return [best[k] for k in order]


def _add(signals: list[tuple[str, str, str]], sid: str, sev: str, note: str) -> None:
    signals.append((sid, sev, note))


def cross_compare(
    facts: dict[str, dict[str, Any]],
    expected_nodes: int,
    expected_ips: list[str],
) -> tuple[list[tuple[str, str, str]], dict[str, Any]]:
    extra: list[tuple[str, str, str]] = []
    collected_ips = [ip for ip in expected_ips if ip in facts]
    n_col = len(collected_ips)
    meta: dict[str, Any] = {
        "nodes_collected": n_col,
        "expected_nodes": expected_nodes,
        "majority_master": "",
        "coverage": "ok",
        "no_master": False,
        "evidence_gap": [],
    }
    if n_col < expected_nodes:
        meta["coverage"] = "degraded"
        missing = [ip for ip in expected_ips if ip not in facts]
        meta["evidence_gap"].append("missing_nodes=" + ",".join(missing))
        _add(extra, "ES172", "high", "nodes missing: " + ",".join(missing))
        if n_col == 0:
            meta["coverage"] = "empty"

    masters = []
    auth_na = 0
    for ip in collected_ips:
        f = facts[ip]
        if f.get("auth_fail"):
            auth_na += 1
            continue
        masters.append((ip, str(f.get("local_master") or "")))

    nonempty = [m for _, m in masters if m]
    empty = [ip for ip, m in masters if not m]
    maj = ""
    if nonempty:
        maj, cnt = Counter(nonempty).most_common(1)[0]
        if cnt >= 2 or (expected_nodes == 1 and cnt == 1):
            maj_ok = maj
        else:
            maj_ok = maj if cnt == len(nonempty) else ""
        maj = maj_ok
    meta["majority_master"] = maj

    all_collected = n_col == expected_nodes and expected_nodes >= 1
    all_empty = all_collected and not nonempty and auth_na == 0
    if all_empty:
        _add(extra, "ES050", "high", "all %s nodes have empty local_master" % n_col)
        _add(extra, "ES191", "high", "NO_MASTER")
        meta["no_master"] = True
        meta["majority_master"] = ""
    elif n_col < expected_nodes and nonempty == [] and empty:
        meta["evidence_gap"].append("NO_MASTER_OBSERVED")
        _add(extra, "ES173", "medium", "observed nodes have no master but collection incomplete")
    elif maj and empty:
        _add(extra, "ES051", "high", "majority master=%s disagree/empty on %s" % (maj, ",".join(empty)))
        _add(extra, "ES199", "high", "master view split")
    elif nonempty and len(set(nonempty)) > 1:
        _add(extra, "ES051", "high", "local_master values disagree: " + ",".join(sorted(set(nonempty))))
        _add(extra, "ES199", "high", "master view split")

    health = {}
    for ip in collected_ips:
        h = facts[ip].get("cluster_health")
        if isinstance(h, dict) and h.get("status"):
            health = h
            if maj and (facts[ip].get("is_elected") or facts[ip].get("local_master") == maj):
                break

    nodes_in_health = int(health.get("number_of_nodes") or 0) if health else 0
    status = str(health.get("status") or "")
    unassigned = int(health.get("unassigned_shards") or 0) if health else 0
    delayed = int(health.get("delayed_unassigned_shards") or 0) if health else 0
    pending = int(health.get("number_of_pending_tasks") or 0) if health else 0
    reloc = int(health.get("relocating_shards") or 0) if health else 0
    init = int(health.get("initializing_shards") or 0) if health else 0

    if delayed > 0:
        _add(extra, "ES055", "low", "delayed_unassigned=%s" % delayed)
    if pending >= 10:
        _add(extra, "ES056", "high", "pending_tasks=%s" % pending)
    elif pending >= 1:
        _add(extra, "ES056", "medium", "pending_tasks=%s" % pending)
    if reloc or init:
        _add(extra, "ES057", "medium", "relocating=%s initializing=%s" % (reloc, init))

    down_ips = []
    for ip in expected_ips:
        f = facts.get(ip) or {}
        proc = f.get("process_up")
        http = f.get("http_ok")
        listen = f.get("listen_http")
        if proc is False or listen is False or http is False:
            down_ips.append(ip)
        elif ip not in facts:
            down_ips.append(ip)

    if not meta["no_master"]:
        if nodes_in_health and nodes_in_health < expected_nodes:
            missing_n = expected_nodes - nodes_in_health
            if missing_n >= 2:
                _add(extra, "ES053", "high", "health nodes=%s expected=%s" % (nodes_in_health, expected_nodes))
            else:
                _add(extra, "ES052", "medium", "health nodes=%s expected=%s" % (nodes_in_health, expected_nodes))
            _add(extra, "ES190", "high", "NODE_DOWN health_nodes=%s down_ips=%s" % (nodes_in_health, ",".join(down_ips) or "unknown"))
        elif n_col == expected_nodes and nodes_in_health == expected_nodes and status == "yellow" and unassigned > 0:
            _add(extra, "ES192", "medium", "YELLOW_ALLOC_NOT_DOWN unassigned=%s" % unassigned)
        if status == "red" and not meta["no_master"] and unassigned > 0:
            _add(extra, "ES054", "high", "red with unassigned=%s" % unassigned)

    if meta["no_master"] and status == "red":
        _add(extra, "ES053", "high", "red and NO_MASTER")

    if expected_nodes <= 1:
        extra = [(s, v, n + " node_count=1") if s.startswith("ES19") else (s, v, n) for s, v, n in extra]
        extra = [x for x in extra if not (x[0] in {"ES194", "ES196", "ES198"} and expected_nodes <= 1)]

    heaps = [(ip, facts[ip].get("heap_pct")) for ip in collected_ips if isinstance(facts[ip].get("heap_pct"), int)]
    high_heap = [ip for ip, h in heaps if h is not None and h >= 85]
    if len(high_heap) == 1 and len(heaps) >= 2:
        _add(extra, "ES193", "high", "HEAP_ONE_OUTLIER %s heap=%s" % (high_heap[0], dict(heaps)[high_heap[0]]))
        _add(extra, "ES034", "high", "%s heap=%s" % (high_heap[0], dict(heaps)[high_heap[0]]))
    elif len(high_heap) >= 2:
        _add(extra, "ES194", "high", "HEAP_ALL_SIMILAR " + ",".join("%s=%s" % (ip, dict(heaps)[ip]) for ip in high_heap))

    rejects = [(ip, int(facts[ip].get("write_rejected_delta") or 0) + int(facts[ip].get("search_rejected_delta") or 0)) for ip in collected_ips]
    rej_pos = [ip for ip, r in rejects if r > 0]
    if len(rej_pos) == 1 and len(rejects) >= 2:
        _add(extra, "ES195", "medium", "REJECT_ONE %s delta=%s" % (rej_pos[0], dict(rejects)[rej_pos[0]]))
    elif len(rej_pos) >= 2:
        _add(extra, "ES196", "high", "REJECT_ALL " + ",".join(rej_pos))

    floods = [ip for ip in collected_ips if facts[ip].get("flood") or facts[ip].get("read_only_allow_delete")]
    if len(floods) == 1 and n_col >= 2:
        _add(extra, "ES197", "high", "FLOOD_ONE %s" % floods[0])
    elif len(floods) >= 2:
        _add(extra, "ES198", "high", "FLOOD_ALL " + ",".join(floods))

    for ip in collected_ips:
        f = facts[ip]
        if f.get("http_ok") and f.get("listen_http") and f.get("transport_ok") is False:
            _add(extra, "ES091", "high", "9200 up 9300 down on %s" % ip)
            _add(extra, "ES199", "high", "TRANSPORT_PARTITION %s" % ip)
        peers = f.get("peer_transport") or {}
        if isinstance(peers, dict):
            for peer, ok in peers.items():
                if ok is False and (f.get("peer_http") or {}).get(peer) is True:
                    _add(extra, "ES091", "high", "%s http ok transport fail to %s" % (ip, peer))
                    _add(extra, "ES199", "high", "TRANSPORT_PARTITION %s->%s" % (ip, peer))

    names = [str(facts[ip].get("cluster_name") or "") for ip in collected_ips if facts[ip].get("cluster_name")]
    if names and len(set(names)) > 1:
        _add(extra, "ES060", "high", "cluster.name disagree: " + ",".join(sorted(set(names))))

    alloc = [str(facts[ip].get("allocation_enable") or "") for ip in collected_ips if facts[ip].get("allocation_enable")]
    if any(a and a != "all" for a in alloc):
        _add(extra, "ES058", "high", "allocation.enable=" + ",".join(sorted(set(alloc))))

    explains = []
    for ip in collected_ips:
        ex = facts[ip].get("explain_reasons") or []
        if isinstance(ex, list):
            explains.extend(str(x) for x in ex)
    joined = " ".join(explains).upper()
    if "NODE_LEFT" in joined or "NODE_RESTART" in joined:
        _add(extra, "ES052", "medium", "explain NODE_LEFT")
    if "DECIDERS_NO" in joined and ("DISK" in joined or "WATERMARK" in joined):
        _add(extra, "ES061", "high", "explain DECIDERS_NO disk")
    if "ALLOCATION_FAILED" in joined:
        _add(extra, "ES063", "high", "explain ALLOCATION_FAILED")

    if expected_nodes <= 1:
        extra = [x for x in extra if x[0] not in {"ES194", "ES196", "ES198"}]

    return extra, meta


def render_summary(
    run_id: str,
    expected_ips: list[str],
    facts: dict[str, dict[str, Any]],
    signals: list[tuple[str, str, str]],
    meta: dict[str, Any],
    health: dict[str, Any],
) -> str:
    lines = [
        "# ES 7.x 三节点排查摘要",
        "",
        f"- run_id: `{run_id}`",
        f"- expected_nodes: {meta.get('expected_nodes')}",
        f"- nodes_collected: {meta.get('nodes_collected')}",
        f"- coverage: `{meta.get('coverage')}`",
        f"- majority_master: `{meta.get('majority_master') or ('NO_MASTER' if meta.get('no_master') else 'UNKNOWN')}`",
        "",
        "## 集群健康",
        "",
    ]
    if health:
        lines += [
            f"- status: `{health.get('status', '')}`",
            f"- number_of_nodes: {health.get('number_of_nodes', '')}",
            f"- unassigned_shards: {health.get('unassigned_shards', '')}",
            f"- delayed_unassigned_shards: {health.get('delayed_unassigned_shards', '')}",
            f"- pending_tasks: {health.get('number_of_pending_tasks', '')}",
            "",
        ]
    else:
        lines += ["- （无权威 cluster health）", ""]
    lines += [
        "## 各节点 master 视图",
        "",
        "| IP | local_master | 9200 | 9300 | heap% | write_rejected_delta | disk% |",
        "|----|--------------|------|------|-------|----------------------|-------|",
    ]
    for ip in expected_ips:
        f = facts.get(ip) or {}
        http = "ok" if f.get("http_ok") else ("NA" if not f else "fail")
        tp = f.get("listen_transport")
        trans = "ok" if tp else ("fail" if tp is False else "NA")
        lines.append(
            "| {ip} | {lm} | {http} | {trans} | {heap} | {wr} | {disk} |".format(
                ip=ip,
                lm=f.get("local_master") or ("(empty)" if f else "(missing)"),
                http=http,
                trans=trans,
                heap=f.get("heap_pct") if f.get("heap_pct") is not None else "",
                wr=f.get("write_rejected_delta") if f.get("write_rejected_delta") is not None else "",
                disk=f.get("disk_used_pct") if f.get("disk_used_pct") is not None else "",
            )
        )
    lines += ["", "## Top 信号", "", "| ID | 级别 | 说明 |", "|----|------|------|"]
    if signals:
        for sid, sev, note in signals:
            lines.append(f"| {sid} | {sev} | {note} |")
    else:
        lines.append("| — | — | 无自动信号 |")
    lines += ["", "## 交叉对比结论", ""]
    ids = {s[0] for s in signals}
    bullets = []
    if "ES191" in ids:
        bullets.append("- **ES191 NO_MASTER**：三台均无 elected master，先看发现/传输/进程，不要解释 unassigned。")
    if "ES190" in ids:
        bullets.append("- **ES190 NODE_DOWN**：健康节点数少于期望，优先掉节点而不是业务 QPS。")
    if "ES192" in ids:
        bullets.append("- **ES192 YELLOW_ALLOC_NOT_DOWN**：三台都在集群内，副本未分配是水位/allocation/max_shards。")
    if "ES193" in ids:
        bullets.append("- **ES193 HEAP_ONE_OUTLIER**：单节点 JVM，不是全集群容量。")
    if "ES194" in ids:
        bullets.append("- **ES194 HEAP_ALL_SIMILAR**：多节点堆压力。")
    if "ES195" in ids:
        bullets.append("- **ES195 REJECT_ONE**：单节点线程池拒绝。")
    if "ES196" in ids:
        bullets.append("- **ES196 REJECT_ALL**：多节点 reject。")
    if "ES197" in ids:
        bullets.append("- **ES197 FLOOD_ONE**：单节点磁盘 flood / 只读块。")
    if "ES198" in ids:
        bullets.append("- **ES198 FLOOD_ALL**：集群块。")
    if "ES199" in ids:
        bullets.append("- **ES199 TRANSPORT_PARTITION**：9200/9300 分叉或 master 视图分裂。")
    if not bullets:
        if meta.get("coverage") == "ok" and not ids:
            bullets.append("- 倾向 **ES001 基线正常**，或故障未落入 P0 信号。")
        else:
            bullets.append("- 无组合结论；见证据缺口。")
    lines.extend(bullets)
    lines += ["", "## 证据缺口", ""]
    gaps = list(meta.get("evidence_gap") or [])
    if meta.get("no_master"):
        gaps.append("unassigned explain 不可靠（NO_MASTER）")
    if not gaps:
        lines.append("- 无")
    else:
        for g in gaps:
            lines.append(f"- {g}")
    lines.append("")
    return "\n".join(lines)


def cleanse(base: str, run_id: str, expected_ips: list[str], profile: str = "v1") -> dict[str, Any]:
    root = Path(base)
    root.mkdir(parents=True, exist_ok=True)
    facts: dict[str, dict[str, Any]] = {}
    for ip in expected_ips:
        data = _read_json(root / f"facts.{ip}.json")
        if data:
            facts[ip] = data
        master = _read_json(root / f"master.{ip}.json")
        if master:
            facts.setdefault(ip, {})
            for k in ("local_master", "local_master_ip", "http_ok", "auth_fail", "is_elected"):
                if k in master and master[k] is not None:
                    facts[ip].setdefault(k, master[k])

    raw = _read_signals(root)
    extra, meta = cross_compare(facts, len(expected_ips), expected_ips)
    if profile.endswith("degraded") and meta["coverage"] == "ok":
        meta["coverage"] = "degraded"
        meta["evidence_gap"].append("forced_degraded_profile")
    merged = _dedup(raw + extra)
    health = {}
    for ip in expected_ips:
        h = (facts.get(ip) or {}).get("cluster_health")
        if isinstance(h, dict) and h:
            health = h
            if facts[ip].get("is_elected"):
                break

    kinds = ("precheck", "metrics", "status", "config", "logs", "hostnet")
    found = sum(1 for k in kinds if any(root.glob(f"{k}.*.txt")))
    if found == 0 and meta["coverage"] == "ok":
        meta["coverage"] = "empty"
    elif found < 3 and meta["coverage"] == "ok":
        meta["coverage"] = "degraded"

    summary = render_summary(run_id, expected_ips, facts, merged, meta, health)
    (root / "summary.md").write_text(summary, encoding="utf-8")
    sig_txt = "".join(f"{a}\t{b}\t{c}\n" for a, b, c in merged)
    (root / "signals.txt").write_text(sig_txt, encoding="utf-8")
    (root / "signals.uniq.tsv").write_text(sig_txt, encoding="utf-8")

    cleaned_parts = [
        f"===== ES_TS cleaned run_id={run_id} profile={profile} =====",
        f"nodes={','.join(expected_ips)}",
        f"coverage={meta['coverage']} majority_master={meta.get('majority_master')}",
        "",
        "----- SIGNALS -----",
        sig_txt or "NO_SIGNALS",
        "",
    ]
    for p in sorted(root.glob("*.txt")):
        if p.name in {"cleaned.txt", "signals.txt"}:
            continue
        body = p.read_text(encoding="utf-8", errors="replace")
        lines = body.splitlines()
        keep = [ln for ln in lines if ln.startswith("SIGNAL ") or ln.startswith("CMD_FAIL") or "KEYWORD" in ln]
        if not keep:
            keep = lines[-40:]
        cleaned_parts.append(f"### {p.name} ###")
        cleaned_parts.extend(keep[:80])
        cleaned_parts.append("")
    cleaned = "\n".join(cleaned_parts)
    if len(cleaned.encode()) > 64000:
        cleaned = cleaned.encode()[:64000].decode("utf-8", errors="ignore")
    (root / "cleaned.txt").write_text(cleaned, encoding="utf-8")
    meta_out = {
        "run_id": run_id,
        "profile": profile,
        "coverage_status": meta["coverage"],
        "nodes_collected": meta["nodes_collected"],
        "expected_nodes": meta["expected_nodes"],
        "majority_master": meta.get("majority_master") or "",
        "no_master": str(bool(meta.get("no_master"))).lower(),
        "signal_count": len(merged),
        "kinds_found": found,
    }
    meta_txt = "".join(f"{k}={v}\n" for k, v in meta_out.items())
    (root / "cleaned.meta").write_text(meta_txt, encoding="utf-8")
    return {"meta": meta_out, "signals": merged, "summary": summary}


def _cli(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: es_lib.py parse-master|parse-stats|parse-health|merge-facts|cleanse ...", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "parse-master":
        print(json.dumps(parse_cat_master(sys.stdin.read()), ensure_ascii=False))
        return 0
    if cmd == "parse-stats":
        print(json.dumps(parse_local_stats(sys.stdin.read()), ensure_ascii=False))
        return 0
    if cmd == "parse-health":
        print(json.dumps(parse_cluster_health(sys.stdin.read()), ensure_ascii=False))
        return 0
    if cmd == "parse-nodes":
        local_ip = argv[2] if len(argv) > 2 else ""
        print(json.dumps(parse_cat_nodes(sys.stdin.read(), local_ip), ensure_ascii=False))
        return 0
    if cmd == "merge-facts":
        path = argv[2]
        updates = json.loads(argv[3] if len(argv) > 3 else sys.stdin.read())
        print(json.dumps(merge_facts(path, updates), ensure_ascii=False))
        return 0
    if cmd == "cleanse":
        base, run_id = argv[2], argv[3]
        ips = argv[4:]
        profile = os.environ.get("TS_PROFILE", "v1")
        result = cleanse(base, run_id, ips, profile)
        print(json.dumps(result["meta"], ensure_ascii=False))
        return 0
    print("unknown command", cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_cli(sys.argv))
