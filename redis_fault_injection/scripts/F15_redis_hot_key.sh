#!/usr/bin/env bash
# Scenario F15: Hot key / hot shard traffic
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
KEY="${KEY:-fault:hotkey}"
THREADS="${THREADS:-8}"
parse_duration

case "${ACTION}" in
  inject)
    host="${NODE%%:*}"; port="${NODE##*:}"
    log "hot key ${KEY} on ${NODE}, threads=${THREADS}, duration=${DURATION}s"
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      for t in \$(seq 1 ${THREADS}); do
        (
          i=0
          while (( SECONDS < end )); do
            redis-cli -h ${host} -p ${port} SET ${KEY}:\$i hot >/dev/null 2>&1
            redis-cli -h ${host} -p ${port} GET ${KEY}:\$i >/dev/null 2>&1
            i=\$((i+1))
          done
        ) &
      done
      wait
    " &
    echo $! > "$(background_pid_file hot_key)"
    log "expected: hot shard / redis process CPU / latency (L2 acceptable)"
    ;;
  recover)
    stop_background hot_key
    ;;
  *)
    echo "Usage: NODE=ip:port KEY=fault:hotkey $0 [inject|recover]"; exit 1;;
esac
