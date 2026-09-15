#!/usr/bin/env bash
# Shared helpers for MySQL one-primary multi-replica fault injection.
# Model: injector bot on docker-node; mysqld in Docker containers (simulated VMs)
# or SSH to SOPS hosts. INJECT_DRY_RUN=1 skips destructive side effects (CI).
set -euo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${_LIB_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/config.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/config.env"
fi

INJECT_BACKEND="${INJECT_BACKEND:-docker}"
INJECT_DRY_RUN="${INJECT_DRY_RUN:-0}"
MYSQL_PRIMARY="${MYSQL_PRIMARY:-10.10.26.144:3306}"
MYSQL_REPLICAS="${MYSQL_REPLICAS:-10.10.26.145:3306 10.10.26.146:3306}"
MYSQL_NODES="${MYSQL_NODES:-${MYSQL_PRIMARY} ${MYSQL_REPLICAS}}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_DATADIR="${MYSQL_DATADIR:-auto}"
MYSQL_SERVICE="${MYSQL_SERVICE:-mysqld}"
MYSQL_CONTAINER_MAP="${MYSQL_CONTAINER_MAP:-}"
MYSQL_CONTAINERS="${MYSQL_CONTAINERS:-}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_CONTAINER="${TARGET_CONTAINER:-}"
FAULT_DURATION_SEC="${FAULT_DURATION_SEC:-600}"
SSH_USER="${SSH_USER:-root}"
NET_DEV="${NET_DEV:-eth0}"
SEMI_SYNC_WAIT_REPLICA_COUNT="${SEMI_SYNC_WAIT_REPLICA_COUNT:-1}"
SEMI_SYNC_TIMEOUT_MS="${SEMI_SYNC_TIMEOUT_MS:-10000}"

if [[ "${INJECT_DRY_RUN}" == "1" ]]; then
  INJECT_SKIP_POSTCHECK="${INJECT_SKIP_POSTCHECK:-1}"
  INJECT_BACKEND="${INJECT_BACKEND:-local}"
fi
INJECT_SKIP_POSTCHECK="${INJECT_SKIP_POSTCHECK:-0}"

STATE_DIR="${ROOT_DIR}/.state"
INJECT_LOCK_FILE="${STATE_DIR}/inject.lock"
DOCKER_ALL_OK="${STATE_DIR}/docker_all_nodes.ok"
mkdir -p "${STATE_DIR}"

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

dry() { [[ "${INJECT_DRY_RUN}" == "1" ]]; }

acquire_inject_lock() {
  [[ "${INJECT_LOCK_SKIP:-}" == "1" ]] && return 0
  exec 200>"${INJECT_LOCK_FILE}"
  if ! flock -n 200; then
    die "another injection is active (${INJECT_LOCK_FILE}); wait until it auto-recovers"
  fi
  log "acquired injection lock"
}

# --- docker / ssh / local --------------------------------------------------

container_from_map() {
  local host="$1" entry ip name
  for entry in ${MYSQL_CONTAINER_MAP}; do
    ip="${entry%%:*}"; name="${entry#*:}"
    [[ "${ip}" == "${host}" ]] && { printf '%s' "${name}"; return 0; }
  done
  return 1
}

container_from_docker_ip() {
  local host="$1" id name ips
  dry && return 1
  require_cmd docker
  while read -r id; do
    [[ -n "${id}" ]] || continue
    ips="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${id}" 2>/dev/null || true)"
    if echo " ${ips} " | grep -q " ${host} "; then
      name="$(docker inspect -f '{{.Name}}' "${id}" | sed 's#^/##')"
      printf '%s' "${name}"
      return 0
    fi
  done < <(docker ps -q)
  return 1
}

resolve_container() {
  local host_or_name="${1:-}"
  [[ -n "${host_or_name}" ]] || return 1
  if dry; then
    local mapped=""
    mapped="$(container_from_map "${host_or_name}" 2>/dev/null || true)"
    printf '%s' "${mapped:-mysql-n1}"
    return 0
  fi
  if docker inspect "${host_or_name}" >/dev/null 2>&1; then
    printf '%s' "${host_or_name}"; return 0
  fi
  local ctn=""
  ctn="$(container_from_map "${host_or_name}" 2>/dev/null || true)"
  [[ -z "${ctn}" ]] && ctn="$(container_from_docker_ip "${host_or_name}" 2>/dev/null || true)"
  [[ -n "${ctn}" ]] || return 1
  docker inspect "${ctn}" >/dev/null 2>&1 || return 1
  printf '%s' "${ctn}"
}

