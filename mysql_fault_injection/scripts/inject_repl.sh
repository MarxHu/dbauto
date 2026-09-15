#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""; NODE=""; SCOPE="${SCOPE:-one}"
CONFIRM="${CONFIRM:-}"
DELAY_SEC="${DELAY_SEC:-30}"
REPLICA="${REPLICA:-}"
ORIG_RO=""
ORIG_SRO=""
ORIG_WORKERS=""
ORIG_WAIT_COUNT=""
ORIG_TIMEOUT=""
ORIG_SERVER_ID=""
ORIG_SOURCE_HOST=""
BAD_AUTH_NODE=""

usage() {
  usage_header
  cat <<EOF

Replication / semi-sync (Redis 3-master-0-replica cannot do these):
  stop-io                 STOP REPLICA IO_THREAD --scope one|all (MY040/MY190)
  stop-sql                STOP REPLICA SQL_THREAD --scope one|all (MY041/MY192)
  binlog-purge            PURGE after stopping replica IO (MY046) --confirm YES
  replica-writable        SET read_only=0 on replica (MY110)
  replica-1062            Writable replica + duplicate PK (MY130) --confirm YES
  dup-server-id           SET GLOBAL server_id = primary (MY111) --confirm YES
  serial-apply            replica_parallel_workers=0 (MY065)
  sql-backlog             Stop SQL while primary writes (MY063)
  gtid-skip               Inject empty GTID (MY132) --confirm YES
  bad-repl-auth           Wrong replication password (MY042)
  bad-source-host         CHANGE SOURCE to 127.0.0.1 (MY047)
  sql-delay               SOURCE_DELAY (MY066)
  semi-sync-degrade       Isolate ALL replicas from dump (MY100)
  semi-sync-wait-ack      wait_count=2 + delay replicas (MY102)  [never isolate only one when wait_count=1]
  semi-sync-under-ack     wait_count=2 + stop one IO (MY103)
  semi-sync-timeout-pulse Short timeout (MY101)

Examples:
  $0 --action stop-sql --scope one --node 10.10.26.145:3306 --duration 600
  $0 --action semi-sync-wait-ack --duration 300
EOF
}

targets_for_scope() {
  if [[ "${SCOPE}" == "all" ]]; then
    replica_nodes
  else
    echo "${NODE:-$(echo "${MYSQL_REPLICAS}" | awk '{print $1}')}"
  fi
}

recover_io() {
  local n
  for n in $(targets_for_scope); do
    repl_start_io "${n}" || true
  done
}

recover_sql() {
  local n
  for n in $(targets_for_scope); do
    repl_start_sql "${n}" || true
  done
}

recover_writable() {
  local n="${NODE}"
  mysql_sql "${n}" "SET GLOBAL super_read_only=${ORIG_SRO:-1}" >/dev/null || true
  mysql_sql "${n}" "SET GLOBAL read_only=${ORIG_RO:-1}" >/dev/null || true
}

recover_workers() {
  [[ -n "${ORIG_WORKERS}" ]] || return 0
  mysql_try "${NODE}" "SET GLOBAL replica_parallel_workers=${ORIG_WORKERS}" \
    "SET GLOBAL slave_parallel_workers=${ORIG_WORKERS}" || true
}

recover_server_id() {
  [[ -n "${ORIG_SERVER_ID}" ]] || return 0
  mysql_sql "${NODE}" "SET GLOBAL server_id=${ORIG_SERVER_ID}" >/dev/null || true
}

recover_source() {
  local n="${BAD_AUTH_NODE:-${NODE}}"
  repl_stop_all "${n}" || true
  mysql_try "${n}" \
    "CHANGE REPLICATION SOURCE TO SOURCE_HOST='${MYSQL_PRIMARY%%:*}', SOURCE_PORT=${MYSQL_PORT}, SOURCE_PASSWORD='${MYSQL_PASSWORD}'" \
    "CHANGE MASTER TO MASTER_HOST='${MYSQL_PRIMARY%%:*}', MASTER_PORT=${MYSQL_PORT}, MASTER_PASSWORD='${MYSQL_PASSWORD}'" || true
  repl_start_all "${n}" || true
}

