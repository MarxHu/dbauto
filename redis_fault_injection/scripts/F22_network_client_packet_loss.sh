#!/usr/bin/env bash
# Scenario F22/F23: Client->Redis packet loss / restore (tc netem)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE="${NODE:-$(first_node)}"
CLIENT_CIDR="${CLIENT_CIDR:-0.0.0.0/0}"
LOSS="${LOSS:-30}"
host="${NODE%%:*}"
port="${NODE##*:}"
dev="${NET_DEV:-eth0}"

case "${ACTION}" in
  inject)
    require_cmd tc
    log "inject ${LOSS}% loss toward redis ${NODE} dev=${dev}"
    run_on_target "
      tc qdisc add dev ${dev} root handle 1: htb 2>/dev/null || true
      tc qdisc add dev ${dev} parent 1:1 handle 10: netem loss ${LOSS}%
    "
    save_state client_loss_dev "${dev}"
    log "expected: timeout/latency/client errors (L2 acceptable)"
    ;;
  recover)
    dev="$(load_state client_loss_dev "${dev}")"
    run_on_target "tc qdisc del dev ${dev} root 2>/dev/null || true"
    log "removed netem on ${dev}"
    ;;
  *)
    echo "Usage: NODE=ip:port LOSS=30 NET_DEV=eth0 $0 [inject|recover]"; exit 1;;
esac