ensure_target_container() {
  if dry; then
    TARGET_CONTAINER="${TARGET_CONTAINER:-$(resolve_container "${TARGET_HOST:-mysql-n1}")}"
    return 0
  fi
  if [[ -n "${TARGET_CONTAINER}" ]]; then
    docker inspect "${TARGET_CONTAINER}" >/dev/null 2>&1 || die "container not found: ${TARGET_CONTAINER}"
    return 0
  fi
  [[ -n "${TARGET_HOST}" ]] || return 1
  TARGET_CONTAINER="$(resolve_container "${TARGET_HOST}")" \
    || die "cannot map ${TARGET_HOST} to a docker container; set MYSQL_CONTAINER_MAP or --target-container"
  log "resolved ${TARGET_HOST} -> container ${TARGET_CONTAINER}"
}

require_target() {
  if dry; then
    TARGET_HOST="${TARGET_HOST:-${MYSQL_PRIMARY%%:*}}"
    TARGET_CONTAINER="${TARGET_CONTAINER:-mysql-n1}"
    return 0
  fi
  case "${INJECT_BACKEND}" in
    docker)
      if [[ -z "${TARGET_CONTAINER}" && -z "${TARGET_HOST}" ]]; then
        die "host-level fault requires --target-host <IP> or --target-container <name>"
      fi
      ensure_target_container
      ;;
    ssh)
      [[ -n "${TARGET_HOST}" ]] || die "host-level fault requires --target-host <IP>"
      ;;
    local) : ;;
    *) die "unknown INJECT_BACKEND=${INJECT_BACKEND}" ;;
  esac
}

run_on_target() {
  local cmd="$1"
  if dry; then
    log "DRY run_on_target $(target_label): ${cmd}"
    return 0
  fi
  case "${INJECT_BACKEND}" in
    docker) ensure_target_container; docker exec "${TARGET_CONTAINER}" bash -lc "${cmd}" ;;
    ssh) ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${TARGET_HOST}" "${cmd}" ;;
    local) bash -lc "${cmd}" ;;
  esac
}

run_on_host() {
  local host="$1" cmd="$2"
  local saved_host="${TARGET_HOST}" saved_ctn="${TARGET_CONTAINER}"
  TARGET_HOST="${host}"; TARGET_CONTAINER=""
  run_on_target "${cmd}"
  local rc=$?
  TARGET_HOST="${saved_host}"; TARGET_CONTAINER="${saved_ctn}"
  return "${rc}"
}

target_label() {
  case "${INJECT_BACKEND}" in
    docker) printf '%s' "${TARGET_CONTAINER:-${TARGET_HOST:-unknown}}" ;;
    *) printf '%s' "${TARGET_HOST:-localhost}" ;;
  esac
}

docker_check() { dry && return 0; docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }
docker_cmd_check() { dry && return 0; docker exec "$1" bash -lc "command -v $2" >/dev/null 2>&1; }
require_all_targets_ok() {
  dry && return 0
  [[ -f "${DOCKER_ALL_OK}" ]] || die "run preflight.sh first (missing ${DOCKER_ALL_OK})"
}

first_node() { echo "${MYSQL_NODES%% *}"; }
primary_node() { echo "${MYSQL_PRIMARY%% *}"; }

replica_nodes() {
  # shellcheck disable=SC2086
  echo ${MYSQL_REPLICAS}
}

parse_duration() {
  DURATION="${DURATION:-${FAULT_DURATION_SEC}}"
  [[ "${DURATION}" =~ ^[0-9]+$ ]] || die "--duration must be a positive integer (seconds)"
}

usage_header() {
  cat <<EOF
Usage: $0 --action <name> [options]

Common options:
  --duration <sec>            Fault active time, auto-recover after expiry (default: ${FAULT_DURATION_SEC})
  --target-host <ip>          Container IP (or host) to inject into
  --target-container <name>   Docker container name
  --node <ip:port>            MySQL endpoint (default: primary ${MYSQL_PRIMARY})
  --scope one|all             Replica scope for replication faults
  --confirm YES               Required for destructive actions
  -h, --help

Backend: INJECT_BACKEND=${INJECT_BACKEND} (docker|ssh|local) DRY_RUN=${INJECT_DRY_RUN}
Lock: ${INJECT_LOCK_FILE}
EOF
}

