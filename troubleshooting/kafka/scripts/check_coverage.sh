#!/usr/bin/env bash
# Map KF IDs in the catalog to inject actions / explicit N/A.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CATALOG="${ROOT}/troubleshooting/kafka/KAFKA_FAULT_SCENARIOS.md"
INJECT_DOCS="${ROOT}/kafka_fault_injection"
fail=0

ids=$(grep -oE '\*\*KF[0-9]{3}\*\*' "$CATALOG" | tr -d '*' | sort -u)
count=$(printf '%s\n' "$ids" | grep -c . || true)
echo "catalog unique IDs: ${count}"
[[ "$count" -ge 120 ]] || { echo "FAIL expected >=120 KF IDs"; fail=1; }

# IDs that must appear in injection command table or be marked N in catalog
missing=()
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  if grep -q "$id" "$INJECT_DOCS/KAFKA_FAULT_SCENARIOS.md" \
     || grep -q "$id" "$INJECT_DOCS/scripts/"*.sh \
     || grep -E "\*\*${id}\*\*.*\|\s*N\s*\|" "$CATALOG" >/dev/null; then
    continue
  fi
  # P or Y with inject action in catalog is ok even if not in command table
  if grep -E "\*\*${id}\*\*" "$CATALOG" | grep -qE '\| Y \||\| P \|'; then
    # still want either script mention or N/A section
    if ! grep -q "$id" "$INJECT_DOCS"/scripts/*.sh "$INJECT_DOCS"/KAFKA_FAULT_SCENARIOS.md; then
      missing+=("$id")
    fi
  fi
done <<<"$ids"

if ((${#missing[@]})); then
  echo "WARN injectable IDs not referenced in inject package: ${missing[*]}"
fi

# YAML v2 must include parallel collect + clean + ai
yaml="${ROOT}/troubleshooting/kafka/kafka38-kraft-troubleshoot-v2.yaml"
for needle in ParallelGateway ConvergeGateway 采集监控指标 数据清洗 AI诊断 ExclusiveGateway; do
  grep -q "$needle" "$yaml" || { echo "FAIL v2 yaml missing $needle"; fail=1; }
done

echo "coverage check done fail=${fail} missing_refs=${#missing[@]}"
exit "$fail"
