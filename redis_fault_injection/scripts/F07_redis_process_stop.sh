#!/usr/bin/env bash
# Scenario F07/F08: Stop / start redis-server on one node
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
host="${NODE%%:*}"
port="${NODE##*:}"

case "${ACTION}" in
  inject)
    log "stop redis on ${NODE}"
    run_on_target "redis-cli -h ${host} -p ${port} SHUTDOWN NOSAVE 2>/dev/null || systemctl stop redis 2>/dev/null || pkill -f 'redis-server.*:${port}' || true"
    save_state redis_stop_node "${NODE}"
    log "expected: process/port/ping/cluster slot signals on ${NODE}"
    ;;
  recover)
    NODE="$(load_state redis_stop_node "${NODE}")"
    log "start redis on ${NODE}"
    run_on_target "systemctl start redis 2>/dev/null || redis-server /etc/redis/redis.conf 2>/dev/null || true"
    ;;
  *)
    echo "Usage: NODE=ip:port $0 [inject|recover]"; exit 1;;
esac
