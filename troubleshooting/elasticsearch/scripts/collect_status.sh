#!/usr/bin/env bash
# S 运行状态：每台本地 master 视图；仅 elected master 抽样 shards + allocation/explain。
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
begin_artifact status "$target_ip" "$run_id"
emit "collector=status"

record_local_master

if [[ "${IS_ELECTED:-0}" != "1" ]]; then
  emit "EXPLAIN_SKIPPED=not_elected"
  finish_artifact
  exit 0
fi

shards=$(es_curl 10 "$(es_base_url)/_cat/shards?h=index,shard,prirep,state,unassigned.reason,node&format=json" || true)
printf '%s' "$shards" > "${ARTIFACT_DIR}/shards.raw.json"
emit "----- _cat/shards filtered -----"
python3 - "$FACTS_FILE" "${ARTIFACT_DIR}/shards.raw.json" "${ARTIFACT_DIR}/shards.keep.json" <<'PY' >> "$ARTIFACT_FILE" 2>&1 || true
import json, sys
path, rawp, keepp = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    rows = json.loads(open(rawp, encoding="utf-8").read() or "[]")
except Exception:
    rows = []
keep = []
if isinstance(rows, list):
    for r in rows:
        st = str(r.get("state") or "").upper()
        if st in {"UNASSIGNED", "RELOCATING", "INITIALIZING"}:
            keep.append(r)
keep = keep[:200]
open(keepp, "w", encoding="utf-8").write(json.dumps(keep, ensure_ascii=False))
print(json.dumps(keep[:20], ensure_ascii=False, indent=2))
reasons = []
for r in keep:
    u = str(r.get("unassigned.reason") or "")
    if u:
        reasons.append(u)
try:
    cur = json.loads(open(path, encoding="utf-8").read())
except Exception:
    cur = {}
if reasons:
    cur["explain_reasons"] = list(dict.fromkeys((cur.get("explain_reasons") or []) + reasons))
cur["unassigned_sample_n"] = len(keep)
open(path, "w", encoding="utf-8").write(json.dumps(cur, ensure_ascii=False, indent=2) + "\n")
PY

n=0
if [[ -s "${ARTIFACT_DIR}/shards.keep.json" ]]; then
  mapfile -t EXPLAIN_ROWS < <(python3 - "${ARTIFACT_DIR}/shards.keep.json" <<'PY'
import json, sys
try:
    keep = json.loads(open(sys.argv[1], encoding="utf-8").read())
except Exception:
    keep = []
for r in keep[:5]:
    print("%s\t%s\t%s" % (r.get("index", ""), r.get("shard", "0"), r.get("prirep", "p")))
PY
)
  for row in "${EXPLAIN_ROWS[@]:-}"; do
    [[ -z "${row:-}" ]] && continue
    IFS=$'\t' read -r idx shard pri <<<"$row"
    [[ -z "$idx" ]] && continue
    n=$((n + 1))
    body=$(python3 -c 'import json,sys; print(json.dumps({"index":sys.argv[1],"shard":int(float(sys.argv[2])),"primary": sys.argv[3].lower().startswith("p")}))' "$idx" "$shard" "$pri")
    expl=$(es_curl 5 "$(es_base_url)/_cluster/allocation/explain?include_yes_decisions=false" \
      -H 'Content-Type: application/json' -X GET -d "$body" || true)
    if [[ -z "$expl" ]] || printf '%s' "$expl" | grep -q '"error"'; then
      expl=$(es_curl 5 "$(es_base_url)/_cluster/allocation/explain?include_yes_decisions=false" \
        -H 'Content-Type: application/json' -X POST -d "$body" || true)
    fi
    emit "----- allocation/explain ${idx} ${shard} ${pri} -----"
    printf '%s\n' "$expl" | head -c 4000 >> "$ARTIFACT_FILE"
    echo >> "$ARTIFACT_FILE"
    if printf '%s' "$expl" | grep -qiE 'NODE_LEFT|NODE_RESTART'; then
      signal ES052 medium "explain NODE_LEFT ${idx}"
    fi
    if printf '%s' "$expl" | grep -qi 'DECIDERS_NO'; then
      if printf '%s' "$expl" | grep -qiE 'disk|watermark'; then
        signal ES061 high "explain DECIDERS_NO disk ${idx}"
      else
        signal ES062 medium "explain DECIDERS_NO ${idx}"
      fi
    fi
    if printf '%s' "$expl" | grep -qi 'ALLOCATION_FAILED'; then
      signal ES063 high "explain ALLOCATION_FAILED ${idx}"
    fi
  done
fi

if (( n == 0 )); then
  expl=$(es_curl 5 "$(es_base_url)/_cluster/allocation/explain?include_yes_decisions=false" || true)
  emit "----- allocation/explain first-unassigned -----"
  printf '%s\n' "$expl" | head -c 4000 >> "$ARTIFACT_FILE"
  echo >> "$ARTIFACT_FILE"
fi

settings=$(es_curl 8 "$(es_base_url)/_all/_settings?flat_settings=true&filter_path=**.index.blocks*" || true)
emit "----- index.blocks (truncated) -----"
printf '%s\n' "$settings" | head -c 8000 >> "$ARTIFACT_FILE"
echo >> "$ARTIFACT_FILE"
if printf '%s' "$settings" | grep -q 'read_only_allow_delete'; then
  signal ES071 high "index.blocks.read_only_allow_delete present"
  facts_merge '{"read_only_allow_delete": true}'
fi

finish_artifact
exit 0