run_timed_fault() {
  local duration="$1" cleanup_fn="$2"
  trap "${cleanup_fn}" EXIT INT TERM
  log "fault active for ${duration}s, will auto-recover"
  if (( duration > 0 )); then
    sleep "${duration}"
  fi
  "${cleanup_fn}"
  trap - EXIT INT TERM
  log "auto-recovered"
}

require_action() { [[ -n "${ACTION:-}" ]] || die "missing --action"; }
resolve_node() { NODE="${NODE:-$(primary_node)}"; }

bind_target_from_node() {
  local node="${1:-}"
  resolve_node
  node="${node:-${NODE}}"
  TARGET_HOST="${TARGET_HOST:-${node%%:*}}"
  if [[ "${INJECT_BACKEND}" == "docker" ]] || dry; then
    ensure_target_container
  fi
}

node_host() { printf '%s' "${1%%:*}"; }
node_port() {
  local n="$1"
  if [[ "${n}" == *:* ]]; then printf '%s' "${n##*:}"; else printf '%s' "${MYSQL_PORT}"; fi
}

# --- mysql client ----------------------------------------------------------

_mysql_mock() {
  local addr="$1" sql="$2"
  local sql_u host
  sql_u="$(printf '%s' "${sql}" | tr '[:lower:]' '[:upper:]')"
  host="${addr%%:*}"
  case "${sql_u}" in
    *"SELECT 1"*) echo 1 ;;
    *"READ_ONLY"*)
      if [[ "${host}" == "${MYSQL_PRIMARY%%:*}" ]]; then echo 0; else echo 1; fi
      ;;
    *"SUPER_READ_ONLY"*)
      if [[ "${host}" == "${MYSQL_PRIMARY%%:*}" ]]; then echo 0; else echo 1; fi
      ;;
    *"SERVICE_STATE"*)
      if [[ "${host}" == "${MYSQL_PRIMARY%%:*}" ]]; then echo ""; else echo ON; fi
      ;;
    *"SERVER_ID"*)
      case "${host}" in
        *144*|*0.11) echo 11 ;;
        *145*|*0.12) echo 12 ;;
        *) echo 13 ;;
      esac
      ;;
    *"DATADIR"*) echo /var/lib/mysql ;;
    *"MAX_CONNECTIONS"*) echo 151 ;;
    *"INNODB_BUFFER_POOL_SIZE"*) echo 134217728 ;;
    *"REPLICA_PARALLEL_WORKERS"*|*"SLAVE_PARALLEL_WORKERS"*) echo 4 ;;
    *"WAIT_SESSIONS"*) echo 1 ;;
    *"WAIT_FOR_REPLICA_COUNT"*|*"WAIT_FOR_SLAVE_COUNT"*) echo "${SEMI_SYNC_WAIT_REPLICA_COUNT}" ;;
    *"SOURCE_TIMEOUT"*|*"MASTER_TIMEOUT"*) echo "${SEMI_SYNC_TIMEOUT_MS}" ;;
    *"SEMI_SYNC"*"STATUS"*) echo ON ;;
    *"NO_TX"*) echo 0 ;;
    *"GTID_SUBSET"*) echo 1 ;;
    *) echo 0 ;;
  esac
}

mysql_sql() {
  local addr="$1"; shift
  local sql="$1"
  if dry; then
    printf '[%s] DRY mysql %s :: %s\n' "$(date -Iseconds)" "${addr}" "${sql}" >&2
    _mysql_mock "${addr}" "${sql}"
    return 0
  fi
  local host port
  host="${addr%%:*}"
  port="$(node_port "${addr}")"
  MYSQL_PWD="${MYSQL_PASSWORD}" mysql -h "${host}" -P "${port}" -u "${MYSQL_USER}" \
    --connect-timeout=5 --batch --raw --skip-column-names -N -e "${sql}" 2>/dev/null
}

mysql_ok() {
  local addr="$1"
  local v
  v="$(mysql_sql "${addr}" "SELECT 1" 2>/dev/null | tail -1 | tr -d '\r' || true)"
  [[ "${v}" == "1" ]]
}

mysql_try() {
  local addr="$1" sql84="$2" sql80="${3:-}"
  if mysql_sql "${addr}" "${sql84}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "${sql80}" ]]; then
    mysql_sql "${addr}" "${sql80}" >/dev/null 2>&1
  else
    return 1
  fi
}

