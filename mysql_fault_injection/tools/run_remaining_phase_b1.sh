#!/usr/bin/env bash
# Remaining heavier / confirm-gated scenarios (disk, reboot, purge, 1062, composites).
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
R2="$(echo "${MYSQL_REPLICAS:-10.10.26.145:3306 10.10.26.146:3306}" | awk '{print $2}')"
R2="${R2:-${R1}}"
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

echo "=== remaining phase B1 (confirm/disk/composite) duration=${DUR} dry=${INJECT_DRY_RUN:-0} ==="

run MY010-S-spike scripts/inject_host.sh --action cpu-spike --target-host "${PH}"
run MY010-M-multi scripts/inject_host.sh --action multi-cpu
run MY035-reboot scripts/inject_host.sh --action reboot --target-host "${R1H}" --confirm YES
run MY036-freeze scripts/inject_mysql.sh --action process-freeze --node "${P}"
run MY034-oom scripts/inject_mysql.sh --action oom --node "${P}" --confirm YES
run MY046-purge scripts/inject_repl.sh --action binlog-purge --replica "${R1}" --confirm YES
run MY130-1062 scripts/inject_repl.sh --action replica-1062 --node "${R1}" --confirm YES
run MY111-dupid scripts/inject_repl.sh --action dup-server-id --node "${R2}" --confirm YES
run MY132-gtid scripts/inject_repl.sh --action gtid-skip --node "${R1}" --confirm YES
run MY160-disk-p scripts/inject_disk.sh --action disk-full --target-host "${PH}"
run MY160-disk-r scripts/inject_disk.sh --action disk-full --target-host "${R1H}"
run MY164-ro scripts/inject_disk.sh --action datadir-readonly --node "${R2}"
run MY161-inode scripts/inject_disk.sh --action inode-exhaust --target-host "${PH}"
run MY162-P-io scripts/inject_disk.sh --action io-stress --target-host "${PH}"
run MY142-rate scripts/inject_network.sh --action rate-limit --target-host "${PH}"
run MY144-P-part scripts/inject_network.sh --action primary-replica-partition --node-a "${PH}" --node-b "${R1H}"
run MY141-oneway scripts/inject_network.sh --action one-way-drop --node-a "${PH}" --node-b "${R1H}"
run MY190-N-allnet scripts/inject_network.sh --action repl-block --scope all
run MY196-combo scripts/inject_composite.sh --action long-trx-plus-lag
run MY197-acknet scripts/inject_composite.sh --action ack-plus-net
run MY198-disk-sql scripts/inject_composite.sh --action disk-plus-sql-stop --replica-host "${R1H}"
run MY199-clock scripts/inject_composite.sh --action clock-plus-lag-metric --replica-host "${R1H}"
run C01-stopmem scripts/inject_composite.sh --action primary-stop-plus-memory
run C02-writecpu scripts/inject_composite.sh --action write-reject-plus-cpu --target-host "${PH}"
run C03-oneio scripts/inject_composite.sh --action one-io-plus-other-cpu

echo "=== phase B1 summary pass=${PASS} fail=${FAIL} ==="
[[ "${FAIL}" -eq 0 ]]
