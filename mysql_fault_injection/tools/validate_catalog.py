#!/usr/bin/env python3
"""Validate MySQL fault-injection catalogs against Redis mapping and the min fault set.

Reads markdown tables; fails if required IDs or Redis mappings are missing.
Does not execute injection.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INJECT_CATALOG = ROOT / "MYSQL_FAULT_SCENARIOS.md"
TS_CATALOG = ROOT.parent / "troubleshooting" / "mysql" / "MYSQL_FAULT_SCENARIOS.md"

# Redis catalog IDs that must appear in the mapping section (section 10).
REDIS_IDS = [
    "F01",
    "F02",
    "F04",
    "F06",
    "F07",
    "F09",
    "F10",
    "F12",
    "F14",
    "F15",
    "F16",
    "F17",
    "F18",
    "F19",
    "F20",
    "F22",
    "F24",
    "F26",
    "F28",
    "F29",
    "F30",
    "C01",
    "C02",
    "C03",
    "D01",
    "D02",
]

# Troubleshooting design §14.2 + inject catalog min set.
MIN_FAULT_IDS = [
    "MY001",
    "MY010",
    "MY030",
    "MY040",
    "MY041",
    "MY043",
    "MY044",
    "MY046",
    "MY061",
    "MY087",
    "MY102",
    "MY110",
    "MY130",
    "MY140",
    "MY162",
    "MY171",
    "MY190",
    "MY191",
    "MY193",
    "MY194",
    "MY195",
    "MY196",
    "MY197",
]

# IDs that must exist as inject actions in the CLI contract tables.
REQUIRED_ACTIONS = [
    "baseline",
    "cpu",
    "memory",
    "process-stop",
    "stop-io",
    "stop-sql",
    "long-trx",
    "semi-sync-wait-ack",
    "io-stress",
    "hide-tools",
    "binlog-purge",
    "replica-1062",
    "packet-loss",
    "repl-block",
]


def extract_ids(text: str, pattern: str) -> set[str]:
    return set(re.findall(pattern, text))


def fail(errors: list[str]) -> None:
    print("CATALOG_VALIDATE status=fail")
    for err in errors:
        print(f"ERROR: {err}")
    sys.exit(1)


def main() -> None:
    errors: list[str] = []
    if not INJECT_CATALOG.is_file():
        fail([f"missing {INJECT_CATALOG}"])
    if not TS_CATALOG.is_file():
        fail([f"missing {TS_CATALOG}"])

    inject = INJECT_CATALOG.read_text(encoding="utf-8")
    ts = TS_CATALOG.read_text(encoding="utf-8")

    mapping_marker = "## 10. Redis → MySQL 对照速查"
    if mapping_marker not in inject:
        errors.append("inject catalog missing Redis mapping section")
        mapping = ""
    else:
        mapping = inject.split(mapping_marker, 1)[1].split("\n## ", 1)[0]

    for rid in REDIS_IDS:
        if rid not in mapping:
            errors.append(f"Redis {rid} not in mapping table")

    inject_ids = extract_ids(inject, r"\bMY\d{3}(?:-[A-Z]+)?\b")
    ts_ids = extract_ids(ts, r"\bMY\d{3}\b")

    for mid in MIN_FAULT_IDS:
        if mid not in inject_ids:
            errors.append(f"min-fault {mid} missing from inject catalog")
        if mid not in ts_ids:
            errors.append(f"min-fault {mid} missing from troubleshooting catalog")

    for action in REQUIRED_ACTIONS:
        if f"--action {action}" not in inject and f"/ `{action}`" not in inject:
            # SCENARIOS + inject catalog should mention the action token
            if action not in inject:
                errors.append(f"CLI action {action!r} missing from inject catalog")

    na_required = ["自动 Failover", "Group Replication", "Slot"]
    if "## 9. 当前环境不做" not in inject:
        errors.append("inject catalog missing section 9 (out of scope)")
    else:
        section9 = inject.split("## 9. 当前环境不做", 1)[1].split("\n## ", 1)[0]
        for token in na_required:
            if token not in section9:
                errors.append(f"section 9 missing opt-out {token!r}")
    for token in ("F17", "F18", "MOVED", "CROSSSLOT"):
        if token not in inject:
            errors.append(f"expected opt-out mention {token!r}")

    # wait_count=1 trap must be documented
    if "wait_for_replica_count=1" not in inject and "wait_count=1" not in inject:
        errors.append("semi-sync wait_count=1 trap not documented")

    if "GTID_SUBSET" not in inject:
        errors.append("GTID_SUBSET rule missing")

    scripts_dir = ROOT / "scripts"
    required_scripts = [
        "preflight.sh",
        "inject_host.sh",
        "inject_mysql.sh",
        "inject_repl.sh",
        "inject_network.sh",
        "inject_disk.sh",
        "inject_composite.sh",
        "inject_degrade.sh",
    ]
    for name in required_scripts:
        path = scripts_dir / name
        if not path.is_file():
            errors.append(f"missing inject script {name}")
            continue
        body = path.read_text(encoding="utf-8")
        if name != "preflight.sh" and "emit_inject_result" not in body and "inject_pass" not in body:
            errors.append(f"{name} never emits inject result")

    script_blob = ""
    if scripts_dir.is_dir():
        script_blob = "\n".join(p.read_text(encoding="utf-8") for p in scripts_dir.glob("inject_*.sh"))
    for action in REQUIRED_ACTIONS:
        if f'"{action}")' not in script_blob and f"{action})" not in script_blob:
            errors.append(f"CLI action {action!r} not implemented in inject_*.sh")

    if not (ROOT / "lib" / "common.sh").is_file():
        errors.append("missing lib/common.sh")
    if not (ROOT / "run.sh").is_file():
        errors.append("missing run.sh")

    n_inject = len(inject_ids)
    n_ts = len(ts_ids)
    print(f"inject_catalog={INJECT_CATALOG.relative_to(ROOT.parent)}")
    print(f"troubleshoot_catalog={TS_CATALOG.relative_to(ROOT.parent)}")
    print(f"inject_my_ids={n_inject} ts_my_ids={n_ts} redis_mapped={len(REDIS_IDS)}")
    print(f"min_fault_ids={len(MIN_FAULT_IDS)} required_actions={len(REQUIRED_ACTIONS)}")
    if errors:
        fail(errors)
    print("CATALOG_VALIDATE status=pass")
    print("detail=redis mapping complete, min fault set present, CLI actions implemented")


if __name__ == "__main__":
    main()
