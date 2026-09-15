#!/usr/bin/env bash
# H 主机+网络：磁盘/iostat/FD/时钟 + 9200/9300 分端口探测。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
ES_HTTP_PORT=${4:-9200}
ES_TRANSPORT_PORT=${5:-9300}
run_id=${6:-manual}
ES_USER=${7:-${ES_USER:-}}
ES_PASS=${8:-${ES_PASS:-}}
data_dir=${9:-}
export ES_HTTP_PORT ES_USER ES_PASS

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact hostnet "$target_ip" "$run_id"
emit "collector=hostnet"

if [[ -z "$data_dir" || ! -d "$data_dir" ]]; then
  for alt in /var/lib/elasticsearch /opt/elasticsearch/data; do
    [[ -d "$alt" ]] && data_dir=$alt && break
  done
fi
emit "data_dir=${data_dir:-unknown}"

emit_cmd "uptime" uptime || true
emit_cmd "free -m" free -m || true
if command -v vmstat >/dev/null 2>&1; then
  emit_cmd_timeout 6 "vmstat 1 3" vmstat 1 3 || true
fi
if command -v iostat >/dev/null 2>&1; then
  emit_cmd_timeout 6 "iostat -x 1 3" iostat -x 1 3 || true
else
  signal ES171 low "iostat missing"
fi

