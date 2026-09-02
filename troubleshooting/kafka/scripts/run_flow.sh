#!/usr/bin/env bash
# 在诊断机/注入机汇聚三节点采集产物并跑清洗+AI（实验室补充 SOPS 无共享盘的缺口）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/scripts"

NODE1=${NODE1:-10.10.26.144}
NODE2=${NODE2:-10.10.26.145}
NODE3=${NODE3:-10.10.26.146}
KAFKA_HOME=${KAFKA_HOME:-/opt/kafka/3.8.1}
PORT=${KAFKA_PORT:-9092}
CPORT=${KAFKA_CONTROLLER_PORT:-9093}
RUN_ID=${TS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
PROFILE=${TS_PROFILE:-v2}
BACKEND=${INJECT_BACKEND:-local}
CONTAINER_MAP=${KAFKA_CONTAINER_MAP:-"10.10.26.144:kafka-n1 10.10.26.145:kafka-n2 10.10.26.146:kafka-n3"}

ART=${TS_ARTIFACT_DIR:-/tmp/kafka-troubleshoot}/${RUN_ID}
mkdir -p "$ART"
export TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR:-/tmp/kafka-troubleshoot}

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }

container_for() {
  local host=$1 entry ip name
  for entry in $CONTAINER_MAP; do
    ip=${entry%%:*}; name=${entry#*:}
    [[ "$ip" == "$host" ]] && { printf '%s' "$name"; return 0; }
  done
  return 1
}

run_on_node() {
  local host=$1
  shift
  case "$BACKEND" in
    docker)
      local ctn
      ctn=$(container_for "$host") || { log "no container for $host"; return 1; }
      docker exec "$ctn" bash -lc "$*"
      ;;
    ssh)
      ssh -o BatchMode=yes -o ConnectTimeout=8 "root@${host}" "$@"
      ;;
    local)
      bash -lc "$*"
      ;;
    *)
      log "unknown BACKEND=$BACKEND"; return 1
      ;;
  esac
}

copy_scripts_to_node() {
  local host=$1
  case "$BACKEND" in
    docker)
      local ctn
      ctn=$(container_for "$host") || return 1
      docker exec "$ctn" mkdir -p /tmp/kafka-ts-scripts
      docker cp "${SCRIPTS}/." "$ctn":/tmp/kafka-ts-scripts/ >/dev/null
      ;;
    ssh)
      ssh "root@${host}" mkdir -p /tmp/kafka-ts-scripts
      scp -q "${SCRIPTS}"/*.sh "root@${host}:/tmp/kafka-ts-scripts/"
      ;;
    local)
      mkdir -p /tmp/kafka-ts-scripts
      cp -a "${SCRIPTS}/." /tmp/kafka-ts-scripts/
      ;;
  esac
}

collect_kind() {
  local script=$1 extra=$2
  local host
  for host in "$NODE1" "$NODE2" "$NODE3"; do
    log "collect $(basename "$script") on $host"
    copy_scripts_to_node "$host" || true
    run_on_node "$host" \
      "TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR} bash /tmp/kafka-ts-scripts/$(basename "$script") \
        '$NODE1' '$NODE2' '$NODE3' '$KAFKA_HOME' '$PORT' '$CPORT' '$RUN_ID' $extra" \
      > "${ART}/stdout.$(basename "$script" .sh).${host}.log" 2>&1 || true
    if [[ "$BACKEND" == "docker" ]]; then
      ctn=$(container_for "$host") || continue
      docker cp "$ctn:${TS_ARTIFACT_DIR}/${RUN_ID}/." "$ART/" 2>/dev/null || true
    elif [[ "$BACKEND" == "ssh" ]]; then
      scp -q "root@${host}:${TS_ARTIFACT_DIR}/${RUN_ID}/*" "$ART/" 2>/dev/null || true
    fi
  done
}

log "run_id=${RUN_ID} backend=${BACKEND} profile=${PROFILE} art=${ART}"

if [[ "$PROFILE" == v2* ]]; then
  collect_kind collect_precheck.sh ""
fi
collect_kind collect_metrics.sh "'deploy-verify'"
collect_kind collect_config.sh ""
collect_kind collect_logs.sh "'/var/log/kafka' '800'"
collect_kind collect_host.sh "'/var/lib/kafka/data'"
collect_kind collect_network.sh ""

log "cleanse locally using gathered artifacts"
TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR} bash "${SCRIPTS}/cleanse_artifacts.sh" \
  "$NODE1" "$NODE2" "$NODE3" "$KAFKA_HOME" "$PORT" "$CPORT" "$RUN_ID" "$PROFILE" \
  | tee "${ART}/stdout.cleanse.log" >/dev/null

log "ai diagnose"
TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR} bash "${SCRIPTS}/ai_diagnose.sh" \
  "$NODE1" "$NODE2" "$NODE3" "$KAFKA_HOME" "$PORT" "$CPORT" "$RUN_ID" "$PROFILE" "${KAFKA_AI_ENDPOINT:-}" \
  | tee "${ART}/stdout.ai.log" >/dev/null

log "done artifacts in ${ART}"
ls -la "$ART" || true
[[ -f "${ART}/summary.md" ]] && cat "${ART}/summary.md"
exit 0
