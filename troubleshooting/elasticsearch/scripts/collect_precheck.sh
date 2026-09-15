#!/usr/bin/env bash
# 采集预检：curl/进程/9200/工具。不阻断后续并行采集。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
ES_HTTP_PORT=${4:-9200}
ES_TRANSPORT_PORT=${5:-9300}
run_id=${6:-manual}
ES_USER=${7:-${ES_USER:-}}
ES_PASS=${8:-${ES_PASS:-}}
export ES_HTTP_PORT ES_USER ES_PASS

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact precheck "$target_ip" "$run_id"
emit "collector=precheck"
emit "http_port=${ES_HTTP_PORT} transport_port=${ES_TRANSPORT_PORT}"

for c in bash curl python3; do
  if command -v "$c" >/dev/null 2>&1; then
    emit "HAS ${c}"
  else
    emit "MISS ${c}"
    signal ES171 high "missing ${c}"
  fi
done
for c in timeout iostat ss nc; do
  if command -v "$c" >/dev/null 2>&1; then
    emit "HAS ${c}"
  else
    emit "MISS_OPTIONAL ${c}"
    signal ES171 low "optional missing ${c}"
  fi
done

if es_process_up; then
  emit "PROCESS_UP"
  facts_merge '{"process_up": true}'
else
  emit "PROCESS_DOWN"
  signal ES030 high "elasticsearch process down"
  facts_merge '{"process_up": false}'
fi

if listen_port "$ES_HTTP_PORT"; then
  emit "LISTEN ${ES_HTTP_PORT}"
  facts_merge '{"listen_http": true}'
else
  emit "NOLISTEN ${ES_HTTP_PORT}"
  signal ES031 high "http port ${ES_HTTP_PORT} not listening"
  facts_merge '{"listen_http": false}'
fi

if listen_port "$ES_TRANSPORT_PORT"; then
  emit "LISTEN ${ES_TRANSPORT_PORT}"
  facts_merge '{"listen_transport": true}'
else
  emit "NOLISTEN ${ES_TRANSPORT_PORT}"
  facts_merge '{"listen_transport": false}'
fi

record_local_master

finish_artifact
exit 0
