#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""; NODE=""
MAX_CONNECTIONS="${MAX_CONNECTIONS:-10}"
ERROR_TYPE="${ERROR_TYPE:-WRONGPASS}"
SLEEP_SEC="${SLEEP_SEC:-8}"
CONFIRM="${CONFIRM:-}"
FILL_PID=""
ORIG_MAXCONN=""
ORIG_BP=""
STOPPED_NODE=""

usage() {
  usage_header
  cat <<EOF

Actions:
  process-stop         Stop mysqld (MY030 replica / MY030-P primary)
  process-freeze       SIGSTOP mysqld (MY036)
  max-connections      Lower max_connections and occupy (MY081)
  slow-query           Periodic SELECT SLEEP (MY080)
  hot-row              Two sessions race one PK (MY084)
  big-trx              Large uncommitted update (MY082)
  long-trx             Hold a row lock >= duration (MY087)
  buffer-pool-shrink   SET GLOBAL innodb_buffer_pool_size small (MY085, P)
  error-pulse          Wrong-password pulse (MY205)
  oom                  Aggressive vm stress (MY034) --confirm YES

Examples:
  $0 --action process-stop --node 10.10.26.145:3306 --duration 600
  $0 --action long-trx --node 10.10.26.144:3306 --duration 300
EOF
}

recover_process() {
  local node="${STOPPED_NODE:-${NODE}}"
  bind_target_from_node "${node}"
  run_on_target "systemctl start ${MYSQL_SERVICE} 2>/dev/null || mysqld_safe --datadir=$(detect_datadir "${node}") >/dev/null 2>&1 &"
  restore_container_restart_policy
}

recover_freeze() {
  bind_target_from_node "${NODE}"
  run_on_target "pkill -CONT mysqld 2>/dev/null || kill -CONT \$(pidof mysqld) 2>/dev/null || true"
}

recover_maxconn() {
  [[ -n "${FILL_PID:-}" ]] && kill "${FILL_PID}" 2>/dev/null || true
  if [[ -n "${ORIG_MAXCONN}" ]]; then
    mysql_sql "${NODE}" "SET GLOBAL max_connections=${ORIG_MAXCONN}" >/dev/null || true
  fi
}

recover_sleepers() { [[ -n "${FILL_PID:-}" ]] && kill "${FILL_PID}" 2>/dev/null || true; }

recover_bp() {
  if [[ -n "${ORIG_BP}" ]]; then
    mysql_sql "${NODE}" "SET GLOBAL innodb_buffer_pool_size=${ORIG_BP}" >/dev/null || true
  fi
}

recover_oom() { run_on_target "pkill -f 'stress-ng --vm' 2>/dev/null || true"; }

ensure_fault_table() {
  local node="${1:-$(primary_node)}"
  mysql_sql "${node}" "CREATE DATABASE IF NOT EXISTS fault_inject" >/dev/null || true
  mysql_sql "${node}" "CREATE TABLE IF NOT EXISTS fault_inject.t (id INT PRIMARY KEY, v INT)" >/dev/null || true
  mysql_sql "${node}" "INSERT IGNORE INTO fault_inject.t VALUES (1,0)" >/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    --max-connections) MAX_CONNECTIONS="$2"; shift 2 ;;
    --error-type) ERROR_TYPE="$2"; shift 2 ;;
    --confirm) CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
resolve_node
acquire_inject_lock

sid_for_stop() {
  local role
  role="$(node_role "${NODE}")"
  if [[ "${role}" == "primary" ]]; then echo MY030-P; else echo MY030; fi
}

