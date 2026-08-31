#!/usr/bin/env bash
# Scenario F29: Seed historical MISCONF counter without current activity
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-10.10.26.146:6381}"
DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"

case "${ACTION}" in
  inject)
    log "create historical MISCONF on ${NODE}, then restore persistence"
    run_on_target "
      redis-cli -h ${NODE%%:*} -p ${NODE##*:} CONFIG SET stop-writes-on-bgsave-error yes >/dev/null 2>&1 || true
      chmod -R a-w ${DATA_DIR}
      redis-cli -h ${NODE%%:*} -p ${NODE##*:} SET historical:misconf:seed 1 >/dev/null 2>&1 || true
      chmod -R u+w ${DATA_DIR}
      redis-cli -h ${NODE%%:*} -p ${NODE##*:} CONFIG SET stop-writes-on-bgsave-error yes >/dev/null 2>&1 || true
    "
    log "expected later: cumulative MISCONF in context_signals as historical_inactive"
    ;;
  recover)
    log "historical counter remains until redis restart; no destructive cleanup required"
    ;;
  *)
    echo "Usage: NODE=10.10.26.146:6381 $0 inject"; exit 1;;
esac
