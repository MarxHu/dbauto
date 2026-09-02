#!/usr/bin/env bash
# Verify lab prerequisites before running Kafka injection scenarios.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

PASS=0; FAIL=0; WARN=0; TARGET_OK=0; TARGET_TOTAL=0
ok() { log "PASS: $*"; PASS=$((PASS + 1)); }
bad() { log "FAIL: $*"; FAIL=$((FAIL + 1)); }
warn() { log "WARN: $*"; WARN=$((WARN + 1)); }

log "=== Kafka fault injection preflight ==="
log "backend: INJECT_BACKEND=${INJECT_BACKEND}"

for cmd in bash flock timeout; do
  command -v "${cmd}" >/dev/null 2>&1 && ok "bot has ${cmd}" || bad "bot missing ${cmd}"
done

if [[ -x "${KAFKA_HOME}/bin/kafka-broker-api-versions.sh" ]]; then
  ok "bot Kafka CLI ${KAFKA_HOME}"
else
  bad "bot missing ${KAFKA_HOME}/bin/kafka-broker-api-versions.sh (set KAFKA_HOME)"
fi

if [[ -f "${INJECT_LOCK_FILE}" ]]; then
  warn "lock file exists: ${INJECT_LOCK_FILE}"
else
  ok "no active injection lock"
fi

rm -f "${DOCKER_ALL_OK}"

if [[ "${INJECT_BACKEND}" == "docker" ]]; then
  command -v docker >/dev/null 2>&1 && ok "bot has docker" || bad "bot missing docker"
  docker info >/dev/null 2>&1 && ok "docker daemon reachable" || bad "docker daemon not reachable"

  for node in ${KAFKA_NODES}; do
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
      for req in stress-ng vmstat chmod dd iptables tc java; do
        if docker_cmd_check "${ctn}" "${req}"; then
          ok "${req} in ${ctn}"
        else
          bad "${req} missing in ${ctn}"
        fi
      done
      mem_bytes="$(docker inspect -f '{{.HostConfig.Memory}}' "${ctn}" 2>/dev/null || echo 0)"
      if [[ "${mem_bytes}" =~ ^[0-9]+$ ]] && [[ "${mem_bytes}" -gt 0 ]]; then
        ok "memory limit on ${ctn}: $((mem_bytes / 1024 / 1024))MB"
      else
        warn "no memory limit on ${ctn} (KF004 needs mem_limit)"
      fi
    else
      bad "no docker container for ${host}; set KAFKA_CONTAINER_MAP"
    fi
  done
fi

api_ok=0
for node in ${KAFKA_NODES}; do
  if broker_api_ok "${node}"; then
    ok "broker API ${node}"
    api_ok=$((api_ok + 1))
  else
    bad "broker API fail ${node}"
  fi
done

if [[ -x "${KAFKA_HOME}/bin/kafka-metadata-quorum.sh" ]]; then
  if "${KAFKA_HOME}/bin/kafka-metadata-quorum.sh" --bootstrap-server "${BOOTSTRAP}" describe --status >/dev/null 2>&1; then
    ok "metadata quorum reachable"
  else
    warn "metadata quorum describe failed (cluster may still be starting)"
  fi
fi

if [[ "${INJECT_BACKEND}" == "docker" && "${TARGET_OK}" -eq "${TARGET_TOTAL}" && "${TARGET_TOTAL}" -ge 3 && "${FAIL}" -eq 0 ]]; then
  date -Iseconds > "${DOCKER_ALL_OK}"
  ok "wrote ${DOCKER_ALL_OK}"
fi

log "=== summary PASS=${PASS} WARN=${WARN} FAIL=${FAIL} containers=${TARGET_OK}/${TARGET_TOTAL} api=${api_ok} ==="
[[ "${FAIL}" -eq 0 ]]
