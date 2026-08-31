#!/usr/bin/env bash
# Scenario F09: Host reboot (dangerous; requires CONFIRM=YES)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
CONFIRM="${CONFIRM:-}"

case "${ACTION}" in
  inject)
    [[ "${CONFIRM}" == "YES" ]] || die "set CONFIRM=YES to reboot host ${TARGET_HOST:-localhost}"
    log "rebooting target in 5 seconds"
    run_on_target "sleep 5 && reboot"
    ;;
  recover)
    log "wait for host to come back, then run diagnosis pipeline"
    ;;
  *)
    echo "Usage: CONFIRM=YES TARGET_HOST=10.10.26.144 $0 inject"; exit 1;;
esac
