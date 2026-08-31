#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""
DURATION=""
CPU_LOAD="${CPU_LOAD:-90}"
MEM_WORKERS="${MEM_WORKERS:-2}"
MEM_PERCENT="${MEM_PERCENT:-85}"
BURST_SEC="${BURST_SEC:-2}"
CONFIRM="${CONFIRM:-}"
POSTCHECK_FAILED=0

usage() {
  usage_header
  cat <<EOF

Actions:
  baseline          Health check only, no fault
  cpu               Sustained host CPU pressure on --target-host VM
  memory            Host memory pressure on --target-host VM
  cpu-spike         Periodic CPU bursts on --target-host VM
  multi-cpu         CPU on all VM nodes (requires preflight ssh_all_nodes.ok)
  reboot            Reboot --target-host VM (requires --confirm YES)

Host-level actions require --target-host <VM IP> (bot runs outside Docker/VM).

Examples:
  $0 --action cpu --target-host 10.10.26.144 --duration 600
  $0 --action memory --target-host 10.10.26.144 --duration 600
EOF
}

recover_cpu() {
  run_on_target "pkill -f 'stress-ng --cpu' 2>/dev/null || true; rm -f /tmp/redis_fault_cpu.pid"
}

recover_memory() {
  run_on_target "pkill -f 'stress-ng --vm' 2>/dev/null || true; rm -f /tmp/redis_fault_mem.pid"
}

recover_cpu_spike() {
  run_on_target "pkill -f 'stress-ng --cpu' 2>/dev/null || true"
  [[ -n "${SPIKE_PID:-}" ]] && kill "${SPIKE_PID}" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --confirm) CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action

case "${ACTION}" in
  baseline)
    for node in ${REDIS_NODES}; do
      redis_cmd "${node}" PING >/dev/null || die "node unhealthy: ${node}"
      log "PING ok: ${node}"
    done
    emit_inject_result "baseline" "pass" "all nodes pong"
    ;;
  cpu)
    acquire_inject_lock
    require_target_host
    parse_duration
    run_on_target "command -v stress-ng >/dev/null" || die "stress-ng not installed on ${TARGET_HOST}"
    run_on_target "nohup stress-ng --cpu 0 --cpu-load ${CPU_LOAD} --timeout ${DURATION}s >/tmp/redis_fault_cpu.log 2>&1 &"
    post_check_cpu 80 || POSTCHECK_FAILED=1
    if [[ "${POSTCHECK_FAILED}" -eq 1 ]]; then
      recover_cpu
      emit_inject_result "cpu" "fail" "post-check cpu<80"
      exit 1
    fi
    emit_inject_result "cpu" "pass" "cpu>=80 on ${TARGET_HOST}"
    run_timed_fault "${DURATION}" recover_cpu
    ;;
  memory)
    acquire_inject_lock
    require_target_host
    parse_duration
    run_on_target "command -v stress-ng >/dev/null" || die "stress-ng not installed on ${TARGET_HOST}"
    run_on_target "nohup stress-ng --vm ${MEM_WORKERS} --vm-bytes ${MEM_PERCENT}% --timeout ${DURATION}s >/tmp/redis_fault_mem.log 2>&1 &"
    post_check_memory 15 || POSTCHECK_FAILED=1
    if [[ "${POSTCHECK_FAILED}" -eq 1 ]]; then
      recover_memory
      emit_inject_result "memory" "fail" "post-check mem avail>15%"
      exit 1
    fi
    emit_inject_result "memory" "pass" "memory_available<=15% on ${TARGET_HOST}"
    run_timed_fault "${DURATION}" recover_memory
    ;;
  cpu-spike)
    acquire_inject_lock
    require_target_host
    parse_duration
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )); do
        stress-ng --cpu 0 --cpu-load 95 --timeout ${BURST_SEC}s >/dev/null 2>&1 || true
        sleep 20
      done
    " &
    SPIKE_PID=$!
    emit_inject_result "cpu-spike" "pass" "burst started on ${TARGET_HOST}"
    run_timed_fault "${DURATION}" recover_cpu_spike
    ;;
  multi-cpu)
    acquire_inject_lock
    parse_duration
    require_ssh_all_nodes
    for node in ${REDIS_NODES}; do
      host="${node%%:*}"
      log "start cpu fault on ${host} for ${DURATION}s"
      INJECT_LOCK_SKIP=1 bash "${SCRIPT_DIR}/inject_host.sh" \
        --action cpu --duration "${DURATION}" --target-host "${host}" &
    done
    wait
    emit_inject_result "multi-cpu" "pass" "all nodes cpu injection completed"
    ;;
  reboot)
    acquire_inject_lock
    require_target_host
    [[ "${CONFIRM}" == "YES" ]] || die "reboot requires --confirm YES"
    log "rebooting ${TARGET_HOST} in 5s (no auto-recover)"
    run_on_target "sleep 5 && reboot"
    emit_inject_result "reboot" "pass" "reboot issued ${TARGET_HOST}"
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
