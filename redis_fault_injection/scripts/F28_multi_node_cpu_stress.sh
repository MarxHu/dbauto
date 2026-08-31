#!/usr/bin/env bash
# Scenario F28: Multi-node host CPU stress
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
parse_duration
NODES="${NODES:-${REDIS_NODES}}"

case "${ACTION}" in
  inject)
    for node in ${NODES}; do
      host="${node%%:*}"
      log "start CPU stress on ${host}"
      TARGET_HOST="${host}" "${SCRIPT_DIR}/F02_host_cpu_stress.sh" inject
    done
    ;;
  recover)
    for node in ${NODES}; do
      host="${node%%:*}"
      TARGET_HOST="${host}" "${SCRIPT_DIR}/F02_host_cpu_stress.sh" recover
    done
    ;;
  *)
    echo "Usage: $0 [inject|recover]"; exit 1;;
esac
