#!/usr/bin/env bash
# 降级清洗：采集覆盖不足时仍产出 summary.md
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}; node2=${2:-}; node3=${3:-}
http=${4:-9200}
transport=${5:-9300}
run_id=${6:-manual}
ES_USER=${7:-${ES_USER:-}}
ES_PASS=${8:-${ES_PASS:-}}

exec "${SCRIPT_DIR}/cleanse_artifacts.sh" \
  "$node1" "$node2" "$node3" "$http" "$transport" "$run_id" "v2-degraded" "$ES_USER" "$ES_PASS"
