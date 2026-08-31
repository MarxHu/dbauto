#!/usr/bin/env bash
# Scenario F20/F21: Block Redis Cluster bus (16379) / restore
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
host="${NODE%%:*}"
port="${NODE##*:}"
bus_port="${CLUSTER_BUS_PORT:-$((port + 10000))}"

iptables_block() {
  run_on_target "
    iptables -C INPUT -p tcp --dport ${bus_port} -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --dport ${bus_port} -j DROP
    iptables -C OUTPUT -p tcp --dport ${bus_port} -j DROP 2>/dev/null || \
    iptables -A OUTPUT -p tcp --dport ${bus_port} -j DROP
  "
}

iptables_unblock() {
  run_on_target "
    iptables -D INPUT -p tcp --dport ${bus_port} -j DROP 2>/dev/null || true
    iptables -D OUTPUT -p tcp --dport ${bus_port} -j DROP 2>/dev/null || true
  "
}

case "${ACTION}" in
  inject)
    log "block cluster bus tcp/${bus_port} on host ${host}"
    iptables_block
    save_state bus_block_port "${bus_port}"
    log "expected: PFAIL/FAIL/cluster view inconsistency on ${NODE}"
    ;;
  recover)
    bus_port="$(load_state bus_block_port "${bus_port}")"
    log "unblock cluster bus tcp/${bus_port}"
    iptables_unblock
    ;;
  *)
    echo "Usage: NODE=ip:port $0 [inject|recover]"; exit 1;;
esac
