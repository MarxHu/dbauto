#!/usr/bin/env bash
# Scenario F02/F03: Host CPU sustained stress / recovery
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
parse_duration

case "${ACTION}" in
  inject)
    require_cmd stress-ng
    log "inject host CPU stress for ${DURATION}s on target=${TARGET_HOST:-localhost}"
    run_on_target "nohup stress-ng --cpu 0 --cpu-load 90 --timeout ${DURATION}s >/tmp/redis_fault_cpu.log 2>&1 & echo \$! > /tmp/redis_fault_cpu.pid"
    log "expected: host_cpu_used_pct_avg>=80 on injected host"
    ;;
  recover)
    log "recover host CPU stress"
    run_on_target "if [[ -f /tmp/redis_fault_cpu.pid ]]; then kill \$(cat /tmp/redis_fault_cpu.pid) 2>/dev/null || true; rm -f /tmp/redis_fault_cpu.pid; fi; pkill -f 'stress-ng --cpu' 2>/dev/null || true"
    ;;
  *)
    echo "Usage: $0 [inject|recover]"; exit 1;;
esac