repl_stop_io() { mysql_try "$1" "STOP REPLICA IO_THREAD" "STOP SLAVE IO_THREAD"; }
repl_start_io() { mysql_try "$1" "START REPLICA IO_THREAD" "START SLAVE IO_THREAD"; }
repl_stop_sql() { mysql_try "$1" "STOP REPLICA SQL_THREAD" "STOP SLAVE SQL_THREAD"; }
repl_start_sql() { mysql_try "$1" "START REPLICA SQL_THREAD" "START SLAVE SQL_THREAD"; }
repl_stop_all() { mysql_try "$1" "STOP REPLICA" "STOP SLAVE"; }
repl_start_all() { mysql_try "$1" "START REPLICA" "START SLAVE"; }

io_state() {
  local addr="$1" v
  v="$(mysql_sql "${addr}" "SELECT SERVICE_STATE FROM performance_schema.replication_connection_status LIMIT 1" 2>/dev/null | tail -1 | tr -d '\r' || true)"
  v="${v// /}"
  printf '%s' "${v:-NA}"
}

sql_state() {
  local addr="$1" v
  v="$(mysql_sql "${addr}" "SELECT SERVICE_STATE FROM performance_schema.replication_applier_status_by_coordinator LIMIT 1" 2>/dev/null | tail -1 | tr -d '\r' || true)"
  if [[ -z "${v}" ]]; then
    v="$(mysql_sql "${addr}" "SELECT SERVICE_STATE FROM performance_schema.replication_applier_status LIMIT 1" 2>/dev/null | tail -1 | tr -d '\r' || true)"
  fi
  v="${v// /}"
  printf '%s' "${v:-NA}"
}

node_role() {
  local addr="$1" io ro
  io="$(io_state "${addr}")"
  case "${io}" in
    ON|OFF|CONNECTING) printf 'replica'; return 0 ;;
  esac
  ro="$(mysql_sql "${addr}" "SELECT @@global.read_only" 2>/dev/null || echo NA)"
  if [[ "${ro}" == "0" ]]; then printf 'primary'; else printf 'unknown'; fi
}

require_replica_node() {
  local addr="$1" role
  role="$(node_role "${addr}")"
  [[ "${role}" == "replica" ]] || die "${addr} is not a replica (role=${role}); pass --node <replica>"
}

require_primary_node() {
  local addr="$1" role
  role="$(node_role "${addr}")"
  [[ "${role}" == "primary" ]] || die "${addr} is not primary (role=${role})"
}

other_replicas() {
  local skip="$1" n
  for n in ${MYSQL_REPLICAS}; do
    [[ "${n}" == "${skip}" ]] && continue
    echo "${n}"
  done
}

detect_datadir() {
  local node="${1:-$(primary_node)}"
  if [[ -n "${MYSQL_DATADIR}" && "${MYSQL_DATADIR}" != "auto" ]]; then
    printf '%s' "${MYSQL_DATADIR}"
    return 0
  fi
  local d
  d="$(mysql_sql "${node}" "SELECT @@datadir" 2>/dev/null || true)"
  d="${d%%/}"
  printf '%s' "${d:-/var/lib/mysql}"
}

semi_status() {
  local addr="${1:-$(primary_node)}" v
  v="$(mysql_sql "${addr}" "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_status'" 2>/dev/null | awk '{print $NF}' || true)"
  if [[ -z "${v}" ]]; then
    v="$(mysql_sql "${addr}" "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_status'" 2>/dev/null | awk '{print $NF}' || true)"
  fi
  printf '%s' "${v:-NA}"
}

semi_wait_sessions() {
  local addr="${1:-$(primary_node)}" v
  v="$(mysql_sql "${addr}" "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_source_wait_sessions'" 2>/dev/null | awk '{print $NF}' || true)"
  if [[ -z "${v}" ]]; then
    v="$(mysql_sql "${addr}" "SHOW GLOBAL STATUS LIKE 'Rpl_semi_sync_master_wait_sessions'" 2>/dev/null | awk '{print $NF}' || true)"
  fi
  printf '%s' "${v:-0}"
}

# --- post-checks -----------------------------------------------------------

skip_pc() {
  if [[ "${INJECT_SKIP_POSTCHECK}" == "1" ]]; then
    log "POSTCHECK skip (dry-run/skip)"
    return 0
  fi
  return 1
}