emit "----- df -----"
df -h >> "$ARTIFACT_FILE" 2>&1 || true
df -i >> "$ARTIFACT_FILE" 2>&1 || true
if [[ -n "$data_dir" && -d "$data_dir" ]]; then
  used=$(df -P "$data_dir" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  inode=$(df -iP "$data_dir" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  emit "data_dir_used_pct=${used:-na} inode_pct=${inode:-na}"
  facts_merge "$(python3 -c 'import json,sys; d={"disk_used_pct": int(sys.argv[1]) if sys.argv[1].isdigit() else None}; print(json.dumps({k:v for k,v in d.items() if v is not None}))' "${used:-}")"
  if [[ "${used:-0}" =~ ^[0-9]+$ ]] && (( used >= 95 )); then
    signal ES015 high "path.data used ${used}%"
    signal ES070 high "disk ${used}% flood likely"
    facts_merge '{"flood": true}'
  elif [[ "${used:-0}" =~ ^[0-9]+$ ]] && (( used >= 90 )); then
    signal ES015 medium "path.data used ${used}%"
    signal ES072 medium "disk ${used}%"
  fi
  if [[ "${inode:-0}" =~ ^[0-9]+$ ]] && (( inode >= 90 )); then
    signal ES016 high "inode used ${inode}%"
  fi
fi

if [[ -r /proc/loadavg ]]; then
  load=$(awk '{print $1}' /proc/loadavg)
  cores=$(nproc 2>/dev/null || echo 1)
  emit "load1=${load} cores=${cores}"
  awk -v l="$load" -v c="$cores" 'BEGIN{if (c>0 && l+0 > c*0.85) exit 0; exit 1}' && \
    signal ES010 medium "load1=${load} cores=${cores}" || true
fi
if [[ -r /proc/meminfo ]]; then
  avail_pct=$(awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{if(t>0) printf "%d", a*100/t; else print 100}' /proc/meminfo)
  emit "mem_available_pct=${avail_pct}"
  if (( avail_pct <= 15 )); then
    signal ES011 high "memory available ${avail_pct}%"
  fi
  swap_used=$(awk '/SwapTotal:/{t=$2} /SwapFree:/{f=$2} END{print t-f+0}' /proc/meminfo)
  if (( swap_used > 1024*1024 )); then
    signal ES012 medium "swap used ${swap_used} kB"
  fi
fi

pid=$(pgrep -f 'org.elasticsearch.bootstrap.Elasticsearch' | head -n1 || true)
if [[ -n "$pid" && -d /proc/$pid/fd ]]; then
  fdn=$(ls /proc/$pid/fd 2>/dev/null | wc -l | tr -d ' ')
  ul=$(awk '/Max open files/{print $4}' /proc/$pid/limits 2>/dev/null | head -n1)
  emit "es_pid=${pid} fd=${fdn} ulimit=${ul:-na}"
  if [[ "${ul:-0}" =~ ^[0-9]+$ && "$ul" -gt 0 && "$fdn" -ge $((ul * 80 / 100)) ]]; then
    signal ES013 high "fd ${fdn}/${ul}"
  fi
fi

if command -v timedatectl >/dev/null 2>&1; then
  emit_cmd "timedatectl" timedatectl || true
fi
if command -v chronyc >/dev/null 2>&1; then
  offset=$(chronyc tracking 2>/dev/null | awk -F: '/Last offset/{print $2}' | awk '{print $1}')
  emit "chrony_last_offset=${offset:-na}"
  python3 -c 'import sys
s=sys.argv[1].strip().replace("seconds","").strip()
try:
    v=abs(float(s))
except Exception:
    raise SystemExit(0)
if v>=2: raise SystemExit(2)
' "${offset:-0}" && true || {
    rc=$?
    if (( rc == 2 )); then
      signal ES014 medium "clock offset ${offset}"
    fi
  }
fi

emit "----- listening -----"
if command -v ss >/dev/null 2>&1; then
  ss -lntp >> "$ARTIFACT_FILE" 2>&1 || true
else
  netstat -lntp >> "$ARTIFACT_FILE" 2>&1 || true
fi
http_l=0 trans_l=0
listen_port "$ES_HTTP_PORT" && http_l=1
listen_port "$ES_TRANSPORT_PORT" && trans_l=1
facts_merge "$(python3 -c 'import json,sys; print(json.dumps({"listen_http": sys.argv[1]=="1", "listen_transport": sys.argv[2]=="1"}))' "$http_l" "$trans_l")"
if (( http_l == 1 && trans_l == 0 )); then
  signal ES091 high "listen 9200 but not ${ES_TRANSPORT_PORT}"
  facts_merge '{"transport_ok": false}'
elif (( trans_l == 1 && http_l == 0 )); then
  signal ES092 medium "listen ${ES_TRANSPORT_PORT} but not http"
fi

emit "----- peer ping/tcp -----"
peer_http_json="{"
peer_tp_json="{"
first=1
for ip in "$node1" "$node2" "$node3"; do
  [[ -z "$ip" || "$ip" == "$target_ip" ]] && continue
  if ping -c 3 -W 1 "$ip" >> "$ARTIFACT_FILE" 2>&1; then
    emit "PING_OK ${ip}"
  else
    emit "PING_FAIL ${ip}"
    signal ES090 medium "ping fail ${ip}"
  fi
  h=0 t=0
  tcp_probe "$ip" "$ES_HTTP_PORT" && h=1 || emit "TCP_FAIL ${ip}:${ES_HTTP_PORT}"
  tcp_probe "$ip" "$ES_TRANSPORT_PORT" && t=1 || emit "TCP_FAIL ${ip}:${ES_TRANSPORT_PORT}"
  (( h )) && emit "TCP_OK ${ip}:${ES_HTTP_PORT}"
  (( t )) && emit "TCP_OK ${ip}:${ES_TRANSPORT_PORT}"
  if (( h == 1 && t == 0 )); then
    signal ES091 high "9200 ok 9300 fail ${target_ip}->${ip}"
  fi
  if (( first == 0 )); then
    peer_http_json+=", "
    peer_tp_json+=", "
  fi
  first=0
  peer_http_json+="\"${ip}\": $([[ $h -eq 1 ]] && echo true || echo false)"
  peer_tp_json+="\"${ip}\": $([[ $t -eq 1 ]] && echo true || echo false)"
done
peer_http_json+="}"
peer_tp_json+="}"
facts_merge "{\"peer_http\": ${peer_http_json}, \"peer_transport\": ${peer_tp_json}}"

if command -v nstat >/dev/null 2>&1; then
  emit_cmd "nstat -az TcpRetransSegs" nstat -az TcpRetransSegs || true
fi
if command -v iptables >/dev/null 2>&1; then
  if iptables -S 2>/dev/null | grep -q DROP; then
    signal ES094 low "iptables DROP rules present"
  fi
fi

finish_artifact
exit 0
