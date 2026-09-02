#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""; NODE=""
FILL_PCT="${FILL_PCT:-95}"

usage() {
  usage_header
  cat <<EOF

Actions:
  disk-full          dd fill log.dirs (KF083)
  logdir-readonly    chmod a-w data dir (KF084)
  io-stress          dd loop in log.dirs/fault_io (KF085)
  inode-exhaust      many small files (KF012)

Examples:
  $0 --action disk-full --target-host 10.10.26.146 --duration 300
  $0 --action logdir-readonly --node 10.10.26.146:9092 --duration 300
EOF
}

FILL_FILE=""
recover_disk_full() {
  run_on_target "rm -f ${KAFKA_DATA_DIR}/kafka_fault_fill.bin; rm -f /tmp/kafka_fault_fill.bin"
}
recover_readonly() {
  run_on_target "chmod -R u+w ${KAFKA_DATA_DIR} 2>/dev/null || true"
}
recover_io() {
  run_on_target "pkill -f 'dd if=/dev/zero of=${KAFKA_DATA_DIR}/fault_io' 2>/dev/null || true; rm -rf ${KAFKA_DATA_DIR}/fault_io"
}
recover_inode() {
  run_on_target "rm -rf ${KAFKA_DATA_DIR}/fault_inodes"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
acquire_inject_lock
parse_duration

case "${ACTION}" in
  disk-full)
    bind_target_from_node "${NODE}"
    inject_begin KF083 recover_disk_full
    run_on_target "
      mkdir -p ${KAFKA_DATA_DIR}
      # fill until df >= ${FILL_PCT} or 2G written
      dd if=/dev/zero of=${KAFKA_DATA_DIR}/kafka_fault_fill.bin bs=1M count=2048 conv=fsync >/tmp/kafka_fill.log 2>&1 || true
    "
    post_check_disk_full "${KAFKA_DATA_DIR}" 80 || log "WARN disk not >=80% (small volume? fill file created anyway)"
    inject_pass "fill file in ${KAFKA_DATA_DIR} on $(target_label)"
    run_timed_fault "${DURATION}" recover_disk_full
    ;;
  logdir-readonly)
    bind_target_from_node "${NODE}"
    inject_begin KF084 recover_readonly
    run_on_target "chmod a-w ${KAFKA_DATA_DIR} ${KAFKA_DATA_DIR}/* 2>/dev/null || chmod a-w ${KAFKA_DATA_DIR}"
    inject_pass "log.dirs readonly on $(target_label)"
    run_timed_fault "${DURATION}" recover_readonly
    ;;
  io-stress)
    bind_target_from_node "${NODE}"
    inject_begin KF085 recover_io
    run_on_target "
      mkdir -p ${KAFKA_DATA_DIR}/fault_io
      nohup bash -c 'while true; do dd if=/dev/zero of=${KAFKA_DATA_DIR}/fault_io/blob bs=1M count=256 conv=fsync; done' >/tmp/kafka_io.log 2>&1 &
    "
    inject_pass "io-stress started under ${KAFKA_DATA_DIR}"
    run_timed_fault "${DURATION}" recover_io
    ;;
  inode-exhaust)
    bind_target_from_node "${NODE}"
    inject_begin KF012 recover_inode
    run_on_target "
      mkdir -p ${KAFKA_DATA_DIR}/fault_inodes
      i=0
      while [[ \$i -lt 200000 ]]; do
        : > ${KAFKA_DATA_DIR}/fault_inodes/f_\$i || break
        i=\$((i+1))
      done
      echo created=\$i
    "
    inject_pass "inode files created on $(target_label)"
    run_timed_fault "${DURATION}" recover_inode
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
