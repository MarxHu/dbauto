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
SKEW_SEC="${SKEW_SEC:-120}"
CONFIRM="${CONFIRM:-}"

usage() {
  usage_header
  cat <<EOF

Actions:
  baseline     SELECT 1 + replica IO/SQL ON (MY001)
  cpu          Sustained CPU (MY010 / MY010-R)
  memory       Memory pressure (MY011)
  cpu-spike    Periodic CPU bursts (MY010-S)
  multi-cpu    CPU on all nodes (MY010-M)
  reboot       Restart container/VM (MY035) --confirm YES
  clock-skew   Shift clock then restore (MY014)

Examples:
  $0 --action cpu --target-host 10.10.26.144 --duration 600
  $0 --action clock-skew --target-host 10.10.26.145 --duration 600 --skew-sec 120
EOF
}

recover_cpu() { run_on_target "pkill -f 'stress-ng --cpu' 2>/dev/null || true"; }
recover_memory() { run_on_target "pkill -f 'stress-ng --vm' 2>/dev/null || true"; }
recover_cpu_spike() {
  run_on_target "pkill -f 'stress-ng --cpu' 2>/dev/null || true"
  [[ -n "${SPIKE_PID:-}" ]] && kill "${SPIKE_PID}" 2>/dev/null || true
}
CLOCK_SAVED=""
recover_clock() {
  if [[ -n "${CLOCK_SAVED}" ]]; then
    run_on_target "date -s '@${CLOCK_SAVED}' >/dev/null 2>&1 || true"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    --confirm) CONFIRM="$2"; shift 2 ;;
    --skew-sec) SKEW_SEC="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action

scenario_for_cpu() {
  local host="${TARGET_HOST:-}"
  if [[ "${host}" == "${MYSQL_PRIMARY%%:*}" ]]; then
    echo MY010
  else
    echo MY010-R
  fi
}

case "${ACTION}" in
  baseline)
    for node in ${MYSQL_NODES}; do
      mysql_ok "${node}" || die "node unhealthy: ${node}"
      log "SELECT 1 ok: ${node} role=$(node_role "${node}")"
    done
    for n in ${MYSQL_REPLICAS}; do
      log "replica ${n} IO=$(io_state "${n}") SQL=$(sql_state "${n}")"
    done
    emit_inject_result "MY001" "pass" "all nodes reachable"
    ;;
  cpu)
    acquire_inject_lock; require_target; parse_duration
    inject_begin "$(scenario_for_cpu)" recover_cpu
    run_on_target "command -v stress-ng >/dev/null" || inject_fail "stress-ng missing in $(target_label)"
    run_on_target "nohup stress-ng --cpu 0 --cpu-load ${CPU_LOAD} --timeout ${DURATION}s >/tmp/mysql_fault_cpu.log 2>&1 &"
    post_check_cpu 80 || inject_fail "post-check cpu<80"
    inject_pass "cpu>=80 on $(target_label)"
    run_timed_fault "${DURATION}" recover_cpu
    ;;
  memory)
    acquire_inject_lock; require_target; parse_duration
    inject_begin MY011 recover_memory
    run_on_target "command -v stress-ng >/dev/null" || inject_fail "stress-ng missing in $(target_label)"
    run_on_target "nohup stress-ng --vm ${MEM_WORKERS} --vm-bytes ${MEM_PERCENT}% --timeout ${DURATION}s >/tmp/mysql_fault_mem.log 2>&1 &"
    post_check_memory 15 85 || inject_fail "post-check memory not pressured"
    inject_pass "memory pressured on $(target_label)"
    run_timed_fault "${DURATION}" recover_memory
    ;;
  cpu-spike)
    acquire_inject_lock; require_target; parse_duration
    inject_begin MY010-S recover_cpu_spike
    if (( DURATION > 0 )); then
      (
        end=$((SECONDS + DURATION))
        while (( SECONDS < end )); do
          run_on_target "stress-ng --cpu 0 --cpu-load 95 --timeout ${BURST_SEC}s >/dev/null 2>&1 || true" || true
          sleep 20
        done
      ) &
      SPIKE_PID=$!
    fi
    inject_pass "burst started on $(target_label)"
    run_timed_fault "${DURATION}" recover_cpu_spike
    ;;
  multi-cpu)
    acquire_inject_lock; parse_duration; require_all_targets_ok
    inject_begin MY010-M true
    for node in ${MYSQL_NODES}; do
      host="${node%%:*}"
      log "start cpu fault on ${host} for ${DURATION}s"
      INJECT_LOCK_SKIP=1 bash "${SCRIPT_DIR}/inject_host.sh" \
        --action cpu --duration "${DURATION}" --target-host "${host}" &
    done
    wait
    emit_inject_result "MY010-M" "pass" "all nodes cpu injection completed"
    INJECT_RESULT_EMITTED=1
    trap - EXIT
    ;;
  reboot)
    acquire_inject_lock; require_target
    require_confirm "reboot"
    inject_begin MY035 true
    log "restarting $(target_label) (no auto-recover of workload)"
    restart_target
    inject_pass "reboot/restart issued $(target_label)"
    ;;
  clock-skew)
    acquire_inject_lock; require_target; parse_duration
    inject_begin MY014 recover_clock
    CLOCK_SAVED="$(run_on_target "date +%s" 2>/dev/null || echo "")"
    if dry; then CLOCK_SAVED="${CLOCK_SAVED:-0}"; fi
    run_on_target "date -s @\$(( \$(date +%s) + ${SKEW_SEC} )) >/dev/null"
    inject_pass "clock +${SKEW_SEC}s on $(target_label)"
    run_timed_fault "${DURATION}" recover_clock
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