case "${ACTION}" in
  process-stop)
    parse_duration
    STOPPED_NODE="${NODE}"
    bind_target_from_node "${NODE}"
    inject_begin "$(sid_for_stop)" recover_process
    save_container_restart_policy
    run_on_target "mysqladmin --socket=/var/lib/mysql/mysql.sock shutdown 2>/dev/null || systemctl stop ${MYSQL_SERVICE} 2>/dev/null || pkill mysqld || true"
    post_check_mysql_down_sustained "${NODE}" 5 3 || inject_fail "mysqld still reachable"
    inject_pass "mysqld down on ${NODE}"
    run_timed_fault "${DURATION}" recover_process
    ;;
  process-freeze)
    parse_duration; bind_target_from_node "${NODE}"
    inject_begin MY036 recover_freeze
    run_on_target "pkill -STOP mysqld || kill -STOP \$(pidof mysqld)"
    inject_pass "SIGSTOP mysqld on $(target_label)"
    run_timed_fault "${DURATION}" recover_freeze
    ;;
  max-connections)
    parse_duration
    inject_begin MY081 recover_maxconn
    ORIG_MAXCONN="$(mysql_sql "${NODE}" "SELECT @@global.max_connections" || echo 151)"
    mysql_sql "${NODE}" "SET GLOBAL max_connections=${MAX_CONNECTIONS}" >/dev/null \
      || inject_fail "cannot set max_connections"
    if (( DURATION > 0 )) && ! dry; then
      (
        end=$((SECONDS + DURATION))
        while (( SECONDS < end )); do
          mysql_cli "${NODE%%:*}" "$(node_port "${NODE}")" -N -e "SELECT SLEEP(30)" >/dev/null 2>&1 || true
        done
      ) &
      FILL_PID=$!
    fi
    inject_pass "max_connections=${MAX_CONNECTIONS} on ${NODE} orig=${ORIG_MAXCONN}"
    run_timed_fault "${DURATION}" recover_maxconn
    ;;
  slow-query)
    parse_duration
    inject_begin MY080 recover_sleepers
    if (( DURATION > 0 )); then
      (
        end=$((SECONDS + DURATION))
        while (( SECONDS < end )); do
          mysql_sql "${NODE}" "SELECT SLEEP(${SLEEP_SEC})" >/dev/null || true
        done
      ) &
      FILL_PID=$!
    fi
    inject_pass "slow-query loop on ${NODE}"
    run_timed_fault "${DURATION}" recover_sleepers
    ;;
  hot-row)
    parse_duration
    inject_begin MY084 recover_sleepers
    ensure_fault_table "$(primary_node)"
    if (( DURATION > 0 )); then
      (
        mysql_sql "$(primary_node)" "START TRANSACTION; UPDATE fault_inject.t SET v=v+1 WHERE id=1; SELECT SLEEP(${DURATION}); ROLLBACK" >/dev/null || true
      ) &
      FILL_PID=$!
      mysql_sql "$(primary_node)" "UPDATE fault_inject.t SET v=v+1 WHERE id=1" >/dev/null 2>&1 || true
    fi
    inject_pass "hot-row on $(primary_node)"
    run_timed_fault "${DURATION}" recover_sleepers
    ;;
  big-trx|long-trx)
    parse_duration
    local_sid=MY087
    [[ "${ACTION}" == "big-trx" ]] && local_sid=MY082
    inject_begin "${local_sid}" recover_sleepers
    ensure_fault_table "$(primary_node)"
    if (( DURATION > 0 )); then
      (
        mysql_sql "$(primary_node)" "START TRANSACTION; UPDATE fault_inject.t SET v=v+1 WHERE id=1; SELECT SLEEP(${DURATION}); ROLLBACK" >/dev/null || true
      ) &
      FILL_PID=$!
    fi
    inject_pass "${ACTION} held on $(primary_node) for ${DURATION}s"
    run_timed_fault "${DURATION}" recover_sleepers
    ;;
  buffer-pool-shrink)
    parse_duration
    inject_begin MY085 recover_bp
    ORIG_BP="$(mysql_sql "${NODE}" "SELECT @@global.innodb_buffer_pool_size" || echo 134217728)"
    mysql_sql "${NODE}" "SET GLOBAL innodb_buffer_pool_size=8388608" >/dev/null \
      || log "WARN buffer_pool shrink rejected (version may need restart)"
    inject_pass "attempted buffer_pool shrink on ${NODE} orig=${ORIG_BP}"
    run_timed_fault "${DURATION}" recover_bp
    ;;
  error-pulse)
    parse_duration
    inject_begin MY205 true
    if ! dry; then
      pulse_end=$((SECONDS + DURATION))
      while (( SECONDS < pulse_end )); do
        MYSQL_PWD="wrong-${ERROR_TYPE}" mysql --protocol=TCP -h "${NODE%%:*}" -P "$(node_port "${NODE}")" -u "${MYSQL_USER}" \
          --connect-timeout=2 --batch -e "SELECT 1" >/dev/null 2>&1 || true
        sleep 1
      done
    fi
    inject_pass "error-pulse ${ERROR_TYPE} on ${NODE}"
    ;;
  oom)
    require_confirm "oom"
    parse_duration; bind_target_from_node "${NODE}"
    inject_begin MY034 recover_oom
    start_memory_stress 4 95 "${DURATION}"
    inject_pass "oom-path vm stress on $(target_label)"
    run_timed_fault "${DURATION}" recover_oom
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
