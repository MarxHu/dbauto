#!/usr/bin/env bash
# K1 集群监控指标：Broker API、Topic/URP/Offline、KRaft quorum、消费组、log.dirs、产消探针
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
topic_hint=${8:-deploy-verify}

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact metrics "$target_ip" "$run_id"

emit "collector=metrics"
emit "kafka_port=${kafka_port} controller_port=${controller_port}"
emit "install_prefix=${KAFKA_INSTALL_PREFIX}"

bootstrap="${node1}:${kafka_port},${node2}:${kafka_port},${node3}:${kafka_port}"
local_bs="${target_ip}:${kafka_port}"
emit "bootstrap=${bootstrap}"
emit "local_bootstrap=${local_bs}"

api_bin=$(kafka_bin kafka-broker-api-versions.sh || true)
topics_bin=$(kafka_bin kafka-topics.sh || true)
groups_bin=$(kafka_bin kafka-consumer-groups.sh || true)
logdirs_bin=$(kafka_bin kafka-log-dirs.sh || true)
quorum_bin=$(kafka_bin kafka-metadata-quorum.sh || true)
producer_bin=$(kafka_bin kafka-console-producer.sh || true)
consumer_bin=$(kafka_bin kafka-console-consumer.sh || true)
configs_bin=$(kafka_bin kafka-configs.sh || true)

if [[ -z "$api_bin" ]]; then
  signal KF024 high "kafka-broker-api-versions.sh missing"
  emit "ERROR missing Kafka CLI under ${KAFKA_INSTALL_PREFIX}"
  finish_artifact
  exit 0
fi

local_api_ok=0
if emit_cmd_timeout 15 "broker-api-versions local" "$api_bin" --bootstrap-server "$local_bs"; then
  local_api_ok=1
else
  signal KF015 high "local broker API unreachable ${local_bs}"
  signal KF038 medium "Leader/API may be unavailable on ${target_ip}"
fi

cluster_api_ok=0
if emit_cmd_timeout 20 "broker-api-versions cluster" "$api_bin" --bootstrap-server "$bootstrap"; then
  cluster_api_ok=1
else
  signal KF026 high "cluster bootstrap API failed"
fi

if [[ -n "$quorum_bin" ]]; then
  if emit_cmd_timeout 20 "metadata-quorum status" "$quorum_bin" --bootstrap-server "$bootstrap" describe --status; then
    :
  else
    signal KF025 high "metadata quorum status failed"
  fi
  emit_cmd_timeout 20 "metadata-quorum replication" "$quorum_bin" --bootstrap-server "$bootstrap" describe --replication || \
    signal KF025 medium "metadata quorum replication failed"

  if grep -Eqi 'CurrentVoters|Observer|Lag|LeaderId' "$ARTIFACT_FILE"; then
    if grep -Eqi 'Lag:[1-9]|Unknown|ERROR' "$ARTIFACT_FILE"; then
      signal KF025 medium "quorum lag or voter anomaly in status output"
    fi
  fi
else
  signal KF119 low "kafka-metadata-quorum.sh missing"
fi

if [[ -n "$topics_bin" ]]; then
  emit_cmd_timeout 30 "topics list" "$topics_bin" --bootstrap-server "$bootstrap" --list || \
    signal KF015 high "topics --list failed"

  emit_cmd_timeout 45 "topics describe all" "$topics_bin" --bootstrap-server "$bootstrap" --describe || \
    signal KF036 medium "topics --describe failed"

  urp_out=$(mktemp)
  if timeout 30 "$topics_bin" --bootstrap-server "$bootstrap" --describe --under-replicated-partitions >"$urp_out" 2>&1; then
    emit "----- under-replicated-partitions -----"
    cat "$urp_out" >> "$ARTIFACT_FILE"
    if grep -q "Topic:" "$urp_out"; then
      signal KF036 high "under-replicated partitions present"
      signal KF039 medium "ISR shrink likely"
    else
      emit "URP_NONE"
    fi
  else
    emit "URP_QUERY_FAIL"
    cat "$urp_out" >> "$ARTIFACT_FILE" || true
  fi
  rm -f "$urp_out"

  off_out=$(mktemp)
  if timeout 30 "$topics_bin" --bootstrap-server "$bootstrap" --describe --unavailable-partitions >"$off_out" 2>&1; then
    emit "----- unavailable-partitions -----"
    cat "$off_out" >> "$ARTIFACT_FILE"
    if grep -q "Topic:" "$off_out"; then
      signal KF037 high "unavailable/offline partitions present"
      signal KF046 high "partitions without leader"
    else
      emit "OFFLINE_NONE"
    fi
  else
    emit "OFFLINE_QUERY_FAIL"
    cat "$off_out" >> "$ARTIFACT_FILE" || true
  fi
  rm -f "$off_out"

  if [[ -n "$topic_hint" ]]; then
    emit_cmd_timeout 20 "topic describe ${topic_hint}" "$topics_bin" --bootstrap-server "$bootstrap" --describe --topic "$topic_hint" || \
      signal KF050 medium "hint topic ${topic_hint} describe failed"
  fi
