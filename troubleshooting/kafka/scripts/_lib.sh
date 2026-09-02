#!/usr/bin/env bash
# Shared helpers for Kafka troubleshooting collectors. Sourced, not executed.
# Collectors must not abort the SOPS flow: they always exit 0 and write artifacts.

umask 077

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

ts_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

resolve_local_ip() {
  local node1=$1 node2=$2 node3=$3
  local local_ips target_ip=""
  local_ips=$(hostname -I 2>/dev/null || true)
  for ip in "$node1" "$node2" "$node3"; do
    [[ " ${local_ips} " == *" ${ip} "* ]] && target_ip=$ip && break
  done
  if [[ -z "$target_ip" ]]; then
    target_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  printf '%s' "${target_ip:-unknown}"
}

artifact_dir_for() {
  local run_id=$1
  local base=${TS_ARTIFACT_DIR:-/tmp/kafka-troubleshoot}
  printf '%s/%s' "$base" "$run_id"
}

begin_artifact() {
  local kind=$1 node=$2 run_id=$3
  ARTIFACT_KIND=$kind
  ARTIFACT_NODE=$node
  ARTIFACT_RUN_ID=$run_id
  ARTIFACT_DIR=$(artifact_dir_for "$run_id")
  mkdir -p "$ARTIFACT_DIR"
  ARTIFACT_FILE="${ARTIFACT_DIR}/${kind}.${node}.txt"
  SIGNAL_FILE="${ARTIFACT_DIR}/${kind}.${node}.signals"
  : > "$ARTIFACT_FILE"
  : > "$SIGNAL_FILE"
  {
    echo "===== KAFKA_TS artifact=${kind} node=${node} ts=$(ts_now) run_id=${run_id} ====="
    echo "hostname=$(hostname 2>/dev/null || echo unknown)"
  } >> "$ARTIFACT_FILE"
}

emit() {
  printf '%s\n' "$*" >> "$ARTIFACT_FILE"
}

emit_cmd() {
  local title=$1
  shift
  emit "----- ${title} -----"
  if ! "$@" >> "$ARTIFACT_FILE" 2>&1; then
    emit "CMD_FAIL: ${title} rc=$?"
    return 1
  fi
  return 0
}

emit_cmd_timeout() {
  local seconds=$1 title=$2
  shift 2
  emit "----- ${title} (timeout ${seconds}s) -----"
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "$seconds" "$@" >> "$ARTIFACT_FILE" 2>&1; then
      emit "CMD_FAIL_OR_TIMEOUT: ${title}"
      return 1
    fi
  else
    if ! "$@" >> "$ARTIFACT_FILE" 2>&1; then
      emit "CMD_FAIL: ${title}"
      return 1
    fi
  fi
  return 0
}

signal() {
  # signal <id> <severity> <note>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SIGNAL_FILE"
  emit "SIGNAL ${1} severity=${2} ${3}"
}

finish_artifact() {
  emit "===== END KAFKA_TS artifact=${ARTIFACT_KIND} node=${ARTIFACT_NODE} ====="
  echo "###KAFKA_TS_ARTIFACT kind=${ARTIFACT_KIND} node=${ARTIFACT_NODE} file=${ARTIFACT_FILE}###"
  cat "$ARTIFACT_FILE"
  echo "###KAFKA_TS_SIGNALS kind=${ARTIFACT_KIND} node=${ARTIFACT_NODE}###"
  cat "$SIGNAL_FILE"
  echo "###END_KAFKA_TS_ARTIFACT###"
}

kafka_bin() {
  local name=$1
  local prefix=${KAFKA_INSTALL_PREFIX:-/opt/kafka/3.8.1}
  if [[ -x "${prefix}/bin/${name}" ]]; then
    printf '%s' "${prefix}/bin/${name}"
    return 0
  fi
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  return 1
}
