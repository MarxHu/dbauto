#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""
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
  baseline     Produce/consume + broker API on all nodes (KF001)
  cpu          Sustained CPU (KF002)
  memory       Memory pressure (KF004)
  cpu-spike    Periodic CPU bursts (KF003)
  multi-cpu    CPU on all nodes (KF007)
  reboot       Restart target container/VM (KF006) --confirm YES
  clock-skew   Shift clock forward then restore (KF010)

Examples:
  $0 --action cpu --target-host 10.10.26.144 --duration 600
  $0 --action reboot --target-container kafka-n1 --confirm YES
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
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action

case "${ACTION}" in
  baseline)
    for node in ${KAFKA_NODES}; do
      broker_api_ok "${node}" || die "node unhealthy: ${node}"
      log "API ok: ${node}"
    done
    ensure_topic "${FAULT_TOPIC}" 3 3
    msg="baseline-$(date +%s)"
    printf '%s\n' "${msg}" | timeout 15 "${KAFKA_HOME}/bin/kafka-console-producer.sh" \
      --bootstrap-server "${BOOTSTRAP}" --topic "${FAULT_TOPIC}" >/dev/null \
      || die "produce failed"
    emit_inject_result "KF001" "pass" "all brokers up produce ok"
    ;;
  cpu)
    acquire_inject_lock; require_target; parse_duration
    inject_begin KF002 recover_cpu
    run_on_target "command -v stress-ng >/dev/null" || inject_fail "stress-ng missing in $(target_label)"
    run_on_target "nohup stress-ng --cpu 0 --cpu-load ${CPU_LOAD} --timeout ${DURATION}s >/tmp/kafka_fault_cpu.log 2>&1 &"
    post_check_cpu 80 || inject_fail "post-check cpu<80"
    inject_pass "cpu>=80 on $(target_label)"
    run_timed_fault "${DURATION}" recover_cpu
    ;;
  memory)
    acquire_inject_lock; require_target; parse_duration
    inject_begin KF004 recover_memory
    run_on_target "command -v stress-ng >/dev/null" || inject_fail "stress-ng missing"
    run_on_target "nohup stress-ng --vm ${MEM_WORKERS} --vm-bytes ${MEM_PERCENT}% --timeout ${DURATION}s >/tmp/kafka_fault_mem.log 2>&1 &"
    post_check_memory 15 85 || inject_fail "post-check memory not pressured"
    inject_pass "memory pressured on $(target_label)"
    run_timed_fault "${DURATION}" recover_memory
    ;;
  cpu-spike)
    acquire_inject_lock; require_target; parse_duration
    inject_begin KF003 recover_cpu_spike
    (
      end=$((SECONDS + DURATION))
      while (( SECONDS < end )); do
        run_on_target "stress-ng --cpu 0 --cpu-load 95 --timeout ${BURST_SEC}s >/dev/null 2>&1 || true" || true
        sleep 20
      done
    ) &
    SPIKE_PID=$!
    inject_pass "burst started on $(target_label)"
    run_timed_fault "${DURATION}" recover_cpu_spike
    ;;
  multi-cpu)
    acquire_inject_lock; parse_duration; require_all_targets_ok
    inject_begin KF007 true
    for node in ${KAFKA_NODES}; do
      host="${node%%:*}"
      INJECT_LOCK_SKIP=1 bash "${SCRIPT_DIR}/inject_host.sh" \
        --action cpu --duration "${DURATION}" --target-host "${host}" &
    done
    wait
    emit_inject_result "KF007" "pass" "multi-cpu launched"
    INJECT_RESULT_EMITTED=1
    trap - EXIT
    ;;
  reboot)
    require_target
    [[ "${CONFIRM}" == "YES" ]] || die "reboot requires --confirm YES"
    inject_begin KF006 true
    restart_target
    inject_pass "restarted $(target_label)"
    ;;
  clock-skew)
    acquire_inject_lock; require_target; parse_duration
    inject_begin KF010 recover_clock
    CLOCK_SAVED="$(run_on_target "date +%s")"
    run_on_target "date -s @\$(( \$(date +%s) + ${SKEW_SEC} )) >/dev/null"
    inject_pass "clock +${SKEW_SEC}s on $(target_label)"
    run_timed_fault "${DURATION}" recover_clock
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
