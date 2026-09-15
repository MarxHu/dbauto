#!/usr/bin/env bash
# Shared helpers for ES 7.x troubleshooting collectors. Sourced, not executed.
# Collectors always exit 0. Do not mutate the cluster.

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
  local base=${TS_ARTIFACT_DIR:-/tmp/es-troubleshoot}
  printf '%s/%s' "$base" "$run_id"
}

es_lib_py() {
  local here=${SCRIPT_DIR:-}
  if [[ -n "$here" && -f "${here}/es_lib.py" ]]; then
    printf '%s' "${here}/es_lib.py"
    return 0
  fi
  if [[ -f /tmp/es-ts-lib/es_lib.py ]]; then
    printf '%s' /tmp/es-ts-lib/es_lib.py
    return 0
  fi
  return 1
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
  FACTS_FILE="${ARTIFACT_DIR}/facts.${node}.json"
  MASTER_FILE="${ARTIFACT_DIR}/master.${node}.json"
  : > "$ARTIFACT_FILE"
  : > "$SIGNAL_FILE"
  {
    echo "===== ES_TS artifact=${kind} node=${node} ts=$(ts_now) run_id=${run_id} ====="
    echo "hostname=$(hostname 2>/dev/null || echo unknown)"
  } >> "$ARTIFACT_FILE"
}

emit() {
  printf '%s\n' "$*" >> "$ARTIFACT_FILE"
}

emit_cmd() {
  local title=$1
  local rc=0
  shift
  emit "----- ${title} -----"
  "$@" >> "$ARTIFACT_FILE" 2>&1
  rc=$?
  if (( rc != 0 )); then
    emit "CMD_FAIL: ${title} rc=${rc}"
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
      signal ES174 low "timeout ${title}"
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
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SIGNAL_FILE"
  emit "SIGNAL ${1} severity=${2} ${3}"
}

finish_artifact() {
  emit "===== END ES_TS artifact=${ARTIFACT_KIND} node=${ARTIFACT_NODE} ====="
  echo "###ES_TS_ARTIFACT kind=${ARTIFACT_KIND} node=${ARTIFACT_NODE} file=${ARTIFACT_FILE}###"
  cat "$ARTIFACT_FILE"
  echo "###ES_TS_SIGNALS kind=${ARTIFACT_KIND} node=${ARTIFACT_NODE}###"
  cat "$SIGNAL_FILE"
  echo "###END_ES_TS_ARTIFACT###"
}

es_curl() {
  # es_curl <seconds> <url> [curl extra...]
  local seconds=$1
  shift
  local url=$1
  shift
  local args=(-sS --max-time "$seconds" --connect-timeout 3 -H 'Accept: application/json')
  if [[ -n "${ES_USER:-}" ]]; then
    args+=(-u "${ES_USER}:${ES_PASS:-}")
  fi
  curl "${args[@]}" "$@" "$url" 2>/dev/null
}

es_base_url() {
  printf 'http://127.0.0.1:%s' "${ES_HTTP_PORT:-9200}"
}

facts_merge() {
  local json=$1
  local py
  py=$(es_lib_py) || return 0
  python3 "$py" merge-facts "$FACTS_FILE" "$json" >/dev/null 2>&1 || true
}

record_local_master() {
  local url
  url="$(es_base_url)/_cat/master?h=id,host,ip,node&format=json"
  local body rc=0
  body=$(es_curl 3 "$url" -w '\nHTTP_CODE:%{http_code}\n') || rc=$?
  local code
  code=$(printf '%s\n' "$body" | awk -F: '/HTTP_CODE:/{print $2}' | tail -n1)
  local json
  json=$(printf '%s\n' "$body" | sed '/HTTP_CODE:/d')
  emit "----- local _cat/master http=${code:-na} rc=${rc} -----"
  emit "$json"

  local parsed="{}"
  local py
  py=$(es_lib_py) || true
  if [[ -n "$py" ]]; then
    parsed=$(printf '%s' "$json" | python3 "$py" parse-master 2>/dev/null || echo '{}')
  fi
  local http_ok=false auth_fail=false local_master="" local_ip=""
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    auth_fail=true
    signal ES032 high "local HTTP auth failed code=${code}"
  elif [[ "$code" == "200" ]]; then
    http_ok=true
  else
    signal ES032 medium "local _cat/master failed code=${code:-na} rc=${rc}"
  fi
  if [[ "$http_ok" == true ]]; then
    local_master=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("local_master",""))' "$parsed" 2>/dev/null || true)
    local_ip=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("local_master_ip",""))' "$parsed" 2>/dev/null || true)
  fi
  emit "local_master=${local_master}"
  emit "local_master_ip=${local_ip}"

  local nodes_json=""
  nodes_json=$(es_curl 3 "$(es_base_url)/_cat/nodes?h=id,name,ip,master,node.role&format=json" || true)
  emit "----- local _cat/nodes -----"
  emit "$nodes_json"
  local self_elected=false
  if [[ -n "$py" && -n "$nodes_json" ]]; then
    local nodes_parsed
    nodes_parsed=$(printf '%s' "$nodes_json" | python3 "$py" parse-nodes "$ARTIFACT_NODE" 2>/dev/null || echo '{}')
    if python3 -c 'import json,sys; raise SystemExit(0 if json.loads(sys.argv[1]).get("self_elected") else 1)' "$nodes_parsed" 2>/dev/null; then
      self_elected=true
    fi
  fi
  if [[ "$self_elected" != true && -n "$local_ip" && "$local_ip" == "$ARTIFACT_NODE" ]]; then
    self_elected=true
  fi
  emit "is_elected=${self_elected}"

  mkdir -p "$ARTIFACT_DIR"
  python3 - "$MASTER_FILE" "$ARTIFACT_NODE" "$local_master" "$local_ip" "$http_ok" "$auth_fail" "$self_elected" <<'PY' 2>/dev/null || true
import json,sys
path, node, lm, lip, http_ok, auth, elected = sys.argv[1:8]
doc = {
  "node": node,
  "local_master": lm,
  "local_master_ip": lip,
  "http_ok": http_ok == "true",
  "auth_fail": auth == "true",
  "is_elected": elected == "true",
}
open(path,"w",encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=2)+"\n")
PY
  facts_merge "$(python3 -c 'import json,sys; print(json.dumps({"local_master":sys.argv[1],"local_master_ip":sys.argv[2],"http_ok":sys.argv[3]=="true","auth_fail":sys.argv[4]=="true","is_elected":sys.argv[5]=="true","node":sys.argv[6]}))' \
    "$local_master" "$local_ip" "$http_ok" "$auth_fail" "$self_elected" "$ARTIFACT_NODE")"
  if [[ "$self_elected" == true ]]; then
    IS_ELECTED=1
  else
    IS_ELECTED=0
  fi
}

listen_port() {
  local port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
    return $?
  fi
  netstat -lnt 2>/dev/null | grep -q ":${port} "
}

tcp_probe() {
  local host=$1 port=$2
  if timeout 2 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
    return 0
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 2 "$host" "$port" >/dev/null 2>&1 && return 0
  fi
  return 1
}

es_process_up() {
  # Character class so pgrep does not match its own argv.
  pgrep -f '[o]rg.elasticsearch.bootstrap.Elasticsearch' >/dev/null 2>&1 && return 0
  pgrep -x elasticsearch >/dev/null 2>&1 && return 0
  return 1
}
