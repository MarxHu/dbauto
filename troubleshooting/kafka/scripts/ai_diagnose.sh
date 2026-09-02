#!/usr/bin/env bash
# AI 诊断节点：读取清洗产物，组装 SRE prompt；若配置了 AI 端点则调用，否则输出启发式诊断 + 完整 prompt
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
KAFKA_INSTALL_PREFIX=${4:-/opt/kafka/3.8.1}
kafka_port=${5:-9092}
_controller_port=${6:-9093}
run_id=${7:-manual}
profile=${8:-v1}
ai_endpoint=${9:-${KAFKA_AI_ENDPOINT:-}}

base=$(artifact_dir_for "$run_id")
mkdir -p "$base"
prompt="${base}/ai_prompt.md"
diagnosis="${base}/ai_diagnosis.md"
heuristic="${base}/heuristic_diagnosis.md"
summary="${base}/summary.md"
cleaned="${base}/cleaned.txt"
signals="${base}/signals.uniq.tsv"
meta="${base}/cleaned.meta"

coverage=unknown
if [[ -f "$meta" ]]; then
  coverage=$(awk -F= '$1=="coverage_status"{print $2}' "$meta")
fi

catalog_hint() {
  cat <<'EOF'
你必须尽量把根因映射到下列 Kafka 故障场景 ID（可多选，按置信度排序）：
KF001 基线正常
KF002 CPU高压  KF003 CPU尖峰  KF004 内存压力  KF005 OOM killer  KF006 主机重启
KF007 多节点CPU  KF009 Swap  KF010 时钟偏移  KF011 FD耗尽  KF012 inode耗尽  KF013 DNS失败  KF014 ulimit过小
KF015 Broker进程停止  KF016 SIGSTOP挂起  KF017 JVM OOM  KF018 长GC  KF021 systemd反复重启  KF022 fd泄漏  KF023 错误堆参数  KF024 启动/配置失败
KF025 单Controller失联  KF026 法定人数丢失  KF027 元数据损坏  KF028 cluster.id不匹配  KF029 node.id冲突  KF031 Controller选举风暴  KF033 voters不一致
KF036 URP  KF037 Offline分区  KF038 Leader不可用  KF039 ISR收缩  KF040 副本落后  KF041 首选副本倾斜  KF043 RF>存活broker  KF044 min.isr>ISR  KF045 unclean leader  KF046 无Leader  KF047 热点分区  KF050 未知Topic  KF051 自动建主题关闭
KF052 生产超时  KF053 NotEnoughReplicas  KF055 消息过大  KF056 acks=all阻塞  KF060 ProduceQuota
KF061 重平衡风暴  KF062 消费lag  KF063 OffsetOutOfRange  KF064 Coordinator不可用
KF071 9092阻断  KF072 9093阻断  KF073 Broker分区  KF074 客户端隔离  KF075 丢包  KF076 延迟抖动  KF077 限速  KF078 advertised错误  KF079 防火墙
KF083 磁盘满  KF084 只读权限  KF085 IO饱和  KF087 日志损坏  KF093 fsync超时
KF094 SASL失败  KF095 ACL拒绝  KF097 连接打满  KF099 配额
KF101 min.isr>=RF  KF102 RF=1  KF106 unclean.enable  KF109 listener错误  KF110 保留过短
KF111 磁盘满+CPU  KF112 网络分区+ISR  KF113 Broker停+远端内存  KF114 GC+重平衡  KF115 Controller失联+URP  KF116 IO+生产超时
KF117 采集机不通  KF118 采集工具缺失  KF119 JMX/工具不可用  KF120 部分节点采集失败
EOF
}

{
  echo "# Kafka KRaft 排障 AI Prompt"
  echo
  echo "你是资深 Kafka SRE。集群为 **KRaft 三节点（broker+controller 合一）**，默认 RF=3、min.insync.replicas=2，PLAINTEXT 9092 / CONTROLLER 9093。"
  echo "任务：根据清洗后的采集证据，给出：**根因假设（按置信度）**、**对应场景 ID**、**关键证据**、**影响面**、**立即止损建议**、**验证步骤**、**仍缺的数据**。"
  echo "不要编造未出现的指标。若采集覆盖不足，明确说降级诊断。"
  echo
  catalog_hint
  echo
  echo "## 清洗摘要"
  echo
  if [[ -f "$summary" ]]; then
    cat "$summary"
  else
    echo "（无 summary，清洗节点可能失败）"
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
    head -c 120000 "$cleaned"
  else
    echo "CLEANED_MISSING"
  fi
  echo
  echo '```'
} > "$prompt"

