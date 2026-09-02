#!/usr/bin/env bash
# Kafka KRaft 三节点 - 等待全部 Broker 就绪
set -euo pipefail

NODE1="${NODE1:?}"
NODE2="${NODE2:?}"
NODE3="${NODE3:?}"
KAFKA_PORT="${KAFKA_PORT:-9092}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"

log() { echo "[$(date '+%F %T')][等待全部节点就绪][$HOSTNAME] $*"; }
error() { echo "[ERROR][等待全部节点就绪] $*" >&2; exit 1; }

wait_node() {
  local host=$1
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if timeout 3 bash -c "echo >/dev/tcp/${host}/${KAFKA_PORT}" 2>/dev/null; then
      log "${host}:${KAFKA_PORT} 端口可达"
      return 0
    fi
    sleep 2
  done
  error "等待 ${host} 超时 (${WAIT_TIMEOUT_SEC}s)"
}

for node in "${NODE1}" "${NODE2}" "${NODE3}"; do
  wait_node "${node}"
done
log "全部节点已就绪"
