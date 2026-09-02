#!/usr/bin/env bash
# Kafka KRaft 三节点 - 启动 kafka
set -euo pipefail

log() { echo "[$(date '+%F %T')][启动kafka][$HOSTNAME] $*"; }
error() { echo "[ERROR][启动kafka][$HOSTNAME] $*" >&2; exit 1; }

systemctl restart kafka
sleep 5
systemctl is-active --quiet kafka || error "kafka.service 未 active"
log "kafka.service active"
