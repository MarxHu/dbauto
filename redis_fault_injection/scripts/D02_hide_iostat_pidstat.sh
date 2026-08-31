#!/usr/bin/env bash
# Scenario D02: Simulate missing iostat/pidstat by hiding binaries temporarily
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
HIDE_DIR="${HIDE_DIR:-/tmp/redis_fault_hidden_bins}"

case "${ACTION}" in
  inject)
    log "hide iostat/pidstat from PATH on target"
    run_on_target "
      mkdir -p ${HIDE_DIR}
      for cmd in iostat pidstat; do
        path=\$(command -v \$cmd 2>/dev/null || true)
        if [[ -n \"\$path\" ]]; then
          mv \"\$path\" ${HIDE_DIR}/\$(basename \$path).bak
        fi
      done
    "
    save_state hide_dir "${HIDE_DIR}"
    log "run diagnosis; expect /proc fallback or collection_issues, not fake host failure"
    ;;
  recover)
    HIDE_DIR="$(load_state hide_dir "${HIDE_DIR}")"
    run_on_target "
      for bak in ${HIDE_DIR}/*.bak; do
        [[ -f \"\$bak\" ]] || continue
        orig=\$(basename \"\$bak\" .bak)
        mv \"\$bak\" /usr/bin/\$orig 2>/dev/null || mv \"\$bak\" /usr/local/bin/\$orig 2>/dev/null || true
      done
    "
    ;;
  *)
    echo "Usage: $0 [inject|recover]"; exit 1;;
esac