post_check_cpu() {
  local min_used="${1:-80}"
  skip_pc && return 0
  sleep 5
  local avg
  avg="$(run_on_target "vmstat 1 4 | awk 'NR>3 {idle=\$15; if(idle!=\"\") {sum+=100-idle; n++}} END {if(n>0) printf \"%.0f\", sum/n; else print \"0\"}'")"
  if [[ -z "${avg}" ]] || ! [[ "${avg}" =~ ^[0-9]+$ ]]; then
    log "POSTCHECK FAIL: could not parse CPU from vmstat on $(target_label)"; return 1
  fi
  if (( avg >= min_used )); then
    log "POSTCHECK PASS: host_cpu_used_pct_avg=${avg} (>=${min_used})"; return 0
  fi
  log "POSTCHECK FAIL: host_cpu_used_pct_avg=${avg} (<${min_used})"; return 1
}

post_check_memory() {
  local max_avail="${1:-15}" min_used="${2:-85}"
  skip_pc && return 0
  sleep 5
  local metrics avail used source
  metrics="$(run_on_target '
    if [[ -f /sys/fs/cgroup/memory.max ]]; then
      max=$(cat /sys/fs/cgroup/memory.max); cur=$(cat /sys/fs/cgroup/memory.current)
      if [[ "$max" != "max" && "$max" -gt 0 ]]; then
        echo "source=cgroup avail=$(( (max - cur) * 100 / max )) used=$(( cur * 100 / max ))"; exit 0
      fi
    fi
    awk "/MemTotal:/{t=\$2} /MemAvailable:/{a=\$2} END{if(t>0) print \"source=meminfo avail=\" int(a*100/t) \" used=\" int((t-a)*100/t); else print \"source=meminfo avail=100 used=0\"}" /proc/meminfo
  ')"
  source="$(printf '%s' "${metrics}" | sed -n 's/.*source=\([^ ]*\).*/\1/p')"
  avail="$(printf '%s' "${metrics}" | sed -n 's/.*avail=\([0-9]*\).*/\1/p')"
  used="$(printf '%s' "${metrics}" | sed -n 's/.*used=\([0-9]*\).*/\1/p')"
  if [[ -z "${avail}" ]] || ! [[ "${avail}" =~ ^[0-9]+$ ]]; then
    log "POSTCHECK FAIL: could not parse memory on $(target_label) metrics=${metrics}"; return 1
  fi
  used="${used:-$((100 - avail))}"
  log "POSTCHECK memory ${source} avail=${avail}% used=${used}% on $(target_label)"
  if (( avail <= max_avail )) || (( used >= min_used )); then
    log "POSTCHECK PASS: memory_available_pct=${avail} (<=${max_avail}) or used_pct=${used} (>=${min_used})"; return 0
  fi
  log "POSTCHECK FAIL: memory_available_pct=${avail} (>${max_avail}) and used_pct=${used} (<${min_used})"; return 1
}

post_check_packet_loss() {
  local dev="${1:-${NET_DEV}}"
  skip_pc && return 0
  sleep 1
  local show
  show="$(run_on_target "tc qdisc show dev ${dev} 2>/dev/null || true")"
  if printf '%s' "${show}" | grep -qE 'netem.*loss'; then
    log "POSTCHECK PASS: netem loss active on ${dev}: ${show}"; return 0
  fi
  log "POSTCHECK FAIL: no netem loss qdisc on ${dev}; got: ${show}"; return 1
}

post_check_mysql_down_sustained() {
  local node="$1" seconds="${2:-5}" min_fail="${3:-3}"
  skip_pc && return 0
  local fails=0 i
  for (( i=0; i<seconds; i++ )); do
    if ! mysql_ok "${node}"; then
      fails=$((fails + 1))
    fi
    sleep 1
  done
  if (( fails >= min_fail )); then
    log "POSTCHECK PASS: mysql down on ${node} for ${fails}/${seconds}s"; return 0
  fi
  log "POSTCHECK FAIL: mysql still reachable (${fails}/${seconds}s down, need ${min_fail})"; return 1
}

post_check_io_not_on() {
  local node="$1"
  skip_pc && return 0
  local st
  st="$(io_state "${node}")"
  if [[ "${st}" != "ON" ]]; then
    log "POSTCHECK PASS: IO state=${st} on ${node}"; return 0
  fi
  log "POSTCHECK FAIL: IO still ON on ${node}"; return 1
}

post_check_sql_not_on() {
  local node="$1"
  skip_pc && return 0
  local st
  st="$(sql_state "${node}")"
  if [[ "${st}" != "ON" ]]; then
    log "POSTCHECK PASS: SQL state=${st} on ${node}"; return 0
  fi
  log "POSTCHECK FAIL: SQL still ON on ${node}"; return 1
}

