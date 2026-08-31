#!/usr/bin/env bash
# Scenario F10/F11: Redis maxmemory limit (OOM / eviction) / restore
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
MAXMEMORY="${MAXMEMORY:-64mb}"
parse_duration

case "${ACTION}" in
  inject)
    orig="$(redis_cmd "${NODE}" CONFIG GET maxmemory | awk 'NR==2{print}')"
    save_state maxmemory_orig "${orig}"
    save_state maxmemory_node "${NODE}"
    redis_cmd "${NODE}" CONFIG SET maxmemory "${MAXMEMORY}" >/dev/null
    log "set maxmemory=${MAXMEMORY} on ${NODE}, original=${orig}"
    log "fill keys to trigger OOM/eviction if needed"
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      i=0
      while (( SECONDS < end )); do
        redis-cli -h ${NODE%%:*} -p ${NODE##*:} SET fault:fill:\$i \$(head -c 4096 /dev/zero | tr '\0' 'x') >/dev/null 2>&1 || break
        i=\$((i+1))
      done
    " &
    echo $! > "$(background_pid_file maxmemory_fill)"
    log "expected: Redis OOM write reject / evicted_keys / MISCONF if persistence blocked"
    ;;
  recover)
    NODE="$(load_state maxmemory_node "$(first_node)")"
    orig="$(load_state maxmemory_orig "0")"
    stop_background maxmemory_fill
    redis_cmd "${NODE}" CONFIG SET maxmemory "${orig}" >/dev/null || true
    log "restored maxmemory=${orig} on ${NODE}"
    ;;
  *)
    echo "Usage: NODE=ip:port MAXMEMORY=64mb $0 [inject|recover]"; exit 1;;
esac
