#!/usr/bin/env bash
# M 指标：本地 _nodes/_local/stats + 若本机为 elected master 则打一次 cluster health。
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
begin_artifact metrics "$target_ip" "$run_id"
emit "collector=metrics"

record_local_master

FILTER='filter_path=nodes.*.name,nodes.*.jvm.mem.heap_used_percent,nodes.*.jvm.gc.collectors,nodes.*.thread_pool.write,nodes.*.thread_pool.index,nodes.*.thread_pool.search,nodes.*.breakers.parent,nodes.*.breakers.request,nodes.*.breakers.fielddata,nodes.*.fs.total,nodes.*.indices.indexing.index_total,nodes.*.indices.indexing.index_time_in_millis,nodes.*.indices.search.query_total,nodes.*.indices.search.query_time_in_millis,nodes.*.os.cpu'
URL="$(es_base_url)/_nodes/_local/stats?${FILTER}"

stats1=$(es_curl 8 "$URL" || true)
emit "----- _nodes/_local/stats sample1 -----"
emit "$stats1"
sleep 1
stats2=$(es_curl 8 "$URL" || true)
emit "----- _nodes/_local/stats sample2 -----"
emit "$stats2"

py=$(es_lib_py || true)
if [[ -n "$py" && -n "$stats2" ]]; then
  p1=$(printf '%s' "$stats1" | python3 "$py" parse-stats 2>/dev/null || echo '{}')
  p2=$(printf '%s' "$stats2" | python3 "$py" parse-stats 2>/dev/null || echo '{}')
  emit "PARSED_STATS1 ${p1}"
  emit "PARSED_STATS2 ${p2}"
  python3 - "$p1" "$p2" "$FACTS_FILE" <<'PY' 2>/dev/null || true
import json,sys
a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2]); path=sys.argv[3]
def d(k):
    x,y=a.get(k),b.get(k)
    if isinstance(x,int) and isinstance(y,int):
        return max(0, y-x)
    return 0
heap=b.get("heap_pct")
wr=d("write_rejected")
sr=d("search_rejected")
upd={
  "heap_pct": heap,
  "write_rejected": b.get("write_rejected"),
  "search_rejected": b.get("search_rejected"),
  "write_rejected_delta": wr,
  "search_rejected_delta": sr,
  "write_pool": b.get("write_pool") or "",
  "breaker_parent_pct": b.get("breaker_parent_pct"),
  "breaker_tripped": b.get("breaker_tripped"),
  "disk_used_pct": b.get("disk_used_pct"),
  "gc_young_delta_ms": d("gc_young_ms"),
  "gc_old_delta_ms": d("gc_old_ms"),
}
try:
    cur=json.loads(open(path,encoding="utf-8").read())
except Exception:
    cur={}
cur.update({k:v for k,v in upd.items() if v is not None})
open(path,"w",encoding="utf-8").write(json.dumps(cur,ensure_ascii=False,indent=2)+"\n")
open(path+".env","w",encoding="utf-8").write(
    "HEAP=%s\nWR=%s\nSR=%s\nBRK=%s\nDISK=%s\nGC=%s\nPOOL=%s\n" % (
        heap if heap is not None else "",
        wr, sr,
        b.get("breaker_tripped") or 0,
        b.get("disk_used_pct") if b.get("disk_used_pct") is not None else "",
        d("gc_old_ms")+d("gc_young_ms"),
        b.get("write_pool") or "",
    )
)
PY
  if [[ -f "${FACTS_FILE}.env" ]]; then
    # shellcheck disable=SC1091
    source "${FACTS_FILE}.env"
    rm -f "${FACTS_FILE}.env"
    if [[ "${HEAP:-}" =~ ^[0-9]+$ ]] && (( HEAP >= 95 )); then
      signal ES034 high "heap_used_percent=${HEAP}"
    elif [[ "${HEAP:-}" =~ ^[0-9]+$ ]] && (( HEAP >= 85 )); then
      signal ES034 medium "heap_used_percent=${HEAP}"
    fi
    if [[ "${WR:-0}" =~ ^[0-9]+$ ]] && (( WR > 0 )); then
      signal ES036 high "write rejected delta=${WR} pool=${POOL:-write}"
    fi
    if [[ "${SR:-0}" =~ ^[0-9]+$ ]] && (( SR > 0 )); then
      signal ES037 medium "search rejected delta=${SR}"
    fi
    if [[ "${BRK:-0}" =~ ^[0-9]+$ ]] && (( BRK > 0 )); then
      signal ES038 high "circuit breaker tripped=${BRK}"
    fi
    if [[ "${DISK:-}" =~ ^[0-9]+$ ]] && (( DISK >= 95 )); then
      signal ES070 high "fs used_pct=${DISK} flood-stage likely"
      facts_merge '{"flood": true}'
    elif [[ "${DISK:-}" =~ ^[0-9]+$ ]] && (( DISK >= 90 )); then
      signal ES072 medium "fs used_pct=${DISK} high watermark likely"
    fi
    if [[ "${GC:-0}" =~ ^[0-9]+$ ]] && (( GC > 2000 )); then
      signal ES035 medium "gc time delta_ms=${GC} in ~1s window"
    fi
  fi
else
  signal ES174 medium "local stats parse skipped"
fi

if [[ "${IS_ELECTED:-0}" == "1" ]]; then
  emit "cluster_health=local_elected"
  HF='filter_path=status,number_of_nodes,number_of_data_nodes,active_primary_shards,active_shards,relocating_shards,initializing_shards,unassigned_shards,delayed_unassigned_shards,number_of_pending_tasks,task_max_waiting_in_queue_millis,active_shards_percent_as_number,timed_out'
  health=$(es_curl 5 "$(es_base_url)/_cluster/health?${HF}" || true)
  emit "----- _cluster/health -----"
  emit "$health"
  if [[ -n "$py" && -n "$health" ]]; then
    hp=$(printf '%s' "$health" | python3 "$py" parse-health 2>/dev/null || echo '{}')
    emit "PARSED_HEALTH ${hp}"
    facts_merge "$(python3 -c 'import json,sys; print(json.dumps({"cluster_health": json.loads(sys.argv[1])}))' "$hp")"
  fi
else
  emit "cluster_health=delegated"
fi

finish_artifact
exit 0