post_check_peer_io_on() {
  local skip="$1" n st
  skip_pc && return 0
  for n in $(other_replicas "${skip}"); do
    st="$(io_state "${n}")"
    if [[ "${st}" != "ON" ]]; then
      log "POSTCHECK FAIL: peer replica ${n} IO=${st} (expected ON for --scope one)"; return 1
    fi
    log "POSTCHECK PASS: peer replica ${n} IO=ON"
  done
  return 0
}

post_check_peer_sql_on() {
  local skip="$1" n st
  skip_pc && return 0
  for n in $(other_replicas "${skip}"); do
    st="$(sql_state "${n}")"
    if [[ "${st}" != "ON" ]]; then
      log "POSTCHECK FAIL: peer replica ${n} SQL=${st} (expected ON)"; return 1
    fi
  done
  return 0
}

# --- inject lifecycle ------------------------------------------------------

emit_inject_result() {
  local scenario="$1" status="$2" detail="${3:-}"
  log "INJECT_RESULT scenario=${scenario} status=${status} detail=${detail}"
}

INJECT_SCENARIO=""; INJECT_RECOVER=""; INJECT_RESULT_EMITTED=0

inject_on_exit() {
  local rc=$?
  if [[ "${INJECT_RESULT_EMITTED}" -eq 1 ]]; then return "${rc}"; fi
  if [[ -n "${INJECT_RECOVER}" ]]; then ${INJECT_RECOVER} || true; fi
  if [[ -n "${INJECT_SCENARIO}" ]]; then
    emit_inject_result "${INJECT_SCENARIO}" "fail" "aborted rc=${rc}"
    INJECT_RESULT_EMITTED=1
  fi
  return "${rc}"
}

inject_begin() {
  INJECT_SCENARIO="$1"; INJECT_RECOVER="${2:-}"; INJECT_RESULT_EMITTED=0
  trap inject_on_exit EXIT
}

inject_pass() {
  emit_inject_result "${INJECT_SCENARIO}" "pass" "$1"
  INJECT_RESULT_EMITTED=1
  trap - EXIT
}

inject_fail() {
  local detail="$1"
  if [[ -n "${INJECT_RECOVER}" ]]; then ${INJECT_RECOVER} || true; fi
  emit_inject_result "${INJECT_SCENARIO}" "fail" "${detail}"
  INJECT_RESULT_EMITTED=1
  trap - EXIT
  exit 1
}

CONTAINER_RESTART_SAVED=""
save_container_restart_policy() {
  dry && return 0
  [[ "${INJECT_BACKEND}" == "docker" ]] || return 0
  ensure_target_container
  CONTAINER_RESTART_SAVED="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${TARGET_CONTAINER}" 2>/dev/null || echo unless-stopped)"
  docker update --restart=no "${TARGET_CONTAINER}" >/dev/null
  log "disabled auto-restart on ${TARGET_CONTAINER} (was ${CONTAINER_RESTART_SAVED})"
}

restore_container_restart_policy() {
  dry && return 0
  [[ "${INJECT_BACKEND}" == "docker" ]] || return 0
  [[ -n "${TARGET_CONTAINER}" && -n "${CONTAINER_RESTART_SAVED}" ]] || return 0
  docker update --restart="${CONTAINER_RESTART_SAVED}" "${TARGET_CONTAINER}" >/dev/null 2>&1 || true
  log "restored auto-restart=${CONTAINER_RESTART_SAVED} on ${TARGET_CONTAINER}"
  CONTAINER_RESTART_SAVED=""
}

apply_netem() {
  local dev="$1" spec="$2"
  if dry; then
    log "DRY tc netem ${dev} ${spec}"; return 0
  fi
  if ! run_on_target "tc qdisc replace dev ${dev} root netem ${spec} 2>/dev/null"; then
    command -v modprobe >/dev/null 2>&1 && modprobe sch_netem 2>/dev/null || true
    run_on_target "tc qdisc replace dev ${dev} root netem ${spec}"
  fi
}

restart_target() {
  if dry; then log "DRY restart $(target_label)"; return 0; fi
  case "${INJECT_BACKEND}" in
    docker) ensure_target_container; log "docker restart ${TARGET_CONTAINER}"; docker restart "${TARGET_CONTAINER}" ;;
    ssh) run_on_target "reboot" ;;
    local) die "reboot not supported on local backend" ;;
  esac
}

require_confirm() {
  local what="$1"
  [[ "${CONFIRM:-}" == "YES" ]] || die "${what} requires --confirm YES"
}
