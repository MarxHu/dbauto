#!/usr/bin/env bash
# Verify lab prerequisites before running injection scenarios.
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

log "=== MySQL fault injection preflight ==="
log "backend=${INJECT_BACKEND} dry_run=${INJECT_DRY_RUN}"

for cmd in bash flock; do
  command -v "${cmd}" >/dev/null 2>&1 && ok "bot has ${cmd}" || bad "bot missing ${cmd}"
done

if dry; then
  ok "DRY_RUN: skip mysql/docker live checks"
  touch "${DOCKER_ALL_OK}"
  log "=== summary: pass=${PASS} fail=${FAIL} warn=${WARN} ==="
  [[ "${FAIL}" -eq 0 ]] || exit 1
  exit 0
fi

if command -v mysql >/dev/null 2>&1; then
  ok "bot has mysql client"
else
  bad "bot missing mysql client"
fi

if [[ -n "${MYSQL_PASSWORD}" ]]; then
  ok "MYSQL_PASSWORD configured"
else
  bad "MYSQL_PASSWORD empty; set it in config.env"
fi

if [[ -f "${INJECT_LOCK_FILE}" ]]; then
  warn "lock file exists: ${INJECT_LOCK_FILE}"
else
  ok "no active injection lock"
fi

rm -f "${DOCKER_ALL_OK}" "${STATE_DIR}/ssh_all_nodes.ok"

if [[ "${INJECT_BACKEND}" == "docker" ]]; then
  command -v docker >/dev/null 2>&1 && ok "bot has docker" || bad "bot missing docker"
  if docker info >/dev/null 2>&1; then
    ok "docker daemon reachable"
  else
    bad "docker daemon not reachable"
  fi
  for node in ${MYSQL_NODES}; do
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
      for req in stress-ng vmstat chmod dd iptables tc; do
        if docker_cmd_check "${ctn}" "${req}"; then
          ok "${req} in ${ctn}"
        else
          bad "${req} missing in ${ctn}"
        fi
      done
    else
      bad "no docker container for ${host}; set MYSQL_CONTAINER_MAP"
    fi
  done
  if [[ "${TARGET_OK}" -eq "${TARGET_TOTAL}" ]] && [[ "${TARGET_TOTAL}" -gt 0 ]]; then
    touch "${DOCKER_ALL_OK}"
    ok "all ${TARGET_TOTAL} docker nodes ready"
  else
    warn "not all docker nodes ready (multi-cpu / partition disabled)"
  fi
elif [[ "${INJECT_BACKEND}" == "ssh" ]]; then
  command -v ssh >/dev/null 2>&1 && ok "bot has ssh" || bad "bot missing ssh"
  for node in ${MYSQL_NODES}; do
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

for node in ${MYSQL_NODES}; do
  if mysql_ok "${node}"; then
    ok "SELECT 1 ${node} role=$(node_role "${node}")"
  else
    bad "SELECT 1 failed ${node}"
  fi
done

prim="$(primary_node)"
if mysql_ok "${prim}"; then
  log "primary=${prim} semi_status=$(semi_status "${prim}")"
fi
for n in ${MYSQL_REPLICAS}; do
  log "replica ${n} IO=$(io_state "${n}") SQL=$(sql_state "${n}")"
done

log "=== summary: pass=${PASS} fail=${FAIL} warn=${WARN} ==="
[[ "${FAIL}" -eq 0 ]] || exit 1
