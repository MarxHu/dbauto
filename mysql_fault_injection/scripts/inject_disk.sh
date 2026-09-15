#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""; NODE=""
DATA_DIR=""

usage() {
  usage_header
  cat <<EOF

Actions:
  disk-full          dd fill datadir (MY160 / MY160-R)
  datadir-readonly   chmod a-w datadir (MY164)
  io-stress          dd loop under datadir/fault_io (MY162 / MY162-P)
  inode-exhaust      many small files (MY161)

Examples:
  $0 --action io-stress --target-host 10.10.26.145 --duration 600
  $0 --action disk-full --target-host 10.10.26.144 --duration 300
EOF
}

sid_disk() {
  local host="${TARGET_HOST:-${NODE%%:*}}"
  if [[ "${host}" == "${MYSQL_PRIMARY%%:*}" ]]; then
    echo MY160
  else
    echo MY160-R
  fi
}

sid_io() {
  local host="${TARGET_HOST:-${NODE%%:*}}"
  if [[ "${host}" == "${MYSQL_PRIMARY%%:*}" ]]; then
    echo MY162-P
  else
    echo MY162
  fi
}

recover_disk_full() {
  run_on_target "rm -f ${DATA_DIR}/mysql_fault_fill.bin"
}

recover_readonly() {
  run_on_target "chmod -R u+w ${DATA_DIR} 2>/dev/null || true"
}

recover_io() {
  run_on_target "pkill -f 'dd if=/dev/zero of=${DATA_DIR}/fault_io' 2>/dev/null || true; rm -rf ${DATA_DIR}/fault_io"
}

recover_inode() {
  run_on_target "rm -rf ${DATA_DIR}/fault_inodes"
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
resolve_node
bind_target_from_node "${NODE}"
DATA_DIR="$(detect_datadir "${NODE}")"
log "datadir=${DATA_DIR}"

case "${ACTION}" in
  disk-full)
    inject_begin "$(sid_disk)" recover_disk_full
    run_on_target "
      mkdir -p ${DATA_DIR}
      dd if=/dev/zero of=${DATA_DIR}/mysql_fault_fill.bin bs=1M count=2048 conv=fsync >/tmp/mysql_fill.log 2>&1 || true
    "
    inject_pass "fill file in ${DATA_DIR} on $(target_label)"
    run_timed_fault "${DURATION}" recover_disk_full
    ;;
  datadir-readonly)
    inject_begin MY164 recover_readonly
    run_on_target "chmod a-w ${DATA_DIR} 2>/dev/null || true"
    inject_pass "datadir readonly on $(target_label)"
    run_timed_fault "${DURATION}" recover_readonly
    ;;
  io-stress)
    inject_begin "$(sid_io)" recover_io
    run_on_target "
      mkdir -p ${DATA_DIR}/fault_io
      nohup bash -c 'while true; do dd if=/dev/zero of=${DATA_DIR}/fault_io/blob bs=1M count=256 conv=fsync; done' >/tmp/mysql_io.log 2>&1 &
    "
    inject_pass "io-stress started under ${DATA_DIR}"
    run_timed_fault "${DURATION}" recover_io
    ;;
  inode-exhaust)
    inject_begin MY161 recover_inode
    run_on_target "
      mkdir -p ${DATA_DIR}/fault_inodes
      i=0
      while [[ \$i -lt 200000 ]]; do
        : > ${DATA_DIR}/fault_inodes/f_\$i || break
        i=\$((i+1))
      done
    "
    inject_pass "inode files created on $(target_label)"
    run_timed_fault "${DURATION}" recover_inode
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
