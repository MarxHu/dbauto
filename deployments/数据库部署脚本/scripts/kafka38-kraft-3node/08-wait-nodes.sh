#!/usr/bin/env bash
# Kafka KRaft 三节点 - 等待全部 Broker 就绪
set -euo pipefail

NODE1="${NODE1:?}"
NODE2="${NODE2:?}"
NODE3="${NODE3:?}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/kafka/3.8.1}"
KAFKA_PORT="${KAFKA_PORT:-9092}"
CONTROLLER_PORT="${CONTROLLER_PORT:-9093}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-180}"

kafka_broker_api="${INSTALL_PREFIX}/bin/kafka-broker-api-versions.sh"

log() { echo "[$(date '+%F %T')][等待全部节点就绪][$HOSTNAME] $*"; }
error() { echo "[ERROR][等待全部节点就绪] $*" >&2; exit 1; }

wait_port() {
  local host=$1 port=$2
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
      log "${host}:${port} 端口可达"
      return 0
    fi
    sleep 2
  done
  error "等待 ${host}:${port} 超时 (${WAIT_TIMEOUT_SEC}s)"
}

wait_broker_api() {
  local host=$1
  local bootstrap="${host}:${KAFKA_PORT}"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  while (( SECONDS < deadline )); do
    if "${kafka_broker_api}" --bootstrap-server "${bootstrap}" >/dev/null 2>&1; then
      log "${bootstrap} Broker API 就绪"
      return 0
    fi
    sleep 3
  done
  error "等待 ${bootstrap} Broker API 超时 (${WAIT_TIMEOUT_SEC}s)"
}

[[ -x "${kafka_broker_api}" ]] || error "缺少 ${kafka_broker_api}"

for node in "${NODE1}" "${NODE2}" "${NODE3}"; do
  wait_port "${node}" "${KAFKA_PORT}"
  wait_port "${node}" "${CONTROLLER_PORT}"
done

for node in "${NODE1}" "${NODE2}" "${NODE3}"; do
  wait_broker_api "${node}"
done

log "全部节点已就绪"
