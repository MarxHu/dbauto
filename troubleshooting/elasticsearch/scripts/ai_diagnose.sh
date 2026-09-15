#!/usr/bin/env bash
# AI 诊断：最后一节点。端点空、HTTP 失败、超时、空响应 → 本节点非 0 退出。
# 清洗产物必须已经存在；失败不影响 summary.md。
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
ai_endpoint=${8:-${ES_AI_ENDPOINT:-}}
ES_USER=${9:-${ES_USER:-}}
ES_PASS=${10:-${ES_PASS:-}}

base=$(artifact_dir_for "$run_id")
mkdir -p "$base"
prompt="${base}/ai_prompt.md"
diagnosis="${base}/ai_diagnosis.md"
summary="${base}/summary.md"
cleaned="${base}/cleaned.txt"
signals="${base}/signals.txt"
meta="${base}/cleaned.meta"

coverage=unknown
if [[ -f "$meta" ]]; then
  coverage=$(awk -F= '$1=="coverage_status"{print $2}' "$meta")
fi

catalog_hint() {
  cat <<'EOF'
将根因映射到下列 ES 场景 ID（可多选，按置信度）。禁止编造未出现的指标。
禁止在未满足「三台都采到且都无 master」时写集群没有 master。
ES001 基线
ES010 CPU ES011 内存 ES012 swap ES013 FD ES014 时钟 ES015 磁盘满 ES016 inode ES017 磁盘延迟 ES018 iowait
ES030 进程不在 ES031 9200未监听 ES032 本地HTTP失败 ES033 fatal ES034 heap/OOM ES035 GC ES036 write reject ES037 search reject ES038 breaker ES039 反复重启
ES050 三台均无主 ES051 master视图不一致 ES052 掉1节点 ES053 掉≥2/红无主 ES054 主分片未分配 ES055 delayed ES056 pending tasks ES057 relocating卡住 ES058 allocation.enable ES059 max_shards ES060 cluster.name ES061 DECIDERS_NO disk ES062 DECIDERS_NO filter ES063 ALLOCATION_FAILED
ES070 flood-stage ES071 read_only_allow_delete ES072 high watermark ES073 path.data权限
ES090 ping失败 ES091 9200通9300不通 ES092 9300通9200不通 ES093 重传 ES094 防火墙
ES110 zen.minimum_master_nodes残留 ES111 seed_hosts不全 ES112 Xms≠Xmx ES113 watermark过激 ES114 端口不一致
ES170 预检失败 ES171 工具缺失 ES172 节点不可达 ES173 部分采集失败 ES174 命令超时
ES190 NODE_DOWN_ONE ES191 NO_MASTER ES192 YELLOW_ALLOC_NOT_DOWN ES193 HEAP_ONE_OUTLIER ES194 HEAP_ALL_SIMILAR ES195 REJECT_ONE ES196 REJECT_ALL ES197 FLOOD_ONE ES198 FLOOD_ALL ES199 TRANSPORT_PARTITION
EOF
}

{
  echo "# Elasticsearch 7.x 三节点排障 AI Prompt"
  echo
  echo "你是资深 Elasticsearch SRE。集群为 **7.x 三节点全角色**，默认副本 1，HTTP 9200 / transport 9300。"
  echo "本流程 **只诊断、不变更**：不要建议脚本去 reroute、取消块、重启、等待选举。"
  echo "输出 Markdown："
  echo
  echo "## 根因假设（按置信度）"
  echo "## 关键证据"
  echo "## 影响面（集群可用性 / 写入 / 查询 / 数据风险）"
  echo "## 立即止损（不自动执行）"
  echo "## 验证步骤"
  echo "## 证据缺口（5 分钟未做项）"
  echo
  echo "硬约束：有 ES191 先打选举/发现/传输；有 ES192 禁止写成节点掉了；有 ES193/195/197 禁止写成全集群；有 ES199 必须提 9300。"
  echo
  catalog_hint
  echo
  echo "## 清洗摘要"
  echo
  if [[ -f "$summary" ]]; then
    cat "$summary"
  else
    echo "（无 summary.md，清洗节点可能失败）"
  fi
  echo
  echo "## 去重信号"
  echo
  if [[ -s "$signals" ]]; then
    cat "$signals"
  else
    echo "NO_SIGNALS"
  fi
  echo
  echo "## 清洗正文（截断）"
  echo
  echo '```'
  if [[ -f "$cleaned" ]]; then
    head -c 32000 "$cleaned"
  else
    echo "CLEANED_MISSING"
  fi
  echo
  echo '```'
} > "$prompt"

