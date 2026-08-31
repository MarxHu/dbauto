#!/usr/bin/env bash
# Scenario F18: Cache penetration (ChaosMesh cache-penetration equivalent)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
REQUEST_COUNT="${REQUEST_COUNT:-10000}"
parse_duration

case "${ACTION}" in
  inject)
    host="${NODE%%:*}"; port="${NODE##*:}"
    log "cache penetration on ${NODE}, requests=${REQUEST_COUNT}, duration=${DURATION}s"
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      sent=0
      while (( SECONDS < end )) && (( sent < ${REQUEST_COUNT} )); do
        redis-cli -h ${host} -p ${port} GET fault:missing:\$RANDOM >/dev/null 2>&1 || true
        sent=\$((sent+1))
      done
    " &
    echo $! > "$(background_pid_file cache_penetration)"
    log "expected: high GET miss rate; Redis itself may stay healthy"
    ;;
  recover)
    stop_background cache_penetration
    ;;
  *)
    echo "Usage: NODE=ip:port REQUEST_COUNT=10000 $0 [inject|recover]"; exit 1;;
esac
