#!/usr/bin/env bash
# Scenario F19: Bounded client error pulse (NOAUTH/WRONGPASS/MOVED/CROSSSLOT)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
ERROR_TYPE="${ERROR_TYPE:-NOAUTH}"
PULSE_INTERVAL="${PULSE_INTERVAL:-5}"
PULSE_MAX="${PULSE_MAX:-18}"
parse_duration

host="${NODE%%:*}"
port="${NODE##*:}"

build_pulse_cmd() {
  case "${ERROR_TYPE}" in
    NOAUTH)
      echo "redis-cli -h ${host} -p ${port} -a wrong_password PING >/dev/null 2>&1 || true"
      ;;
    WRONGPASS)
      echo "redis-cli -h ${host} -p ${port} --user default --pass wrong PING >/dev/null 2>&1 || true"
      ;;
    MOVED)
      echo "redis-cli -h ${host} -p ${port} SET moved:key:value value >/dev/null 2>&1 || true"
      ;;
    CROSSSLOT)
      echo "redis-cli -h ${host} -p ${port} MGET '{a}:1' '{b}:2' >/dev/null 2>&1 || true"
      ;;
    *)
      die "unsupported ERROR_TYPE=${ERROR_TYPE}"
      ;;
  esac
}

case "${ACTION}" in
  inject)
    pulse_cmd="$(build_pulse_cmd)"
    log "error pulse ${ERROR_TYPE} on ${NODE}, interval=${PULSE_INTERVAL}s, max=${PULSE_MAX}"
    run_on_target "
      count=0
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )) && (( count < ${PULSE_MAX} )); do
        ${pulse_cmd}
        count=\$((count+1))
        sleep ${PULSE_INTERVAL}
      done
    "
    log "expected: counter_delta_30s > 0 when pulse overlaps diagnosis sampling"
    ;;
  recover)
    log "pulse finished; no persistent state to clean"
    ;;
  *)
    echo "Usage: NODE=ip:port ERROR_TYPE=NOAUTH|WRONGPASS|MOVED|CROSSSLOT $0 inject"; exit 1;;
esac
