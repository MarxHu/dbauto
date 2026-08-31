#!/usr/bin/env bash
# Verify lab prerequisites before running injection scenarios.
# Default model: injection bot on docker-node; Redis in Docker containers (simulated VMs).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

PASS=0
FAIL=0
WARN=0
TARGET_OK=0
TARGET_TOTAL=0

ok() { log "PASS: $*"; PASS=$((PASS + 1)); }
bad() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }
warn() { log "WARN: $*"; WARN=$((WARN + 1)); }

log "=== Redis fault injection preflight ==="
log "scope: injection behavior only; diagnosis bot is separate"
log "backend: INJECT_BACKEND=${INJECT_BACKEND}"

case "${INJECT_BACKEND}" in
  docker)
    log "model: bot on docker-node; host faults via docker exec into Redis containers"
    ;;
  ssh)
    log "model: bot SSHes into real VMs"
    ;;
  local)
    log "model: faults run on this machine"
    ;;
esac

for cmd in bash redis-cli flock; do
  command -v "${cmd}" >/dev/null 2>&1 && ok "bot has ${cmd}" || bad "bot missing ${cmd}"
done

if [[ -f "${INJECT_LOCK_FILE}" ]]; then
  warn "lock file exists: ${INJECT_LOCK_FILE} (stale injection?)"
else
  ok "no active injection lock"
fi

if [[ -n "${REDIS_PASSWORD}" ]]; then
  ok "REDIS_PASSWORD configured in config.env"
else
  bad "REDIS_PASSWORD empty; set it in config.env"
fi

# --- backend-specific target checks ----------------------------------------
rm -f "${DOCKER_ALL_OK}" "${STATE_DIR}/ssh_all_nodes.ok"

if [[ "${INJECT_BACKEND}" == "docker" ]]; then
  if command -v docker >/dev/null 2>&1; then
    ok "bot has docker"
  else
    bad "bot missing docker (required for INJECT_BACKEND=docker)"
  fi

  if ! docker info >/dev/null 2>&1; then
    bad "docker daemon not reachable (permission or service down)"
  else
    ok "docker daemon reachable"
  fi

  for node in ${REDIS_NODES}; do
    host="${node%%:*}"
    TARGET_TOTAL=$((TARGET_TOTAL + 1))
    ctn=""
    if ctn="$(resolve_container "${host}" 2>/dev/null)"; then
      ok "container for ${host}: ${ctn}"
      if docker_check "${ctn}"; then
        ok "container running: ${ctn}"
        TARGET_OK=$((TARGET_OK + 1))
      else
        bad "container not running: ${ctn}"
        continue
      fi

      if docker_cmd_check "${ctn}" stress-ng; then
        ok "stress-ng in ${ctn}"
      else
        bad "stress-ng missing in ${ctn} (NODE_SPEC required)"
      fi
      for req in vmstat chmod dd iptables tc; do
        if docker_cmd_check "${ctn}" "${req}"; then
          ok "${req} in ${ctn}"
        else
          bad "${req} missing in ${ctn} (NODE_SPEC required)"
        fi
      done
    else
      bad "no docker container for ${host} (set REDIS_CONTAINER_MAP=\"${host}:<name> ...\" or REDIS_CONTAINERS)"
    fi
  done

  if [[ "${TARGET_OK}" -eq "${TARGET_TOTAL}" ]] && [[ "${TARGET_TOTAL}" -gt 0 ]]; then
    touch "${DOCKER_ALL_OK}"
    ok "all ${TARGET_TOTAL} docker nodes ready (F28 multi-cpu enabled)"
  else
    warn "not all docker nodes ready (F28 multi-cpu disabled)"
  fi

elif [[ "${INJECT_BACKEND}" == "ssh" ]]; then
  command -v ssh >/dev/null 2>&1 && ok "bot has ssh" || bad "bot missing ssh"
  for cmd in iptables tc; do
    command -v "${cmd}" >/dev/null 2>&1 && ok "bot has ${cmd}" || warn "bot missing ${cmd}"
  done
  for node in ${REDIS_NODES}; do
    host="${node%%:*}"
    TARGET_TOTAL=$((TARGET_TOTAL + 1))
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${host}" "echo ok" >/dev/null 2>&1; then
      ok "SSH ${SSH_USER}@${host}"
      TARGET_OK=$((TARGET_OK + 1))
    else
      bad "SSH failed ${SSH_USER}@${host}"
    fi
  done
  if [[ "${TARGET_OK}" -eq "${TARGET_TOTAL}" ]] && [[ "${TARGET_TOTAL}" -gt 0 ]]; then
    touch "${STATE_DIR}/ssh_all_nodes.ok"
    touch "${DOCKER_ALL_OK}"
    ok "all ${TARGET_TOTAL} SSH nodes ready"
  fi
else
  for cmd in stress-ng vmstat iptables tc; do
    command -v "${cmd}" >/dev/null 2>&1 && ok "bot has ${cmd}" || warn "bot missing ${cmd}"
  done
  touch "${DOCKER_ALL_OK}"
  ok "local backend: treat this host as injection target"
fi

# --- Redis connectivity ----------------------------------------------------
for node in ${REDIS_NODES}; do
  if redis_cmd "${node}" PING 2>/dev/null | grep -q PONG; then
    ok "redis PING ${node}"
  else
    bad "redis PING failed ${node}"
  fi
done

detected_dir="$(detect_redis_data_dir || true)"
if [[ -n "${detected_dir}" ]]; then
  if [[ "${REDIS_DATA_DIR}" == "auto" || -z "${REDIS_DATA_DIR}" ]]; then
    ok "CONFIG GET dir=${detected_dir} (REDIS_DATA_DIR=auto will use it)"
  elif [[ "${detected_dir}" == "${REDIS_DATA_DIR}" ]]; then
    ok "CONFIG GET dir matches REDIS_DATA_DIR (${detected_dir})"
  else
    warn "CONFIG GET dir=${detected_dir} differs from REDIS_DATA_DIR=${REDIS_DATA_DIR}; prefer REDIS_DATA_DIR=auto"
  fi
else
  warn "could not read CONFIG GET dir"
fi

node="$(first_node)"
if redis_cmd "${node}" DEBUG SLEEP 1 >/dev/null 2>&1; then
  ok "DEBUG SLEEP enabled on ${node}"
else
  warn "DEBUG SLEEP unavailable on ${node}"
fi

log "=== summary: pass=${PASS} fail=${FAIL} warn=${WARN} ==="
log "hint: docker backend needs REDIS_CONTAINER_MAP or matching container IPs"
[[ "${FAIL}" -eq 0 ]] || exit 1