fail_ai() {
  local reason=$1
  {
    echo "# ES 排障 AI 节点失败"
    echo
    echo "- run_id: \`${run_id}\`"
    echo "- profile: \`${profile}\`"
    echo "- coverage: \`${coverage}\`"
    echo "- reason: \`${reason}\`"
    echo
    echo "清洗节点 \`summary.md\` 仍可展示。本节点按设计失败。"
    echo
    echo "prompt: \`${prompt}\`"
  } > "$diagnosis"
  echo "###ES_TS_AI_DIAGNOSIS run_id=${run_id} ai=fail reason=${reason}###" >&2
  cat "$diagnosis" >&2
  echo "###END_ES_TS_AI_DIAGNOSIS###" >&2
  echo "$reason" >&2
  exit 1
}

if [[ -z "$ai_endpoint" ]]; then
  fail_ai "ai_endpoint_empty"
fi
if ! command -v curl >/dev/null 2>&1; then
  fail_ai "curl_missing"
fi
if [[ ! -f "$summary" ]]; then
  fail_ai "summary_missing"
fi

payload="${base}/ai_request.json"
python3 - "$prompt" "$payload" <<'PY' || fail_ai "payload_build_failed"
import json, sys, pathlib
prompt = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "model": "es-sre",
    "messages": [
        {"role": "system", "content": "You are an Elasticsearch SRE. Reply in Chinese markdown. Diagnose only; do not mutate the cluster."},
        {"role": "user", "content": prompt[:180000]},
    ],
}, ensure_ascii=False), encoding="utf-8")
PY

if ! curl -fsS -m 45 -H 'Content-Type: application/json' -d @"$payload" "$ai_endpoint" \
    > "${base}/ai_raw.json" 2>"${base}/ai_curl.err"; then
  fail_ai "http_error"
fi

if [[ ! -s "${base}/ai_raw.json" ]]; then
  fail_ai "empty_response"
fi

python3 - "${base}/ai_raw.json" "$diagnosis" "$run_id" "$profile" "$coverage" <<'PY' || fail_ai "parse_failed"
import json, sys, pathlib
raw_path, out_path, run_id, profile, coverage = sys.argv[1:6]
raw = pathlib.Path(raw_path).read_text(encoding="utf-8", errors="replace")
text = raw
try:
    data = json.loads(raw)
    if isinstance(data, dict):
        if "choices" in data:
            text = data["choices"][0]["message"]["content"]
        elif "content" in data:
            text = data["content"]
        elif "output" in data:
            text = data["output"]
except Exception:
    pass
text = str(text).strip()
if not text:
    raise SystemExit(2)
body = "\n".join([
    "# ES 排障诊断输出",
    "",
    f"- run_id: `{run_id}`",
    f"- profile: `{profile}`",
    f"- coverage: `{coverage}`",
    f"- ai_endpoint_status: `ok`",
    "",
    text,
    "",
])
pathlib.Path(out_path).write_text(body, encoding="utf-8")
PY

echo "###ES_TS_AI_DIAGNOSIS run_id=${run_id} ai=ok###"
cat "$diagnosis"
echo "###END_ES_TS_AI_DIAGNOSIS###"
exit 0
