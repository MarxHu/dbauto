#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""; NODE=""
NODE_A="${NODE_A:-10.10.26.144}"
NODE_B="${NODE_B:-10.10.26.145}"
LOSS="${LOSS:-30}"
DELAY_MS="${DELAY_MS:-200}"
JITTER_MS="${JITTER_MS:-50}"
RATE="${RATE:-1mbit}"
DNS_HOST="${DNS_HOST:-kafka.invalid}"

usage() {
  usage_header
  cat <<EOF

Actions:
  broker-block         DROP tcp/${KAFKA_PORT} (KF071)
  controller-block     DROP tcp/${CONTROLLER_PORT} (KF072)
  broker-partition     bidirectional DROP between two hosts (KF073)
  packet-loss          netem loss (KF075)
  latency              netem delay (KF076)
  rate-limit           tbf rate limit (KF077)
  dns-fail             poison /etc/hosts for a name (KF013)
  one-way-drop         INPUT DROP from peer only (KF082)

Examples:
  $0 --action controller-block --target-host 10.10.26.144 --duration 300
  $0 --action broker-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 300
EOF
}

recover_port_block() {
  local port="$1"
  run_on_target "
    iptables -D INPUT -p tcp --dport ${port} -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport ${port} -j DROP 2>/dev/null || true
    iptables -D INPUT -p tcp --dport ${port} -j DROP 2>/dev/null || true
  "
}
recover_broker_block() { recover_port_block "${KAFKA_PORT}"; }
recover_controller_block() { recover_port_block "${CONTROLLER_PORT}"; }
recover_qdisc() { run_on_target "tc qdisc del dev ${NET_DEV} root 2>/dev/null || true"; }
recover_partition() {
  for host in "${NODE_A}" "${NODE_B}"; do
    peer="$([[ "${host}" == "${NODE_A}" ]] && echo "${NODE_B}" || echo "${NODE_A}")"
    run_on_host "${host}" "
      iptables -D INPUT -s ${peer} -j DROP 2>/dev/null || true
      iptables -D OUTPUT -d ${peer} -j DROP 2>/dev/null || true
    " || true
  done
}
recover_one_way() {
  run_on_host "${NODE_A}" "iptables -D INPUT -s ${NODE_B} -j DROP 2>/dev/null || true" || true
}
HOSTS_BAK=""
recover_dns() {
  run_on_target "
    if [[ -f /etc/hosts.kafka_fault.bak ]]; then
      cat /etc/hosts.kafka_fault.bak > /etc/hosts
      rm -f /etc/hosts.kafka_fault.bak
    fi
  "
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    --node-a) NODE_A="$2"; shift 2 ;;
    --node-b) NODE_B="$2"; shift 2 ;;
    --loss) LOSS="$2"; shift 2 ;;
    --delay-ms) DELAY_MS="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --net-dev) NET_DEV="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
acquire_inject_lock
parse_duration

case "${ACTION}" in
  broker-block)
    bind_target_from_node "${NODE}"
    inject_begin KF071 recover_broker_block
    run_on_target "iptables -I INPUT -p tcp --dport ${KAFKA_PORT} -j DROP; iptables -I OUTPUT -p tcp --dport ${KAFKA_PORT} -j DROP"
    inject_pass "blocked ${KAFKA_PORT} on $(target_label)"
    run_timed_fault "${DURATION}" recover_broker_block
    ;;
  controller-block)
    bind_target_from_node "${NODE}"
    inject_begin KF072 recover_controller_block
    run_on_target "iptables -I INPUT -p tcp --dport ${CONTROLLER_PORT} -j DROP; iptables -I OUTPUT -p tcp --dport ${CONTROLLER_PORT} -j DROP"
    inject_pass "blocked ${CONTROLLER_PORT} on $(target_label)"
    run_timed_fault "${DURATION}" recover_controller_block
    ;;
  broker-partition)
    require_all_targets_ok
    inject_begin KF073 recover_partition
    for host in "${NODE_A}" "${NODE_B}"; do
      peer="$([[ "${host}" == "${NODE_A}" ]] && echo "${NODE_B}" || echo "${NODE_A}")"
      run_on_host "${host}" "iptables -I INPUT -s ${peer} -j DROP; iptables -I OUTPUT -d ${peer} -j DROP"
    done
    inject_pass "partition ${NODE_A}<->${NODE_B}"
    run_timed_fault "${DURATION}" recover_partition
    ;;
  packet-loss)
    require_target
    inject_begin KF075 recover_qdisc
    apply_netem "${NET_DEV}" "loss ${LOSS}%"
    post_check_packet_loss "${NET_DEV}" || inject_fail "netem loss not active"
    inject_pass "loss ${LOSS}% on $(target_label)"
    run_timed_fault "${DURATION}" recover_qdisc
    ;;
  latency)
    require_target
    inject_begin KF076 recover_qdisc
    apply_netem "${NET_DEV}" "delay ${DELAY_MS}ms ${JITTER_MS}ms"
    show="$(run_on_target "tc qdisc show dev ${NET_DEV}")"
    printf '%s' "${show}" | grep -q netem || inject_fail "netem delay not active"
    inject_pass "delay ${DELAY_MS}ms on $(target_label)"
    run_timed_fault "${DURATION}" recover_qdisc
    ;;
  rate-limit)
    require_target
    inject_begin KF077 recover_qdisc
    run_on_target "tc qdisc replace dev ${NET_DEV} root tbf rate ${RATE} burst 32kbit latency 400ms"
    inject_pass "tbf ${RATE} on $(target_label)"
    run_timed_fault "${DURATION}" recover_qdisc
    ;;
  dns-fail)
    require_target
    inject_begin KF013 recover_dns
    run_on_target "cp -a /etc/hosts /etc/hosts.kafka_fault.bak; echo '127.0.0.1 ${DNS_HOST}' >> /etc/hosts"
    inject_pass "poisoned hosts ${DNS_HOST} -> 127.0.0.1"
    run_timed_fault "${DURATION}" recover_dns
    ;;
  one-way-drop)
    require_all_targets_ok
    inject_begin KF082 recover_one_way
    run_on_host "${NODE_A}" "iptables -I INPUT -s ${NODE_B} -j DROP"
    inject_pass "one-way drop ${NODE_B}->${NODE_A}"
    run_timed_fault "${DURATION}" recover_one_way
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
