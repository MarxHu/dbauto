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
FAULT_DURATION_SEC="${FAULT_DURATION_SEC:-600}"
SSH_USER="${SSH_USER:-root}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
STATE_DIR="${ROOT_DIR}/.state"
INJECT_LOCK_FILE="${STATE_DIR}/inject.lock"

if [[ -n "${REDIS_PASSWORD}" ]]; then
  export REDISCLI_AUTH="${REDIS_PASSWORD}"
fi

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

acquire_inject_lock() {
  [[ "${INJECT_LOCK_SKIP:-}" == "1" ]] && return 0
  exec 200>"${INJECT_LOCK_FILE}"
  if ! flock -n 200; then
    die "another injection is active (${INJECT_LOCK_FILE}); wait until it auto-recovers"
  fi
  log "acquired injection lock"
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

redis_cmd_nocluster() {
  local addr="$1"
  shift
  local host port
  host="${addr%%:*}"
  port="${addr##*:}"
  if [[ -n "${REDIS_PASSWORD}" ]]; then
    "${REDIS_CLI}" --no-auth-warning -h "${host}" -p "${port}" -a "${REDIS_PASSWORD}" "$@"
  else
    "${REDIS_CLI}" --no-auth-warning -h "${host}" -p "${port}" "$@"
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
  --target-host <ip>     Optional remote host via SSH (default: local machine)
  --node <ip:port>       Redis endpoint (default: first node in config)
  -h, --help             Show help

Injection bot runs one action at a time; lock file: ${INJECT_LOCK_FILE}
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

node_state_key() {
  echo "${1//[:.]/_}"
}

misconf_state_file() {
  echo "${STATE_DIR}/misconf_$(node_state_key "${1}")"
}

save_misconf_state() {
  local node="$1"
  local field="$2"
  local value="$3"
  local file
  file="$(misconf_state_file "${node}")"
  touch "${file}"
  printf '%s=%s\n' "${field}" "${value}" >> "${file}"
}

load_misconf_state() {
  local node="$1"
  local field="$2"
  local default="${3:-}"
  local file
  file="$(misconf_state_file "${node}")"
  if [[ -f "${file}" ]]; then
    grep "^${field}=" "${file}" | tail -1 | cut -d= -f2- || printf '%s' "${default}"
  else
    printf '%s' "${default}"
  fi
}

clear_misconf_state() {
  rm -f "$(misconf_state_file "${1}")"
}

remote_redis_cli() {
  local host="$1"
  local port="$2"
  if [[ -n "${REDIS_PASSWORD}" ]]; then
    printf 'redis-cli --no-auth-warning -h %s -p %s -a %q' "${host}" "${port}" "${REDIS_PASSWORD}"
  else
    printf 'redis-cli --no-auth-warning -h %s -p %s' "${host}" "${port}"
  fi
}

detect_redis_data_dir() {
  local node="${1:-$(first_node)}"
  redis_cmd "${node}" CONFIG GET dir 2>/dev/null | awk 'NR==2{print; exit}'
}
