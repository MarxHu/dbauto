#!/usr/bin/env bash
# Scenario F01: Normal baseline - no fault, verify pipeline on healthy cluster.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

log "baseline check only; no fault injected"
for node in ${REDIS_NODES}; do
  redis_cmd "${node}" PING >/dev/null || die "node not healthy: ${node}"
  log "PING ok: ${node}"
done
log "run diagnosis pipeline now; expect no current CPU/memory signals"
