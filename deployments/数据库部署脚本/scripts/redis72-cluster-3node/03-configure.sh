#!/usr/bin/env bash
# Redis Cluster 三节点 - 生成配置并注册 systemd 服务
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-7.2.16}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/redis/${REDIS_VERSION}}"
REDIS_PASSWORD="${REDIS_PASSWORD:-Redis@1314}"
REDIS_PORT="${REDIS_PORT:-6379}"
CLUSTER_BUS_PORT="${CLUSTER_BUS_PORT:-16379}"
CLUSTER_NODE_TIMEOUT_MS="${CLUSTER_NODE_TIMEOUT_MS:-15000}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

CONF_DIR="${CONF_DIR:-/etc/redis}"
DATA_DIR="${DATA_DIR:-/var/lib/redis/${REDIS_PORT}}"
LOG_DIR="${LOG_DIR:-/var/log/redis}"

log() { echo "[$(date '+%F %T')][配置][$HOSTNAME] $*"; }

mkdir -p "${CONF_DIR}" "${DATA_DIR}" "${LOG_DIR}"

cat > "${CONF_DIR}/redis.conf" <<EOF
bind 0.0.0.0
port ${REDIS_PORT}
protected-mode yes
daemonize no
supervised systemd
pidfile /var/run/redis_${REDIS_PORT}.pid
logfile ${LOG_DIR}/redis.log
dir ${DATA_DIR}
appendonly yes
appendfsync everysec
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}
tcp-keepalive 300
timeout 0
maxmemory-policy noeviction
cluster-enabled yes
cluster-config-file nodes-${REDIS_PORT}.conf
cluster-node-timeout ${CLUSTER_NODE_TIMEOUT_MS}
cluster-require-full-coverage yes
cluster-announce-ip ${NODE_IP}
cluster-announce-port ${REDIS_PORT}
cluster-announce-bus-port ${CLUSTER_BUS_PORT}
EOF

cat > /etc/systemd/system/redis.service <<EOF
[Unit]
Description=Redis ${REDIS_VERSION} Cluster Node
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=${INSTALL_PREFIX}/bin/redis-server ${CONF_DIR}/redis.conf
ExecStop=${INSTALL_PREFIX}/bin/redis-cli -a '${REDIS_PASSWORD}' -p ${REDIS_PORT} shutdown
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable redis
log "配置写入 ${CONF_DIR}/redis.conf"