recover_delay() {
  repl_stop_sql "${NODE}" || true
  mysql_try "${NODE}" "CHANGE REPLICATION SOURCE TO SOURCE_DELAY=0" "CHANGE MASTER TO MASTER_DELAY=0" || true
  repl_start_all "${NODE}" || true
}

recover_semi_vars() {
  local p
  p="$(primary_node)"
  if [[ -n "${ORIG_WAIT_COUNT}" ]]; then
    mysql_try "${p}" \
      "SET GLOBAL rpl_semi_sync_source_wait_for_replica_count=${ORIG_WAIT_COUNT}" \
      "SET GLOBAL rpl_semi_sync_master_wait_for_slave_count=${ORIG_WAIT_COUNT}" || true
  fi
  if [[ -n "${ORIG_TIMEOUT}" ]]; then
    mysql_try "${p}" \
      "SET GLOBAL rpl_semi_sync_source_timeout=${ORIG_TIMEOUT}" \
      "SET GLOBAL rpl_semi_sync_master_timeout=${ORIG_TIMEOUT}" || true
  fi
}

recover_semi_net() {
  local n host
  for n in ${MYSQL_REPLICAS}; do
    host="${n%%:*}"
    run_on_host "${host}" "tc qdisc del dev ${NET_DEV} root 2>/dev/null || true
      $(priv)iptables -D OUTPUT -p tcp --dport ${MYSQL_PORT} -d ${MYSQL_PRIMARY%%:*} -j DROP 2>/dev/null || true
      $(priv)iptables -D OUTPUT -p tcp --dport ${MYSQL_PORT} -d ${MYSQL_PRIMARY%%:*} -j DROP 2>/dev/null || true" || true
  done
  recover_semi_vars
}

recover_under_ack() {
  recover_semi_vars
  recover_io
}

save_semi_vars() {
  local p
  p="$(primary_node)"
  ORIG_WAIT_COUNT="$(mysql_sql "${p}" "SELECT @@global.rpl_semi_sync_source_wait_for_replica_count" 2>/dev/null \
    || mysql_sql "${p}" "SELECT @@global.rpl_semi_sync_master_wait_for_slave_count" 2>/dev/null \
    || echo "${SEMI_SYNC_WAIT_REPLICA_COUNT}")"
  ORIG_TIMEOUT="$(mysql_sql "${p}" "SELECT @@global.rpl_semi_sync_source_timeout" 2>/dev/null \
    || mysql_sql "${p}" "SELECT @@global.rpl_semi_sync_master_timeout" 2>/dev/null \
    || echo "${SEMI_SYNC_TIMEOUT_MS}")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --replica) REPLICA="$2"; NODE="$2"; shift 2 ;;
    --delay-sec) DELAY_SEC="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    --confirm) CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
acquire_inject_lock
[[ "${SCOPE}" == "one" || "${SCOPE}" == "all" ]] || die "--scope must be one|all"

default_one_replica() {
  NODE="${NODE:-$(echo "${MYSQL_REPLICAS}" | awk '{print $1}')}"
}

