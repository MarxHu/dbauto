#!/usr/bin/env bash
# Redis Cluster 三节点 - 部署验收（集群模式 -c，跨 slot，测完清理）
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-7.2.16}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/redis/${REDIS_VERSION}}"
REDIS_PASSWORD="${REDIS_PASSWORD:-Redis@1314}"
REDIS_PORT="${REDIS_PORT:-6379}"
NODE1="${NODE1:-172.30.0.11}"

CLI="${INSTALL_PREFIX}/bin/redis-cli"
export REDISCLI_AUTH="${REDIS_PASSWORD}"

log() { echo "[$(date '+%F %T')][验收][$HOSTNAME] $*"; }

info="$("${CLI}" -h "${NODE1}" -p "${REDIS_PORT}" CLUSTER INFO)"
echo "${info}"

echo "${info}" | grep -q "cluster_state:ok" || { echo "[ERROR] cluster_state 非 ok" >&2; exit 1; }
echo "${info}" | grep -q "cluster_slots_assigned:16384" || { echo "[ERROR] slots 未分满" >&2; exit 1; }
echo "${info}" | grep -q "cluster_known_nodes:3" || { echo "[ERROR] 节点数不是 3" >&2; exit 1; }

nodes="$("${CLI}" -h "${NODE1}" -p "${REDIS_PORT}" CLUSTER NODES)"
master_count="$(echo "${nodes}" | awk '$3 ~ /master/ && $3 !~ /fail/ {c++} END {print c+0}')"
if [[ "${master_count}" != "3" ]]; then
  echo "[ERROR] master 数量=${master_count}，期望 3" >&2
  exit 1
fi

log "集群模式写入 hash tag key"
"${CLI}" -c -h "${NODE1}" -p "${REDIS_PORT}" SET '{deploy}:cluster:verify' ok | grep -q OK
"${CLI}" -c -h "${NODE1}" -p "${REDIS_PORT}" GET '{deploy}:cluster:verify' | grep -q ok

log "跨 slot 写入独立 key"
for key in sops:verify:node11 sops:verify:node12 sops:verify:node13; do
  "${CLI}" -c -h "${NODE1}" -p "${REDIS_PORT}" SET "${key}" ok | grep -q OK
done

log "清理测试 key"
"${CLI}" -c -h "${NODE1}" -p "${REDIS_PORT}" DEL '{deploy}:cluster:verify' \
  sops:verify:node11 sops:verify:node12 sops:verify:node13 >/dev/null

log "验收通过"
