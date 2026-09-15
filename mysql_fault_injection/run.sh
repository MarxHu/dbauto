#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "${ROOT_DIR}/scripts/"*.sh "${ROOT_DIR}/lib/common.sh" 2>/dev/null || true

if [[ $# -lt 1 ]] || [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $0 <category> --action <name> [options]

Categories:
  host        inject_host.sh
  mysql       inject_mysql.sh
  repl        inject_repl.sh
  network     inject_network.sh
  disk        inject_disk.sh
  composite   inject_composite.sh
  degrade     inject_degrade.sh

Examples:
  $0 host --action cpu --target-host 10.10.26.144 --duration 600
  $0 repl --action stop-sql --scope one --node 10.10.26.145:3306 --duration 600
  $0 mysql --action process-stop --node 10.10.26.145:3306 --duration 300
EOF
  exit 1
fi

category="$1"
shift
if [[ "${category}" == "preflight" ]]; then
  exec "${ROOT_DIR}/scripts/preflight.sh" "$@"
fi
script="${ROOT_DIR}/scripts/inject_${category}.sh"
[[ -f "${script}" ]] || { echo "unknown category: ${category}" >&2; exit 1; }
exec bash "${script}" "$@"