case "${ACTION}" in
  stop-io)
    parse_duration
    default_one_replica
    if [[ "${SCOPE}" == "one" ]]; then require_replica_node "${NODE}"; fi
    inject_begin "$([[ "${SCOPE}" == "all" ]] && echo MY190 || echo MY040)" recover_io
    for n in $(targets_for_scope); do
      repl_stop_io "${n}" || inject_fail "STOP IO failed on ${n}"
    done
    if [[ "${SCOPE}" == "one" ]]; then
      post_check_io_not_on "${NODE}" || inject_fail "IO still ON"
      post_check_peer_io_on "${NODE}" || inject_fail "peer replica also lost IO (not a one-replica fault)"
    else
      for n in ${MYSQL_REPLICAS}; do
        post_check_io_not_on "${n}" || inject_fail "IO still ON on ${n}"
      done
    fi
    inject_pass "stop-io scope=${SCOPE} node=${NODE}"
    run_timed_fault "${DURATION}" recover_io
    ;;
  stop-sql)
    parse_duration
    default_one_replica
    if [[ "${SCOPE}" == "one" ]]; then require_replica_node "${NODE}"; fi
    inject_begin "$([[ "${SCOPE}" == "all" ]] && echo MY192 || echo MY041)" recover_sql
    for n in $(targets_for_scope); do
      repl_stop_sql "${n}" || inject_fail "STOP SQL failed on ${n}"
    done
    if [[ "${SCOPE}" == "one" ]]; then
      post_check_sql_not_on "${NODE}" || inject_fail "SQL still ON"
      post_check_peer_sql_on "${NODE}" || inject_fail "peer replica SQL also down"
    fi
    inject_pass "stop-sql scope=${SCOPE} node=${NODE}"
    run_timed_fault "${DURATION}" recover_sql
    ;;
  binlog-purge)
    require_confirm "binlog-purge"
    default_one_replica
    require_replica_node "${NODE}"
    inject_begin MY046 true
    repl_stop_io "${NODE}" || inject_fail "cannot stop IO"
    relay="$(relay_source_file "${NODE}")"
    relay="${relay:-mysql-bin.000001}"
    log "replica ${NODE} Relay_Source=${relay}; rotating primary binlogs past it"
    cur=""
    for _i in $(seq 1 20); do
      mysql_sql "$(primary_node)" "FLUSH BINARY LOGS" >/dev/null || true
      cur="$(primary_binlog_file)"
      cur="${cur:-mysql-bin.000001}"
      if binlog_file_after "${cur}" "${relay}"; then
        break
      fi
    done
    cur="$(primary_binlog_file)"
    cur="${cur:-mysql-bin.000002}"
    if ! binlog_file_after "${cur}" "${relay}"; then
      inject_fail "primary binlog ${cur} did not advance past replica Relay_Source ${relay}"
    fi
    mysql_sql "$(primary_node)" "PURGE BINARY LOGS TO '${cur}'" >/dev/null \
      || inject_fail "PURGE BINARY LOGS TO ${cur} failed"
    repl_start_io "${NODE}" || true
    wait_io_break_or_1236 "${NODE}" || inject_fail "expected IO break / errno 1236 after PURGE TO ${cur}"
    inject_pass "purged binlogs TO ${cur} (replica ${NODE} Relay_Source=${relay}; IO break/1236)"
    ;;
  replica-writable)
    parse_duration
    default_one_replica
    require_replica_node "${NODE}"
    inject_begin MY110 recover_writable
    ORIG_RO="$(mysql_sql "${NODE}" "SELECT @@global.read_only" || echo 1)"
    ORIG_SRO="$(mysql_sql "${NODE}" "SELECT @@global.super_read_only" || echo 1)"
    mysql_sql "${NODE}" "SET GLOBAL super_read_only=0" >/dev/null
    mysql_sql "${NODE}" "SET GLOBAL read_only=0" >/dev/null
    inject_pass "read_only=0 on ${NODE}"
    run_timed_fault "${DURATION}" recover_writable
    ;;
  replica-1062)
    require_confirm "replica-1062"
    default_one_replica
    require_replica_node "${NODE}"
    inject_begin MY130 recover_writable
    ORIG_RO="$(mysql_sql "${NODE}" "SELECT @@global.read_only" || echo 1)"
    ORIG_SRO="$(mysql_sql "${NODE}" "SELECT @@global.super_read_only" || echo 1)"
    mysql_sql "${NODE}" "SET GLOBAL super_read_only=0" >/dev/null
    mysql_sql "${NODE}" "SET GLOBAL read_only=0" >/dev/null
    mysql_sql "$(primary_node)" "CREATE DATABASE IF NOT EXISTS fault_inject" >/dev/null || true
    mysql_sql "$(primary_node)" "CREATE TABLE IF NOT EXISTS fault_inject.pk (id INT PRIMARY KEY)" >/dev/null || true
    wait_replica_table "${NODE}" "fault_inject" "pk" \
      || inject_fail "replica ${NODE} never received fault_inject.pk"
    pk="${FAULT_1062_PK:-$(date +%s)}"
    mysql_sql "${NODE}" "INSERT INTO fault_inject.pk VALUES (${pk})" >/dev/null \
      || inject_fail "cannot seed PK ${pk} on writable replica ${NODE}"
    mysql_sql "$(primary_node)" "INSERT INTO fault_inject.pk VALUES (${pk})" >/dev/null \
      || inject_fail "cannot insert same PK ${pk} on primary"
    wait_sql_errno_1062 "${NODE}" || inject_fail "expected Last_SQL_Errno=1062 on ${NODE}"
    inject_pass "duplicate PK ${pk} on ${NODE}; Last_SQL_Errno=1062 (no auto data repair)"
    ;;
  dup-server-id)
    require_confirm "dup-server-id"
    parse_duration
    default_one_replica
    inject_begin MY111 recover_server_id
    ORIG_SERVER_ID="$(mysql_sql "${NODE}" "SELECT @@global.server_id" || echo 12)"
    prim_id="$(mysql_sql "$(primary_node)" "SELECT @@global.server_id" || echo 11)"
    mysql_sql "${NODE}" "SET GLOBAL server_id=${prim_id}" >/dev/null || inject_fail "cannot set server_id"
    inject_pass "server_id=${prim_id} on ${NODE} (dup primary)"
    run_timed_fault "${DURATION}" recover_server_id
    ;;
  serial-apply)
    parse_duration
    default_one_replica
    inject_begin MY065 recover_workers
    ORIG_WORKERS="$(mysql_sql "${NODE}" "SELECT @@global.replica_parallel_workers" 2>/dev/null \
      || mysql_sql "${NODE}" "SELECT @@global.slave_parallel_workers" 2>/dev/null || echo 4)"
    mysql_try "${NODE}" "SET GLOBAL replica_parallel_workers=0" "SET GLOBAL slave_parallel_workers=0" \
      || inject_fail "cannot set parallel_workers=0"
    inject_pass "parallel_workers=0 on ${NODE} orig=${ORIG_WORKERS}"
    run_timed_fault "${DURATION}" recover_workers
    ;;
  sql-backlog)
    parse_duration
    default_one_replica
    inject_begin MY063 recover_sql
    repl_stop_sql "${NODE}" || inject_fail "STOP SQL failed"
    mysql_sql "$(primary_node)" "CREATE DATABASE IF NOT EXISTS fault_inject" >/dev/null || true
    mysql_sql "$(primary_node)" "CREATE TABLE IF NOT EXISTS fault_inject.lag (id INT PRIMARY KEY AUTO_INCREMENT, v INT)" >/dev/null || true
    mysql_sql "$(primary_node)" "INSERT INTO fault_inject.lag (v) VALUES (1),(2),(3)" >/dev/null || true
    inject_pass "SQL stopped on ${NODE} while primary writes (backlog)"
    run_timed_fault "${DURATION}" recover_sql
    ;;
  gtid-skip)
    require_confirm "gtid-skip"
    default_one_replica
    inject_begin MY132 true
    repl_stop_sql "${NODE}" || true
    mysql_sql "${NODE}" "SET GTID_NEXT='AUTOMATIC'" >/dev/null || true
    log "WARN gtid-skip is topology-specific; dry-run records intent only unless GTID set provided"
    inject_pass "gtid-skip attempted on ${NODE} (rebuild replica after lab use)"
    ;;
  bad-repl-auth)
    parse_duration
    default_one_replica
    BAD_AUTH_NODE="${NODE}"
    inject_begin MY042 recover_source
    repl_stop_all "${NODE}" || true
    mysql_try "${NODE}" \
      "CHANGE REPLICATION SOURCE TO SOURCE_PASSWORD='wrong-fault'" \
      "CHANGE MASTER TO MASTER_PASSWORD='wrong-fault'" || inject_fail "CHANGE SOURCE failed"
    repl_start_io "${NODE}" || true
    inject_pass "wrong repl password on ${NODE}"
    run_timed_fault "${DURATION}" recover_source
    ;;
  bad-source-host)
    parse_duration
    default_one_replica
    BAD_AUTH_NODE="${NODE}"
    inject_begin MY047 recover_source
    repl_stop_all "${NODE}" || true
    mysql_try "${NODE}" \
      "CHANGE REPLICATION SOURCE TO SOURCE_HOST='127.0.0.1', SOURCE_PORT=1" \
      "CHANGE MASTER TO MASTER_HOST='127.0.0.1', MASTER_PORT=1" || inject_fail "CHANGE SOURCE failed"
    repl_start_io "${NODE}" || true
    inject_pass "source host poisoned on ${NODE}"
    run_timed_fault "${DURATION}" recover_source
    ;;
  sql-delay)
    parse_duration
    default_one_replica
    inject_begin MY066 recover_delay
    repl_stop_sql "${NODE}" || inject_fail "STOP SQL required before SOURCE_DELAY"
    if ! mysql_try "${NODE}" \
      "CHANGE REPLICATION SOURCE TO SOURCE_DELAY=${DELAY_SEC}" \
      "CHANGE MASTER TO MASTER_DELAY=${DELAY_SEC}"; then
      repl_stop_all "${NODE}" || true
      mysql_try "${NODE}" \
        "CHANGE REPLICATION SOURCE TO SOURCE_DELAY=${DELAY_SEC}" \
        "CHANGE MASTER TO MASTER_DELAY=${DELAY_SEC}" || inject_fail "SOURCE_DELAY failed"
    fi
    repl_start_all "${NODE}" || true
    inject_pass "SOURCE_DELAY=${DELAY_SEC} on ${NODE}"
    run_timed_fault "${DURATION}" recover_delay
    ;;
  semi-sync-degrade)
    parse_duration
    inject_begin MY100 recover_semi_net
    for n in ${MYSQL_REPLICAS}; do
      run_on_host "${n%%:*}" "$(priv)iptables -I OUTPUT -p tcp --dport ${MYSQL_PORT} -d ${MYSQL_PRIMARY%%:*} -j DROP"
    done
    inject_pass "all replicas blocked from primary:3306 (semi-sync should degrade)"
    run_timed_fault "${DURATION}" recover_semi_net
    ;;
  semi-sync-wait-ack)
    parse_duration
    inject_begin MY102 recover_semi_net
    save_semi_vars
    # wait_count=1: isolating one replica is NOT enough. Raise wait_count to 2, then delay replicas.
    mysql_try "$(primary_node)" \
      "SET GLOBAL rpl_semi_sync_source_wait_for_replica_count=2" \
      "SET GLOBAL rpl_semi_sync_master_wait_for_slave_count=2" || true
    mysql_try "$(primary_node)" \
      "SET GLOBAL rpl_semi_sync_source_timeout=600000" \
      "SET GLOBAL rpl_semi_sync_master_timeout=600000" || true
    for n in ${MYSQL_REPLICAS}; do
      TARGET_HOST="${n%%:*}"; TARGET_CONTAINER=""
      apply_netem "${NET_DEV}" "delay 5000ms"
    done
    inject_pass "wait_count=2 + 5s delay on ALL replicas (MY102); not a single-replica drop"
    run_timed_fault "${DURATION}" recover_semi_net
    ;;
  semi-sync-under-ack)
    parse_duration
    default_one_replica
    inject_begin MY103 recover_under_ack
    save_semi_vars
    mysql_try "$(primary_node)" \
      "SET GLOBAL rpl_semi_sync_source_wait_for_replica_count=2" \
      "SET GLOBAL rpl_semi_sync_master_wait_for_slave_count=2" || true
    SCOPE=one
    repl_stop_io "${NODE}" || inject_fail "STOP IO failed"
    inject_pass "wait_count=2 and IO down on ${NODE}"
    run_timed_fault "${DURATION}" recover_under_ack
    ;;
  semi-sync-timeout-pulse)
    parse_duration
    inject_begin MY101 recover_semi_vars
    save_semi_vars
    mysql_try "$(primary_node)" \
      "SET GLOBAL rpl_semi_sync_source_timeout=1000" \
      "SET GLOBAL rpl_semi_sync_master_timeout=1000" || inject_fail "cannot set timeout"
    inject_pass "semi-sync timeout=1000ms"
    run_timed_fault "${DURATION}" recover_semi_vars
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
