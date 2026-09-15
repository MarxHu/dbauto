#!/usr/bin/env bash
# C 配置：解析 elasticsearch.yml / jvm.options 关键项；elected master 再拉 cluster settings。
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
conf_hint=${9:-}
export ES_HTTP_PORT ES_USER ES_PASS

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact config "$target_ip" "$run_id"
emit "collector=config"

record_local_master

yml=""
for cand in \
  "$conf_hint" \
  /etc/elasticsearch/elasticsearch.yml \
  /opt/elasticsearch/config/elasticsearch.yml \
  /usr/share/elasticsearch/config/elasticsearch.yml \
  "$HOME/elasticsearch/config/elasticsearch.yml"; do
  [[ -n "$cand" && -f "$cand" ]] && yml=$cand && break
done
emit "elasticsearch_yml=${yml:-MISSING}"

parse_yml_key() {
  local file=$1 key=$2
  awk -F: -v k="$key" '
    $0 ~ "^[[:space:]]*#" {next}
    index($1,k)==1 {
      v=$0
      sub(/^[^:]+:[[:space:]]*/,"",v)
      gsub(/[[:space:]]+#.*/,"",v)
      gsub(/[[:space:]"'\'']/, "", v)
      print v
      exit
    }
  ' "$file" 2>/dev/null
}

if [[ -n "$yml" ]]; then
  emit "----- parsed ${yml} -----"
  cluster_name=$(parse_yml_key "$yml" "cluster.name")
  node_name=$(parse_yml_key "$yml" "node.name")
  seed=$(parse_yml_key "$yml" "discovery.seed_hosts")
  zen_hosts=$(parse_yml_key "$yml" "discovery.zen.ping.unicast.hosts")
  zen_mmn=$(parse_yml_key "$yml" "discovery.zen.minimum_master_nodes")
  initial=$(parse_yml_key "$yml" "cluster.initial_master_nodes")
  path_data=$(parse_yml_key "$yml" "path.data")
  http_port=$(parse_yml_key "$yml" "http.port")
  trans_port=$(parse_yml_key "$yml" "transport.port")
  emit "PARSED cluster.name=${cluster_name}"
  emit "PARSED node.name=${node_name}"
  emit "PARSED discovery.seed_hosts=${seed}"
  emit "PARSED discovery.zen.ping.unicast.hosts=${zen_hosts}"
  emit "PARSED discovery.zen.minimum_master_nodes=${zen_mmn}"
  emit "PARSED cluster.initial_master_nodes=${initial}"
  emit "PARSED path.data=${path_data}"
  emit "PARSED http.port=${http_port}"
  emit "PARSED transport.port=${trans_port}"
  facts_merge "$(python3 -c 'import json,sys; print(json.dumps({"cluster_name":sys.argv[1],"path_data":sys.argv[2]}))' "${cluster_name:-}" "${path_data:-}")"
  if [[ -n "$zen_mmn" ]]; then
    signal ES110 low "legacy discovery.zen.minimum_master_nodes=${zen_mmn}"
  fi
  if [[ -n "$http_port" && "$http_port" != "$ES_HTTP_PORT" ]]; then
    signal ES114 medium "yml http.port=${http_port} probe=${ES_HTTP_PORT}"
  fi
else
  signal ES171 low "elasticsearch.yml not found"
fi

jvm=""
for cand in \
  /etc/elasticsearch/jvm.options \
  /opt/elasticsearch/config/jvm.options \
  /usr/share/elasticsearch/config/jvm.options; do
  [[ -f "$cand" ]] && jvm=$cand && break
done
emit "jvm_options=${jvm:-MISSING}"
if [[ -n "$jvm" ]]; then
  xms=$(grep -E '^-Xms' "$jvm" | tail -n1 || true)
  xmx=$(grep -E '^-Xmx' "$jvm" | tail -n1 || true)
  emit "PARSED ${xms}"
  emit "PARSED ${xmx}"
  if [[ -n "$xms" && -n "$xmx" && "$xms" != "$xmx" ]]; then
    # compare numeric-ish suffix after -Xms/-Xmx
    a=${xms#-Xms}; b=${xmx#-Xmx}
    if [[ "$a" != "$b" ]]; then
      signal ES112 low "Xms=${a} Xmx=${b}"
    fi
  fi
fi

if [[ "${IS_ELECTED:-0}" == "1" ]]; then
  cs=$(es_curl 8 "$(es_base_url)/_cluster/settings?include_defaults=false&flat_settings=true&filter_path=transient.cluster.routing.allocation.*,persistent.cluster.routing.allocation.*,transient.cluster.max_shards_per_node,persistent.cluster.max_shards_per_node,transient.cluster.blocks.*,persistent.cluster.blocks.*" || true)
  emit "----- _cluster/settings (overrides) -----"
  emit "$cs"
  enable=$(printf '%s' "$cs" | python3 -c 'import json,sys,re
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
flat={}
for k in ("persistent","transient"):
    v=d.get(k) or {}
    if isinstance(v,dict):
        flat.update(v)
s=json.dumps(flat)
m=re.search(r"cluster.routing.allocation.enable["'\'':" ]+([a-z_]+)", s)
print(m.group(1) if m else "")
' 2>/dev/null || true)
  # simpler grep
  if printf '%s' "$cs" | grep -q 'cluster.routing.allocation.enable'; then
    val=$(printf '%s' "$cs" | tr ',' '\n' | grep 'cluster.routing.allocation.enable' | head -n1)
    emit "PARSED ${val}"
    if printf '%s' "$val" | grep -Eq '"none"|"primaries"|"new_primaries"'; then
      signal ES058 high "allocation.enable overridden"
      facts_merge '{"allocation_enable":"not_all"}'
    fi
  fi
  if printf '%s' "$cs" | grep -q 'max_shards_per_node'; then
    signal ES059 medium "cluster.max_shards_per_node overridden"
  fi
  if printf '%s' "$cs" | grep -qi 'watermark'; then
    signal ES113 low "disk watermark overridden"
  fi
else
  emit "cluster_settings=delegated"
fi

finish_artifact
exit 0
