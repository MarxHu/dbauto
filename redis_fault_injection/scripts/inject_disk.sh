#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""
DURATION=""
NODE=""
IO_DIR="${IO_DIR:-/tmp/redis_fault_io}"
IO_PID=""

usage() {
  usage_header
  cat <<EOF

Actions:
  persistence-fail     Make redis data dir read-only and trigger BGSAVE
  io-stress            Sustained disk write load

Extra options:
  --data-dir <path>    redis data directory (default ${REDIS_DATA_DIR})

Examples:
  $0 --action persistence-fail --node 10.10.26.146:6381 --duration 240
  $0 --action io-stress --target-host 10.10.26.144 --duration 240
EOF
}

recover_persistence_fail() {
  resolve_node
  run_on_target "chmod -R u+w ${REDIS_DATA_DIR} 2>/dev/null || chmod -R 755 ${REDIS_DATA_DIR}"
  log "restored write permission on ${REDIS_DATA_DIR}"
}

recover_io_stress() {
  [[ -n "${IO_PID:-}" ]] && kill "${IO_PID}" 2>/dev/null || true
  run_on_target "rm -rf ${IO_DIR}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --data-dir) REDIS_DATA_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action

acquire_inject_lock

case "${ACTION}" in
  persistence-fail)
    parse_duration
    resolve_node
    host="${NODE%%:*}"
    port="${NODE##*:}"
    log "persistence failure on ${NODE} for ${DURATION}s"
    run_on_target "
      chmod -R a-w ${REDIS_DATA_DIR}
      redis-cli -h ${host} -p ${port} CONFIG SET stop-writes-on-bgsave-error yes >/dev/null 2>&1 || true
      redis-cli -h ${host} -p ${port} BGSAVE >/dev/null 2>&1 || true
    "
    run_timed_fault "${DURATION}" recover_persistence_fail
    ;;
  io-stress)
    parse_duration
    run_on_target "
      mkdir -p ${IO_DIR}
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )); do
        dd if=/dev/zero of=${IO_DIR}/fault.bin bs=1M count=256 conv=fdatasync >/dev/null 2>&1 || true
      done
    " &
    IO_PID=$!
    run_timed_fault "${DURATION}" recover_io_stress
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
