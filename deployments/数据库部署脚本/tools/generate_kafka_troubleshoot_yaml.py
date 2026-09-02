#!/usr/bin/env python3
"""Wrapper: generate Kafka troubleshooting SOPS YAML."""
import runpy
from pathlib import Path

runpy.run_path(
    str(Path(__file__).resolve().parents[3] / "troubleshooting" / "kafka" / "tools" / "generate_yaml.py"),
    run_name="__main__",
)
