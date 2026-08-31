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

usage() {
  usage_header
  cat <<EOF

Actions:
  baseline          Health check only, no fault
  cpu               Sustained host CPU pressure
  memory            Host memory pressure
  cpu-spike         Periodic CPU bursts
  multi-cpu         CPU pressure on all configured cluster hosts
  reboot            Reboot target host (no auto-recover; requires --confirm YES)

Examples:
  $0 --action cpu --duration 600
  $0 --action memory --duration 600
  $0 --action multi-cpu --duration 600
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
    log "baseline ok; run diagnosis pipeline"
    ;;
  cpu)
    acquire_inject_lock
    parse_duration
    require_cmd stress-ng
    run_on_target "nohup stress-ng --cpu 0 --cpu-load ${CPU_LOAD} --timeout ${DURATION}s >/tmp/redis_fault_cpu.log 2>&1 &"
    run_timed_fault "${DURATION}" recover_cpu
    ;;
  memory)
    acquire_inject_lock
    parse_duration
    require_cmd stress-ng
    run_on_target "nohup stress-ng --vm ${MEM_WORKERS} --vm-bytes ${MEM_PERCENT}% --timeout ${DURATION}s >/tmp/redis_fault_mem.log 2>&1 &"
    run_timed_fault "${DURATION}" recover_memory
    ;;
  cpu-spike)
    acquire_inject_lock
    parse_duration
    require_cmd stress-ng
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )); do
        stress-ng --cpu 0 --cpu-load 95 --timeout ${BURST_SEC}s >/dev/null 2>&1 || true
        sleep 20
      done
    " &
    SPIKE_PID=$!
    run_timed_fault "${DURATION}" recover_cpu_spike
    ;;
  multi-cpu)
    acquire_inject_lock
    parse_duration
    for node in ${REDIS_NODES}; do
      host="${node%%:*}"
      log "start cpu fault on ${host} for ${DURATION}s"
      INJECT_LOCK_SKIP=1 TARGET_HOST="${host}" bash "${SCRIPT_DIR}/inject_host.sh" \
        --action cpu --duration "${DURATION}" --target-host "${host}" &
    done
    wait
    log "all host cpu faults finished and auto-recovered"
    ;;
  reboot)
    acquire_inject_lock
    [[ "${CONFIRM}" == "YES" ]] || die "reboot requires --confirm YES"
    log "rebooting ${TARGET_HOST:-localhost} in 5s (no auto-recover)"
    run_on_target "sleep 5 && reboot"
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
