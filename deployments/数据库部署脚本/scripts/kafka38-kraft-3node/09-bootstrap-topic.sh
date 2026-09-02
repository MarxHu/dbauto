#!/usr/bin/env bash
# Kafka KRaft 三节点 - 创建验收 Topic（仅首节点执行一次）
set -euo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/kafka/3.8.1}"
NODE1="${NODE1:?}"
KAFKA_PORT="${KAFKA_PORT:-9092}"
TOPIC_NAME="${TOPIC_NAME:-deploy-verify}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-3}"
PARTITIONS="${PARTITIONS:-3}"

kafka_topics="${INSTALL_PREFIX}/bin/kafka-topics.sh"
bootstrap="${NODE1}:${KAFKA_PORT}"

log() { echo "[$(date '+%F %T')][创建验收Topic][$HOSTNAME] $*"; }

if "${kafka_topics}" --bootstrap-server "${bootstrap}" --list 2>/dev/null | grep -qx "${TOPIC_NAME}"; then
  log "Topic ${TOPIC_NAME} 已存在，跳过"
  exit 0
fi

"${kafka_topics}" --bootstrap-server "${bootstrap}" \
  --create \
  --topic "${TOPIC_NAME}" \
  --partitions "${PARTITIONS}" \
  --replication-factor "${REPLICATION_FACTOR}" \
  --if-not-exists

log "Topic ${TOPIC_NAME} 创建完成"
