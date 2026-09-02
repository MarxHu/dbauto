#!/usr/bin/env bash
# Kafka KRaft 三节点 - 防火墙放行
set -euo pipefail

KAFKA_PORT="${KAFKA_PORT:-9092}"
CONTROLLER_PORT="${CONTROLLER_PORT:-9093}"

log() { echo "[$(date '+%F %T')][防火墙放行][$HOSTNAME] $*"; }

open_firewall_port() {
  local port=$1
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    log "firewalld 已放行 ${port}/tcp"
  elif command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
    ufw allow "${port}/tcp" >/dev/null
    log "ufw 已放行 ${port}/tcp"
  else
    log "未检测到 active 的 firewalld/ufw，跳过本地防火墙配置"
  fi
}

open_firewall_port "${KAFKA_PORT}"
open_firewall_port "${CONTROLLER_PORT}"
log "本机防火墙配置完成"
