#!/usr/bin/env bash
# Scenario F16: Big key seeding for large-key clues
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
KEY="${KEY:-fault:bighash}"
FIELD_COUNT="${FIELD_COUNT:-20000}"
VALUE_SIZE="${VALUE_SIZE:-256}"

case "${ACTION}" in
  inject)
    log "seed big hash ${KEY} on ${NODE}, fields=${FIELD_COUNT}, value_size=${VALUE_SIZE}"
    run_on_target "
      redis-cli -h ${NODE%%:*} -p ${NODE##*:} DEL ${KEY} >/dev/null 2>&1 || true
      for i in \$(seq 1 ${FIELD_COUNT}); do
        redis-cli -h ${NODE%%:*} -p ${NODE##*:} HSET ${KEY} field_\$i \$(head -c ${VALUE_SIZE} /dev/zero | tr '\0' 'b') >/dev/null
      done
    "
    save_state big_key "${KEY}@${NODE}"
    log "expected: memory pressure / slow command / big key clues (L2)"
    ;;
  recover)
    target="$(load_state big_key "")"
    [[ -n "${target}" ]] || die "no big key state"
    key="${target%%@*}"; node="${target##*@}"
    redis_cmd "${node}" DEL "${key}" >/dev/null || true
    log "deleted ${key} on ${node}"
    ;;
  *)
    echo "Usage: NODE=ip:port $0 [inject|recover]"; exit 1;;
esac
