#!/usr/bin/env bash
# Verify lab prerequisites before running injection scenarios.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

PASS=0
FAIL=0
WARN=0
SSH_OK=0
SSH_TOTAL=0

ok() { log "PASS: $*"; PASS=$((PASS + 1)); }
bad() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }
warn() { log "WARN: $*"; WARN=$((WARN + 1)); }

log "=== Redis fault injection preflight ==="
log "scope: injection behavior only; diagnosis bot is separate"
log "model: injection bot outside Docker/VM; faults SSH into Redis VM nodes"

for cmd in bash redis-cli flock ssh; do
  command -v "${cmd}" >/dev/null 2>&1 && ok "bot has ${cmd}" || bad "bot missing ${cmd}"
done

for cmd in iptables tc; do
  command -v "${cmd}" >/dev/null 2>&1 && ok "bot has ${cmd}" || warn "bot missing ${cmd} (network scenarios need it on target VM or bot)"
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

for node in ${REDIS_NODES}; do
  host="${node%%:*}"
  SSH_TOTAL=$((SSH_TOTAL + 1))
  if ssh_check "${host}"; then
    ok "SSH ${SSH_USER}@${host}"
    SSH_OK=$((SSH_OK + 1))
    if remote_cmd_check "${host}" stress-ng; then
      ok "stress-ng on ${host}"
    else
      bad "stress-ng missing on ${host} (install on VM for CPU/memory faults)"
    fi
    if remote_cmd_check "${host}" vmstat; then
      ok "vmstat on ${host}"
    else
      warn "vmstat missing on ${host} (post-check may fail)"
    fi
    data_dir_ok="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${host}" \
      "test -d ${REDIS_DATA_DIR} && echo yes || echo no" 2>/dev/null || echo no)"
    if [[ "${data_dir_ok}" == "yes" ]]; then
      ok "REDIS_DATA_DIR exists on ${host}: ${REDIS_DATA_DIR}"
    else
      warn "REDIS_DATA_DIR not found on ${host}: ${REDIS_DATA_DIR}"
    fi
  else
    bad "SSH failed ${SSH_USER}@${host} (required for host-level faults)"
  fi
done

if [[ "${SSH_OK}" -eq "${SSH_TOTAL}" ]] && [[ "${SSH_TOTAL}" -gt 0 ]]; then
  touch "${STATE_DIR}/ssh_all_nodes.ok"
  ok "all ${SSH_TOTAL} VM nodes SSH reachable (F28 multi-cpu enabled)"
else
  rm -f "${STATE_DIR}/ssh_all_nodes.ok"
  warn "not all VM nodes SSH reachable (F28 multi-cpu disabled)"
fi

for node in ${REDIS_NODES}; do
  if redis_cmd "${node}" PING 2>/dev/null | grep -q PONG; then
    ok "redis PING ${node}"
  else
    bad "redis PING failed ${node}"
  fi
done

detected_dir="$(detect_redis_data_dir || true)"
if [[ -n "${detected_dir}" ]]; then
  if [[ "${detected_dir}" == "${REDIS_DATA_DIR}" ]]; then
    ok "CONFIG GET dir matches REDIS_DATA_DIR (${detected_dir})"
  else
    warn "CONFIG GET dir=${detected_dir} differs from REDIS_DATA_DIR=${REDIS_DATA_DIR}"
  fi
fi

node="$(first_node)"
if redis_cmd "${node}" DEBUG SLEEP 1 >/dev/null 2>&1; then
  ok "DEBUG SLEEP enabled on ${node}"
else
  warn "DEBUG SLEEP unavailable on ${node}"
fi

log "=== summary: pass=${PASS} fail=${FAIL} warn=${WARN} ==="
[[ "${FAIL}" -eq 0 ]] || exit 1
