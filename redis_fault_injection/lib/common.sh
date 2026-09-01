#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/config.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/config.env"
fi

# Lab model: docker-node runs injection bot; Redis lives in Docker containers
# that simulate VMs (binary redis inside). Host-level faults use docker exec.
INJECT_BACKEND="${INJECT_BACKEND:-docker}"

REDIS_NODES="${REDIS_NODES:-10.10.26.144:6379 10.10.26.145:6379 10.10.26.146:6379}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
REDIS_CLI="${REDIS_CLI:-redis-cli}"
CLUSTER_BUS_PORT="${CLUSTER_BUS_PORT:-16379}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_CONTAINER="${TARGET_CONTAINER:-}"
FAULT_DURATION_SEC="${FAULT_DURATION_SEC:-600}"
SSH_USER="${SSH_USER:-root}"
# Prefer CONFIG GET dir when empty or "auto"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-auto}"
REDIS_CONF="${REDIS_CONF:-/etc/redis/redis.conf}"
REDIS_SERVICE="${REDIS_SERVICE:-redis}"
# Optional: "ip:container ip:container ..." — overrides auto IP→container lookup
REDIS_CONTAINER_MAP="${REDIS_CONTAINER_MAP:-}"
# Optional: space-separated container names in same order as REDIS_NODES
REDIS_CONTAINERS="${REDIS_CONTAINERS:-}"

STATE_DIR="${ROOT_DIR}/.state"
INJECT_LOCK_FILE="${STATE_DIR}/inject.lock"
DOCKER_ALL_OK="${STATE_DIR}/docker_all_nodes.ok"

if [[ -n "${REDIS_PASSWORD}" ]]; then
  export REDISCLI_AUTH="${REDIS_PASSWORD}"
fi

mkdir -p "${STATE_DIR}"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

acquire_inject_lock() {
  [[ "${INJECT_LOCK_SKIP:-}" == "1" ]] && return 0
  exec 200>"${INJECT_LOCK_FILE}"
  if ! flock -n 200; then
    die "another injection is active (${INJECT_LOCK_FILE}); wait until it auto-recovers"
  fi
  log "acquired injection lock"
}

# --- backend: docker | ssh | local ------------------------------------------

container_from_map() {
  local host="$1"
  local entry ip name
  for entry in ${REDIS_CONTAINER_MAP}; do
    ip="${entry%%:*}"
    name="${entry#*:}"
    if [[ "${ip}" == "${host}" ]]; then
      printf '%s' "${name}"
      return 0
    fi
  done
  return 1
}

container_from_order() {
  local host="$1"
  local i=0
  local node h
  local -a containers=()
  # shellcheck disable=SC2206
  containers=(${REDIS_CONTAINERS})
  [[ ${#containers[@]} -gt 0 ]] || return 1
  for node in ${REDIS_NODES}; do
    h="${node%%:*}"
    if [[ "${h}" == "${host}" ]]; then
      printf '%s' "${containers[$i]:-}"
      [[ -n "${containers[$i]:-}" ]]
      return $?
    fi
    i=$((i + 1))
  done
  return 1
}

container_from_docker_ip() {
  local host="$1"
  local id name ips
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

  # Already a running container name?
  if docker inspect "${host_or_name}" >/dev/null 2>&1; then
    printf '%s' "${host_or_name}"
    return 0
  fi

  local ctn=""
  ctn="$(container_from_map "${host_or_name}" 2>/dev/null || true)"
  if [[ -z "${ctn}" ]]; then
    ctn="$(container_from_order "${host_or_name}" 2>/dev/null || true)"
  fi
  if [[ -z "${ctn}" ]]; then
    ctn="$(container_from_docker_ip "${host_or_name}" 2>/dev/null || true)"
  fi
  [[ -n "${ctn}" ]] || return 1
  docker inspect "${ctn}" >/dev/null 2>&1 || return 1
  printf '%s' "${ctn}"
}

# Resolve TARGET_CONTAINER from TARGET_HOST / TARGET_CONTAINER / --node host
ensure_target_container() {
  if [[ -n "${TARGET_CONTAINER}" ]]; then
    docker inspect "${TARGET_CONTAINER}" >/dev/null 2>&1 \
      || die "container not found: ${TARGET_CONTAINER}"
    return 0
  fi
  [[ -n "${TARGET_HOST}" ]] || return 1
  TARGET_CONTAINER="$(resolve_container "${TARGET_HOST}")" \
    || die "cannot map ${TARGET_HOST} to a docker container; set REDIS_CONTAINER_MAP or --target-container"
  log "resolved ${TARGET_HOST} -> container ${TARGET_CONTAINER}"
}

require_target() {
  case "${INJECT_BACKEND}" in
    docker)
      if [[ -z "${TARGET_CONTAINER}" && -z "${TARGET_HOST}" ]]; then
        die "host-level fault requires --target-host <container IP> or --target-container <name>"
      fi
      ensure_target_container
      ;;
    ssh)
      [[ -n "${TARGET_HOST}" ]] || die "host-level fault requires --target-host <IP> (INJECT_BACKEND=ssh)"
      ;;
    local)
      :
      ;;
    *)
      die "unknown INJECT_BACKEND=${INJECT_BACKEND} (use docker|ssh|local)"
      ;;
  esac
}

