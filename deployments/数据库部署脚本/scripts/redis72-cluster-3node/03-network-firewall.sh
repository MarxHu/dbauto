#!/usr/bin/env bash
# Redis Cluster - 防火墙放行 + 节点间连通性预检
set -euo pipefail

REDIS_PORT="${REDIS_PORT:-6379}"
CLUSTER_BUS_PORT="${CLUSTER_BUS_PORT:-16379}"

log() { echo "[$(date '+%F %T')][网络][$HOSTNAME] $*"; }

open_firewall_port() {
  local port="$1"
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

log "本机放行 Redis 端口 ${REDIS_PORT}/${CLUSTER_BUS_PORT}"
open_firewall_port "${REDIS_PORT}"
open_firewall_port "${CLUSTER_BUS_PORT}"

log "本机防火墙配置完成（节点间连通性在 07-wait-nodes 阶段检查）"
