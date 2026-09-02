#!/usr/bin/env bash
# Kafka KRaft 三节点 - 内核参数
set -euo pipefail

log() { echo "[$(date '+%F %T')][内核参数][$HOSTNAME] $*"; }
error() { echo "[ERROR][内核参数][$HOSTNAME] $*" >&2; exit 1; }

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-kafka.conf <<'EOF'
vm.max_map_count = 262144
vm.swappiness = 1
fs.file-max = 1000000
EOF
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-kafka.conf >/dev/null

current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
(( current >= 262144 )) || error "vm.max_map_count=${current}，需要 >= 262144"
log "sysctl 配置完成"
