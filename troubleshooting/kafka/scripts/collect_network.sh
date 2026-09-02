#!/usr/bin/env bash
# K5 主机网络：监听、对等连通、丢包/qdisc、连接数、防火墙、advertised 可达性
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
KAFKA_INSTALL_PREFIX=${4:-/opt/kafka/3.8.1}
kafka_port=${5:-9092}
controller_port=${6:-9093}
run_id=${7:-manual}

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact network "$target_ip" "$run_id"

emit "collector=network"
emit "ports broker=${kafka_port} controller=${controller_port}"

emit "----- ip / routes -----"
ip -4 addr >> "$ARTIFACT_FILE" 2>&1 || ifconfig >> "$ARTIFACT_FILE" 2>&1 || true
ip route >> "$ARTIFACT_FILE" 2>&1 || true

emit "----- listening sockets -----"
if command -v ss >/dev/null 2>&1; then
  ss -lntp >> "$ARTIFACT_FILE" 2>&1 || true
  ss -s >> "$ARTIFACT_FILE" 2>&1 || true
  if ! ss -lnt | awk '{print $4}' | grep -q ":${kafka_port}$"; then
    signal KF071 high "broker port ${kafka_port} not listening"
    signal KF015 medium "broker may be down (no ${kafka_port})"
  fi
  if ! ss -lnt | awk '{print $4}' | grep -q ":${controller_port}$"; then
    signal KF072 high "controller port ${controller_port} not listening"
    signal KF025 medium "controller listener down"
  fi
  conn9092=$(ss -tn state established "( dport = :${kafka_port} or sport = :${kafka_port} )" 2>/dev/null | wc -l | tr -d ' ')
  emit "established_9092_lines=${conn9092}"
  tw=$(ss -tn state time-wait 2>/dev/null | wc -l | tr -d ' ')
  emit "time_wait_lines=${tw}"
  if (( tw > 5000 )); then
    signal KF081 medium "time-wait connections ${tw}"
  fi
else
  netstat -lntp >> "$ARTIFACT_FILE" 2>&1 || true
  signal KF118 low "ss missing"
fi

tcp_probe() {
  local host=$1 port=$2
  if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
    emit "TCP_OK ${host}:${port}"
    return 0
  fi
  emit "TCP_FAIL ${host}:${port}"
  return 1
}

emit "----- peer connectivity -----"
peer_fail=0
ctrl_fail=0
for ip in "$node1" "$node2" "$node3"; do
  [[ -z "$ip" ]] && continue
  if ping -c 2 -W 2 "$ip" >> "$ARTIFACT_FILE" 2>&1; then
    emit "PING_OK ${ip}"
  else
    emit "PING_FAIL ${ip}"
    signal KF073 medium "icmp fail to ${ip}"
  fi
  tcp_probe "$ip" "$kafka_port" || { peer_fail=$((peer_fail + 1)); signal KF071 medium "tcp ${ip}:${kafka_port} fail"; }
  tcp_probe "$ip" "$controller_port" || { ctrl_fail=$((ctrl_fail + 1)); signal KF072 medium "tcp ${ip}:${controller_port} fail"; }
done
if (( peer_fail >= 2 )); then
  signal KF073 high "multiple broker port connectivity failures"
fi
if (( ctrl_fail >= 2 )); then
  signal KF026 high "multiple controller port connectivity failures"
fi

emit "----- tc qdisc -----"
if command -v tc >/dev/null 2>&1; then
  for dev in $(ls /sys/class/net 2>/dev/null | grep -v '^lo$' || echo eth0); do
    emit "dev=${dev}"
    tc qdisc show dev "$dev" >> "$ARTIFACT_FILE" 2>&1 || true
    if tc qdisc show dev "$dev" 2>/dev/null | grep -Eq 'netem|tbf|htb'; then
      signal KF075 medium "tc qdisc netem/tbf/htb active on ${dev}"
      signal KF076 medium "possible injected delay/loss/rate-limit on ${dev}"
    fi
  done
else
  emit "TC_MISSING"
fi

emit "----- iptables / nft / firewall -----"
if command -v iptables >/dev/null 2>&1; then
  iptables -S | head -80 >> "$ARTIFACT_FILE" 2>&1 || true
  if iptables -S 2>/dev/null | grep -E 'DROP|REJECT' | grep -E "${kafka_port}|${controller_port}|10\\.10\\.26" >/dev/null; then
    signal KF079 medium "iptables DROP/REJECT related to kafka ports or lab net"
  fi
fi
if command -v nft >/dev/null 2>&1; then
  nft list ruleset 2>/dev/null | head -60 >> "$ARTIFACT_FILE" || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --list-all >> "$ARTIFACT_FILE" 2>&1 || true
fi

emit "----- dns / hosts -----"
cat /etc/resolv.conf >> "$ARTIFACT_FILE" 2>&1 || true
grep -E 'kafka|10.10.26' /etc/hosts >> "$ARTIFACT_FILE" 2>&1 || true
for ip in "$node1" "$node2" "$node3"; do
  getent hosts "$ip" >> "$ARTIFACT_FILE" 2>&1 || true
done

conf=/etc/kafka/server.properties
if [[ -f "$conf" ]]; then
  advertised=$(awk -F= '$1=="advertised.listeners"{print $2}' "$conf")
  emit "advertised.listeners=${advertised}"
  if [[ -n "$advertised" ]]; then
    echo "$advertised" | tr ',;' '\n' | while IFS= read -r spec; do
      hostport=${spec##*://}
      host=${hostport%%:*}
      port=${hostport##*:}
      [[ "$host" == "$hostport" ]] && continue
      tcp_probe "$host" "$port" || signal KF078 high "advertised endpoint unreachable ${host}:${port}"
    done
  fi
fi

emit "----- conntrack / somaxconn -----"
sysctl net.core.somaxconn net.ipv4.tcp_tw_reuse net.ipv4.ip_local_port_range 2>/dev/null >> "$ARTIFACT_FILE" || true
if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
  emit "nf_conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count)"
fi

finish_artifact
exit 0
