#!/usr/bin/env bash
# Redis Cluster - 在首节点创建三主零从集群（仅执行一次）
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-7.2.16}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/redis/${REDIS_VERSION}}"
REDIS_PASSWORD="${REDIS_PASSWORD:-Redis@1314}"
REDIS_PORT="${REDIS_PORT:-6379}"
CLUSTER_REPLICAS="${CLUSTER_REPLICAS:-0}"

NODE1="${NODE1:-172.30.0.11}"
NODE2="${NODE2:-172.30.0.12}"
NODE3="${NODE3:-172.30.0.13}"

CLI="${INSTALL_PREFIX}/bin/redis-cli"

log() { echo "[$(date '+%F %T')][创建集群][$HOSTNAME] $*"; }

cluster_state="$("${CLI}" -a "${REDIS_PASSWORD}" -h "${NODE1}" -p "${REDIS_PORT}" CLUSTER INFO 2>/dev/null | awk -F: '/cluster_state/ {print $2}' | tr -d '\r' || true)"
if [[ "${cluster_state}" == "ok" ]]; then
  log "集群已是 cluster_state:ok，跳过 create"
  exit 0
fi

log "执行 redis-cli --cluster create（三主零从）"
"${CLI}" -a "${REDIS_PASSWORD}" --cluster create \
  "${NODE1}:${REDIS_PORT}" \
  "${NODE2}:${REDIS_PORT}" \
  "${NODE3}:${REDIS_PORT}" \
  --cluster-replicas "${CLUSTER_REPLICAS}" \
  --cluster-yes

log "集群创建完成"
