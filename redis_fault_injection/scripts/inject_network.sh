#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""
DURATION=""
NODE=""
NODE_A="${NODE_A:-10.10.26.144}"
NODE_B="${NODE_B:-10.10.26.145}"
LOSS="${LOSS:-30}"
NET_DEV="${NET_DEV:-eth0}"
BUS_PORT=""

usage() {
  usage_header
  cat <<EOF

Actions:
  bus-block            Block cluster bus port on target host
  packet-loss          Inject netem packet loss on target host NIC
  master-partition     Bidirectional partition between two master hosts

Extra options:
  --node-a <ip>        first host for master-partition
  --node-b <ip>        second host for master-partition
  --loss <percent>     packet loss percent (default 30)
  --net-dev <iface>    network device (default eth0)

Examples:
  $0 --action bus-block --node 10.10.26.144:6381 --duration 240
  $0 --action packet-loss --target-host 10.10.26.144 --duration 120 --loss 30
  $0 --action master-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 240
EOF
}

recover_bus_block() {
  resolve_node
  local port="${BUS_PORT:-$(( ${NODE##*:} + 10000 ))}"
  run_on_target "
    iptables -D INPUT -p tcp --dport ${port} -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport ${port} -j DROP 2>/dev/null || true
  "
}

recover_packet_loss() {
  run_on_target "tc qdisc del dev ${NET_DEV} root 2>/dev/null || true"
}

recover_master_partition() {
  for host in "${NODE_A}" "${NODE_B}"; do
    peer="$([[ "${host}" == "${NODE_A}" ]] && echo "${NODE_B}" || echo "${NODE_A}")"
    TARGET_HOST="${host}" run_on_target "
      iptables -D INPUT -s ${peer} -j DROP 2>/dev/null || true
      iptables -D OUTPUT -d ${peer} -j DROP 2>/dev/null || true
    "
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --node-a) NODE_A="$2"; shift 2 ;;
    --node-b) NODE_B="$2"; shift 2 ;;
    --loss) LOSS="$2"; shift 2 ;;
    --net-dev) NET_DEV="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action

acquire_inject_lock

case "${ACTION}" in
  bus-block)
    parse_duration
    resolve_node
    TARGET_HOST="${TARGET_HOST:-${NODE%%:*}}"
    BUS_PORT="${CLUSTER_BUS_PORT:-$(( ${NODE##*:} + 10000 ))}"
    log "block cluster bus tcp/${BUS_PORT} on ${TARGET_HOST}"
    run_on_target "
      iptables -C INPUT -p tcp --dport ${BUS_PORT} -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport ${BUS_PORT} -j DROP
      iptables -C OUTPUT -p tcp --dport ${BUS_PORT} -j DROP 2>/dev/null || iptables -A OUTPUT -p tcp --dport ${BUS_PORT} -j DROP
    "
    run_timed_fault "${DURATION}" recover_bus_block
    ;;
  packet-loss)
    parse_duration
    require_cmd tc
    log "inject ${LOSS}% packet loss on ${NET_DEV} for ${DURATION}s"
    run_on_target "
      tc qdisc add dev ${NET_DEV} root handle 1: htb 2>/dev/null || true
      tc qdisc add dev ${NET_DEV} parent 1:1 handle 10: netem loss ${LOSS}%
    "
    run_timed_fault "${DURATION}" recover_packet_loss
    ;;
  master-partition)
    parse_duration
    log "partition ${NODE_A} <-> ${NODE_B} for ${DURATION}s"
    for host in "${NODE_A}" "${NODE_B}"; do
      peer="$([[ "${host}" == "${NODE_A}" ]] && echo "${NODE_B}" || echo "${NODE_A}")"
      TARGET_HOST="${host}" run_on_target "
        iptables -C INPUT -s ${peer} -j DROP 2>/dev/null || iptables -A INPUT -s ${peer} -j DROP
        iptables -C OUTPUT -d ${peer} -j DROP 2>/dev/null || iptables -A OUTPUT -d ${peer} -j DROP
      "
    done
    run_timed_fault "${DURATION}" recover_master_partition
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
