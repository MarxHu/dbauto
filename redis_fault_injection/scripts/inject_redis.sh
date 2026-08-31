#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""
DURATION=""
NODE=""
MAXMEMORY="${MAXMEMORY:-64mb}"
MAXCLIENTS="${MAXCLIENTS:-10}"
SLEEP_MS="${SLEEP_MS:-3000}"
INTERVAL="${INTERVAL:-5}"
KEY="${KEY:-fault:hotkey}"
THREADS="${THREADS:-8}"
FIELD_COUNT="${FIELD_COUNT:-20000}"
VALUE_SIZE="${VALUE_SIZE:-256}"
REQUEST_COUNT="${REQUEST_COUNT:-10000}"
ERROR_TYPE="${ERROR_TYPE:-NOAUTH}"
PULSE_INTERVAL="${PULSE_INTERVAL:-5}"
PULSE_MAX="${PULSE_MAX:-18}"
EXPIRE_KEY="${EXPIRE_KEY:-}"
EXPIRE_AFTER="${EXPIRE_AFTER:-0}"
CLEANUP_BIGKEY="${CLEANUP_BIGKEY:-yes}"

STOPPED_NODE=""
ORIG_MAXMEMORY=""
ORIG_MAXCLIENTS=""
BIGKEY_NAME=""
FILL_PID=""

usage() {
  usage_header
  cat <<EOF

Actions:
  process-stop       Stop redis-server, auto-start after duration
  maxmemory          Lower maxmemory and fill keys, restore after duration
  maxclients         Lower maxclients and flood connections, restore after duration
  slow-command       Inject DEBUG SLEEP periodically
  hot-key            High-frequency access on one key
  big-key            Seed a large hash; optional cleanup after duration (--no-cleanup-bigkey)
  cache-expire       Expire one key or FLUSHDB when --expire-key omitted (destructive)
  cache-penetrate    Burst GET on missing keys
  error-pulse        NOAUTH/WRONGPASS/MOVED/CROSSSLOT bounded pulse
  historical-misconf One-shot seed historical MISCONF counter (no auto state restore)
  historical-misconf-cleanup  Restore config and restart redis to clear ERRORSTATS (recommended after F29/C01)

Extra options:
  --maxmemory <size>       default 64mb
  --maxclients <n>         default 10
  --error-type <name>      NOAUTH|WRONGPASS|MOVED|CROSSSLOT
  --expire-key <name>      key for cache-expire; omit to FLUSHDB
  --request-count <n>      cache-penetrate volume
  --no-cleanup-bigkey      keep seeded big key after duration

Examples:
  $0 --action process-stop --node 10.10.26.144:6379 --duration 240
  $0 --action maxmemory --node 10.10.26.144:6379 --duration 240 --maxmemory 64mb
  $0 --action error-pulse --node 10.10.26.146:6379 --duration 90 --error-type NOAUTH
EOF
}

recover_process_stop() {
  resolve_node
  local node="${STOPPED_NODE:-${NODE}}"
  TARGET_HOST="${TARGET_HOST:-${node%%:*}}"
  TARGET_CONTAINER="${TARGET_CONTAINER:-}"
  log "auto-start redis on ${node} via ${INJECT_BACKEND}"
  run_on_target "
    systemctl start ${REDIS_SERVICE} 2>/dev/null || \
    redis-server ${REDIS_CONF} 2>/dev/null || \
    redis-server --port ${node##*:} --dir ${REDIS_DATA_DIR:-/var/lib/redis} --daemonize yes 2>/dev/null || true
  "
}

recover_maxmemory() {
  resolve_node
  [[ -n "${FILL_PID:-}" ]] && kill "${FILL_PID}" 2>/dev/null || true
  if [[ -n "${ORIG_MAXMEMORY}" ]]; then
    redis_cmd "${NODE}" CONFIG SET maxmemory "${ORIG_MAXMEMORY}" >/dev/null || true
    log "restored maxmemory=${ORIG_MAXMEMORY} on ${NODE}"
  fi
}

recover_maxclients() {
  [[ -n "${FILL_PID:-}" ]] && kill "${FILL_PID}" 2>/dev/null || true
  if [[ -n "${ORIG_MAXCLIENTS}" ]]; then
    redis_cmd "${NODE}" CONFIG SET maxclients "${ORIG_MAXCLIENTS}" >/dev/null || true
    log "restored maxclients=${ORIG_MAXCLIENTS} on ${NODE}"
  fi
}

recover_slow_command() {
  :
}

recover_hot_key() {
  [[ -n "${FILL_PID:-}" ]] && kill "${FILL_PID}" 2>/dev/null || true
}

recover_big_key() {
  if [[ "${CLEANUP_BIGKEY}" == "yes" && -n "${BIGKEY_NAME}" ]]; then
    redis_cmd "${NODE}" DEL "${BIGKEY_NAME}" >/dev/null || true
    log "removed big key ${BIGKEY_NAME}"
  fi
}

recover_cache_penetrate() {
  [[ -n "${FILL_PID:-}" ]] && kill "${FILL_PID}" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --maxmemory) MAXMEMORY="$2"; shift 2 ;;
    --maxclients) MAXCLIENTS="$2"; shift 2 ;;
    --error-type) ERROR_TYPE="$2"; shift 2 ;;
    --expire-key) EXPIRE_KEY="$2"; shift 2 ;;
    --request-count) REQUEST_COUNT="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    --no-cleanup-bigkey) CLEANUP_BIGKEY="no"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
