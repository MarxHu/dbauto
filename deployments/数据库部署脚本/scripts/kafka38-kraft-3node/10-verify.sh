#!/usr/bin/env bash
# Kafka KRaft 三节点 - 部署验收
set -euo pipefail

INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/kafka/3.8.1}"
NODE1="${NODE1:?}"
NODE2="${NODE2:?}"
NODE3="${NODE3:?}"
KAFKA_PORT="${KAFKA_PORT:-9092}"
TOPIC_NAME="${TOPIC_NAME:-deploy-verify}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-3}"

bootstrap="${NODE1}:${KAFKA_PORT}"
kafka_topics="${INSTALL_PREFIX}/bin/kafka-topics.sh"
kafka_producer="${INSTALL_PREFIX}/bin/kafka-console-producer.sh"
kafka_consumer="${INSTALL_PREFIX}/bin/kafka-console-consumer.sh"
kafka_broker_api="${INSTALL_PREFIX}/bin/kafka-broker-api-versions.sh"

log() { echo "[$(date '+%F %T')][部署验收][$HOSTNAME] $*"; }
error() { echo "[ERROR][部署验收] $*" >&2; exit 1; }

log "检查 Broker API"
"${kafka_broker_api}" --bootstrap-server "${bootstrap}" >/dev/null

describe="$("${kafka_topics}" --bootstrap-server "${bootstrap}" --describe --topic "${TOPIC_NAME}")"
printf '%s\n' "${describe}"
echo "${describe}" | grep -q "Topic: ${TOPIC_NAME}" || error "Topic ${TOPIC_NAME} 不存在"
echo "${describe}" | grep -q "ReplicationFactor: ${REPLICATION_FACTOR}" \
  || error "副本因子不符合期望 ${REPLICATION_FACTOR}"

test_msg="sops-kafka-verify-$(date +%s)"
printf '%s\n' "${test_msg}" | "${kafka_producer}" \
  --bootstrap-server "${bootstrap}" \
  --topic "${TOPIC_NAME}" >/dev/null

consumed="$("${kafka_consumer}" \
  --bootstrap-server "${bootstrap}" \
  --topic "${TOPIC_NAME}" \
  --from-beginning \
  --max-messages 1 \
  --timeout-ms 15000 2>/dev/null | tail -n1)"
[[ "${consumed}" == "${test_msg}" ]] || error "消费验收失败: got=${consumed}"

for node in "${NODE1}" "${NODE2}" "${NODE3}"; do
  timeout 5 bash -c "echo >/dev/tcp/${node}/${KAFKA_PORT}" \
    || error "节点 ${node}:${KAFKA_PORT} 不可达"
done

log "验收通过"
