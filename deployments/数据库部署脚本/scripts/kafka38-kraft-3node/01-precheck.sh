#!/usr/bin/env bash
# Kafka KRaft 三节点 - 环境预检
set -euo pipefail

KAFKA_PORT="${KAFKA_PORT:-9092}"
CONTROLLER_PORT="${CONTROLLER_PORT:-9093}"
NOFILE_MIN="${NOFILE_MIN:-65535}"
JAVA_MIN_MAJOR="${JAVA_MIN_MAJOR:-17}"

log() { echo "[$(date '+%F %T')][环境预检][$HOSTNAME] $*"; }
error() { echo "[ERROR][环境预检][$HOSTNAME] $*" >&2; exit 1; }

log "检查 root 权限"
[[ $(id -u) -eq 0 ]] || error "必须由 root 作业账户执行"

log "检查 Java >= ${JAVA_MIN_MAJOR}"
command -v java >/dev/null || error "缺少 java 命令"
java_version="$(java -version 2>&1 | head -n1)"
java_major="$(java -version 2>&1 | awk -F '[\".]' '/version/ {print $2; exit}')"
[[ -n "${java_major}" && "${java_major}" -ge "${JAVA_MIN_MAJOR}" ]] \
  || error "Java 版本不满足要求: ${java_version}"

log "检查编译/运维依赖"
for cmd in curl tar sha512sum ss pgrep systemctl hostname; do
  command -v "${cmd}" >/dev/null || error "缺少命令: ${cmd}"
done

log "检查端口 ${KAFKA_PORT}/${CONTROLLER_PORT}"
for port in "${KAFKA_PORT}" "${CONTROLLER_PORT}"; do
  if ss -lnt | awk '{print $4}' | grep -q ":${port}$"; then
    error "端口 ${port} 已被占用"
  fi
done

log "检查 ulimit nofile >= ${NOFILE_MIN}"
current_nofile="$(ulimit -n)"
(( current_nofile >= NOFILE_MIN )) || error "ulimit -n=${current_nofile}，需要 >= ${NOFILE_MIN}"

log "检查是否已有 kafka 进程冲突"
if pgrep -f 'kafka\.Kafka' >/dev/null 2>&1; then
  error "已存在 kafka 进程，请先清理"
fi

log "环境预检通过"
