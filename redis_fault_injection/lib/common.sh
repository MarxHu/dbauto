#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/config.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/config.env"
fi

REDIS_NODES="${REDIS_NODES:-10.10.26.144:6381 10.10.26.145:6381 10.10.26.146:6381}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
REDIS_CLI="${REDIS_CLI:-redis-cli}"
CLUSTER_BUS_PORT="${CLUSTER_BUS_PORT:-16379}"
TARGET_HOST="${TARGET_HOST:-}"
FAULT_DURATION_SEC="${FAULT_DURATION_SEC:-240}"
SSH_USER="${SSH_USER:-root}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
STATE_DIR="${ROOT_DIR}/.state"

mkdir -p "${STATE_DIR}"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

run_on_target() {
  local cmd="$1"
  if [[ -n "${TARGET_HOST}" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${TARGET_HOST}" "${cmd}"
  else
    bash -lc "${cmd}"
  fi
}

redis_cmd() {
  local addr="$1"
  shift
  local host port
  host="${addr%%:*}"
  port="${addr##*:}"
  if [[ -n "${REDIS_PASSWORD}" ]]; then
    "${REDIS_CLI}" -h "${host}" -p "${port}" -a "${REDIS_PASSWORD}" --no-auth-warning "$@"
  else
    "${REDIS_CLI}" -h "${host}" -p "${port}" "$@"
  fi
}

first_node() {
  echo "${REDIS_NODES%% *}"
}

parse_duration() {
  DURATION="${DURATION:-${FAULT_DURATION_SEC}}"
  [[ "${DURATION}" =~ ^[0-9]+$ ]] || die "--duration must be a positive integer (seconds)"
}

usage_header() {
  cat <<EOF
Usage: $0 --action <name> [options]

Common options:
  --duration <sec>       Fault active time, auto-recover after expiry (default: ${FAULT_DURATION_SEC})
  --target-host <ip>     Run host-level fault on this VM via SSH (default: local)
  --node <ip:port>       Redis endpoint (default: first node in config)
  -h, --help             Show help

All faults auto-recover when duration elapses. No separate recover command.
EOF
}

run_timed_fault() {
  local duration="$1"
  local cleanup_fn="$2"
  trap "${cleanup_fn}" EXIT INT TERM
  log "fault active for ${duration}s, will auto-recover"
  sleep "${duration}"
  "${cleanup_fn}"
  trap - EXIT INT TERM
  log "auto-recovered"
}

require_action() {
  [[ -n "${ACTION:-}" ]] || die "missing --action"
}

resolve_node() {
  NODE="${NODE:-$(first_node)}"
}