resolve_node
host="${NODE%%:*}"
port="${NODE##*:}"

acquire_inject_lock

case "${ACTION}" in
  process-stop)
    parse_duration
    STOPPED_NODE="${NODE}"
    bind_target_from_node "${NODE}"
    resolve_data_dir "${NODE}" || true
    RCLI="$(remote_redis_cli "127.0.0.1" "${port}")"
    log "stop redis on ${NODE} for ${DURATION}s via ${INJECT_BACKEND} $(target_label)"
    run_on_target "${RCLI} SHUTDOWN NOSAVE 2>/dev/null || systemctl stop ${REDIS_SERVICE} 2>/dev/null || pkill -f 'redis-server' || true"
    sleep 2
    post_check_ping_down "${NODE}" || { emit_inject_result "process-stop" "fail" "still pingable"; exit 1; }
    emit_inject_result "process-stop" "pass" "redis down on ${NODE}"
    run_timed_fault "${DURATION}" recover_process_stop
    ;;
  maxmemory)
    parse_duration
    ORIG_MAXMEMORY="$(redis_cmd "${NODE}" CONFIG GET maxmemory | awk 'NR==2{print}')"
    redis_cmd "${NODE}" CONFIG SET maxmemory "${MAXMEMORY}" >/dev/null
    current="$(redis_cmd "${NODE}" CONFIG GET maxmemory | awk 'NR==2{print}')"
    [[ "${current}" == "${MAXMEMORY}" ]] || die "maxmemory not applied on ${NODE}"
    log "maxmemory=${MAXMEMORY} on ${NODE}, original=${ORIG_MAXMEMORY}"
    (
      end=$((SECONDS + DURATION))
      i=0
      while (( SECONDS < end )); do
        redis_cmd "${NODE}" SET "fault:fill:${i}" "$(head -c 4096 /dev/zero | tr '\0' 'x')" >/dev/null 2>&1 || break
        i=$((i + 1))
        sleep 0.2
      done
    ) &
    FILL_PID=$!
    emit_inject_result "maxmemory" "pass" "maxmemory=${MAXMEMORY} on ${NODE}"
    run_timed_fault "${DURATION}" recover_maxmemory
    ;;
  maxclients)
    parse_duration
    ORIG_MAXCLIENTS="$(redis_cmd "${NODE}" CONFIG GET maxclients | awk 'NR==2{print}')"
    redis_cmd "${NODE}" CONFIG SET maxclients "${MAXCLIENTS}" >/dev/null
    current="$(redis_cmd "${NODE}" CONFIG GET maxclients | awk 'NR==2{print}')"
    [[ "${current}" == "${MAXCLIENTS}" ]] || die "maxclients not applied on ${NODE}"
    (
      end=$((SECONDS + DURATION))
      while (( SECONDS < end )); do
        for _ in $(seq 1 20); do
          redis_cmd "${NODE}" PING >/dev/null 2>&1 &
        done
        sleep 1
      done
      wait 2>/dev/null || true
    ) &
    FILL_PID=$!
    emit_inject_result "maxclients" "pass" "maxclients=${MAXCLIENTS} on ${NODE}"
    run_timed_fault "${DURATION}" recover_maxclients
    ;;
  slow-command)
    parse_duration
    redis_cmd "${NODE}" DEBUG SLEEP 1 >/dev/null 2>&1 || die "DEBUG SLEEP not available on ${NODE}"
    (
      end=$((SECONDS + DURATION))
      while (( SECONDS < end )); do
        redis_cmd "${NODE}" DEBUG SLEEP "${SLEEP_MS}" >/dev/null 2>&1 || true
        sleep "${INTERVAL}"
      done
    ) &
    FILL_PID=$!
    emit_inject_result "slow-command" "pass" "debug sleep on ${NODE}"
    run_timed_fault "${DURATION}" recover_slow_command
    ;;
  hot-key)
    parse_duration
    (
      end=$((SECONDS + DURATION))
      i=0
      while (( SECONDS < end )); do
        redis_cmd "${NODE}" SET "${KEY}:${i}" hot >/dev/null 2>&1
        redis_cmd "${NODE}" GET "${KEY}:${i}" >/dev/null 2>&1
        i=$((i + 1))
      done
    ) &
    FILL_PID=$!
    emit_inject_result "hot-key" "pass" "hot key traffic on ${NODE}"
    run_timed_fault "${DURATION}" recover_hot_key
    ;;
  big-key)
    parse_duration
    BIGKEY_NAME="${KEY}"
    redis_cmd "${NODE}" DEL "${BIGKEY_NAME}" >/dev/null 2>&1 || true
    for i in $(seq 1 "${FIELD_COUNT}"); do
      redis_cmd "${NODE}" HSET "${BIGKEY_NAME}" "field_${i}" "$(head -c "${VALUE_SIZE}" /dev/zero | tr '\0' 'b')" >/dev/null
    done
    emit_inject_result "big-key" "pass" "seeded ${BIGKEY_NAME} on ${NODE}"
    run_timed_fault "${DURATION}" recover_big_key
    ;;
  cache-expire)
    parse_duration
    if [[ -n "${EXPIRE_KEY}" ]]; then
      if [[ "${EXPIRE_AFTER}" == "0" ]]; then
        redis_cmd "${NODE}" DEL "${EXPIRE_KEY}" >/dev/null || true
      else
        redis_cmd "${NODE}" EXPIRE "${EXPIRE_KEY}" "${EXPIRE_AFTER}" >/dev/null
      fi
      log "expired key ${EXPIRE_KEY} on ${NODE}"
    else
      redis_cmd "${NODE}" FLUSHDB >/dev/null
      log "FLUSHDB on ${NODE} (lab only)"
    fi
    sleep "${DURATION}"
    log "cache-expire window ended; keys are not auto-restored"
    ;;
  cache-penetrate)
    parse_duration
    (
      end=$((SECONDS + DURATION))
      sent=0
      while (( SECONDS < end )) && (( sent < REQUEST_COUNT )); do
        redis_cmd "${NODE}" GET "fault:missing:${RANDOM}" >/dev/null 2>&1 || true
        sent=$((sent + 1))
      done
    ) &
    FILL_PID=$!
    emit_inject_result "cache-penetrate" "pass" "started on ${NODE}"
    run_timed_fault "${DURATION}" recover_cache_penetrate
    ;;
  error-pulse)
    parse_duration
    log "error pulse ${ERROR_TYPE} on ${NODE}; bounded ${PULSE_INTERVAL}s x ${PULSE_MAX}"
    stat_key="${ERROR_TYPE}"
    [[ "${ERROR_TYPE}" == "WRONGPASS" ]] && stat_key="WRONGPASS"
    before="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep -i "${stat_key}" | awk -F: '{gsub(/\r/,"",$2); print $2}' | head -1 || echo 0)"
    before="${before:-0}"
    end_time=$((SECONDS + DURATION))
    count=0
    while (( SECONDS < end_time )) && (( count < PULSE_MAX )); do
      case "${ERROR_TYPE}" in
        NOAUTH)
          env -u REDISCLI_AUTH redis-cli --no-auth-warning -h "${host}" -p "${port}" PING >/dev/null 2>&1 || true
          ;;
        WRONGPASS)
          redis-cli --no-auth-warning -h "${host}" -p "${port}" \
            --user "${REDIS_ACL_USER:-default}" --pass wrong_password PING >/dev/null 2>&1 || true
          ;;
        MOVED)
          redis_cmd_nocluster "${NODE}" SET "fault:moved:${RANDOM}" value >/dev/null 2>&1 || true
          ;;
        CROSSSLOT)
          redis_cmd "${NODE}" MGET "{faulta}:1" "{faultb}:2" >/dev/null 2>&1 || true
          ;;
      esac
      count=$((count + 1))
      sleep "${PULSE_INTERVAL}"
    done
    after="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep -i "${stat_key}" | awk -F: '{gsub(/\r/,"",$2); print $2}' | head -1 || echo 0)"
    after="${after:-0}"
    log "pulse count=${count} ${ERROR_TYPE} errorstats before=${before} after=${after}"
    if (( after > before )); then
      emit_inject_result "error-pulse" "pass" "${ERROR_TYPE} ${before}->${after}"
    else
      emit_inject_result "error-pulse" "fail" "${ERROR_TYPE} no increment"
      exit 1
    fi
    ;;
  historical-misconf)
    bind_target_from_node "${NODE}"
    resolve_data_dir "${NODE}"
    RCLI="$(remote_redis_cli "127.0.0.1" "${port}")"
    before="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep MISCONF | awk -F: '{gsub(/\r/,"",$2); print $2}' || echo 0)"
    before="${before:-0}"
    orig_stop="$(redis_cmd "${NODE}" CONFIG GET stop-writes-on-bgsave-error | awk 'NR==2{print}')"
    orig_stop="${orig_stop:-yes}"
    save_misconf_state "${NODE}" stop_writes "${orig_stop}"
    redis_cmd "${NODE}" CONFIG SET stop-writes-on-bgsave-error yes >/dev/null 2>&1 || \
      die "cannot set stop-writes-on-bgsave-error on ${NODE}"
    run_on_target "chmod -R a-w ${REDIS_DATA_DIR}"
    run_on_target "${RCLI} SET fault:historical:misconf:$(date +%s) seed >/dev/null 2>&1 || true"
    run_on_target "chmod -R u+w ${REDIS_DATA_DIR}"
    run_on_target "${RCLI} BGSAVE >/dev/null 2>&1 || true"
    sleep 2
    after="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep MISCONF | awk -F: '{gsub(/\r/,"",$2); print $2}' || echo 0)"
    after="${after:-0}"
    log "MISCONF before=${before} after=${after}"
    if (( after > before )); then
      emit_inject_result "historical-misconf" "pass" "MISCONF ${before}->${after}"
    else
      emit_inject_result "historical-misconf" "fail" "MISCONF not incremented"
      exit 1
    fi
    log "run historical-misconf-cleanup after test"
    ;;
  historical-misconf-cleanup)
    MISCONF_CLEANUP_RESTART="${MISCONF_CLEANUP_RESTART:-YES}"
    bind_target_from_node "${NODE}"
    resolve_data_dir "${NODE}" || true
    RCLI="$(remote_redis_cli "127.0.0.1" "${port}")"
    orig_stop="$(load_misconf_state "${NODE}" stop_writes "yes")"
    redis_cmd "${NODE}" CONFIG SET stop-writes-on-bgsave-error "${orig_stop}" >/dev/null 2>&1 || true
    if [[ "${MISCONF_CLEANUP_RESTART}" == "YES" ]]; then
      run_on_target "${RCLI} SHUTDOWN NOSAVE 2>/dev/null || systemctl stop ${REDIS_SERVICE} 2>/dev/null || pkill -f redis-server || true"
      sleep 2
      run_on_target "systemctl start ${REDIS_SERVICE} 2>/dev/null || redis-server ${REDIS_CONF} 2>/dev/null || true"
      for _ in $(seq 1 30); do
        redis_cmd "${NODE}" PING >/dev/null 2>&1 && break
        sleep 1
      done
      post_check_ping_up "${NODE}" || { emit_inject_result "historical-misconf-cleanup" "fail" "redis not up"; exit 1; }
    fi
    after="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep MISCONF | awk -F: '{gsub(/\r/,"",$2); print $2}' | head -1 || echo 0)"
    clear_misconf_state "${NODE}"
    emit_inject_result "historical-misconf-cleanup" "pass" "MISCONF=${after}"
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