run_on_target() {
  local cmd="$1"
  case "${INJECT_BACKEND}" in
    docker)
      ensure_target_container
      docker exec "${TARGET_CONTAINER}" bash -lc "${cmd}"
      ;;
    ssh)
      [[ -n "${TARGET_HOST}" ]] || die "TARGET_HOST empty for ssh backend"
      ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${TARGET_HOST}" "${cmd}"
      ;;
    local)
      bash -lc "${cmd}"
      ;;
  esac
}

# Run a command on a specific host/container without clobbering caller's target forever
run_on_host() {
  local host="$1"
  local cmd="$2"
  local saved_host="${TARGET_HOST}"
  local saved_ctn="${TARGET_CONTAINER}"
  TARGET_HOST="${host}"
  TARGET_CONTAINER=""
  run_on_target "${cmd}"
  local rc=$?
  TARGET_HOST="${saved_host}"
  TARGET_CONTAINER="${saved_ctn}"
  return "${rc}"
}

target_label() {
  case "${INJECT_BACKEND}" in
    docker) printf '%s' "${TARGET_CONTAINER:-${TARGET_HOST:-unknown}}" ;;
    *) printf '%s' "${TARGET_HOST:-localhost}" ;;
  esac
}

docker_check() {
  local ctn="$1"
  docker inspect -f '{{.State.Running}}' "${ctn}" 2>/dev/null | grep -q true
}

docker_cmd_check() {
  local ctn="$1"
  local cmd="$2"
  docker exec "${ctn}" bash -lc "command -v ${cmd}" >/dev/null 2>&1
}

require_all_targets_ok() {
  [[ -f "${DOCKER_ALL_OK}" ]] || die "requires all docker nodes ready; run preflight.sh first"
}

# --- redis helpers ----------------------------------------------------------

redis_cmd() {
  local addr="$1"
  shift
  local host port
  host="${addr%%:*}"
  port="${addr##*:}"
  if [[ -n "${REDIS_PASSWORD}" ]]; then
    "${REDIS_CLI}" -h "${host}" -p "${port}" -a "${REDIS_PASSWORD}" --no-auth-warning "$@"
  else
    "${REDIS_CLI}" -h "${host}" -p "${port}" "$@"
  fi
}

redis_cmd_nocluster() {
  local addr="$1"
  shift
  local host port
  host="${addr%%:*}"
  port="${addr##*:}"
  if [[ -n "${REDIS_PASSWORD}" ]]; then
    "${REDIS_CLI}" --no-auth-warning -h "${host}" -p "${port}" -a "${REDIS_PASSWORD}" "$@"
  else
    "${REDIS_CLI}" --no-auth-warning -h "${host}" -p "${port}" "$@"
  fi
}

first_node() {
  echo "${REDIS_NODES%% *}"
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
  --target-container <name>   Docker container name (INJECT_BACKEND=docker)
  --node <ip:port>            Redis endpoint (default: first node in config)
  -h, --help                  Show help

Backend: INJECT_BACKEND=${INJECT_BACKEND} (docker|ssh|local)
Injection bot runs one action at a time; lock file: ${INJECT_LOCK_FILE}
EOF
}

run_timed_fault() {
  local duration="$1"
  local cleanup_fn="$2"
  trap "${cleanup_fn}" EXIT INT TERM
  log "fault active for ${duration}s, will auto-recover"
  sleep "${duration}"
  "${cleanup_fn}"
  trap - EXIT INT TERM
  log "auto-recovered"
}

