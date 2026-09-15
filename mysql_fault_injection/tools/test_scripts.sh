#!/usr/bin/env bash
# Syntax + CLI dry-run coverage for mysql_fault_injection (no live mysqld required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

export INJECT_DRY_RUN=1
export INJECT_BACKEND=local
export MYSQL_PASSWORD=dummy
export FAULT_DURATION_SEC=0
export MYSQL_CONTAINER_MAP="10.10.26.144:mysql-n1 10.10.26.145:mysql-n2 10.10.26.146:mysql-n3"

PASS=0
FAIL=0
ok() { echo "PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "=== bash -n ==="
while IFS= read -r f; do
  bash -n "$f" && ok "syntax $f" || bad "syntax $f"
done < <(find lib scripts run.sh tools -type f -name '*.sh' | sort)

echo "=== --help ==="
for s in scripts/inject_*.sh; do
  bash "$s" --help >/tmp/mysql_fi_help.out 2>&1 || true
  if grep -q 'Usage:' /tmp/mysql_fi_help.out; then
    ok "help $(basename "$s")"
  else
    bad "help $(basename "$s")"
  fi
done
bash run.sh --help >/tmp/mysql_fi_help.out 2>&1 || true
grep -q 'Categories:' /tmp/mysql_fi_help.out && ok "help run.sh" || bad "help run.sh"

run_one() {
  local label="$1"; shift
  local out rc
  set +e
  out="$(bash "$@" --duration 0 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]] && grep -q 'INJECT_RESULT scenario=.* status=pass' <<<"${out}"; then
    ok "${label}"
  else
    bad "${label} rc=${rc}"
    echo "${out}" | tail -20
  fi
}

echo "=== dry-run actions ==="
bash scripts/preflight.sh >/tmp/mysql_fi_pre.out 2>&1 && grep -q 'summary:' /tmp/mysql_fi_pre.out && ok "preflight dry" || bad "preflight dry"

run_one host-baseline scripts/inject_host.sh --action baseline
run_one host-cpu scripts/inject_host.sh --action cpu --target-host 10.10.26.144
run_one host-cpu-r scripts/inject_host.sh --action cpu --target-host 10.10.26.145
run_one host-memory scripts/inject_host.sh --action memory --target-host 10.10.26.145
run_one host-spike scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144
run_one host-multi scripts/inject_host.sh --action multi-cpu
run_one host-reboot scripts/inject_host.sh --action reboot --target-host 10.10.26.144 --confirm YES
run_one host-clock scripts/inject_host.sh --action clock-skew --target-host 10.10.26.145

run_one mysql-stop-r scripts/inject_mysql.sh --action process-stop --node 10.10.26.145:3306
run_one mysql-stop-p scripts/inject_mysql.sh --action process-stop --node 10.10.26.144:3306
run_one mysql-freeze scripts/inject_mysql.sh --action process-freeze --node 10.10.26.144:3306
run_one mysql-maxconn scripts/inject_mysql.sh --action max-connections --node 10.10.26.144:3306
run_one mysql-slow scripts/inject_mysql.sh --action slow-query --node 10.10.26.144:3306
run_one mysql-hot scripts/inject_mysql.sh --action hot-row
run_one mysql-big scripts/inject_mysql.sh --action big-trx
run_one mysql-long scripts/inject_mysql.sh --action long-trx
run_one mysql-bp scripts/inject_mysql.sh --action buffer-pool-shrink --node 10.10.26.144:3306
run_one mysql-pulse scripts/inject_mysql.sh --action error-pulse --node 10.10.26.146:3306
run_one mysql-oom scripts/inject_mysql.sh --action oom --node 10.10.26.144:3306 --confirm YES

run_one repl-io-one scripts/inject_repl.sh --action stop-io --scope one --node 10.10.26.145:3306
run_one repl-io-all scripts/inject_repl.sh --action stop-io --scope all
run_one repl-sql-one scripts/inject_repl.sh --action stop-sql --scope one --node 10.10.26.145:3306
run_one repl-sql-all scripts/inject_repl.sh --action stop-sql --scope all
run_one repl-purge scripts/inject_repl.sh --action binlog-purge --replica 10.10.26.145:3306 --confirm YES
run_one repl-writable scripts/inject_repl.sh --action replica-writable --node 10.10.26.145:3306
run_one repl-1062 scripts/inject_repl.sh --action replica-1062 --node 10.10.26.145:3306 --confirm YES
run_one repl-dupid scripts/inject_repl.sh --action dup-server-id --node 10.10.26.146:3306 --confirm YES
run_one repl-serial scripts/inject_repl.sh --action serial-apply --node 10.10.26.145:3306
run_one repl-backlog scripts/inject_repl.sh --action sql-backlog --node 10.10.26.145:3306
run_one repl-gtid scripts/inject_repl.sh --action gtid-skip --node 10.10.26.145:3306 --confirm YES
run_one repl-auth scripts/inject_repl.sh --action bad-repl-auth --node 10.10.26.146:3306
run_one repl-host scripts/inject_repl.sh --action bad-source-host --node 10.10.26.146:3306
run_one repl-delay scripts/inject_repl.sh --action sql-delay --node 10.10.26.145:3306
run_one repl-ss-deg scripts/inject_repl.sh --action semi-sync-degrade
run_one repl-ss-ack scripts/inject_repl.sh --action semi-sync-wait-ack
run_one repl-ss-under scripts/inject_repl.sh --action semi-sync-under-ack --node 10.10.26.145:3306
run_one repl-ss-pulse scripts/inject_repl.sh --action semi-sync-timeout-pulse

run_one net-repl-one scripts/inject_network.sh --action repl-block --node 10.10.26.145:3306
run_one net-repl-all scripts/inject_network.sh --action repl-block --scope all
run_one net-loss scripts/inject_network.sh --action packet-loss --target-host 10.10.26.146
run_one net-lat scripts/inject_network.sh --action latency --target-host 10.10.26.146
run_one net-rate scripts/inject_network.sh --action rate-limit --target-host 10.10.26.144
run_one net-part scripts/inject_network.sh --action primary-replica-partition --node-a 10.10.26.144 --node-b 10.10.26.145
run_one net-oneway scripts/inject_network.sh --action one-way-drop --node-a 10.10.26.144 --node-b 10.10.26.145
run_one net-client scripts/inject_network.sh --action client-block --node 10.10.26.144:3306

run_one disk-full-p scripts/inject_disk.sh --action disk-full --target-host 10.10.26.144
run_one disk-full-r scripts/inject_disk.sh --action disk-full --target-host 10.10.26.145
run_one disk-ro scripts/inject_disk.sh --action datadir-readonly --node 10.10.26.146:3306
run_one disk-io-r scripts/inject_disk.sh --action io-stress --target-host 10.10.26.145
run_one disk-io-p scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144
run_one disk-inode scripts/inject_disk.sh --action inode-exhaust --target-host 10.10.26.144

run_one c-lag scripts/inject_composite.sh --action long-trx-plus-lag
run_one c-ack scripts/inject_composite.sh --action ack-plus-net
run_one c-disk scripts/inject_composite.sh --action disk-plus-sql-stop --replica-host 10.10.26.145
run_one c-clock scripts/inject_composite.sh --action clock-plus-lag-metric --replica-host 10.10.26.145
run_one c-stopmem scripts/inject_composite.sh --action primary-stop-plus-memory
run_one c-writecpu scripts/inject_composite.sh --action write-reject-plus-cpu --target-host 10.10.26.144
run_one c-oneio scripts/inject_composite.sh --action one-io-plus-other-cpu

run_one d-unreach scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146
run_one d-hide scripts/inject_degrade.sh --action hide-tools

echo "=== run.sh dispatch ==="
out="$(bash run.sh host --action baseline --duration 0 2>&1)" || true
grep -q 'INJECT_RESULT scenario=MY001 status=pass' <<<"${out}" && ok "run.sh host baseline" || bad "run.sh host baseline"

echo "=== confirm gate ==="
set +e
out="$(bash scripts/inject_repl.sh --action binlog-purge --node 10.10.26.145:3306 --duration 0 2>&1)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && grep -q 'requires --confirm YES' <<<"${out}"; then
  ok "binlog-purge confirm gate"
else
  bad "binlog-purge confirm gate rc=${rc}"
fi

echo "=== summary pass=${PASS} fail=${FAIL} ==="
[[ "${FAIL}" -eq 0 ]]
