#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""
BLOCKED_HOST="${BLOCKED_HOST:-$(echo "${MYSQL_REPLICAS}" | awk '{print $NF}' | cut -d: -f1)}"
BLOCKED_PORT="${BLOCKED_PORT:-${MYSQL_PORT}}"
HIDE_BINS="${HIDE_BINS:-iostat mysql pidstat}"

usage() {
  usage_header
  cat <<EOF

Degrade the troubleshooting collector, not mysqld:
  job-unreachable   iptables on THIS host blocking one MySQL IP:port (MY172)
  hide-tools        move iostat/mysql/pidstat aside (MY171)

Run on the injector/diagnose host.
EOF
}

recover_unreach() {
  dry && return 0
  injector_iptables -D OUTPUT -d "${BLOCKED_HOST}" -p tcp --dport "${BLOCKED_PORT}" -j DROP 2>/dev/null || true
}

HIDDEN_DIR="/tmp/mysql_hidden_tools"
recover_hide() {
  dry && return 0
  if [[ -d "${HIDDEN_DIR}" ]]; then
    mv "${HIDDEN_DIR}"/* /usr/bin/ 2>/dev/null || mv "${HIDDEN_DIR}"/* /usr/local/bin/ 2>/dev/null || true
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
    inject_begin MY172 recover_unreach
    if dry; then
      log "DRY iptables OUTPUT DROP ${BLOCKED_HOST}:${BLOCKED_PORT}"
    else
      injector_iptables -I OUTPUT -d "${BLOCKED_HOST}" -p tcp --dport "${BLOCKED_PORT}" -j DROP
    fi
    inject_pass "blocked ${BLOCKED_HOST}:${BLOCKED_PORT} from injector"
    run_timed_fault "${DURATION}" recover_unreach
    ;;
  hide-tools)
    inject_begin MY171 recover_hide
    if dry; then
      log "DRY would hide: ${HIDE_BINS}"
    else
      mkdir -p "${HIDDEN_DIR}"
      for b in ${HIDE_BINS}; do
        p="$(command -v "${b}" 2>/dev/null || true)"
        if [[ -n "$p" && -x "$p" ]]; then
          mv "$p" "${HIDDEN_DIR}/"
          log "hid ${p}"
        fi
      done
    fi
    inject_pass "hid tools: ${HIDE_BINS}"
    run_timed_fault "${DURATION}" recover_hide
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
