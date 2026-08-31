#!/usr/bin/env bash
# Redis Cluster 三节点 - 环境预检
set -euo pipefail

REDIS_PORT="${REDIS_PORT:-6379}"
CLUSTER_BUS_PORT="${CLUSTER_BUS_PORT:-16379}"
NOFILE_MIN="${NOFILE_MIN:-65535}"

log() { echo "[$(date '+%F %T')][环境预检][$HOSTNAME] $*"; }

log "检查端口 ${REDIS_PORT}/${CLUSTER_BUS_PORT}"
for port in "${REDIS_PORT}" "${CLUSTER_BUS_PORT}"; do
  if ss -lnt | awk '{print $4}' | grep -q ":${port}$"; then
    echo "[ERROR] 端口 ${port} 已被占用" >&2
    exit 1
  fi
done

log "检查编译依赖 gcc/make/tcl"
for cmd in gcc make tclsh wget curl tar; do
  command -v "${cmd}" >/dev/null || { echo "[ERROR] 缺少命令: ${cmd}" >&2; exit 1; }
done

log "检查 ulimit nofile >= ${NOFILE_MIN}"
current_nofile="$(ulimit -n)"
if (( current_nofile < NOFILE_MIN )); then
  echo "[ERROR] ulimit -n=${current_nofile}，需要 >= ${NOFILE_MIN}" >&2
  exit 1
fi

log "检查是否已有 redis-server 进程冲突"
if pgrep -x redis-server >/dev/null 2>&1; then
  echo "[ERROR] 已存在 redis-server 进程，请先清理" >&2
  exit 1
fi

log "环境预检通过"
