#!/usr/bin/env bash
# Scenario C01: Memory pressure + historical MISCONF background
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
MEMORY_NODE="${MEMORY_NODE:-10.10.26.144:6381}"
MISCONF_NODE="${MISCONF_NODE:-10.10.26.146:6381}"

case "${ACTION}" in
  inject)
    NODE="${MISCONF_NODE}" "${SCRIPT_DIR}/F29_seed_historical_misconf.sh" inject
    TARGET_HOST="${MEMORY_NODE%%:*}" "${SCRIPT_DIR}/F04_host_memory_stress.sh" inject
    log "run diagnosis; expect memory primary, historical MISCONF not displayed"
    ;;
  recover)
    TARGET_HOST="${MEMORY_NODE%%:*}" "${SCRIPT_DIR}/F04_host_memory_stress.sh" recover
    ;;
  *)
    echo "Usage: $0 [inject|recover]"; exit 1;;
esac
