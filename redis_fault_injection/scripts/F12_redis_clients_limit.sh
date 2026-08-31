#!/usr/bin/env bash
# Scenario F12/F13: Redis maxclients limit / restore
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
MAXCLIENTS="${MAXCLIENTS:-10}"
parse_duration

case "${ACTION}" in
  inject)
    orig="$(redis_cmd "${NODE}" CONFIG GET maxclients | awk 'NR==2{print}')"
    save_state maxclients_orig "${orig}"
    save_state maxclients_node "${NODE}"
    redis_cmd "${NODE}" CONFIG SET maxclients "${MAXCLIENTS}" >/dev/null
    log "set maxclients=${MAXCLIENTS} on ${NODE}, original=${orig}"
    host="${NODE%%:*}"; port="${NODE##*:}"
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      pids=()
      while (( SECONDS < end )); do
        for _ in \$(seq 1 20); do
          redis-cli -h ${host} -p ${port} PING >/dev/null 2>&1 &
          pids+=(\$!)
        done
        sleep 1
      done
      for pid in \"\${pids[@]}\"; do kill \$pid 2>/dev/null || true; done
    " &
    echo $! > "$(background_pid_file clients_flood)"
    log "expected: rejected_connections / max number of clients reached"
    ;;
  recover)
    NODE="$(load_state maxclients_node "$(first_node)")"
    orig="$(load_state maxclients_orig "10000")"
    stop_background clients_flood
    redis_cmd "${NODE}" CONFIG SET maxclients "${orig}" >/dev/null || true
    log "restored maxclients=${orig} on ${NODE}"
    ;;
  *)
    echo "Usage: NODE=ip:port MAXCLIENTS=10 $0 [inject|recover]"; exit 1;;
esac