require_action() {
  [[ -n "${ACTION:-}" ]] || die "missing --action"
}

resolve_node() {
  NODE="${NODE:-$(first_node)}"
}

node_state_key() {
  echo "${1//[:.]/_}"
}

misconf_state_file() {
  echo "${STATE_DIR}/misconf_$(node_state_key "${1}")"
}

save_misconf_state() {
  local node="$1"
  local field="$2"
  local value="$3"
  local file
  file="$(misconf_state_file "${node}")"
  touch "${file}"
  printf '%s=%s\n' "${field}" "${value}" >> "${file}"
}

load_misconf_state() {
  local node="$1"
  local field="$2"
  local default="${3:-}"
  local file
  file="$(misconf_state_file "${node}")"
  if [[ -f "${file}" ]]; then
    grep "^${field}=" "${file}" | tail -1 | cut -d= -f2- || printf '%s' "${default}"
  else
    printf '%s' "${default}"
  fi
}

clear_misconf_state() {
  rm -f "$(misconf_state_file "${1}")"
}

# Command string to run redis-cli *inside* the target container
remote_redis_cli() {
  local host="$1"
  local port="$2"
  if [[ -n "${REDIS_PASSWORD}" ]]; then
    printf 'redis-cli --no-auth-warning -h %s -p %s -a %q' "${host}" "${port}" "${REDIS_PASSWORD}"
  else
    printf 'redis-cli --no-auth-warning -h %s -p %s' "${host}" "${port}"
  fi
}

detect_redis_data_dir() {
  local node="${1:-$(first_node)}"
  redis_cmd "${node}" CONFIG GET dir 2>/dev/null | awk 'NR==2{print; exit}'
}

resolve_data_dir() {
  local node="${1:-$(first_node)}"
  if [[ -z "${REDIS_DATA_DIR}" || "${REDIS_DATA_DIR}" == "auto" ]]; then
    REDIS_DATA_DIR="$(detect_redis_data_dir "${node}" || true)"
    [[ -n "${REDIS_DATA_DIR}" ]] || die "cannot detect Redis dir; set REDIS_DATA_DIR in config.env"
    log "using Redis data dir from CONFIG GET dir: ${REDIS_DATA_DIR}"
  fi
}

# Bind target from a redis node address (ip:port)
bind_target_from_node() {
  local node="${1:-}"
  resolve_node
  node="${node:-${NODE}}"
  TARGET_HOST="${TARGET_HOST:-${node%%:*}}"
  if [[ "${INJECT_BACKEND}" == "docker" ]]; then
    ensure_target_container
  fi
}

# --- post-checks ------------------------------------------------------------

post_check_cpu() {
  local min_used="${1:-80}"
  sleep 5
  local avg
  # vmstat prints 2 header lines, then 1 since-boot summary, then interval samples.
  # Use vmstat 1 4 and skip NR<=3 so the average is only over 3 true 1s intervals
  # (including since-boot idle ~90%+ falsely pulls avg below the 80% gate).
  avg="$(run_on_target "vmstat 1 4 | awk 'NR>3 {idle=\$15; if(idle!=\"\") {sum+=100-idle; n++}} END {if(n>0) printf \"%.0f\", sum/n; else print \"0\"}'")"
  if [[ -z "${avg}" ]] || ! [[ "${avg}" =~ ^[0-9]+$ ]]; then
    log "POSTCHECK FAIL: could not parse CPU from vmstat on $(target_label)"
    return 1
  fi
  if (( avg >= min_used )); then
    log "POSTCHECK PASS: host_cpu_used_pct_avg=${avg} (>=${min_used})"
    return 0
  fi
  log "POSTCHECK FAIL: host_cpu_used_pct_avg=${avg} (<${min_used})"
  return 1
}

