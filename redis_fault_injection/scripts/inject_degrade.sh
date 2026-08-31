#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""
DURATION=""
BLOCKED_HOST="${BLOCKED_HOST:-10.10.26.146}"
COLLECTOR_PORT="${COLLECTOR_PORT:-22}"
HIDE_DIR="${HIDE_DIR:-/tmp/redis_fault_hidden_bins}"

usage() {
  usage_header
  cat <<EOF

Actions:
  job-unreachable      Block collector SSH to one host
  hide-tools           Temporarily hide iostat/pidstat from PATH

Extra options:
  --blocked-host <ip>
  --collector-port <port>

Examples:
  $0 --action job-unreachable --blocked-host 10.10.26.146 --duration 240
  $0 --action hide-tools --duration 240
EOF
}

recover_job_unreachable() {
  run_on_target "iptables -D OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${COLLECTOR_PORT} -j DROP 2>/dev/null || true"
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
    --collector-port) COLLECTOR_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action

case "${ACTION}" in
  job-unreachable)
    parse_duration
    log "block collector -> ${BLOCKED_HOST}:${COLLECTOR_PORT} for ${DURATION}s"
    run_on_target "
      iptables -C OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${COLLECTOR_PORT} -j DROP 2>/dev/null || \
      iptables -A OUTPUT -d ${BLOCKED_HOST} -p tcp --dport ${COLLECTOR_PORT} -j DROP
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
