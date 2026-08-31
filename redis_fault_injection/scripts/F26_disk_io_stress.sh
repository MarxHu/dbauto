#!/usr/bin/env bash
# Scenario F26/F27: Disk IO pressure without iostat dependency / recover
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
parse_duration
IO_DIR="${IO_DIR:-/tmp/redis_fault_io}"

case "${ACTION}" in
  inject)
    log "disk IO stress for ${DURATION}s in ${IO_DIR}"
    run_on_target "
      mkdir -p ${IO_DIR}
      end=\$((SECONDS+${DURATION}))
      while (( SECONDS < end )); do
        dd if=/dev/zero of=${IO_DIR}/fault.bin bs=1M count=256 conv=fdatasync >/dev/null 2>&1 || true
      done
    " &
    echo $! > "$(background_pid_file disk_io)"
    log "expected: high iowait / disk util via /proc or vmstat (L2 acceptable)"
    ;;
  recover)
    stop_background disk_io
    run_on_target "rm -rf ${IO_DIR}"
    ;;
  *)
    echo "Usage: $0 [inject|recover]"; exit 1;;
esac
