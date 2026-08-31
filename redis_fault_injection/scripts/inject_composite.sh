#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""
DURATION=""
MEMORY_NODE="${MEMORY_NODE:-10.10.26.144:6381}"
MISCONF_NODE="${MISCONF_NODE:-10.10.26.146:6381}"
STOP_NODE="${STOP_NODE:-10.10.26.144:6381}"
MEM_NODE="${MEM_NODE:-10.10.26.146:6381}"
WRITE_NODE="${WRITE_NODE:-10.10.26.144:6381}"

usage() {
  usage_header
  cat <<EOF

Actions:
  memory-plus-misconf        Host memory pressure + historical MISCONF background
  write-reject-plus-cpu      Persistence fail + host CPU stress on same node
  master-stop-plus-memory    Stop redis on one node + memory stress on another

Extra options:
  --memory-node <ip:port>
  --misconf-node <ip:port>
  --stop-node <ip:port>
  --mem-node <ip:port>
  --write-node <ip:port>

Examples:
  $0 --action memory-plus-misconf --duration 240
  $0 --action write-reject-plus-cpu --write-node 10.10.26.144:6381 --duration 240
  $0 --action master-stop-plus-memory --stop-node 10.10.26.144:6381 --mem-node 10.10.26.146:6381 --duration 240
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --memory-node) MEMORY_NODE="$2"; shift 2 ;;
    --misconf-node) MISCONF_NODE="$2"; shift 2 ;;
    --stop-node) STOP_NODE="$2"; shift 2 ;;
    --mem-node) MEM_NODE="$2"; shift 2 ;;
    --write-node) WRITE_NODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
parse_duration

case "${ACTION}" in
  memory-plus-misconf)
    bash "${SCRIPT_DIR}/inject_redis.sh" --action historical-misconf --node "${MISCONF_NODE}"
    bash "${SCRIPT_DIR}/inject_host.sh" --action memory --target-host "${MEMORY_NODE%%:*}" --duration "${DURATION}"
    ;;
  write-reject-plus-cpu)
    bash "${SCRIPT_DIR}/inject_disk.sh" --action persistence-fail --node "${WRITE_NODE}" --duration "${DURATION}" &
    p1=$!
    bash "${SCRIPT_DIR}/inject_host.sh" --action cpu --target-host "${WRITE_NODE%%:*}" --duration "${DURATION}" &
    p2=$!
    wait "${p1}" "${p2}"
    log "composite write-reject-plus-cpu finished"
    ;;
  master-stop-plus-memory)
    bash "${SCRIPT_DIR}/inject_redis.sh" --action process-stop --node "${STOP_NODE}" --duration "${DURATION}" &
    p1=$!
    bash "${SCRIPT_DIR}/inject_host.sh" --action memory --target-host "${MEM_NODE%%:*}" --duration "${DURATION}" &
    p2=$!
    wait "${p1}" "${p2}"
    log "composite master-stop-plus-memory finished"
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
