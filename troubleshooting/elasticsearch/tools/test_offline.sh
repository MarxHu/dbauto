#!/usr/bin/env bash
# Offline checks: cleanse unit tests, collectors exit 0 without ES, AI fail-closed, YAML timeouts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/tools/test_cleanse.py" -q
python3 "$ROOT/tools/generate_yaml.py" >/dev/null
export TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR:-/tmp/es-ts-offline}
RUN=offline
rm -rf "${TS_ARTIFACT_DIR}/${RUN}"
SCR="$ROOT/scripts"
bash "$SCR/collect_precheck.sh" 10.10.26.144 10.10.26.145 10.10.26.146 9200 9300 "$RUN" "" "" >/dev/null
bash "$SCR/collect_metrics.sh" 10.10.26.144 10.10.26.145 10.10.26.146 9200 9300 "$RUN" "" "" >/dev/null
bash "$SCR/collect_status.sh" 10.10.26.144 10.10.26.145 10.10.26.146 9200 9300 "$RUN" "" "" >/dev/null
bash "$SCR/collect_config.sh" 10.10.26.144 10.10.26.145 10.10.26.146 9200 9300 "$RUN" "" "" >/dev/null
bash "$SCR/collect_logs.sh" 10.10.26.144 10.10.26.145 10.10.26.146 9200 9300 "$RUN" "" "" >/dev/null
bash "$SCR/collect_hostnet.sh" 10.10.26.144 10.10.26.145 10.10.26.146 9200 9300 "$RUN" "" "" >/dev/null
bash "$SCR/cleanse_artifacts.sh" 10.10.26.144 10.10.26.145 10.10.26.146 9200 9300 "$RUN" v2 >/dev/null
test -f "${TS_ARTIFACT_DIR}/${RUN}/summary.md"
set +e
bash "$SCR/ai_diagnose.sh" 10.10.26.144 10.10.26.145 10.10.26.146 9200 9300 "$RUN" v2 "" >/dev/null 2>&1
ai_rc=$?
set -e
test "$ai_rc" -ne 0
python3 - <<PY
from pathlib import Path
import re
t = Path("$ROOT/elasticsearch717-troubleshoot.yaml").read_text()
vals = re.findall(r"job_script_timeout:\\n          value: '(\\d+)'", t)
assert set(vals) <= {"30", "120", "60"}, vals
assert t.count("ignore_error: false") == 1
print("offline_ok timeouts", vals, "ai_rc", $ai_rc)
PY
