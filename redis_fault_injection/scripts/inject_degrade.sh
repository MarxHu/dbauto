#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""
DURATION=""
BLOCKED_HOST="${BLOCKED_HOST:-10.10.26.146}"
BLOCKED_PORT="${BLOCKED_PORT:-6379}"
HIDE_DIR="${HIDE_DIR:-/tmp/redis_fault_hidden_bins}"

usage() {
  usage_header
  cat <<EOF

Actions:
  job-unreachable      Block local outbound access to one Redis endpoint (same-machine mode)
  hide-tools           Temporarily hide iostat/pidstat from PATH

Extra options:
  --blocked-host <ip>
  --blocked-port <port>   default 6381

Examples:
  $0 --action job-unreachable --blocked-host 10.10.26.146 --blocked-port 6381 --duration 600
  $0 --action hide-tools --duration 600
EOF
}

recover_job_unreachable() {
  run_on_target "
    iptables -D OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${BLOCKED_PORT} -j DROP 2>/dev/null || true
  "
}

recover_hide_tools() {
  run_on_target "
    for bak in ${HIDE_DIR}/*.bak; do
      [[ -f \"\$bak\" ]] || continue
      orig=\$(basename \"\$bak\" .bak)
      mv \"\$bak\" /usr/bin/\$orig 2>/dev/null || mv \"\$bak\" /usr/local/bin/\$orig 2>/dev/null || true
    done
  "
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --blocked-host) BLOCKED_HOST="$2"; shift 2 ;;
    --blocked-port) BLOCKED_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
acquire_inject_lock

case "${ACTION}" in
  job-unreachable)
    parse_duration
    log "block local -> ${BLOCKED_HOST}:${BLOCKED_PORT} for ${DURATION}s"
    run_on_target "
      iptables -C OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${BLOCKED_PORT} -j DROP 2>/dev/null || \
      iptables -A OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${BLOCKED_PORT} -j DROP
    "
    run_timed_fault "${DURATION}" recover_job_unreachable
    ;;
  hide-tools)
    parse_duration
    log "hide iostat/pidstat for ${DURATION}s"
    run_on_target "
      mkdir -p ${HIDE_DIR}
      for cmd in iostat pidstat; do
        path=\$(command -v \$cmd 2>/dev/null || true)
        if [[ -n \"\$path\" ]]; then
          mv \"\$path\" ${HIDE_DIR}/\$(basename \$path).bak
        fi
      done
    "
    run_timed_fault "${DURATION}" recover_hide_tools
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
