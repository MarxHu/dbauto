#!/usr/bin/env bash
# Scenario C02: Write reject + host CPU high
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-10.10.26.144:6381}"

case "${ACTION}" in
  inject)
    NODE="${NODE}" REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}" "${SCRIPT_DIR}/F24_disk_persistence_fail.sh" inject
    TARGET_HOST="${NODE%%:*}" "${SCRIPT_DIR}/F02_host_cpu_stress.sh" inject
    log "run diagnosis; expect write reject S2 primary, CPU S3 secondary"
    ;;
  recover)
    TARGET_HOST="${NODE%%:*}" "${SCRIPT_DIR}/F02_host_cpu_stress.sh" recover
    NODE="${NODE}" "${SCRIPT_DIR}/F24_disk_persistence_fail.sh" recover
    ;;
  *)
    echo "Usage: NODE=ip:port $0 [inject|recover]"; exit 1;;
esac
