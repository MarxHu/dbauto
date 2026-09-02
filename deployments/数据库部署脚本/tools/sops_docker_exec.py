#!/usr/bin/env python3
"""Simulate SOPS job_fast_execute_script by docker exec on Docker-as-VM nodes.

Reads a schema_v1 deployment YAML, substitutes constants, then runs each
ServiceActivity's job_content on the containers that own job_ip_list IPs.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import os
import shlex
import subprocess
import sys
from pathlib import Path

import yaml

DEFAULT_IP_MAP = {
    "10.10.26.144": "kafka-n1",
    "10.10.26.145": "kafka-n2",
    "10.10.26.146": "kafka-n3",
}


def log(msg: str) -> None:
    now = dt.datetime.now().strftime("%F %T")
    print(f"[{now}] {msg}", flush=True)


def docker_bin() -> list[str]:
    return shlex.split(os.environ.get("DOCKER", "sudo docker"))


def load_yaml(path: Path) -> dict:
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict) or "spec" not in data:
        raise SystemExit(f"invalid SOPS YAML: {path}")
    return data


def constants_map(doc: dict) -> dict[str, str]:
    raw = (doc.get("spec") or {}).get("constants") or {}
    out: dict[str, str] = {}
    for key, meta in raw.items():
        value = "" if meta is None else str(meta.get("value", ""))
        out[str(key)] = value
        if str(key).startswith("${") and str(key).endswith("}"):
            out[str(key)[2:-1]] = value
    return out


def substitute(text: str, consts: dict[str, str]) -> str:
    if text is None:
        return ""
    # Longer keys first so ${kafka_node1_ip} wins over partial matches.
    for key in sorted((k for k in consts if k.startswith("${")), key=len, reverse=True):
        text = text.replace(key, consts[key])
    return text


def walk_activities(doc: dict) -> list[dict]:
    nodes = {n["id"]: n for n in doc["spec"]["nodes"]}
    start = next(n for n in doc["spec"]["nodes"] if n.get("type") == "EmptyStartEvent")
    ordered: list[dict] = []
    nxt = (start.get("next") or [None])[0]
    seen: set[str] = set()
    while nxt and nxt not in seen:
        seen.add(nxt)
        node = nodes[nxt]
        if node.get("type") == "EmptyEndEvent":
            break
        if node.get("type") == "ServiceActivity":
            ordered.append(node)
        nxt = (node.get("next") or [None])[0]
    return ordered


def parse_ip_list(raw: str) -> list[str]:
    return [part.strip() for part in raw.replace(" ", "").split(",") if part.strip()]


def parse_params(raw: str) -> list[str]:
    raw = (raw or "").strip()
    if not raw:
        return []
    return shlex.split(raw)


def run_on_container(
    container: str,
    script: str,
    params: list[str],
    timeout: int,
    stage: str,
    ip: str,
) -> tuple[int, str]:
    cmd = docker_bin() + ["exec", "-i", "-u", "root", "-e", "TERM=xterm", container, "bash", "-s", "--", *params]
    proc = subprocess.run(
        cmd,
        input=script,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    header = f"----- {stage} @ {ip} ({container}) exit={proc.returncode} -----\n"
    return proc.returncode, header + out


def run_stage(node: dict, consts: dict[str, str], ip_map: dict[str, str], log_dir: Path) -> None:
    data = node["component"]["data"]
    stage = node.get("stage_name") or node["id"]
    script = substitute(data["job_content"]["value"], consts)
    param_raw = substitute(str(data["job_script_param"]["value"]), consts)
    ip_raw = substitute(str(data["job_ip_list"]["value"]), consts)
    timeout = int(str(data.get("job_script_timeout", {}).get("value") or "1800"))
    params = parse_params(param_raw)
    ips = parse_ip_list(ip_raw)
    if not ips:
        raise SystemExit(f"[{stage}] empty job_ip_list after substitution: {ip_raw!r}")
    missing = [ip for ip in ips if ip not in ip_map]
    if missing:
        raise SystemExit(f"[{stage}] no container mapping for IPs: {missing}")

    log(f"==> SOPS stage [{stage}] targets={ips} timeout={timeout}s args={params}")
    results: dict[str, tuple[int, str]] = {}

    def _one(ip: str) -> tuple[str, int, str]:
        code, text = run_on_container(ip_map[ip], script, params, timeout, stage, ip)
        return ip, code, text

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(ips))) as pool:
        futs = [pool.submit(_one, ip) for ip in ips]
        for fut in concurrent.futures.as_completed(futs):
            ip, code, text = fut.result()
            results[ip] = (code, text)
            print(text, end="" if text.endswith("\n") else "\n", flush=True)

    stage_log = log_dir / f"{node['id']}.log"
    stage_log.write_text("".join(results[ip][1] for ip in ips))
    failed = [(ip, results[ip][0]) for ip in ips if results[ip][0] != 0]
    if failed:
        detail = ", ".join(f"{ip} exit={code}" for ip, code in failed)
        raise SystemExit(f"[DELIVERY FAILED][{stage}] {detail}")
    log(f"<== SOPS stage [{stage}] OK")


def parse_ip_map(raw: str | None) -> dict[str, str]:
    if not raw:
        return dict(DEFAULT_IP_MAP)
    out: dict[str, str] = {}
    for item in raw.split(","):
        ip, _, name = item.partition("=")
        ip, name = ip.strip(), name.strip()
        if not ip or not name:
            raise SystemExit(f"invalid --ip-map item: {item!r}")
        out[ip] = name
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a SOPS schema v1 YAML via docker exec")
    parser.add_argument("--yaml", required=True, type=Path, help="SOPS YAML path")
    parser.add_argument("--ip-map", default="", help="ip=container,ip=container")
    parser.add_argument("--log-dir", type=Path, default=Path("/tmp/sops-kafka-delivery"))
    parser.add_argument("--from-stage", default="", help="skip until this stage_name")
    parser.add_argument("--dry-run", action="store_true", help="print stage plan only")
    args = parser.parse_args()

    doc = load_yaml(args.yaml)
    consts = constants_map(doc)
    ip_map = parse_ip_map(args.ip_map or None)
    activities = walk_activities(doc)
    if not activities:
        raise SystemExit("no ServiceActivity nodes found")

    args.log_dir.mkdir(parents=True, exist_ok=True)
    meta = doc.get("meta") or {}
    log(f"SOPS delivery start: {meta.get('name')} ({meta.get('id')})")
    log(f"YAML={args.yaml} nodes={len(activities)} log_dir={args.log_dir}")

    started = not args.from_stage
    for node in activities:
        stage = node.get("stage_name") or node["id"]
        if not started:
            if stage == args.from_stage:
                started = True
            else:
                log(f"-- skip [{stage}]")
                continue
        if args.dry_run:
            data = node["component"]["data"]
            ips = parse_ip_list(substitute(str(data["job_ip_list"]["value"]), consts))
            params = parse_params(substitute(str(data["job_script_param"]["value"]), consts))
            log(f"[dry-run] [{stage}] targets={ips} args={params}")
            continue
        run_stage(node, consts, ip_map, args.log_dir)

    log("SOPS delivery SUCCESS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.TimeoutExpired as exc:
        raise SystemExit(f"[DELIVERY FAILED] docker exec timed out: {exc}") from exc
    except KeyboardInterrupt:
        raise SystemExit(130)
