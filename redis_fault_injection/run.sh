#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "${ROOT_DIR}/scripts/"*.sh "${ROOT_DIR}/lib/common.sh" 2>/dev/null || true

if [[ $# -lt 2 ]]; then
  cat <<EOF
Usage: $0 <category> --action <name> [options]

Categories:
  host        inject_host.sh
  redis       inject_redis.sh
  network     inject_network.sh
  disk        inject_disk.sh
  composite   inject_composite.sh
  degrade     inject_degrade.sh

Example:
  $0 host --action cpu --target-host 10.10.26.144 --duration 240
  $0 redis --action maxmemory --node 10.10.26.144:6381 --duration 240
EOF
  exit 1
fi

category="$1"
shift
script="${ROOT_DIR}/scripts/inject_${category}.sh"
[[ -x "${script}" ]] || { echo "unknown category: ${category}" >&2; exit 1; }
exec "${script}" "$@"
