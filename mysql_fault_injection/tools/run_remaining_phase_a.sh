#!/usr/bin/env bash
# Remaining auto-recoverable scenarios after the MYSQL_FAULT_SCENARIOS.md §12 first-run set.
# Does not invent new faults; only dispatches existing inject_*.sh actions.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
# shellcheck disable=SC1091
[[ -f "${ROOT}/config.env" ]] && source "${ROOT}/config.env"

DUR="${BATCH_DURATION:-60}"
if [[ "${INJECT_DRY_RUN:-0}" == "1" ]]; then
  DUR=0
fi
R1="$(echo "${MYSQL_REPLICAS:-10.10.26.145:3306 10.10.26.146:3306}" | awk '{print $1}')"
R1H="${R1%%:*}"
P="${MYSQL_PRIMARY:-10.10.26.144:3306}"
PH="${P%%:*}"

PASS=0
FAIL=0
run() {
  local label="$1"; shift
  echo "=== ${label} ==="
  local out rc
  set +e
  out="$(bash "$@" --duration "${DUR}" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "${out}" | tail -8
  if grep -q 'INJECT_RESULT scenario=.* status=pass' <<<"${out}"; then
    echo "PASS ${label}"
    PASS=$((PASS + 1))
  else
    echo "FAIL ${label} rc=${rc}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== remaining phase A (auto-recover) duration=${DUR} dry=${INJECT_DRY_RUN:-0} ==="

run MY011-memory scripts/inject_host.sh --action memory --target-host "${R1H}"
run MY010-R-cpu scripts/inject_host.sh --action cpu --target-host "${R1H}"
run MY014-clock scripts/inject_host.sh --action clock-skew --target-host "${R1H}"
run MY030-P-stop scripts/inject_mysql.sh --action process-stop --node "${P}"
run MY040-stop-io scripts/inject_repl.sh --action stop-io --scope one --node "${R1}"
run MY190-stop-io-all scripts/inject_repl.sh --action stop-io --scope all
run MY192-stop-sql-all scripts/inject_repl.sh --action stop-sql --scope all
run MY066-sql-delay scripts/inject_repl.sh --action sql-delay --node "${R1}" --delay-sec 30
run MY110-writable scripts/inject_repl.sh --action replica-writable --node "${R1}"
run MY063-backlog scripts/inject_repl.sh --action sql-backlog --node "${R1}"
run MY065-serial scripts/inject_repl.sh --action serial-apply --node "${R1}"
run MY100-ss-degrade scripts/inject_repl.sh --action semi-sync-degrade
run MY103-ss-under scripts/inject_repl.sh --action semi-sync-under-ack --node "${R1}"
run MY101-ss-pulse scripts/inject_repl.sh --action semi-sync-timeout-pulse
run MY042-bad-auth scripts/inject_repl.sh --action bad-repl-auth --node "${R1}"
run MY047-bad-host scripts/inject_repl.sh --action bad-source-host --node "${R1}"
run MY144-repl-block scripts/inject_network.sh --action repl-block --node "${R1}"
run MY140-loss scripts/inject_network.sh --action packet-loss --target-host "${R1H}"
run MY140-L-lat scripts/inject_network.sh --action latency --target-host "${R1H}"
run MY031-client scripts/inject_network.sh --action client-block --node "${P}"
run MY081-maxconn scripts/inject_mysql.sh --action max-connections --node "${P}"
run MY080-slow scripts/inject_mysql.sh --action slow-query --node "${P}"
run MY084-hot scripts/inject_mysql.sh --action hot-row --node "${P}"
run MY082-big scripts/inject_mysql.sh --action big-trx --node "${P}"
run MY085-bp scripts/inject_mysql.sh --action buffer-pool-shrink --node "${P}"
run MY205-pulse scripts/inject_mysql.sh --action error-pulse --node "${R1}"
run MY172-unreach scripts/inject_degrade.sh --action job-unreachable --blocked-host "${R1H}" --blocked-port "${MYSQL_PORT:-3306}"

echo "=== phase A summary pass=${PASS} fail=${FAIL} ==="
[[ "${FAIL}" -eq 0 ]]
