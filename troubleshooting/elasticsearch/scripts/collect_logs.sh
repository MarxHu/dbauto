#!/usr/bin/env bash
# L 日志：tail 最近 8000 行 + 关键字映射到 ES ID。不 cat 全文。
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
log_dir=${9:-}
window_lines=${10:-8000}
export ES_HTTP_PORT ES_USER ES_PASS

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
begin_artifact logs "$target_ip" "$run_id"
emit "collector=logs window=${window_lines}"

if [[ -z "$log_dir" || ! -d "$log_dir" ]]; then
  for alt in /var/log/elasticsearch /opt/elasticsearch/logs /usr/share/elasticsearch/logs; do
    [[ -d "$alt" ]] && log_dir=$alt && break
  done
fi
emit "log_dir=${log_dir:-MISSING}"
if [[ -z "$log_dir" || ! -d "$log_dir" ]]; then
  signal ES171 low "elasticsearch log dir missing"
  finish_artifact
  exit 0
fi

emit "----- log dir listing -----"
ls -lah "$log_dir" >> "$ARTIFACT_FILE" 2>&1 || true

logfile=""
# newest .log excluding gc
logfile=$(ls -1t "$log_dir"/*.log 2>/dev/null | grep -v gc | head -n1 || true)
emit "resolved_log=${logfile:-MISSING}"
if [[ -n "$logfile" ]]; then
  emit "----- tail ${window_lines} ${logfile} keywords -----"
  hits=$(tail -n "$window_lines" "$logfile" 2>/dev/null | grep -Ei \
    'master not discovered|have not received|master_not_discovered_exception|failed to send join request|join validation|circuit_breaking_exception|Data too large|rejected execution|queue capacity|flood stage|exceeded flood-stage|read_only_allow_delete|index read-only|high disk watermark|low disk watermark|OutOfMemoryError|Java heap space|failed to ping|handshake failed|TranslogCorrupted|corrupt' \
    | tail -n 80 || true)
  if [[ -n "$hits" ]]; then
    emit "$hits"
    printf '%s\n' "$hits" | while IFS= read -r line; do
      case "$line" in
        *"master not discovered"*|*"master_not_discovered"*|*"have not received"*) signal ES050 medium "log master_not_discovered" ;;
        *"failed to send join request"*|*"join validation"*) signal ES051 medium "log join failed" ;;
        *"circuit_breaking_exception"*|*"Data too large"*) signal ES038 high "log circuit breaker" ;;
        *"rejected execution"*|*"queue capacity"*) signal ES036 medium "log rejected execution" ;;
        *"flood stage"*|*"exceeded flood-stage"*) signal ES070 high "log flood stage" ;;
        *"read_only_allow_delete"*|*"index read-only"*) signal ES071 high "log read_only block" ;;
        *"high disk watermark"*|*"low disk watermark"*) signal ES072 medium "log disk watermark" ;;
        *"OutOfMemoryError"*|*"Java heap space"*) signal ES034 high "log OOM" ;;
        *"failed to ping"*|*"handshake failed"*) signal ES091 medium "log transport ping/handshake" ;;
        *corrupt*|*TranslogCorrupted*) signal ES063 high "log corruption" ;;
      esac
    done
  else
    emit "KEYWORD_NONE"
  fi
fi

gc=$(ls -1t "$log_dir"/gc.log* 2>/dev/null | head -n1 || true)
if [[ -n "$gc" ]]; then
  emit "----- gc.log pause summary ${gc} -----"
  # G1/CMS pause lines; count and max
  python3 - "$gc" <<'PY' >> "$ARTIFACT_FILE" 2>&1 || true
import re,sys
path=sys.argv[1]
pauses=[]
try:
    # last ~4000 lines
    lines=open(path, errors="replace").read().splitlines()[-4000:]
except Exception as e:
    print("GC_READ_FAIL", e)
    raise SystemExit(0)
for ln in lines:
    m=re.search(r"([0-9]+[.,][0-9]+)ms", ln) or re.search(r"pause[ =]+([0-9.]+)", ln, re.I)
    if m:
        try:
            pauses.append(float(m.group(1).replace(",", ".")))
        except ValueError:
            pass
print("gc_pause_samples=%d max_ms=%s avg_ms=%s" % (
    len(pauses),
    ("%.1f" % max(pauses)) if pauses else "NA",
    ("%.1f" % (sum(pauses)/len(pauses))) if pauses else "NA",
))
PY
fi

finish_artifact
exit 0
