#!/usr/bin/env bash
# Scenario F17: Cache expire / cold cache (ChaosBlade cache-expire equivalent)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
KEY="${KEY:-}"
EXPIRE_AFTER="${EXPIRE_AFTER:-0}"

case "${ACTION}" in
  inject)
    if [[ -n "${KEY}" ]]; then
      log "expire key ${KEY} on ${NODE}"
      if [[ "${EXPIRE_AFTER}" == "0" ]]; then
        redis_cmd "${NODE}" DEL "${KEY}" >/dev/null || true
      else
        redis_cmd "${NODE}" EXPIRE "${KEY}" "${EXPIRE_AFTER}" >/dev/null
      fi
    else
      log "expire ALL keys on ${NODE} (destructive in lab only)"
      redis_cmd "${NODE}" FLUSHDB >/dev/null
    fi
    log "expected: cache miss storm / refill latency (application-facing)"
    ;;
  recover)
    log "no automatic key restore; reload application cache or restore from backup"
    ;;
  *)
    echo "Usage: NODE=ip:port [KEY=name] $0 inject"; exit 1;;
esac
