#!/usr/bin/env bash
# Scenario D01: Simulate single-node JOB unreachable (do not run collector on one host)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
BLOCKED_HOST="${BLOCKED_HOST:-10.10.26.146}"
COLLECTOR_PORT="${COLLECTOR_PORT:-22}"

case "${ACTION}" in
  inject)
    log "block collector access to ${BLOCKED_HOST}:${COLLECTOR_PORT}"
    run_on_target "
      iptables -C OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${COLLECTOR_PORT} -j DROP 2>/dev/null || \
      iptables -A OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${COLLECTOR_PORT} -j DROP
    "
    save_state blocked_host "${BLOCKED_HOST}"
    log "run diagnosis from collector; expect not_received for that node only"
    ;;
  recover)
    BLOCKED_HOST="$(load_state blocked_host "${BLOCKED_HOST}")"
    run_on_target "
      iptables -D OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${COLLECTOR_PORT} -j DROP 2>/dev/null || true
    "
    ;;
  *)
    echo "Usage: BLOCKED_HOST=10.10.26.146 $0 [inject|recover]"; exit 1;;
esac
