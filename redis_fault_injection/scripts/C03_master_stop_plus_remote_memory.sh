#!/usr/bin/env bash
# Scenario C03: Master stop on one node + memory pressure on another
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
STOP_NODE="${STOP_NODE:-10.10.26.144:6381}"
MEM_NODE="${MEM_NODE:-10.10.26.146:6381}"

case "${ACTION}" in
  inject)
    NODE="${STOP_NODE}" "${SCRIPT_DIR}/F07_redis_process_stop.sh" inject
    TARGET_HOST="${MEM_NODE%%:*}" "${SCRIPT_DIR}/F04_host_memory_stress.sh" inject
    log "run diagnosis; expect continuity S1 primary, memory S3 secondary"
    ;;
  recover)
    NODE="${STOP_NODE}" "${SCRIPT_DIR}/F07_redis_process_stop.sh" recover
    TARGET_HOST="${MEM_NODE%%:*}" "${SCRIPT_DIR}/F04_host_memory_stress.sh" recover
    ;;
  *)
    echo "Usage: $0 [inject|recover]"; exit 1;;
esac
