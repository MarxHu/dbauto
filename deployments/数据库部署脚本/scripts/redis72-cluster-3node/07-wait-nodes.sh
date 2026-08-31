#!/usr/bin/env bash
# Redis Cluster - 等待所有节点 redis-server 就绪（在 create 前执行）
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-7.2.16}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/redis/${REDIS_VERSION}}"
REDIS_PASSWORD="${REDIS_PASSWORD:-Redis@1314}"
REDIS_PORT="${REDIS_PORT:-6379}"
CLUSTER_BUS_PORT="${CLUSTER_BUS_PORT:-16379}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-120}"

NODE1="${NODE1:-172.30.0.11}"
NODE2="${NODE2:-172.30.0.12}"
NODE3="${NODE3:-172.30.0.13}"

CLI="${INSTALL_PREFIX}/bin/redis-cli"
export REDISCLI_AUTH="${REDIS_PASSWORD}"

log() { echo "[$(date '+%F %T')][等待节点][$HOSTNAME] $*"; }

wait_node() {
  local host="$1"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if timeout 3 bash -c "echo >/dev/tcp/${host}/${REDIS_PORT}" 2>/dev/null \
      && timeout 3 bash -c "echo >/dev/tcp/${host}/${CLUSTER_BUS_PORT}" 2>/dev/null \
      && "${CLI}" -h "${host}" -p "${REDIS_PORT}" PING 2>/dev/null | grep -q PONG; then
      log "${host}:${REDIS_PORT}/${CLUSTER_BUS_PORT} 就绪"
      return 0
    fi
    sleep 2
  done
  echo "[ERROR] 等待 ${host} 超时 (${WAIT_TIMEOUT_SEC}s)，请检查防火墙/安全组" >&2
  return 1
}

for node in "${NODE1}" "${NODE2}" "${NODE3}"; do
  wait_node "${node}"
done

log "全部节点已就绪，可执行 cluster create"
