#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""
REPLICA_HOST="${REPLICA_HOST:-$(echo "${MYSQL_REPLICAS}" | awk '{print $1}' | cut -d: -f1)}"
REPLICA_NODE="${REPLICA_NODE:-$(echo "${MYSQL_REPLICAS}" | awk '{print $1}')}"
MEM_NODE="${MEM_NODE:-$(echo "${MYSQL_REPLICAS}" | awk '{print $NF}')}"
STOP_NODE="${STOP_NODE:-${MYSQL_PRIMARY}}"
WRITE_HOST="${WRITE_HOST:-${MYSQL_PRIMARY%%:*}}"
OTHER_REPLICA="${OTHER_REPLICA:-$(echo "${MYSQL_REPLICAS}" | awk '{print $NF}')}"

usage() {
  usage_header
  cat <<EOF

Composite (internal calls skip flock):
  long-trx-plus-lag          MY196 = long-trx on primary
  ack-plus-net               MY197 = semi-sync-wait-ack
  disk-plus-sql-stop         MY198 = disk-full on one replica
  clock-plus-lag-metric      MY199 = clock-skew on one replica
  primary-stop-plus-memory   C01   = process-stop primary + memory on replica
  write-reject-plus-cpu      C02   = datadir-readonly + cpu same host
  one-io-plus-other-cpu      C03   = stop-io one replica + cpu on the other

Examples:
  $0 --action long-trx-plus-lag --duration 300
  $0 --action one-io-plus-other-cpu --duration 300
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --replica-host) REPLICA_HOST="$2"; shift 2 ;;
    --replica) REPLICA_NODE="$2"; shift 2 ;;
    --mem-node) MEM_NODE="$2"; shift 2 ;;
    --stop-node) STOP_NODE="$2"; shift 2 ;;
    --target-host) WRITE_HOST="$2"; TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
acquire_inject_lock
parse_duration
export INJECT_LOCK_SKIP=1

run_bg() { bash "$@" & }

case "${ACTION}" in
  long-trx-plus-lag)
    inject_begin MY196 true
    bash "${SCRIPT_DIR}/inject_mysql.sh" --action long-trx --node "$(primary_node)" --duration "${DURATION}"
    emit_inject_result "MY196" "pass" "long-trx on primary"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  ack-plus-net)
    inject_begin MY197 true
    bash "${SCRIPT_DIR}/inject_repl.sh" --action semi-sync-wait-ack --duration "${DURATION}"
    emit_inject_result "MY197" "pass" "semi-sync-wait-ack"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  disk-plus-sql-stop)
    inject_begin MY198 true
    bash "${SCRIPT_DIR}/inject_disk.sh" --action disk-full --target-host "${REPLICA_HOST}" --duration "${DURATION}"
    emit_inject_result "MY198" "pass" "disk-full on ${REPLICA_HOST}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  clock-plus-lag-metric)
    inject_begin MY199 true
    bash "${SCRIPT_DIR}/inject_host.sh" --action clock-skew --target-host "${REPLICA_HOST}" --duration "${DURATION}"
    emit_inject_result "MY199" "pass" "clock-skew on ${REPLICA_HOST}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  primary-stop-plus-memory)
    inject_begin C01 true
    run_bg "${SCRIPT_DIR}/inject_mysql.sh" --action process-stop --node "${STOP_NODE}" --duration "${DURATION}"
    run_bg "${SCRIPT_DIR}/inject_host.sh" --action memory --target-host "${MEM_NODE%%:*}" --duration "${DURATION}"
    wait
    emit_inject_result "C01" "pass" "stop ${STOP_NODE} + mem ${MEM_NODE}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  write-reject-plus-cpu)
    inject_begin C02 true
    run_bg "${SCRIPT_DIR}/inject_disk.sh" --action datadir-readonly --target-host "${WRITE_HOST}" --duration "${DURATION}"
    run_bg "${SCRIPT_DIR}/inject_host.sh" --action cpu --target-host "${WRITE_HOST}" --duration "${DURATION}"
    wait
    emit_inject_result "C02" "pass" "readonly+cpu on ${WRITE_HOST}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  one-io-plus-other-cpu)
    inject_begin C03 true
    run_bg "${SCRIPT_DIR}/inject_repl.sh" --action stop-io --scope one --node "${REPLICA_NODE}" --duration "${DURATION}"
    run_bg "${SCRIPT_DIR}/inject_host.sh" --action cpu --target-host "${OTHER_REPLICA%%:*}" --duration "${DURATION}"
    wait
    emit_inject_result "C03" "pass" "stop-io ${REPLICA_NODE} + cpu ${OTHER_REPLICA}"
    INJECT_RESULT_EMITTED=1; trap - EXIT
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
