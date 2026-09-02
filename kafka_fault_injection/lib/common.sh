#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/config.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/config.env"
fi

INJECT_BACKEND="${INJECT_BACKEND:-docker}"
KAFKA_NODES="${KAFKA_NODES:-10.10.26.144:9092 10.10.26.145:9092 10.10.26.146:9092}"
KAFKA_HOME="${KAFKA_HOME:-/opt/kafka/3.8.1}"
KAFKA_PORT="${KAFKA_PORT:-9092}"
CONTROLLER_PORT="${CONTROLLER_PORT:-9093}"
KAFKA_DATA_DIR="${KAFKA_DATA_DIR:-/var/lib/kafka/data}"
KAFKA_LOG_DIR="${KAFKA_LOG_DIR:-/var/log/kafka}"
KAFKA_CONF="${KAFKA_CONF:-/etc/kafka/server.properties}"
KAFKA_SERVICE="${KAFKA_SERVICE:-kafka}"
KAFKA_CONTAINER_MAP="${KAFKA_CONTAINER_MAP:-}"
KAFKA_CONTAINERS="${KAFKA_CONTAINERS:-}"
BOOTSTRAP="${BOOTSTRAP:-10.10.26.144:9092,10.10.26.145:9092,10.10.26.146:9092}"
FAULT_TOPIC="${FAULT_TOPIC:-fault-inject}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_CONTAINER="${TARGET_CONTAINER:-}"
FAULT_DURATION_SEC="${FAULT_DURATION_SEC:-600}"
SSH_USER="${SSH_USER:-root}"
NET_DEV="${NET_DEV:-eth0}"

STATE_DIR="${ROOT_DIR}/.state"
INJECT_LOCK_FILE="${STATE_DIR}/inject.lock"
DOCKER_ALL_OK="${STATE_DIR}/docker_all_nodes.ok"

mkdir -p "${STATE_DIR}"

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

acquire_inject_lock() {
  [[ "${INJECT_LOCK_SKIP:-}" == "1" ]] && return 0
  exec 200>"${INJECT_LOCK_FILE}"
  if ! flock -n 200; then
    die "another injection is active (${INJECT_LOCK_FILE}); wait until it auto-recovers"
  fi
  log "acquired injection lock"
}

container_from_map() {
  local host="$1" entry ip name
  for entry in ${KAFKA_CONTAINER_MAP}; do
    ip="${entry%%:*}"; name="${entry#*:}"
    [[ "${ip}" == "${host}" ]] && { printf '%s' "${name}"; return 0; }
  done
  return 1
}

container_from_docker_ip() {
  local host="$1" id name ips
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
  if [[ -n "${TARGET_CONTAINER}" ]]; then
    docker inspect "${TARGET_CONTAINER}" >/dev/null 2>&1 || die "container not found: ${TARGET_CONTAINER}"
    return 0
  fi
  [[ -n "${TARGET_HOST}" ]] || return 1
  TARGET_CONTAINER="$(resolve_container "${TARGET_HOST}")" \
    || die "cannot map ${TARGET_HOST} to a docker container; set KAFKA_CONTAINER_MAP or --target-container"
  log "resolved ${TARGET_HOST} -> container ${TARGET_CONTAINER}"
}

require_target() {
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

docker_check() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }
docker_cmd_check() { docker exec "$1" bash -lc "command -v $2" >/dev/null 2>&1; }
require_all_targets_ok() { [[ -f "${DOCKER_ALL_OK}" ]] || die "run preflight.sh first"; }

first_node() { echo "${KAFKA_NODES%% *}"; }

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
  --node <ip:port>            Kafka broker endpoint (default: first node)
  -h, --help

Backend: INJECT_BACKEND=${INJECT_BACKEND} (docker|ssh|local)
Lock: ${INJECT_LOCK_FILE}
EOF
}

run_timed_fault() {
  local duration="$1" cleanup_fn="$2"
  trap "${cleanup_fn}" EXIT INT TERM
  log "fault active for ${duration}s, will auto-recover"
  sleep "${duration}"
  "${cleanup_fn}"
  trap - EXIT INT TERM
  log "auto-recovered"
}

require_action() { [[ -n "${ACTION:-}" ]] || die "missing --action"; }

resolve_node() { NODE="${NODE:-$(first_node)}"; }

bind_target_from_node() {
  local node="${1:-}"
  resolve_node
  node="${node:-${NODE}}"
  TARGET_HOST="${TARGET_HOST:-${node%%:*}}"
  if [[ "${INJECT_BACKEND}" == "docker" ]]; then
    ensure_target_container
  fi
}

node_host() { local n="${1:-}"; printf '%s' "${n%%:*}"; }

kafka_sh() {
  local name="$1"; shift
  local bin="${KAFKA_HOME}/bin/${name}"
  [[ -x "${bin}" ]] || die "missing ${bin}"
  "${bin}" "$@"
}

