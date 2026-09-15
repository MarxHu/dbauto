#!/usr/bin/env bash
# 在诊断机汇聚三节点采集产物并跑清洗+AI（补上 SOPS 无共享盘）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="${ROOT}/scripts"

NODE1=${NODE1:-${ES_NODE1:-10.10.26.144}}
NODE2=${NODE2:-${ES_NODE2:-10.10.26.145}}
NODE3=${NODE3:-${ES_NODE3:-10.10.26.146}}
HTTP=${ES_HTTP_PORT:-9200}
TRANSPORT=${ES_TRANSPORT_PORT:-9300}
RUN_ID=${TS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
PROFILE=${TS_PROFILE:-v2}
BACKEND=${INJECT_BACKEND:-local}
CONTAINER_MAP=${ES_CONTAINER_MAP:-"10.10.26.144:es-n1 10.10.26.145:es-n2 10.10.26.146:es-n3"}
ES_USER=${ES_USER:-}
ES_PASS=${ES_PASS:-}

ART=${TS_ARTIFACT_DIR:-/tmp/es-troubleshoot}/${RUN_ID}
mkdir -p "$ART"
export TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR:-/tmp/es-troubleshoot}

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
      docker exec "$ctn" mkdir -p /tmp/es-ts-scripts
      docker cp "${SCRIPTS}/." "$ctn":/tmp/es-ts-scripts/ >/dev/null
      ;;
    ssh)
      ssh "root@${host}" mkdir -p /tmp/es-ts-scripts
      scp -q "${SCRIPTS}"/*.sh "${SCRIPTS}"/*.py "root@${host}:/tmp/es-ts-scripts/"
      ;;
    local)
      mkdir -p /tmp/es-ts-scripts
      cp -a "${SCRIPTS}/." /tmp/es-ts-scripts/
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
      "TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR} bash /tmp/es-ts-scripts/$(basename "$script") \
        '$NODE1' '$NODE2' '$NODE3' '$HTTP' '$TRANSPORT' '$RUN_ID' '$ES_USER' '$ES_PASS' $extra" \
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

collect_kind collect_precheck.sh ""
collect_kind collect_metrics.sh ""
collect_kind collect_status.sh ""
collect_kind collect_config.sh ""
collect_kind collect_logs.sh "'/var/log/elasticsearch' '8000'"
collect_kind collect_hostnet.sh "''"

log "cleanse locally using gathered artifacts"
TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR} bash "${SCRIPTS}/cleanse_artifacts.sh" \
  "$NODE1" "$NODE2" "$NODE3" "$HTTP" "$TRANSPORT" "$RUN_ID" "$PROFILE" "$ES_USER" "$ES_PASS" \
  | tee "${ART}/stdout.cleanse.log" >/dev/null

log "ai diagnose (fails closed)"
set +e
TS_ARTIFACT_DIR=${TS_ARTIFACT_DIR} bash "${SCRIPTS}/ai_diagnose.sh" \
  "$NODE1" "$NODE2" "$NODE3" "$HTTP" "$TRANSPORT" "$RUN_ID" "$PROFILE" "${ES_AI_ENDPOINT:-}" \
  | tee "${ART}/stdout.ai.log"
ai_rc=${PIPESTATUS[0]}
set -e

log "done artifacts in ${ART} ai_rc=${ai_rc}"
ls -la "$ART" || true
[[ -f "${ART}/summary.md" ]] && cat "${ART}/summary.md"
exit "$ai_rc"
