#!/usr/bin/env bash
# Kafka KRaft 三节点 - 格式化本地存储
set -euo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/kafka/3.8.1}"
CLUSTER_ID="${CLUSTER_ID:?}"
CONF_DIR="${CONF_DIR:-/etc/kafka}"

log() { echo "[$(date '+%F %T')][KRaft存储格式化][$HOSTNAME] $*"; }
error() { echo "[ERROR][KRaft存储格式化][$HOSTNAME] $*" >&2; exit 1; }

storage_sh="${INSTALL_PREFIX}/bin/kafka-storage.sh"
[[ -x "${storage_sh}" ]] || error "缺少 kafka-storage.sh"
[[ -f "${CONF_DIR}/server.properties" ]] || error "缺少 ${CONF_DIR}/server.properties"

if "${storage_sh}" info -c "${CONF_DIR}/server.properties" 2>/dev/null | grep -q "already formatted"; then
  log "存储已格式化，跳过"
  exit 0
fi

"${storage_sh}" format -t "${CLUSTER_ID}" -c "${CONF_DIR}/server.properties" --ignore-formatted
log "KRaft 存储格式化完成"
