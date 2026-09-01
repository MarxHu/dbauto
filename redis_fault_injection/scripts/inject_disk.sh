#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""
DURATION=""
NODE=""
IO_DIR="${IO_DIR:-auto}"
IO_PID=""
MISCONF_BEFORE=""

usage() {
  usage_header
  cat <<EOF

Actions:
  persistence-fail     Read-only data dir + BGSAVE to trigger MISCONF chain
  io-stress            Sustained disk write on Redis data dir (not tmpfs)

Examples:
  $0 --action persistence-fail --node 10.10.26.146:6379 --duration 600
  $0 --action io-stress --target-host 10.10.26.144 --duration 600
EOF
}

recover_persistence_fail() {
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
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    --data-dir) REDIS_DATA_DIR="$2"; shift 2 ;;
    --io-dir) IO_DIR="$2"; shift 2 ;;
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
    bind_target_from_node "${NODE}"
    resolve_data_dir "${NODE}"
    port="${NODE##*:}"
    RCLI="$(remote_redis_cli "127.0.0.1" "${port}")"
    inject_begin persistence-fail recover_persistence_fail
    MISCONF_BEFORE="$(misconf_count "${NODE}")"
    log "persistence failure on ${NODE} via ${INJECT_BACKEND} $(target_label)"
    run_on_target "chmod -R a-w ${REDIS_DATA_DIR}"
    run_on_target "find ${REDIS_DATA_DIR} -type f -exec chmod a-w {} + 2>/dev/null || true"
    run_on_target "${RCLI} CONFIG SET stop-writes-on-bgsave-error yes >/dev/null 2>&1 || true"
    run_on_target "${RCLI} BGSAVE >/dev/null 2>&1 || true"
    post_check_misconf_increment "${NODE}" "${MISCONF_BEFORE}" || inject_fail "MISCONF not incremented"
    inject_pass "MISCONF triggered on $(target_label)"
    run_timed_fault "${DURATION}" recover_persistence_fail
    ;;
  io-stress)
    parse_duration
    require_target
    resolve_io_dir "${NODE:-$(first_node)}"
    inject_begin io-stress recover_io_stress
    (
      run_on_target "
        mkdir -p ${IO_DIR}
        end=\$((SECONDS+${DURATION}))
        while (( SECONDS < end )); do
          dd if=/dev/zero of=${IO_DIR}/fault.bin bs=1M count=256 conv=fdatasync >/dev/null 2>&1 || true
        done
      "
    ) &
    IO_PID=$!
    inject_pass "disk io on ${IO_DIR}@$(target_label)"
    run_timed_fault "${DURATION}" recover_io_stress
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
