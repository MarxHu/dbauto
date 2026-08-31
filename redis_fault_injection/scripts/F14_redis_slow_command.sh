#!/usr/bin/env bash
# Scenario F14: Slow command injection via DEBUG SLEEP (lab only)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
SLEEP_MS="${SLEEP_MS:-3000}"
parse_duration
INTERVAL="${INTERVAL:-5}"

case "${ACTION}" in
  inject)
    log "inject slow commands on ${NODE} for ${DURATION}s"
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )); do
        redis-cli -h ${NODE%%:*} -p ${NODE##*:} DEBUG SLEEP ${SLEEP_MS} >/dev/null 2>&1 || true
        sleep ${INTERVAL}
      done
    " &
    echo $! > "$(background_pid_file slow_cmd)"
    log "expected: slowlog entries in recent 15m window"
    ;;
  recover)
    stop_background slow_cmd
    ;;
  *)
    echo "Usage: NODE=ip:port $0 [inject|recover]"; exit 1;;
esac
