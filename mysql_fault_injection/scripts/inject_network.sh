#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""; NODE=""; SCOPE="${SCOPE:-one}"
NODE_A="${NODE_A:-${MYSQL_PRIMARY%%:*}}"
NODE_B="${NODE_B:-$(echo "${MYSQL_REPLICAS}" | awk '{print $1}' | cut -d: -f1)}"
LOSS="${LOSS:-30}"
DELAY_MS="${DELAY_MS:-200}"
JITTER_MS="${JITTER_MS:-50}"
RATE="${RATE:-1mbit}"

usage() {
  usage_header
  cat <<EOF

Actions:
  repl-block                   DROP replica->primary:3306 --scope one|all (MY144 / MY190-N)
  packet-loss                  netem loss (MY140)
  latency                      netem delay (MY140-L)
  rate-limit                   tbf on primary egress (MY142)
  primary-replica-partition    bidirectional DROP (MY144-P)
  one-way-drop                 INPUT DROP peer only (MY141)
  client-block                 DROP tcp/${MYSQL_PORT} on target (MY031)

Examples:
  $0 --action repl-block --node 10.10.26.145:3306 --duration 600
  $0 --action packet-loss --target-host 10.10.26.146 --loss 30 --duration 600
EOF
}

recover_qdisc() { run_on_target "tc qdisc del dev ${NET_DEV} root 2>/dev/null || true"; }

recover_repl_block() {
  local n host
  if [[ "${SCOPE}" == "all" ]]; then
    for n in ${MYSQL_REPLICAS}; do
      host="${n%%:*}"
      run_on_host "${host}" "$(priv)iptables -D OUTPUT -p tcp --dport ${MYSQL_PORT} -d ${MYSQL_PRIMARY%%:*} -j DROP 2>/dev/null || true" || true
    done
  else
    run_on_target "$(priv)iptables -D OUTPUT -p tcp --dport ${MYSQL_PORT} -d ${MYSQL_PRIMARY%%:*} -j DROP 2>/dev/null || true"
  fi
}

recover_partition() {
  local host peer
  for host in "${NODE_A}" "${NODE_B}"; do
    if [[ "${host}" == "${NODE_A}" ]]; then peer="${NODE_B}"; else peer="${NODE_A}"; fi
    run_on_host "${host}" "
      $(priv)iptables -D INPUT -s ${peer} -j DROP 2>/dev/null || true
      $(priv)iptables -D OUTPUT -d ${peer} -j DROP 2>/dev/null || true
    " || true
  done
}

recover_one_way() {
  run_on_host "${NODE_A}" "$(priv)iptables -D INPUT -s ${NODE_B} -j DROP 2>/dev/null || true" || true
}

recover_client_block() {
  run_on_target "
    $(priv)iptables -D INPUT -p tcp --dport ${MYSQL_PORT} -j DROP 2>/dev/null || true
    $(priv)iptables -D OUTPUT -p tcp --dport ${MYSQL_PORT} -j DROP 2>/dev/null || true
  "
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
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
  repl-block)
    NODE="${NODE:-$(echo "${MYSQL_REPLICAS}" | awk '{print $1}')}"
    if [[ "${SCOPE}" != "all" ]]; then
      bind_target_from_node "${NODE}"
    fi
    inject_begin "$([[ "${SCOPE}" == "all" ]] && echo MY190-N || echo MY144)" recover_repl_block
    if [[ "${SCOPE}" == "all" ]]; then
      for n in ${MYSQL_REPLICAS}; do
        run_on_host "${n%%:*}" "$(priv)iptables -I OUTPUT -p tcp --dport ${MYSQL_PORT} -d ${MYSQL_PRIMARY%%:*} -j DROP"
      done
    else
      run_on_target "$(priv)iptables -I OUTPUT -p tcp --dport ${MYSQL_PORT} -d ${MYSQL_PRIMARY%%:*} -j DROP"
    fi
    inject_pass "repl-block scope=${SCOPE} node=${NODE}"
    run_timed_fault "${DURATION}" recover_repl_block
    ;;
  packet-loss)
    require_target
    inject_begin MY140 recover_qdisc
    apply_netem "${NET_DEV}" "loss ${LOSS}%"
    post_check_packet_loss "${NET_DEV}" || inject_fail "netem loss not active"
    inject_pass "loss ${LOSS}% on $(target_label)"
    run_timed_fault "${DURATION}" recover_qdisc
    ;;
  latency)
    require_target
    inject_begin MY140-L recover_qdisc
    apply_netem "${NET_DEV}" "delay ${DELAY_MS}ms ${JITTER_MS}ms"
    inject_pass "delay ${DELAY_MS}ms on $(target_label)"
    run_timed_fault "${DURATION}" recover_qdisc
    ;;
  rate-limit)
    TARGET_HOST="${TARGET_HOST:-${MYSQL_PRIMARY%%:*}}"
    require_target
    inject_begin MY142 recover_qdisc
    run_on_target "tc qdisc replace dev ${NET_DEV} root tbf rate ${RATE} burst 32kbit latency 400ms"
    inject_pass "tbf ${RATE} on $(target_label) (primary egress fan-out)"
    run_timed_fault "${DURATION}" recover_qdisc
    ;;
  primary-replica-partition)
    require_all_targets_ok
    inject_begin MY144-P recover_partition
    for host in "${NODE_A}" "${NODE_B}"; do
      if [[ "${host}" == "${NODE_A}" ]]; then peer="${NODE_B}"; else peer="${NODE_A}"; fi
      run_on_host "${host}" "$(priv)iptables -I INPUT -s ${peer} -j DROP; $(priv)iptables -I OUTPUT -d ${peer} -j DROP"
    done
    inject_pass "partition ${NODE_A}<->${NODE_B}"
    run_timed_fault "${DURATION}" recover_partition
    ;;
  one-way-drop)
    require_all_targets_ok
    inject_begin MY141 recover_one_way
    run_on_host "${NODE_A}" "$(priv)iptables -I INPUT -s ${NODE_B} -j DROP"
    inject_pass "one-way drop ${NODE_B}->${NODE_A}"
    run_timed_fault "${DURATION}" recover_one_way
    ;;
  client-block)
    bind_target_from_node "${NODE}"
    inject_begin MY031 recover_client_block
    run_on_target "$(priv)iptables -I INPUT -p tcp --dport ${MYSQL_PORT} -j DROP; $(priv)iptables -I OUTPUT -p tcp --dport ${MYSQL_PORT} -j DROP"
    inject_pass "blocked ${MYSQL_PORT} on $(target_label)"
    run_timed_fault "${DURATION}" recover_client_block
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
