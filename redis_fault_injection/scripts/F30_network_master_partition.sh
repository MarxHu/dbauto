#!/usr/bin/env bash
# Scenario F30: Network partition between two cluster masters
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION="${1:-inject}"
NODE_A="${NODE_A:-10.10.26.144}"
NODE_B="${NODE_B:-10.10.26.145}"
DEV="${NET_DEV:-eth0}"

case "${ACTION}" in
  inject)
    log "partition ${NODE_A} <-> ${NODE_B} on both hosts"
    for host in "${NODE_A}" "${NODE_B}"; do
      peer="$([[ "${host}" == "${NODE_A}" ]] && echo "${NODE_B}" || echo "${NODE_A}")"
      TARGET_HOST="${host}" run_on_target "
        iptables -A INPUT -s ${peer} -j DROP
        iptables -A OUTPUT -d ${peer} -j DROP
      "
    done
    save_state partition_pair "${NODE_A}|${NODE_B}"
    log "expected: cluster gossip failure / PFAIL / partial slot impact"
    ;;
  recover)
    pair="$(load_state partition_pair "${NODE_A}|${NODE_B}")"
    NODE_A="${pair%%|*}"; NODE_B="${pair##*|}"
    for host in "${NODE_A}" "${NODE_B}"; do
      peer="$([[ "${host}" == "${NODE_A}" ]] && echo "${NODE_B}" || echo "${NODE_A}")"
      TARGET_HOST="${host}" run_on_target "
        iptables -D INPUT -s ${peer} -j DROP 2>/dev/null || true
        iptables -D OUTPUT -d ${peer} -j DROP 2>/dev/null || true
      "
    done
    ;;
  *)
    echo "Usage: NODE_A=ip NODE_B=ip $0 [inject|recover]"; exit 1;;
esac