post_check_memory() {
  local max_avail="${1:-15}"
  local min_used="${2:-85}"
  sleep 5
  local metrics avail used source
  metrics="$(run_on_target '
    read_meminfo_avail() {
      awk "/MemTotal:/{t=\$2} /MemAvailable:/{a=\$2} END{if(t>0) print int(a*100/t); else print 100}" /proc/meminfo
    }
    if [[ -f /sys/fs/cgroup/memory.max ]]; then
      max=$(cat /sys/fs/cgroup/memory.max)
      cur=$(cat /sys/fs/cgroup/memory.current)
      if [[ "$max" != "max" && "$max" -gt 0 ]]; then
        avail=$(( (max - cur) * 100 / max ))
        used=$(( cur * 100 / max ))
        echo "source=cgroup avail=${avail} used=${used}"
        exit 0
      fi
    fi
    if [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
      max=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
      cur=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes)
      if [[ "$max" -lt 9000000000000000000 && "$max" -gt 0 ]]; then
        avail=$(( (max - cur) * 100 / max ))
        used=$(( cur * 100 / max ))
        echo "source=cgroup avail=${avail} used=${used}"
        exit 0
      fi
    fi
    avail=$(read_meminfo_avail)
    used=$((100 - avail))
    echo "source=meminfo avail=${avail} used=${used}"
  ')"
  source="$(printf '%s' "${metrics}" | sed -n 's/.*source=\([^ ]*\).*/\1/p')"
  avail="$(printf '%s' "${metrics}" | sed -n 's/.*avail=\([0-9]*\).*/\1/p')"
  used="$(printf '%s' "${metrics}" | sed -n 's/.*used=\([0-9]*\).*/\1/p')"
  if [[ -z "${avail}" ]] || ! [[ "${avail}" =~ ^[0-9]+$ ]]; then
    log "POSTCHECK FAIL: could not parse memory on $(target_label) metrics=${metrics}"
    return 1
  fi
  used="${used:-$((100 - avail))}"
  log "POSTCHECK memory ${source} avail=${avail}% used=${used}% on $(target_label)"
  if [[ "${source}" == "meminfo" ]]; then
    log "POSTCHECK WARN: no cgroup memory limit; set container mem_limit for reliable F04"
  fi
  if (( avail <= max_avail )) || (( used >= min_used )); then
    log "POSTCHECK PASS: memory_available_pct=${avail} (<=${max_avail}) or used_pct=${used} (>=${min_used})"
    return 0
  fi
  log "POSTCHECK FAIL: memory_available_pct=${avail} (>${max_avail}) and used_pct=${used} (<${min_used})"
  return 1
}

post_check_packet_loss() {
  local dev="${1:-eth0}"
  local loss="${2:-30}"
  sleep 1
  local show
  show="$(run_on_target "tc qdisc show dev ${dev} 2>/dev/null || true")"
  if printf '%s' "${show}" | grep -qE 'netem.*loss'; then
    log "POSTCHECK PASS: netem loss active on ${dev}: ${show}"
    return 0
  fi
  log "POSTCHECK FAIL: no netem loss qdisc on ${dev}; got: ${show}"
  return 1
}

post_check_misconf_increment() {
  local node="$1"
  local before="$2"
  local after
  sleep 2
  after="$(misconf_count "${node}")"
  before="${before:-0}"
  after="${after:-0}"
  log "POSTCHECK MISCONF before=${before} after=${after} on ${node}"
  if (( after > before )); then
    log "POSTCHECK PASS: MISCONF incremented ${before}->${after}"
    return 0
  fi
  log "POSTCHECK FAIL: MISCONF not incremented on ${node}"
  return 1
}

post_check_ping_down_sustained() {
  local node="$1"
  local seconds="${2:-5}"
  local min_fail="${3:-3}"
  local fails=0 i
  for (( i=0; i<seconds; i++ )); do
    if ! redis_cmd "${node}" PING >/dev/null 2>&1; then
      fails=$((fails + 1))
    fi
    sleep 1
  done
  if (( fails >= min_fail )); then
    log "POSTCHECK PASS: redis down on ${node} for ${fails}/${seconds}s"
    return 0
  fi
  log "POSTCHECK FAIL: redis still reachable (${fails}/${seconds}s down, need ${min_fail})"
  return 1
}

post_check_ping_down() {
  local node="$1"
  if ! redis_cmd "${node}" PING >/dev/null 2>&1; then
    log "POSTCHECK PASS: redis unreachable on ${node}"
    return 0
  fi
  log "POSTCHECK FAIL: redis still responds to PING on ${node}"
  return 1
}

post_check_ping_up() {
  local node="$1"
  if redis_cmd "${node}" PING >/dev/null 2>&1; then
    log "POSTCHECK PASS: redis PING ok on ${node}"
    return 0
  fi
  log "POSTCHECK FAIL: redis PING failed on ${node}"
  return 1
}

