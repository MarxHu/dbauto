#!/usr/bin/env python3
"""Unit tests for ES cleanse cross-compare (no live cluster)."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import es_lib  # noqa: E402


IPS = ["10.10.26.144", "10.10.26.145", "10.10.26.146"]


def _write_facts(base: Path, ip: str, **kw) -> None:
    (base / f"facts.{ip}.json").write_text(json.dumps(kw, ensure_ascii=False), encoding="utf-8")
    master = {
        "node": ip,
        "local_master": kw.get("local_master", ""),
        "local_master_ip": kw.get("local_master_ip", ""),
        "http_ok": kw.get("http_ok", True),
        "auth_fail": kw.get("auth_fail", False),
        "is_elected": kw.get("is_elected", False),
    }
    (base / f"master.{ip}.json").write_text(json.dumps(master), encoding="utf-8")
    (base / f"metrics.{ip}.txt").write_text("ok\n", encoding="utf-8")
    (base / f"status.{ip}.txt").write_text("ok\n", encoding="utf-8")
    (base / f"config.{ip}.txt").write_text("ok\n", encoding="utf-8")


class CleanseTests(unittest.TestCase):
    def test_no_master_requires_all_three_empty(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            for ip in IPS:
                _write_facts(base, ip, local_master="", http_ok=True, process_up=True, listen_http=True)
            r = es_lib.cleanse(td, "t1", IPS, "v2")
            ids = {s[0] for s in r["signals"]}
            self.assertIn("ES191", ids)
            self.assertIn("ES050", ids)
            self.assertTrue((base / "summary.md").read_text().startswith("# ES 7.x"))

    def test_two_agree_one_empty_is_not_no_master(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            _write_facts(base, IPS[0], local_master="n1", local_master_ip=IPS[0], is_elected=True, http_ok=True)
            _write_facts(base, IPS[1], local_master="n1", local_master_ip=IPS[0], http_ok=True)
            _write_facts(base, IPS[2], local_master="", http_ok=True, listen_http=True, transport_ok=False)
            r = es_lib.cleanse(td, "t2", IPS, "v2")
            ids = {s[0] for s in r["signals"]}
            self.assertNotIn("ES191", ids)
            self.assertIn("ES051", ids)
            self.assertIn("ES199", ids)

    def test_missing_node_does_not_declare_cluster_no_master(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            _write_facts(base, IPS[0], local_master="", http_ok=True)
            _write_facts(base, IPS[1], local_master="", http_ok=True)
            r = es_lib.cleanse(td, "t3", IPS, "v2")
            ids = {s[0] for s in r["signals"]}
            self.assertNotIn("ES191", ids)
            self.assertIn("ES172", ids)
            self.assertIn("degraded", r["meta"]["coverage_status"])

    def test_yellow_three_nodes_is_alloc_not_down(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            health = {
                "status": "yellow",
                "number_of_nodes": 3,
                "unassigned_shards": 5,
                "delayed_unassigned_shards": 0,
                "number_of_pending_tasks": 0,
            }
            for ip in IPS:
                _write_facts(
                    base := Path(td),
                    ip,
                    local_master="n1",
                    local_master_ip=IPS[0],
                    is_elected=(ip == IPS[0]),
                    http_ok=True,
                    process_up=True,
                    listen_http=True,
                    cluster_health=health,
                )
            r = es_lib.cleanse(td, "t4", IPS, "v2")
            ids = {s[0] for s in r["signals"]}
            self.assertIn("ES192", ids)
            self.assertNotIn("ES190", ids)
            self.assertNotIn("ES191", ids)

    def test_heap_outlier(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            _write_facts(Path(td), IPS[0], local_master="n1", heap_pct=96, http_ok=True)
            _write_facts(Path(td), IPS[1], local_master="n1", heap_pct=50, http_ok=True)
            _write_facts(Path(td), IPS[2], local_master="n1", heap_pct=48, http_ok=True)
            r = es_lib.cleanse(td, "t5", IPS, "v2")
            ids = {s[0] for s in r["signals"]}
            self.assertIn("ES193", ids)
            self.assertNotIn("ES194", ids)


if __name__ == "__main__":
    unittest.main()