broker_api_ok() {
  local addr="${1:-$(first_node)}"
  timeout 8 "${KAFKA_HOME}/bin/kafka-broker-api-versions.sh" --bootstrap-server "${addr}" >/dev/null 2>&1
}

ensure_topic() {
  local topic="${1:-${FAULT_TOPIC}}"
  local rf="${2:-3}"
  local parts="${3:-3}"
  kafka_sh kafka-topics.sh --bootstrap-server "${BOOTSTRAP}" --create --topic "${topic}" \
    --partitions "${parts}" --replication-factor "${rf}" --if-not-exists >/dev/null 2>&1 || true
}

urp_count() {
  kafka_sh kafka-topics.sh --bootstrap-server "${BOOTSTRAP}" --describe --under-replicated-partitions 2>/dev/null \
    | grep -c "Topic:" || true
}

offline_count() {
  kafka_sh kafka-topics.sh --bootstrap-server "${BOOTSTRAP}" --describe --unavailable-partitions 2>/dev/null \
    | grep -c "Topic:" || true
}

post_check_cpu() {
  local min_used="${1:-80}"
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
  local dev="${1:-eth0}"
  sleep 1
  local show
  show="$(run_on_target "tc qdisc show dev ${dev} 2>/dev/null || true")"
  if printf '%s' "${show}" | grep -qE 'netem.*loss'; then
    log "POSTCHECK PASS: netem loss active on ${dev}: ${show}"; return 0
  fi
  log "POSTCHECK FAIL: no netem loss qdisc on ${dev}; got: ${show}"; return 1
}

post_check_broker_down() {
  local node="${1:-}"
  resolve_node; node="${node:-${NODE}}"
  if ! broker_api_ok "${node}"; then
    log "POSTCHECK PASS: broker API down on ${node}"; return 0
  fi
  log "POSTCHECK FAIL: broker API still up on ${node}"; return 1
}

post_check_broker_up() {
  local node="${1:-}"
  resolve_node; node="${node:-${NODE}}"
  if broker_api_ok "${node}"; then
    log "POSTCHECK PASS: broker API up on ${node}"; return 0
  fi
  log "POSTCHECK FAIL: broker API down on ${node}"; return 1
}

post_check_urp() {
  sleep 8
  local n
  n="$(urp_count)"
  n="${n:-0}"
  if (( n > 0 )); then
    log "POSTCHECK PASS: URP count=${n}"; return 0
  fi
  log "POSTCHECK FAIL: no under-replicated partitions"; return 1
}

post_check_disk_full() {
  local dir="${1:-${KAFKA_DATA_DIR}}" thresh="${2:-90}"
  sleep 2
  local used
  used="$(run_on_target "df -P ${dir} | awk 'NR==2{gsub(\"%\",\"\",\$5); print \$5}'")"
  if [[ "${used}" =~ ^[0-9]+$ ]] && (( used >= thresh )); then
    log "POSTCHECK PASS: ${dir} used ${used}% (>=${thresh})"; return 0
  fi
  log "POSTCHECK FAIL: ${dir} used ${used:-?} < ${thresh}"; return 1
}

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
  [[ "${INJECT_BACKEND}" == "docker" ]] || return 0
  ensure_target_container
  CONTAINER_RESTART_SAVED="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "${TARGET_CONTAINER}" 2>/dev/null || echo unless-stopped)"
  docker update --restart=no "${TARGET_CONTAINER}" >/dev/null
  log "disabled auto-restart on ${TARGET_CONTAINER} (was ${CONTAINER_RESTART_SAVED})"
}

restore_container_restart_policy() {
  [[ "${INJECT_BACKEND}" == "docker" ]] || return 0
  [[ -n "${TARGET_CONTAINER}" && -n "${CONTAINER_RESTART_SAVED}" ]] || return 0
  docker update --restart="${CONTAINER_RESTART_SAVED}" "${TARGET_CONTAINER}" >/dev/null 2>&1 || true
  log "restored auto-restart=${CONTAINER_RESTART_SAVED} on ${TARGET_CONTAINER}"
  CONTAINER_RESTART_SAVED=""
}

apply_netem() {
  local dev="$1" spec="$2"
  if ! run_on_target "tc qdisc replace dev ${dev} root netem ${spec} 2>/dev/null"; then
    command -v modprobe >/dev/null 2>&1 && modprobe sch_netem 2>/dev/null || true
    run_on_target "tc qdisc replace dev ${dev} root netem ${spec}"
  fi
}

restart_target() {
  case "${INJECT_BACKEND}" in
    docker) ensure_target_container; log "docker restart ${TARGET_CONTAINER}"; docker restart "${TARGET_CONTAINER}" ;;
    ssh) run_on_target "reboot" ;;
    local) die "reboot not supported on local backend" ;;
  esac
}
