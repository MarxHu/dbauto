#!/usr/bin/env bash
# 采集预检（v2）：工具与路径是否具备，不阻断后续并行采集
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
KAFKA_INSTALL_PREFIX=${4:-/opt/kafka/3.8.1}
kafka_port=${5:-9092}
controller_port=${6:-9093}
run_id=${7:-manual}

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact precheck "$target_ip" "$run_id"
emit "collector=precheck"

for c in bash ss pgrep hostname; do
  if command -v "$c" >/dev/null 2>&1; then
    emit "HAS ${c}"
  else
    emit "MISS ${c}"
    signal KF118 medium "missing ${c}"
  fi
done
for c in iostat jstat timeout vmstat tc iptables; do
  if command -v "$c" >/dev/null 2>&1; then
    emit "HAS ${c}"
  else
    emit "MISS_OPTIONAL ${c}"
    signal KF118 low "optional missing ${c}"
  fi
done

api=$(kafka_bin kafka-broker-api-versions.sh || true)
if [[ -n "$api" ]]; then
  emit "HAS ${api}"
else
  emit "MISS kafka CLI"
  signal KF118 high "Kafka CLI missing under ${KAFKA_INSTALL_PREFIX}"
fi

[[ -f /etc/kafka/server.properties ]] && emit "HAS server.properties" || emit "MISS server.properties"
[[ -d /var/log/kafka ]] && emit "HAS /var/log/kafka" || emit "MISS /var/log/kafka"
[[ -d /var/lib/kafka/data ]] && emit "HAS /var/lib/kafka/data" || emit "MISS /var/lib/kafka/data"

pgrep -f 'kafka\.Kafka' >/dev/null 2>&1 && emit "PROCESS_UP" || { emit "PROCESS_DOWN"; signal KF015 medium "precheck process down"; }

ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${kafka_port}$" && emit "LISTEN ${kafka_port}" || emit "NOLISTEN ${kafka_port}"
ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${controller_port}$" && emit "LISTEN ${controller_port}" || emit "NOLISTEN ${controller_port}"

finish_artifact
exit 0
