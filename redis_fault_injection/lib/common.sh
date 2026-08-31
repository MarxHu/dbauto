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
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing command: ${cmd}"
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

state_file() {
  echo "${STATE_DIR}/$1"
}

save_state() {
  local name="$1"
  local value="$2"
  printf '%s' "${value}" > "$(state_file "${name}")"
}

load_state() {
  local name="$1"
  local default="${2:-}"
  local file
  file="$(state_file "${name}")"
  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    printf '%s' "${default}"
  fi
}

usage_duration() {
  cat <<EOF
Duration:
  Sustained faults for AI diagnosis should run about ${FAULT_DURATION_SEC}s (>=240s recommended).
  Override with: DURATION=<seconds> $0
EOF
}

parse_duration() {
  DURATION="${DURATION:-${FAULT_DURATION_SEC}}"
  [[ "${DURATION}" =~ ^[0-9]+$ ]] || die "DURATION must be an integer second value"
}

background_pid_file() {
  echo "${STATE_DIR}/$1.pid"
}

start_background() {
  local name="$1"
  shift
  local pid_file
  pid_file="$(background_pid_file "${name}")"
  if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
    die "${name} already running (pid $(cat "${pid_file}"))"
  fi
  nohup "$@" >/dev/null 2>&1 &
  echo $! > "${pid_file}"
  log "started ${name}, pid=$(cat "${pid_file}")"
}

stop_background() {
  local name="$1"
  local pid_file
  pid_file="$(background_pid_file "${name}")"
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      log "stopped ${name}, pid=${pid}"
    fi
    rm -f "${pid_file}"
  else
    log "${name} not running"
  fi
}
