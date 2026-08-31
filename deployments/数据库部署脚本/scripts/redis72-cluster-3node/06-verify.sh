#!/usr/bin/env bash
# Redis Cluster 三节点 - 部署验收
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-7.2.16}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/redis/${REDIS_VERSION}}"
REDIS_PASSWORD="${REDIS_PASSWORD:-Redis@1314}"
REDIS_PORT="${REDIS_PORT:-6379}"

CLI="${INSTALL_PREFIX}/bin/redis-cli"

log() { echo "[$(date '+%F %T')][验收][$HOSTNAME] $*"; }

info="$("${CLI}" -a "${REDIS_PASSWORD}" -p "${REDIS_PORT}" CLUSTER INFO)"
echo "${info}"

echo "${info}" | grep -q "cluster_state:ok" || { echo "[ERROR] cluster_state 非 ok" >&2; exit 1; }
echo "${info}" | grep -q "cluster_slots_assigned:16384" || { echo "[ERROR] slots 未分满" >&2; exit 1; }
echo "${info}" | grep -q "cluster_known_nodes:3" || { echo "[ERROR] 节点数不是 3" >&2; exit 1; }

"${CLI}" -a "${REDIS_PASSWORD}" -p "${REDIS_PORT}" SET deploy:cluster:verify ok | grep -q OK
log "验收通过"
