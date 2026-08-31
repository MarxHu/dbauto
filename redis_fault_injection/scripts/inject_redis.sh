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
  $0 --action process-stop --node 10.10.26.144:6381 --duration 240
  $0 --action maxmemory --node 10.10.26.144:6381 --duration 240 --maxmemory 64mb
  $0 --action error-pulse --node 10.10.26.146:6381 --duration 90 --error-type NOAUTH
EOF
}

recover_process_stop() {
  resolve_node
  local node="${STOPPED_NODE:-${NODE}}"
  TARGET_HOST="${TARGET_HOST:-${node%%:*}}"
  log "auto-start redis on ${node}"
  run_on_target "
    systemctl start redis 2>/dev/null || \
    redis-server /etc/redis/redis.conf 2>/dev/null || true
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
    TARGET_HOST="${TARGET_HOST:-${host}}"
    log "stop redis on ${NODE} for ${DURATION}s"
    run_on_target "
      redis-cli -h ${host} -p ${port} SHUTDOWN NOSAVE 2>/dev/null || \
      systemctl stop redis 2>/dev/null || \
      pkill -f 'redis-server.*:${port}' || true
    "
    run_timed_fault "${DURATION}" recover_process_stop
    ;;
  maxmemory)
    parse_duration
    ORIG_MAXMEMORY="$(redis_cmd "${NODE}" CONFIG GET maxmemory | awk 'NR==2{print}')"
    redis_cmd "${NODE}" CONFIG SET maxmemory "${MAXMEMORY}" >/dev/null
    log "maxmemory=${MAXMEMORY} on ${NODE}, original=${ORIG_MAXMEMORY}"
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      i=0
      while (( SECONDS < end )); do
        redis-cli -h ${host} -p ${port} SET fault:fill:\$i \$(head -c 4096 /dev/zero | tr '\0' 'x') >/dev/null 2>&1 || break
        i=\$((i+1))
        sleep 0.2
      done
    " &
    FILL_PID=$!
    run_timed_fault "${DURATION}" recover_maxmemory
    ;;
  maxclients)
    parse_duration
    ORIG_MAXCLIENTS="$(redis_cmd "${NODE}" CONFIG GET maxclients | awk 'NR==2{print}')"
    redis_cmd "${NODE}" CONFIG SET maxclients "${MAXCLIENTS}" >/dev/null
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )); do
        for _ in \$(seq 1 20); do
          redis-cli -h ${host} -p ${port} PING >/dev/null 2>&1 &
        done
        sleep 1
      done
      pkill -f 'redis-cli -h ${host} -p ${port} PING' 2>/dev/null || true
    " &
    FILL_PID=$!
    run_timed_fault "${DURATION}" recover_maxclients
    ;;
  slow-command)
    parse_duration
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )); do
        redis-cli -h ${host} -p ${port} DEBUG SLEEP ${SLEEP_MS} >/dev/null 2>&1 || true
        sleep ${INTERVAL}
      done
    " &
    FILL_PID=$!
    run_timed_fault "${DURATION}" recover_slow_command
    ;;
  hot-key)
    parse_duration
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      for t in \$(seq 1 ${THREADS}); do
        (
          i=0
          while (( SECONDS < end )); do
            redis-cli -h ${host} -p ${port} SET ${KEY}:\$i hot >/dev/null 2>&1
            redis-cli -h ${host} -p ${port} GET ${KEY}:\$i >/dev/null 2>&1
            i=\$((i+1))
          done
        ) &
      done
      wait
    " &
    FILL_PID=$!
    run_timed_fault "${DURATION}" recover_hot_key
    ;;
  big-key)
    parse_duration
    BIGKEY_NAME="${KEY}"
    run_on_target "
      redis-cli -h ${host} -p ${port} DEL ${BIGKEY_NAME} >/dev/null 2>&1 || true
      for i in \$(seq 1 ${FIELD_COUNT}); do
        redis-cli -h ${host} -p ${port} HSET ${BIGKEY_NAME} field_\$i \$(head -c ${VALUE_SIZE} /dev/zero | tr '\0' 'b') >/dev/null
      done
    "
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
    run_on_target "
      end=\$((SECONDS+${DURATION}))
      sent=0
      while (( SECONDS < end )) && (( sent < ${REQUEST_COUNT} )); do
        redis-cli -h ${host} -p ${port} GET fault:missing:\$RANDOM >/dev/null 2>&1 || true
        sent=\$((sent+1))
      done
    " &
    FILL_PID=$!
    run_timed_fault "${DURATION}" recover_cache_penetrate
    ;;
  error-pulse)
    parse_duration
    log "error pulse ${ERROR_TYPE} on ${NODE}; bounded ${PULSE_INTERVAL}s x ${PULSE_MAX}"
    baseline="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep -E 'NOAUTH|WRONGPASS|MISCONF|MOVED|CROSSSLOT' || true)"
    [[ -n "${baseline}" ]] && log "baseline errorstats: ${baseline}"
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
    after="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep -E 'NOAUTH|WRONGPASS|MISCONF|MOVED|CROSSSLOT' || true)"
    log "sent ${count} ${ERROR_TYPE} pulses"
    [[ -n "${after}" ]] && log "after errorstats: ${after}"
    ;;
  historical-misconf)
    log "seed historical MISCONF on ${NODE}"
    before="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep MISCONF || echo 'MISCONF:0')"
    log "before: ${before}"
    orig_stop="$(redis_cmd "${NODE}" CONFIG GET stop-writes-on-bgsave-error | awk 'NR==2{print}')"
    orig_stop="${orig_stop:-yes}"
    save_misconf_state "${NODE}" stop_writes "${orig_stop}"
    redis_cmd "${NODE}" CONFIG SET stop-writes-on-bgsave-error yes >/dev/null 2>&1 || \
      die "cannot set stop-writes-on-bgsave-error on ${NODE}"
    run_on_target "chmod -R a-w ${REDIS_DATA_DIR}"
    redis_cmd "${NODE}" SET "fault:historical:misconf:$(date +%s)" seed >/dev/null 2>&1 || true
    run_on_target "chmod -R u+w ${REDIS_DATA_DIR}"
    redis_cmd "${NODE}" BGSAVE >/dev/null 2>&1 || true
    after="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep MISCONF || echo '')"
    persist="$(redis_cmd "${NODE}" INFO PERSISTENCE 2>/dev/null | grep -E 'rdb_last_bgsave_status|aof_last_write_status' || true)"
    log "after: ${after}"
    log "persistence: ${persist}"
    log "run historical-misconf-cleanup after test to avoid polluting later scenarios"
    ;;
  historical-misconf-cleanup)
    MISCONF_CLEANUP_RESTART="${MISCONF_CLEANUP_RESTART:-YES}"
    orig_stop="$(load_misconf_state "${NODE}" stop_writes "yes")"
    log "restore stop-writes-on-bgsave-error=${orig_stop} on ${NODE}"
    redis_cmd "${NODE}" CONFIG SET stop-writes-on-bgsave-error "${orig_stop}" >/dev/null 2>&1 || true
    if [[ "${MISCONF_CLEANUP_RESTART}" == "YES" ]]; then
      log "restarting redis on ${NODE} to reset ERRORSTATS counters"
      TARGET_HOST="${TARGET_HOST:-${host}}"
      run_on_target "
        redis-cli -h ${host} -p ${port} SHUTDOWN NOSAVE 2>/dev/null || \
        systemctl stop ${REDIS_SERVICE:-redis} 2>/dev/null || true
        sleep 2
        systemctl start ${REDIS_SERVICE:-redis} 2>/dev/null || \
        redis-server ${REDIS_CONF:-/etc/redis/redis.conf} 2>/dev/null || true
      "
      for _ in $(seq 1 30); do
        if redis_cmd "${NODE}" PING >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      redis_cmd "${NODE}" PING >/dev/null || die "redis did not come back on ${NODE}"
    fi
    after="$(redis_cmd "${NODE}" INFO ERRORSTATS 2>/dev/null | grep MISCONF || echo 'MISCONF:0')"
    log "after cleanup: ${after}"
    clear_misconf_state "${NODE}"
    log "historical MISCONF background cleared"
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