else
  signal KF118 medium "kafka-topics.sh missing"
fi

if [[ -n "$groups_bin" ]]; then
  if emit_cmd_timeout 40 "consumer-groups list" "$groups_bin" --bootstrap-server "$bootstrap" --list; then
    groups=$(timeout 20 "$groups_bin" --bootstrap-server "$bootstrap" --list 2>/dev/null | head -50 || true)
    if [[ -n "$groups" ]]; then
      while IFS= read -r g; do
        [[ -z "$g" ]] && continue
        emit_cmd_timeout 25 "consumer-group ${g}" "$groups_bin" --bootstrap-server "$bootstrap" --describe --group "$g" || true
      done <<<"$groups"
      if grep -Eqi 'LAG|STATE' "$ARTIFACT_FILE"; then
        if grep -Eqi 'Empty|Dead|PreparingRebalance|CompletingRebalance' "$ARTIFACT_FILE"; then
          signal KF061 medium "consumer group rebalance or empty/dead state"
        fi
        if awk 'tolower($0) ~ /lag/ && $NF ~ /^[0-9]+$/ && $NF+0 > 1000 {found=1} END{exit !found}' "$ARTIFACT_FILE" 2>/dev/null; then
          signal KF062 medium "consumer lag observed"
        fi
      fi
    else
      emit "CONSUMER_GROUPS_NONE"
    fi
  else
    signal KF064 medium "consumer group coordinator query failed"
  fi
fi

if [[ -n "$logdirs_bin" ]]; then
  brokers="${node1}:${kafka_port} ${node2}:${kafka_port} ${node3}:${kafka_port}"
  emit_cmd_timeout 40 "log-dirs describe" "$logdirs_bin" --bootstrap-server "$bootstrap" --describe --broker-list "$brokers" || \
    signal KF083 medium "log-dirs describe failed"
fi

if [[ -n "$configs_bin" ]]; then
  for bid in 1 2 3; do
    emit_cmd_timeout 20 "broker ${bid} configs" "$configs_bin" --bootstrap-server "$bootstrap" \
      --entity-type brokers --entity-name "$bid" --describe --all || true
  done
fi

# Produce/consume probe (best-effort, ignore failure)
probe_topic="ts-probe-${run_id}"
if [[ -n "$topics_bin" && -n "$producer_bin" && "$cluster_api_ok" -eq 1 ]]; then
  timeout 20 "$topics_bin" --bootstrap-server "$bootstrap" --create --topic "$probe_topic" \
    --partitions 1 --replication-factor 3 --if-not-exists >/dev/null 2>&1 || true
  msg="probe-$(date +%s)"
  if printf '%s\n' "$msg" | timeout 15 "$producer_bin" --bootstrap-server "$bootstrap" --topic "$probe_topic" \
      --request-timeout-ms 10000 >/dev/null 2>&1; then
    emit "PRODUCE_PROBE_OK topic=${probe_topic}"
  else
    emit "PRODUCE_PROBE_FAIL topic=${probe_topic}"
    signal KF052 high "produce probe failed"
    signal KF053 medium "possible NotEnoughReplicas / ISR issue"
  fi
  if [[ -n "$consumer_bin" ]]; then
    got=$(timeout 20 "$consumer_bin" --bootstrap-server "$bootstrap" --topic "$probe_topic" \
      --from-beginning --max-messages 1 --timeout-ms 12000 2>/dev/null | tail -n1 || true)
    if [[ -n "$got" ]]; then
      emit "CONSUME_PROBE_OK got=${got}"
    else
      emit "CONSUME_PROBE_FAIL"
      signal KF038 medium "consume probe got no message"
    fi
  fi
fi

if [[ "$local_api_ok" -eq 0 && "$cluster_api_ok" -eq 0 ]]; then
  signal KF026 high "both local and cluster API down"
fi

finish_artifact
exit 0
