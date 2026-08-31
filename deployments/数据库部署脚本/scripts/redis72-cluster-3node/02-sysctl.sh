#!/usr/bin/env bash
# Redis Cluster - 内核参数（vm.overcommit_memory + THP）
set -euo pipefail

log() { echo "[$(date '+%F %T')][sysctl][$HOSTNAME] $*"; }

log "设置 vm.overcommit_memory=1"
sysctl -w vm.overcommit_memory=1 >/dev/null
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-redis.conf <<'EOF'
vm.overcommit_memory = 1
EOF
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-redis.conf >/dev/null

for thp_path in \
  /sys/kernel/mm/transparent_hugepage/enabled \
  /sys/kernel/mm/transparent_hugepage/defrag; do
  if [[ -f "${thp_path}" ]]; then
    log "关闭 THP: ${thp_path}"
    echo never > "${thp_path}" || log "WARN: 无法写入 ${thp_path}，请手动关闭 THP"
  fi
done

current="$(sysctl -n vm.overcommit_memory 2>/dev/null || echo 0)"
if [[ "${current}" != "1" ]]; then
  echo "[ERROR] vm.overcommit_memory=${current}，需要为 1" >&2
  exit 1
fi

log "sysctl 配置完成"
