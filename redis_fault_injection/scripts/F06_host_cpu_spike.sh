#!/usr/bin/env bash
# Scenario F06: CPU spike only (avg<80, max>=80) - shorter high burst
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
parse_duration
BURST_SEC="${BURST_SEC:-2}"

case "${ACTION}" in
  inject)
    require_cmd stress-ng
    log "inject CPU spike burst ${BURST_SEC}s inside ${DURATION}s observation window"
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )); do
        stress-ng --cpu 0 --cpu-load 95 --timeout ${BURST_SEC}s >/dev/null 2>&1 || true
        sleep 20
      done
    " &
    echo $! > "$(background_pid_file cpu_spike)"
    log "expected: CPU spike attention candidate, not sustained primary"
    ;;
  recover)
    stop_background cpu_spike
    run_on_target "pkill -f 'stress-ng --cpu' 2>/dev/null || true"
    ;;
  *)
    echo "Usage: $0 [inject|recover]"; exit 1;;
esac