emit_inject_result() {
  local scenario="$1"
  local status="$2"
  local detail="${3:-}"
  log "INJECT_RESULT scenario=${scenario} status=${status} detail=${detail}"
}

# --- injection lifecycle (always emit INJECT_RESULT on abort) ---------------

INJECT_SCENARIO=""
INJECT_RECOVER=""
INJECT_RESULT_EMITTED=0

inject_on_exit() {
  local rc=$?
  if [[ "${INJECT_RESULT_EMITTED}" -eq 1 ]]; then
    return "${rc}"
  fi
  if [[ -n "${INJECT_RECOVER}" ]]; then
    ${INJECT_RECOVER} || true
  fi
  if [[ -n "${INJECT_SCENARIO}" ]]; then
    emit_inject_result "${INJECT_SCENARIO}" "fail" "aborted rc=${rc}"
    INJECT_RESULT_EMITTED=1
  fi
  return "${rc}"
}

inject_begin() {
  INJECT_SCENARIO="$1"
  INJECT_RECOVER="${2:-}"
  INJECT_RESULT_EMITTED=0
  trap inject_on_exit EXIT
}

inject_pass() {
  emit_inject_result "${INJECT_SCENARIO}" "pass" "$1"
  INJECT_RESULT_EMITTED=1
  trap - EXIT
}

inject_fail() {
  local detail="$1"
  if [[ -n "${INJECT_RECOVER}" ]]; then
    ${INJECT_RECOVER} || true
  fi
  emit_inject_result "${INJECT_SCENARIO}" "fail" "${detail}"
  INJECT_RESULT_EMITTED=1
  trap - EXIT
  exit 1
}

# Docker Restart=always/unless-stopped defeats F07 if shorter than cluster timeout
CONTAINER_RESTART_SAVED=""

save_container_restart_policy() {
  [[ "${INJECT_BACKEND}" == "docker" ]] || return 0
  ensure_target_container
  CONTAINER_RESTART_SAVED="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${TARGET_CONTAINER}" 2>/dev/null || echo unless-stopped)"
  docker update --restart=no "${TARGET_CONTAINER}" >/dev/null
  log "disabled auto-restart on ${TARGET_CONTAINER} (was ${CONTAINER_RESTART_SAVED})"
}

restore_container_restart_policy() {
  [[ "${INJECT_BACKEND}" == "docker" ]] || return 0
  [[ -n "${TARGET_CONTAINER}" ]] || return 0
  [[ -n "${CONTAINER_RESTART_SAVED}" ]] || return 0
  docker update --restart="${CONTAINER_RESTART_SAVED}" "${TARGET_CONTAINER}" >/dev/null 2>&1 || true
  log "restored auto-restart=${CONTAINER_RESTART_SAVED} on ${TARGET_CONTAINER}"
  CONTAINER_RESTART_SAVED=""
}

misconf_count() {
  local node="$1"
  redis_cmd "${node}" INFO ERRORSTATS 2>/dev/null \
    | grep -i MISCONF | awk -F: '{gsub(/\r/,"",$2); print $2}' | head -1 || echo 0
}

resolve_io_dir() {
  local node="${1:-$(first_node)}"
  if [[ -z "${IO_DIR:-}" || "${IO_DIR}" == "auto" ]]; then
    resolve_data_dir "${node}"
    IO_DIR="${REDIS_DATA_DIR}/fault_io"
    log "IO_DIR=${IO_DIR} (under Redis data dir, not tmpfs)"
  fi
}

apply_netem_loss() {
  local dev="$1"
  local loss="$2"
  if run_on_target "tc qdisc replace dev ${dev} root netem loss ${loss}% 2>/dev/null"; then
    return 0
  fi
  if command -v modprobe >/dev/null 2>&1; then
    modprobe sch_netem 2>/dev/null || true
  fi
  run_on_target "tc qdisc replace dev ${dev} root netem loss ${loss}%"
}

# Restart "VM" = docker restart container (simulates host reboot)
restart_target() {
  case "${INJECT_BACKEND}" in
    docker)
      ensure_target_container
      log "docker restart ${TARGET_CONTAINER} (simulates VM reboot)"
      docker restart "${TARGET_CONTAINER}"
      ;;
    ssh)
      run_on_target "reboot"
      ;;
    local)
      die "reboot not supported on local backend"
      ;;
  esac
}
