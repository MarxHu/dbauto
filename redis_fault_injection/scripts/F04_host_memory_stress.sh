#!/usr/bin/env bash
# Scenario F04/F05: Host memory pressure / recovery
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
parse_duration
MEM_WORKERS="${MEM_WORKERS:-2}"
MEM_PERCENT="${MEM_PERCENT:-85}"

case "${ACTION}" in
  inject)
    require_cmd stress-ng
    log "inject host memory stress for ${DURATION}s, workers=${MEM_WORKERS}, percent=${MEM_PERCENT}"
    run_on_target "nohup stress-ng --vm ${MEM_WORKERS} --vm-bytes ${MEM_PERCENT}% --timeout ${DURATION}s >/tmp/redis_fault_mem.log 2>&1 & echo \$! > /tmp/redis_fault_mem.pid"
    log "expected: memory_available_pct<=15 on injected host"
    ;;
  recover)
    log "recover host memory stress"
    run_on_target "if [[ -f /tmp/redis_fault_mem.pid ]]; then kill \$(cat /tmp/redis_fault_mem.pid) 2>/dev/null || true; rm -f /tmp/redis_fault_mem.pid; fi; pkill -f 'stress-ng --vm' 2>/dev/null || true"
    ;;
  *)
    echo "Usage: $0 [inject|recover]"; exit 1;;
esac
