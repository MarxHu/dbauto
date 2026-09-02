#!/usr/bin/env bash
# K2 配置信息：server.properties、systemd、JVM 环境、Topic 配置、角色/监听
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
conf_file=${8:-/etc/kafka/server.properties}

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact config "$target_ip" "$run_id"

emit "collector=config"
emit "conf_file=${conf_file}"
emit "install_prefix=${KAFKA_INSTALL_PREFIX}"

if [[ -f "$conf_file" ]]; then
  emit "----- ${conf_file} -----"
  cat "$conf_file" >> "$ARTIFACT_FILE" 2>&1 || emit "READ_FAIL ${conf_file}"
else
  signal KF024 high "server.properties missing ${conf_file}"
  emit "CONF_MISSING ${conf_file}"
  # try common locations
  for alt in /opt/kafka/3.8.1/config/server.properties /opt/kafka/config/kraft/server.properties; do
    if [[ -f "$alt" ]]; then
      emit "----- fallback ${alt} -----"
      cat "$alt" >> "$ARTIFACT_FILE"
      conf_file=$alt
      break
    fi
  done
fi

if [[ -f "$conf_file" ]]; then
  getp() { awk -F= -v k="$1" '$1==k {print $2; exit}' "$conf_file"; }
  roles=$(getp process.roles)
  node_id=$(getp node.id)
  voters=$(getp controller.quorum.voters)
  listeners=$(getp listeners)
  advertised=$(getp advertised.listeners)
  log_dirs=$(getp log.dirs)
  rf=$(getp default.replication.factor)
  min_isr=$(getp min.insync.replicas)
  auto_create=$(getp auto.create.topics.enable)
  unclean=$(getp unclean.leader.election.enable)
  offsets_rf=$(getp offsets.topic.replication.factor)

  emit "PARSED process.roles=${roles}"
  emit "PARSED node.id=${node_id}"
  emit "PARSED controller.quorum.voters=${voters}"
  emit "PARSED listeners=${listeners}"
  emit "PARSED advertised.listeners=${advertised}"
  emit "PARSED log.dirs=${log_dirs}"
  emit "PARSED default.replication.factor=${rf}"
  emit "PARSED min.insync.replicas=${min_isr}"
  emit "PARSED auto.create.topics.enable=${auto_create}"
  emit "PARSED unclean.leader.election.enable=${unclean}"
  emit "PARSED offsets.topic.replication.factor=${offsets_rf}"

  if [[ -n "$min_isr" && -n "$rf" ]]; then
    if (( min_isr >= rf )); then
      signal KF101 high "min.insync.replicas=${min_isr} >= replication.factor=${rf}"
    fi
  fi
  if [[ "$rf" == "1" || "$offsets_rf" == "1" ]]; then
    signal KF102 medium "replication.factor=1 HA degraded"
  fi
  if [[ "$unclean" == "true" ]]; then
    signal KF106 high "unclean.leader.election.enable=true"
    signal KF045 medium "unclean leader election allowed"
  fi
  if [[ "$auto_create" == "false" ]]; then
    emit "NOTE auto.create.topics.enable=false"
  fi
  if [[ -n "$advertised" && "$advertised" != *"$target_ip"* && "$advertised" != *localhost* ]]; then
    signal KF078 medium "advertised.listeners may not contain local ip ${target_ip}: ${advertised}"
  fi
  if [[ -n "$listeners" && "$listeners" != *"${kafka_port}"* ]]; then
    signal KF109 high "listeners missing broker port ${kafka_port}"
  fi
  if [[ -n "$listeners" && "$listeners" != *"${controller_port}"* ]]; then
    signal KF109 high "listeners missing controller port ${controller_port}"
  fi
  if [[ -n "$voters" ]]; then
    for ip in "$node1" "$node2" "$node3"; do
      if [[ "$voters" != *"$ip"* ]]; then
        signal KF033 high "voter list missing ${ip}: ${voters}"
      fi
    done
  fi
fi

emit "----- systemd kafka.service -----"
if [[ -f /etc/systemd/system/kafka.service ]]; then
  cat /etc/systemd/system/kafka.service >> "$ARTIFACT_FILE"
else
  emit "UNIT_MISSING /etc/systemd/system/kafka.service"
fi
if command -v systemctl >/dev/null 2>&1; then
  emit_cmd "systemctl is-active kafka" systemctl is-active kafka || signal KF015 medium "kafka.service not active"
  emit_cmd "systemctl show kafka" systemctl show kafka -p ActiveState -p SubState -p Result -p NRestarts -p Environment -p ExecStart -p Restart || true
fi

emit "----- JVM / env -----"
env | grep -E '^(KAFKA_|LOG_DIR|JAVA_|JMX_)' | sort >> "$ARTIFACT_FILE" || true
if command -v java >/dev/null 2>&1; then
  java -version >> "$ARTIFACT_FILE" 2>&1 || true
else
  signal KF024 high "java missing"
fi

pid=$(pgrep -f 'kafka\.Kafka' | head -1 || true)
if [[ -n "$pid" ]]; then
  emit "KAFKA_PID=${pid}"
  tr '\0' ' ' < "/proc/${pid}/cmdline" >> "$ARTIFACT_FILE" 2>/dev/null || true
  emit ""
  if [[ -r "/proc/${pid}/limits" ]]; then
    emit "----- /proc/${pid}/limits -----"
    grep -E 'open files|Max processes|Max address' "/proc/${pid}/limits" >> "$ARTIFACT_FILE" || true
  fi
else
  signal KF015 high "kafka.Kafka process not found"
fi

topics_bin=$(kafka_bin kafka-topics.sh || true)
configs_bin=$(kafka_bin kafka-configs.sh || true)
bootstrap="${node1}:${kafka_port}"
if [[ -n "$topics_bin" && -n "$configs_bin" ]]; then
  topics=$(timeout 20 "$topics_bin" --bootstrap-server "$bootstrap" --list 2>/dev/null | head -30 || true)
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    emit_cmd_timeout 15 "topic ${t} configs" "$configs_bin" --bootstrap-server "$bootstrap" \
      --entity-type topics --entity-name "$t" --describe || true
  done <<<"$topics"
fi

finish_artifact
exit 0
