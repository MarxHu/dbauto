#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""
CPU_HOST="${CPU_HOST:-10.10.26.144}"
DISK_HOST="${DISK_HOST:-10.10.26.144}"
STOP_NODE="${STOP_NODE:-10.10.26.144:9092}"
MEM_NODE="${MEM_NODE:-10.10.26.146:9092}"
PART_A="${PART_A:-10.10.26.144}"
PART_B="${PART_B:-10.10.26.145}"

usage() {
  usage_header
  cat <<EOF

Composite actions (internal calls skip flock):
  disk-plus-cpu           KF111 = disk-full + cpu same node
  partition-plus-isr      KF112 = broker-partition
  stop-plus-memory        KF113 = process-stop + memory on another node
  gc-plus-rebalance       KF114 = gc-storm + rebalance-storm
  controller-plus-urp     KF115 = controller-block + isr-shrink other node
  io-plus-produce         KF116 = io-stress (produce timeouts follow)

Examples:
  $0 --action disk-plus-cpu --duration 300
  $0 --action stop-plus-memory --stop-node 10.10.26.144:9092 --mem-node 10.10.26.146:9092 --duration 300
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --cpu-host|--disk-host) CPU_HOST="$2"; DISK_HOST="$2"; shift 2 ;;
    --stop-node) STOP_NODE="$2"; shift 2 ;;
    --mem-node) MEM_NODE="$2"; shift 2 ;;
    --node-a) PART_A="$2"; shift 2 ;;
    --node-b) PART_B="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
acquire_inject_lock
parse_duration
export INJECT_LOCK_SKIP=1

run_bg() { bash "$@" & }

case "${ACTION}" in
  disk-plus-cpu)
    inject_begin KF111 true
    run_bg "${SCRIPT_DIR}/inject_disk.sh" --action disk-full --target-host "${DISK_HOST}" --duration "${DURATION}"
    run_bg "${SCRIPT_DIR}/inject_host.sh" --action cpu --target-host "${CPU_HOST}" --duration "${DURATION}"
    wait
    emit_inject_result "KF111" "pass" "disk+cpu on ${DISK_HOST}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  partition-plus-isr)
    inject_begin KF112 true
    bash "${SCRIPT_DIR}/inject_network.sh" --action broker-partition --node-a "${PART_A}" --node-b "${PART_B}" --duration "${DURATION}"
    emit_inject_result "KF112" "pass" "partition ${PART_A}<->${PART_B}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  stop-plus-memory)
    inject_begin KF113 true
    run_bg "${SCRIPT_DIR}/inject_kafka.sh" --action process-stop --node "${STOP_NODE}" --duration "${DURATION}"
    run_bg "${SCRIPT_DIR}/inject_host.sh" --action memory --target-host "${MEM_NODE%%:*}" --duration "${DURATION}"
    wait
    emit_inject_result "KF113" "pass" "stop ${STOP_NODE} + mem ${MEM_NODE}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  gc-plus-rebalance)
    inject_begin KF114 true
    run_bg "${SCRIPT_DIR}/inject_kafka.sh" --action gc-storm --node "$(first_node)" --duration "${DURATION}"
    run_bg "${SCRIPT_DIR}/inject_kafka.sh" --action rebalance-storm --duration "${DURATION}"
    wait
    emit_inject_result "KF114" "pass" "gc+rebalance"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  controller-plus-urp)
    inject_begin KF115 true
    run_bg "${SCRIPT_DIR}/inject_network.sh" --action controller-block --target-host "${PART_A}" --duration "${DURATION}"
    run_bg "${SCRIPT_DIR}/inject_kafka.sh" --action isr-shrink --node "${STOP_NODE}" --duration "${DURATION}"
    wait
    emit_inject_result "KF115" "pass" "controller-block + isr-shrink"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  io-plus-produce)
    inject_begin KF116 true
    bash "${SCRIPT_DIR}/inject_disk.sh" --action io-stress --target-host "${DISK_HOST}" --duration "${DURATION}"
    emit_inject_result "KF116" "pass" "io-stress ${DISK_HOST}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
