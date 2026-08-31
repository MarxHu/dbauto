#!/usr/bin/env bash
# Verify lab prerequisites before running injection scenarios.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

PASS=0
FAIL=0
WARN=0

ok() { log "PASS: $*"; PASS=$((PASS + 1)); }
bad() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }
warn() { log "WARN: $*"; WARN=$((WARN + 1)); }

log "=== Redis fault injection preflight ==="
log "scope: injection behavior only; diagnosis is separate"
log "mode: ${TARGET_HOST:-local machine}"

for cmd in bash redis-cli stress-ng flock; do
  command -v "${cmd}" >/dev/null 2>&1 && ok "${cmd} present" || bad "${cmd} missing"
done

for cmd in iptables tc; do
  command -v "${cmd}" >/dev/null 2>&1 && ok "${cmd} present" || warn "${cmd} missing (network scenarios unavailable)"
done

if [[ -f "${INJECT_LOCK_FILE}" ]]; then
  warn "lock file exists: ${INJECT_LOCK_FILE} (stale injection?)"
else
  ok "no active injection lock"
fi

for node in ${REDIS_NODES}; do
  if redis_cmd "${node}" PING 2>/dev/null | grep -q PONG; then
    ok "redis PING ${node}"
  else
    bad "redis PING failed ${node}"
  fi
done

if [[ -d "${REDIS_DATA_DIR}" ]]; then
  ok "REDIS_DATA_DIR exists: ${REDIS_DATA_DIR}"
else
  bad "REDIS_DATA_DIR missing: ${REDIS_DATA_DIR}"
fi

detected_dir="$(detect_redis_data_dir || true)"
if [[ -n "${detected_dir}" ]]; then
  if [[ "${detected_dir}" == "${REDIS_DATA_DIR}" ]]; then
    ok "CONFIG GET dir matches REDIS_DATA_DIR (${detected_dir})"
  else
    warn "CONFIG GET dir=${detected_dir} differs from REDIS_DATA_DIR=${REDIS_DATA_DIR}; update config.env if needed"
  fi
else
  warn "could not read CONFIG GET dir (auth or connectivity issue)"
fi

if [[ -n "${REDIS_PASSWORD}" ]]; then
  ok "REDIS_PASSWORD configured"
else
  bad "REDIS_PASSWORD empty; set it in config.env (Redis requires auth)"
fi

node="$(first_node)"
if redis_cmd "${node}" DEBUG SLEEP 1 >/dev/null 2>&1; then
  ok "DEBUG SLEEP enabled on ${node}"
else
  warn "DEBUG SLEEP unavailable on ${node} (slow-command scenario may fail)"
fi

if command -v iostat >/dev/null 2>&1 || command -v pidstat >/dev/null 2>&1; then
  ok "iostat/pidstat present (hide-tools scenario applicable)"
else
  warn "iostat/pidstat not found (hide-tools scenario N/A)"
fi

log "=== summary: pass=${PASS} fail=${FAIL} warn=${WARN} ==="
[[ "${FAIL}" -eq 0 ]] || exit 1