# Heuristic ranking from signals
{
  echo "# 启发式诊断（规则引擎，供 AI 对照，不替代模型）"
  echo
  echo "- coverage: ${coverage}"
  echo "- profile: ${profile}"
  echo
  if [[ ! -s "$signals" ]]; then
    if [[ "$coverage" == "empty" || "$coverage" == "degraded" ]]; then
      echo "## 结论"
      echo
      echo "采集不足，优先怀疑 **KF117/KF118/KF120**（采集降级），不要过早下 Kafka 内部根因结论。"
    else
      echo "## 结论"
      echo
      echo "无自动信号。可能为 **KF001 基线正常**，或故障未落入关键字。请 AI 通读日志做开放诊断。"
    fi
  else
    echo "## 信号推导出的候选"
    echo
    echo "| 优先级 | 场景 | 依据 |"
    echo "|--------|------|------|"
    rank=1
    while IFS=$'\t' read -r id sev note; do
      [[ -z "$id" ]] && continue
      printf "| %s | %s (%s) | %s |\n" "$rank" "$id" "$sev" "$note"
      rank=$((rank + 1))
      if (( rank > 8 )); then
        break
      fi
    done < "$signals"
    echo
    echo "## 组合规则"
    echo
    ids=$(awk -F'\t' '{print $1}' "$signals" | tr '\n' ' ')
    echo "- 信号集合: ${ids}"
    if [[ "$ids" == *KF083* && "$ids" == *KF002* ]]; then
      echo "- 命中组合 **KF111**（磁盘满+CPU）"
    fi
    if [[ "$ids" == *KF073* && ( "$ids" == *KF036* || "$ids" == *KF039* ) ]]; then
      echo "- 命中组合 **KF112**（网络分区+ISR）"
    fi
    if [[ "$ids" == *KF015* && "$ids" == *KF004* ]]; then
      echo "- 命中组合 **KF113**（Broker 停 + 内存压）"
    fi
    if [[ "$ids" == *KF018* && "$ids" == *KF061* ]]; then
      echo "- 命中组合 **KF114**（GC+重平衡）"
    fi
    if [[ "$ids" == *KF025* && "$ids" == *KF036* ]]; then
      echo "- 命中组合 **KF115**（Controller 失联+URP）"
    fi
    if [[ "$ids" == *KF085* && "$ids" == *KF052* ]]; then
      echo "- 命中组合 **KF116**（IO+生产超时）"
    fi
    if [[ "$ids" == *KF026* ]]; then
      echo "- **P1**：KRaft 法定人数风险，先恢复 Controller 连通与进程，再谈分区副本。"
    fi
    if [[ "$ids" == *KF083* ]]; then
      echo "- **P1**：log.dirs 空间，先扩容/清日志段，生产会 NotEnoughReplicas 或离线。"
    fi
  fi
  echo
  echo "## 建议止损检查单"
  echo
  echo "1. 三节点 \`systemctl is-active kafka\` 与 \`ss -lnt | grep -E '9092|9093'\`"
  echo "2. \`kafka-metadata-quorum.sh --bootstrap-server ${node1}:${kafka_port} describe --status\`"
  echo "3. \`kafka-topics.sh --describe --under-replicated-partitions / --unavailable-partitions\`"
  echo "4. \`df -h /var/lib/kafka/data\` 与 \`free -h\` / load"
  echo "5. 最近变更：配置、扩缩容、流量、磁盘、网络策略"
} > "$heuristic"

ai_status=skipped
ai_body=""
if [[ -n "$ai_endpoint" ]]; then
  payload="${base}/ai_request.json"
  python3 - "$prompt" "$payload" <<'PY' 2>/dev/null || true
import json, sys, pathlib
prompt = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "model": "kafka-sre",
    "messages": [
        {"role": "system", "content": "You are a Kafka SRE. Reply in Chinese markdown."},
        {"role": "user", "content": prompt[:180000]},
    ],
}, ensure_ascii=False), encoding="utf-8")
PY
  if [[ -f "$payload" ]] && command -v curl >/dev/null 2>&1; then
    if curl -fsS -m 60 -H 'Content-Type: application/json' -d @"$payload" "$ai_endpoint" > "${base}/ai_raw.json" 2>"${base}/ai_curl.err"; then
      ai_status=ok
      ai_body=$(head -c 80000 "${base}/ai_raw.json")
    else
      ai_status=fail
      ai_body=$(head -c 4000 "${base}/ai_curl.err" 2>/dev/null || echo curl_failed)
    fi
  else
    ai_status=no_curl_or_payload
  fi
fi

{
  echo "# Kafka 排障诊断输出"
  echo
  echo "- run_id: \`${run_id}\`"
  echo "- profile: \`${profile}\`"
  echo "- coverage: \`${coverage}\`"
  echo "- ai_endpoint_status: \`${ai_status}\`"
  echo
  cat "$heuristic"
  echo
  echo "## AI 模型输出"
  echo
  if [[ "$ai_status" == "ok" ]]; then
    echo '```'
    printf '%s\n' "$ai_body"
    echo '```'
  else
    echo "未调用在线模型（status=${ai_status}）。把 \`${prompt}\` 交给 LLM 节点即可。"
    echo
    echo "编排侧可将本节点替换为原生 \`ai_diagnose\` 组件，输入文件："
    echo
    echo "- prompt: \`${prompt}\`"
    echo "- cleaned: \`${cleaned}\`"
  fi
} > "$diagnosis"

echo "###KAFKA_TS_AI_DIAGNOSIS run_id=${run_id} ai=${ai_status}###"
cat "$diagnosis"
echo "###END_KAFKA_TS_AI_DIAGNOSIS###"
exit 0
