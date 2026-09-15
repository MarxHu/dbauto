#!/usr/bin/env bash
# 数据清洗：三台交叉认 master、ALL/ONE 组合信号、写出 summary.md。禁止调模型。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
_http=${4:-9200}
_transport=${5:-9300}
run_id=${6:-manual}
profile=${7:-v1}
ES_USER=${8:-${ES_USER:-}}
ES_PASS=${9:-${ES_PASS:-}}

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
base=$(artifact_dir_for "$run_id")
mkdir -p "$base"

py=$(es_lib_py) || {
  echo "es_lib.py missing" >&2
  echo "###ES_TS_CLEANSED run_id=${run_id} coverage=empty signals=0###"
  echo "# ES 7.x 三节点排查摘要"
  echo
  echo "- es_lib.py missing on $(hostname)"
  echo "###END_ES_TS_CLEANSED###"
  exit 0
}

export TS_PROFILE=$profile
python3 "$py" cleanse "$base" "$run_id" "$node1" "$node2" "$node3" >"${base}/cleanse.meta.json" 2>"${base}/cleanse.err" || true

coverage=unknown
if [[ -f "${base}/cleaned.meta" ]]; then
  coverage=$(awk -F= '$1=="coverage_status"{print $2}' "${base}/cleaned.meta")
fi
sig_n=0
if [[ -f "${base}/signals.txt" ]]; then
  sig_n=$(grep -c '^ES' "${base}/signals.txt" 2>/dev/null || echo 0)
fi

echo "###ES_TS_CLEANSED run_id=${run_id} coverage=${coverage} signals=${sig_n} node=${target_ip}###"
if [[ -f "${base}/summary.md" ]]; then
  cat "${base}/summary.md"
else
  echo "# ES 7.x 三节点排查摘要"
  echo
  echo "- cleanse failed to write summary.md"
  echo "- stderr: $(head -c 500 "${base}/cleanse.err" 2>/dev/null || true)"
fi
echo "###END_ES_TS_CLEANSED###"
exit 0
