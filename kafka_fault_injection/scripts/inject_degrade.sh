#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""
BLOCKED_HOST="${BLOCKED_HOST:-10.10.26.146}"
BLOCKED_PORT="${BLOCKED_PORT:-9092}"
HIDE_BINS="${HIDE_BINS:-iostat jstat pidstat}"

usage() {
  usage_header
  cat <<EOF

Degrade the *troubleshooting* collector, not Kafka itself:
  job-unreachable   iptables on THIS host blocking one Kafka IP (KF117/KF074)
  hide-tools        move iostat/jstat aside (KF118/KF119)

Run on the injector/diagnose host.
EOF
}

recover_unreach() {
  iptables -D OUTPUT -d "${BLOCKED_HOST}" -p tcp --dport "${BLOCKED_PORT}" -j DROP 2>/dev/null || true
  iptables -D OUTPUT -d "${BLOCKED_HOST}" -p tcp --dport "${CONTROLLER_PORT}" -j DROP 2>/dev/null || true
}
HIDDEN_DIR=""
recover_hide() {
  if [[ -d /tmp/kafka_hidden_tools ]]; then
    mv /tmp/kafka_hidden_tools/* /usr/bin/ 2>/dev/null || mv /tmp/kafka_hidden_tools/* /usr/local/bin/ 2>/dev/null || true
  fi
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
parse_duration

case "${ACTION}" in
  job-unreachable)
    inject_begin KF117 recover_unreach
    iptables -I OUTPUT -d "${BLOCKED_HOST}" -p tcp --dport "${BLOCKED_PORT}" -j DROP
    iptables -I OUTPUT -d "${BLOCKED_HOST}" -p tcp --dport "${CONTROLLER_PORT}" -j DROP
    inject_pass "blocked ${BLOCKED_HOST}:${BLOCKED_PORT}/${CONTROLLER_PORT} from injector"
    run_timed_fault "${DURATION}" recover_unreach
    ;;
  hide-tools)
    inject_begin KF118 recover_hide
    mkdir -p /tmp/kafka_hidden_tools
    for b in ${HIDE_BINS}; do
      p="$(command -v "${b}" 2>/dev/null || true)"
      if [[ -n "$p" && -x "$p" ]]; then
        mv "$p" /tmp/kafka_hidden_tools/
        log "hid ${p}"
      fi
    done
    inject_pass "hid tools: ${HIDE_BINS}"
    run_timed_fault "${DURATION}" recover_hide
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
