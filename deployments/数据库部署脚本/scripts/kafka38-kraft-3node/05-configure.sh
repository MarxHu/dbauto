#!/usr/bin/env bash
# Kafka KRaft 三节点 - 生成配置并注册 systemd 服务
set -euo pipefail

KAFKA_VERSION="${KAFKA_VERSION:-3.8.1}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/kafka/${KAFKA_VERSION}}"
KAFKA_PORT="${KAFKA_PORT:-9092}"
CONTROLLER_PORT="${CONTROLLER_PORT:-9093}"
NODE1="${NODE1:?}"
NODE2="${NODE2:?}"
NODE3="${NODE3:?}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-3}"
MIN_INSYNC_REPLICAS="${MIN_INSYNC_REPLICAS:-2}"
KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:--Xms1g -Xmx1g}"

CONF_DIR="${CONF_DIR:-/etc/kafka}"
DATA_DIR="${DATA_DIR:-/var/lib/kafka/data}"
LOG_DIR="${LOG_DIR:-/var/log/kafka}"

log() { echo "[$(date '+%F %T')][生成配置与systemd][$HOSTNAME] $*"; }
error() { echo "[ERROR][生成配置与systemd][$HOSTNAME] $*" >&2; exit 1; }

node_id=""
case "${NODE_IP}" in
  "${NODE1}") node_id=1 ;;
  "${NODE2}") node_id=2 ;;
  "${NODE3}") node_id=3 ;;
  *) error "本机 IP ${NODE_IP} 不在节点列表中: ${NODE1},${NODE2},${NODE3}" ;;
esac

voters="1@${NODE1}:${CONTROLLER_PORT},2@${NODE2}:${CONTROLLER_PORT},3@${NODE3}:${CONTROLLER_PORT}"
mkdir -p "${CONF_DIR}" "${DATA_DIR}" "${LOG_DIR}"

cat > "${CONF_DIR}/server.properties" <<EOF
process.roles=broker,controller
node.id=${node_id}
controller.quorum.voters=${voters}
listeners=PLAINTEXT://${NODE_IP}:${KAFKA_PORT},CONTROLLER://${NODE_IP}:${CONTROLLER_PORT}
advertised.listeners=PLAINTEXT://${NODE_IP}:${KAFKA_PORT}
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER
num.network.threads=8
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=${DATA_DIR}
num.partitions=3
num.recovery.threads.per.data.dir=1
offsets.topic.replication.factor=${REPLICATION_FACTOR}
transaction.state.log.replication.factor=${REPLICATION_FACTOR}
transaction.state.log.min.isr=${MIN_INSYNC_REPLICAS}
default.replication.factor=${REPLICATION_FACTOR}
min.insync.replicas=${MIN_INSYNC_REPLICAS}
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
group.initial.rebalance.delay.ms=0
auto.create.topics.enable=false
delete.topic.enable=true
EOF

cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka ${KAFKA_VERSION} KRaft Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=LOG_DIR=${LOG_DIR}
Environment=KAFKA_HEAP_OPTS=${KAFKA_HEAP_OPTS}
ExecStart=${INSTALL_PREFIX}/bin/kafka-server-start.sh ${CONF_DIR}/server.properties
ExecStop=/bin/kill -TERM \$MAINPID
Restart=always
RestartSec=5
LimitNOFILE=65535
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kafka
log "配置写入 ${CONF_DIR}/server.properties (node.id=${node_id})"
