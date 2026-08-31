#!/usr/bin/env bash
# Redis Cluster 三节点 - 启动 redis-server
set -euo pipefail

log() { echo "[$(date '+%F %T')][启动][$HOSTNAME] $*"; }

systemctl restart redis
sleep 2
systemctl is-active --quiet redis
log "redis.service active"
