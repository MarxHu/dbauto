#!/usr/bin/env bash
# Scenario F24/F25: Persistence failure by making data dir read-only / restore
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"

case "${ACTION}" in
  inject)
    log "make ${DATA_DIR} read-only on target host for persistence failure"
    run_on_target "
      chmod -R a-w ${DATA_DIR}
      redis-cli -h ${NODE%%:*} -p ${NODE##*:} CONFIG SET stop-writes-on-bgsave-error yes >/dev/null 2>&1 || true
      redis-cli -h ${NODE%%:*} -p ${NODE##*:} BGSAVE >/dev/null 2>&1 || true
    "
    save_state persistence_dir "${DATA_DIR}"
    log "expected: persistence_failure logs / MISCONF if stop-writes enabled"
    ;;
  recover)
    DATA_DIR="$(load_state persistence_dir "${DATA_DIR}")"
    run_on_target "chmod -R u+w ${DATA_DIR} 2>/dev/null || chmod -R 755 ${DATA_DIR}"
    log "restored write permission on ${DATA_DIR}"
    ;;
  *)
    echo "Usage: NODE=ip:port REDIS_DATA_DIR=/var/lib/redis $0 [inject|recover]"; exit 1;;
esac
