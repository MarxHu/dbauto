#!/usr/bin/env bash
# 降级清洗（v2）：采集覆盖不足时仍产出可给 AI 的最小包
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}; node2=${2:-}; node3=${3:-}
KAFKA_INSTALL_PREFIX=${4:-/opt/kafka/3.8.1}
kafka_port=${5:-9092}
controller_port=${6:-9093}
run_id=${7:-manual}

# Reuse cleanser with degraded profile tag
exec "${SCRIPT_DIR}/cleanse_artifacts.sh" \
  "$node1" "$node2" "$node3" "$KAFKA_INSTALL_PREFIX" \
  "$kafka_port" "$controller_port" "$run_id" "v2-degraded"
