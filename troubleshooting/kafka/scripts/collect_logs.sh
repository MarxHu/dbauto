#!/usr/bin/env bash
# K3 过滤日志：server/controller/state-change/request/cleaner，按关键字与时间窗抽取
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
KAFKA_INSTALL_PREFIX=${4:-/opt/kafka/3.8.1}
_kafka_port=${5:-9092}
_controller_port=${6:-9093}
run_id=${7:-manual}
log_dir=${8:-/var/log/kafka}
window_lines=${9:-800}

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact logs "$target_ip" "$run_id"

emit "collector=logs"
emit "log_dir=${log_dir} window_lines=${window_lines}"

if [[ ! -d "$log_dir" ]]; then
  for alt in "${KAFKA_INSTALL_PREFIX}/logs" /opt/kafka/logs /var/log/kafka; do
    [[ -d "$alt" ]] && log_dir=$alt && break
  done
fi
emit "resolved_log_dir=${log_dir}"

if [[ ! -d "$log_dir" ]]; then
  signal KF118 medium "kafka log dir missing"
  emit "LOG_DIR_MISSING"
  finish_artifact
  exit 0
fi

emit "----- log dir listing -----"
ls -lah "$log_dir" >> "$ARTIFACT_FILE" 2>&1 || true

files=(
  server.log
  controller.log
  state-change.log
  kafka-request.log
  log-cleaner.log
  kafka-authorizer.log
  kafkaServer.out
)

keyword_map() {
  local line=$1
  case "$line" in
    *OutOfMemoryError*|*"Java heap space"*) echo KF017 high ;;
    *"GC overhead"*|*Humongous*|*"Full GC"*) echo KF018 medium ;;
    *"Too many open files"*) echo KF011 high ;;
    *"No space left"*|*"disk is full"*|*"Insufficient disk"*) echo KF083 high ;;
    *"Permission denied"*|*"Read-only file system"*) echo KF084 high ;;
    *UnderReplicated*|*"shrinking ISR"*) echo KF036 high ;;
    *OfflinePartition*|*"going offline"*) echo KF037 high ;;
    *NotEnoughReplicas*) echo KF053 high ;;
    *NotLeaderOrFollower*|*NotLeaderForPartition*) echo KF038 medium ;;
    *LEADER_NOT_AVAILABLE*|*LeaderNotAvailable*) echo KF038 high ;;
    *UNKNOWN_TOPIC_OR_PARTITION*) echo KF050 medium ;;
    *RECORD_TOO_LARGE*|*RecordTooLargeException*) echo KF055 high ;;
    *Disconnect*|*"Timed out waiting for a node"*) echo KF071 medium ;;
    *UnknownHostException*|*"Name or service not known"*) echo KF013 high ;;
    *"Failed to become"*controller*|*"Resigning"*controller*) echo KF025 medium ;;
    *Corrupt*|*Checksum*|*InvalidRecordException*) echo KF087 high ;;
    *fsync*|*"Flushing"*slow*) echo KF093 medium ;;
    *Rebalance*|*PreparingRebalance*|*"member has left"*) echo KF061 medium ;;
    *OffsetOutOfRange*|*"offset out of range"*) echo KF063 medium ;;
    *SASL*|*"Authentication failed"*) echo KF094 medium ;;
    *Unauthorized*|*"not authorized"*) echo KF095 medium ;;
    *Throttl*) echo KF099 medium ;;
    *"Cluster ID"*|*clusterId*) echo KF028 medium ;;
    *"Duplicate broker registration"*) echo KF029 medium ;;
    *) echo "" ;;
  esac
}

scan_file() {
  local f=$1
  local path="${log_dir}/${f}"
  if [[ ! -f "$path" ]]; then
    emit "LOG_ABSENT ${f}"
    return 0
  fi
  emit "----- ${f} size=$(wc -c < "$path" | tr -d ' ') mtime=$(date -r "$path" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo unknown) -----"
  emit "----- ${f} ERROR/WARN/FATAL tail -----"
  grep -E "ERROR|WARN|FATAL|Exception|OutOfMemory|UnderReplicated|Offline|NotEnoughReplicas|Timeout|Disconnect" "$path" \
    | tail -n "$window_lines" >> "$ARTIFACT_FILE" 2>/dev/null || emit "NO_MATCH ${f}"

  local hits
  hits=$(grep -E "ERROR|FATAL|OutOfMemory|UnderReplicated|OfflinePartition|NotEnoughReplicas|No space left|Too many open files" "$path" 2>/dev/null | tail -n 80 || true)
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    mapped=$(keyword_map "$line")
    if [[ -n "$mapped" ]]; then
      # shellcheck disable=SC2086
      signal $mapped "${f}: ${line:0:180}"
    fi
  done <<<"$hits"
}

for f in "${files[@]}"; do
  scan_file "$f"
done

# rotated logs
emit "----- recent rotated logs -----"
ls -1t "$log_dir" | head -40 >> "$ARTIFACT_FILE" || true

finish_artifact
exit 0
