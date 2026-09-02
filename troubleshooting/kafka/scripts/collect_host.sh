#!/usr/bin/env bash
# K4 主机资源：CPU/内存/磁盘/FD/inode/JVM GC/时钟/负载
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
KAFKA_INSTALL_PREFIX=${4:-/opt/kafka/3.8.1}
_kafka_port=${5:-9092}
_controller_port=${6:-9093}
run_id=${7:-manual}
data_dir=${8:-/var/lib/kafka/data}

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact host "$target_ip" "$run_id"

emit "collector=host"
emit "data_dir=${data_dir}"
emit "uname=$(uname -a 2>/dev/null || true)"
emit "nproc=$(nproc 2>/dev/null || echo unknown)"

emit_cmd "uptime" uptime || true
emit_cmd "free -h" free -h || true
emit_cmd "vmstat 1 5" vmstat 1 5 || true

if command -v top >/dev/null 2>&1; then
  emit_cmd "top snapshot" top -b -n 1 | head -25 || true
fi

emit "----- cpu /mem from /proc -----"
if [[ -r /proc/loadavg ]]; then
  load=$(awk '{print $1}' /proc/loadavg)
  emit "load1=${load}"
  cores=$(nproc 2>/dev/null || echo 1)
  awk -v l="$load" -v c="$cores" 'BEGIN{if (c>0 && l+0 > c*0.85) exit 0; exit 1}' && \
    signal KF002 medium "load1=${load} cores=${cores}" || true
fi

if [[ -r /proc/meminfo ]]; then
  awk '/MemTotal|MemAvailable|SwapTotal|SwapFree|Cached|Buffers/' /proc/meminfo >> "$ARTIFACT_FILE"
  avail_pct=$(awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{if(t>0) printf "%d", a*100/t; else print 100}' /proc/meminfo)
  emit "mem_available_pct=${avail_pct}"
  if (( avail_pct <= 15 )); then
    signal KF004 high "memory available ${avail_pct}%"
  fi
  swap_used=$(awk '/SwapTotal:/{t=$2} /SwapFree:/{f=$2} END{print t-f}' /proc/meminfo)
  if (( swap_used > 1024*1024 )); then
    signal KF009 medium "swap used ${swap_used} kB"
  fi
fi

emit "----- disk -----"
df -h >> "$ARTIFACT_FILE" 2>&1 || true
df -i >> "$ARTIFACT_FILE" 2>&1 || true
if [[ -d "$data_dir" ]]; then
  emit "----- df data_dir ${data_dir} -----"
  df -h "$data_dir" >> "$ARTIFACT_FILE" 2>&1 || true
  used=$(df -P "$data_dir" | awk 'NR==2{gsub("%","",$5); print $5}')
  if [[ "${used:-0}" =~ ^[0-9]+$ ]] && (( used >= 90 )); then
    signal KF083 high "log.dirs ${data_dir} used ${used}%"
  elif [[ "${used:-0}" =~ ^[0-9]+$ ]] && (( used >= 80 )); then
    signal KF083 medium "log.dirs ${data_dir} used ${used}%"
  fi
  inode_used=$(df -iP "$data_dir" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  if [[ "${inode_used:-0}" =~ ^[0-9]+$ ]] && (( inode_used >= 90 )); then
    signal KF012 high "inode used ${inode_used}% on ${data_dir}"
  fi
else
  emit "DATA_DIR_MISSING ${data_dir}"
fi

if command -v iostat >/dev/null 2>&1; then
  emit_cmd "iostat -x 1 3" iostat -x 1 3 || true
  if iostat -x 1 3 2>/dev/null | awk 'NF>10 && $1 !~ /Device|Linux/ && $(NF-1)+0 > 90 {exit 0} END{exit 1}'; then
    signal KF085 medium "disk util high from iostat"
  fi
else
  emit "IOSTAT_MISSING"
  signal KF118 low "iostat missing (degraded host IO view)"
fi

emit "----- ulimit / fd -----"
emit "ulimit_n=$(ulimit -n 2>/dev/null || echo unknown)"
nofile=$(ulimit -n 2>/dev/null || echo 0)
if [[ "$nofile" =~ ^[0-9]+$ ]] && (( nofile < 65535 )); then
  signal KF014 medium "ulimit -n=${nofile} < 65535"
fi

pid=$(pgrep -f 'kafka\.Kafka' | head -1 || true)
if [[ -n "$pid" ]]; then
  emit "KAFKA_PID=${pid}"
  if [[ -d "/proc/${pid}/fd" ]]; then
    fd_count=$(ls "/proc/${pid}/fd" 2>/dev/null | wc -l | tr -d ' ')
    emit "kafka_fd_count=${fd_count}"
    if (( fd_count > 20000 )); then
      signal KF022 medium "kafka fd count ${fd_count}"
    fi
  fi
  if [[ -r "/proc/${pid}/status" ]]; then
    awk '/VmRSS|VmSize|Threads|FDSize/' "/proc/${pid}/status" >> "$ARTIFACT_FILE"
    threads=$(awk '/Threads:/{print $2}' "/proc/${pid}/status")
    emit "kafka_threads=${threads}"
  fi
  if command -v jstat >/dev/null 2>&1; then
    emit_cmd "jstat -gc ${pid}" jstat -gc "$pid" || true
    emit_cmd "jstat -gccapacity ${pid}" jstat -gccapacity "$pid" || true
  elif command -v jcmd >/dev/null 2>&1; then
    emit_cmd_timeout 10 "jcmd GC.heap_info" jcmd "$pid" GC.heap_info || true
  else
    emit "JSTAT_JCMD_MISSING"
    signal KF119 low "jstat/jcmd missing"
  fi
  if [[ -r /proc/meminfo ]] && grep -q 'OOM' /var/log/messages 2>/dev/null; then
    signal KF005 medium "host messages mention OOM"
  fi
  dmesg -T 2>/dev/null | grep -iE 'oom|killed process' | tail -5 >> "$ARTIFACT_FILE" || true
else
  signal KF015 high "kafka process absent on host snapshot"
fi

emit "----- clock -----"
date -u +"%Y-%m-%dT%H:%M:%SZ" >> "$ARTIFACT_FILE"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl >> "$ARTIFACT_FILE" 2>&1 || true
  if timedatectl 2>/dev/null | grep -qi 'NTP service: inactive\|synchronized: no'; then
    signal KF010 medium "time not synchronized"
  fi
fi
if command -v ntpq >/dev/null 2>&1; then
  ntpq -p >> "$ARTIFACT_FILE" 2>&1 || true
fi

emit "----- sysctl highlights -----"
sysctl vm.max_map_count vm.swappiness fs.file-max net.core.somaxconn 2>/dev/null >> "$ARTIFACT_FILE" || true

finish_artifact
exit 0
