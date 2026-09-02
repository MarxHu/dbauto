#!/usr/bin/env bash
# 数据清洗：汇聚五路采集产物、去重信号、截断噪声、输出 cleaned 报告供 AI 节点使用
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_lib.sh"

node1=${1:-}
node2=${2:-}
node3=${3:-}
KAFKA_INSTALL_PREFIX=${4:-/opt/kafka/3.8.1}
kafka_port=${5:-9092}
controller_port=${6:-9093}
run_id=${7:-manual}
profile=${8:-v1}

target_ip=$(resolve_local_ip "$node1" "$node2" "$node3")
base=$(artifact_dir_for "$run_id")
mkdir -p "$base"
cleaned="${base}/cleaned.txt"
signals_all="${base}/signals.tsv"
summary="${base}/summary.md"
: > "$cleaned"
: > "$signals_all"

{
  echo "===== KAFKA_TS cleaned run_id=${run_id} profile=${profile} ts=$(ts_now) node=${target_ip} ====="
  echo "cluster_nodes=${node1},${node2},${node3}"
  echo "ports=${kafka_port}/${controller_port}"
  echo "install_prefix=${KAFKA_INSTALL_PREFIX}"
  echo
} >> "$cleaned"

kinds=(metrics config logs host network)
found=0
missing=()
for kind in "${kinds[@]}"; do
  files=( "${base}/${kind}".*.txt )
  if [[ -e "${files[0]}" ]]; then
    found=$((found + 1))
    echo "----- kind=${kind} files=${#files[@]} -----" >> "$cleaned"
    for f in "${files[@]}"; do
      echo "### file=$(basename "$f") ###" >> "$cleaned"
      # cap each artifact to avoid blowing the AI context
      tail -n 400 "$f" >> "$cleaned"
      echo >> "$cleaned"
    done
  else
    missing+=("$kind")
    echo "MISSING_KIND ${kind}" >> "$cleaned"
  fi
  sigs=( "${base}/${kind}".*.signals )
  if [[ -e "${sigs[0]}" ]]; then
    cat "${sigs[@]}" >> "$signals_all"
  fi
done

# Dedup signals: id + first note
sorted="${base}/signals.uniq.tsv"
if [[ -s "$signals_all" ]]; then
  awk -F'\t' '
    NF>=3 {
      id=$1; sev=$2; note=$3
      key=id
      if (!(key in seen)) { seen[key]=1; sev_keep[key]=sev; note_keep[key]=note; order[++n]=key }
      if (sev=="high") sev_keep[key]="high"
    }
    END {
      for (i=1;i<=n;i++) {
        k=order[i]
        print k "\t" sev_keep[k] "\t" note_keep[k]
      }
    }
  ' "$signals_all" > "$sorted"
else
  : > "$sorted"
fi

high_n=$(awk -F'\t' '$2=="high"{c++} END{print c+0}' "$sorted")
med_n=$(awk -F'\t' '$2=="medium"{c++} END{print c+0}' "$sorted")
low_n=$(awk -F'\t' '$2=="low"{c++} END{print c+0}' "$sorted")
sig_n=$(wc -l < "$sorted" | tr -d ' ')

{
  echo "----- SIGNAL_SUMMARY count=${sig_n} high=${high_n} medium=${med_n} low=${low_n} -----"
  if [[ -s "$sorted" ]]; then
    cat "$sorted"
  else
    echo "NO_SIGNALS"
  fi
  echo
  echo "----- COVERAGE kinds_found=${found}/5 missing=${missing[*]:-none} -----"
} >> "$cleaned"

coverage_status=ok
if (( found == 0 )); then
  coverage_status=empty
elif (( found < 3 )); then
  coverage_status=degraded
fi
echo "coverage_status=${coverage_status}" >> "$cleaned"

# Candidate ranking: high signals first
{
  echo "# Kafka 排障清洗摘要"
  echo
  echo "- run_id: \`${run_id}\`"
  echo "- profile: \`${profile}\`"
  echo "- 采集覆盖: ${found}/5 (${coverage_status})"
  echo "- 信号: ${sig_n} (high=${high_n}, medium=${med_n}, low=${low_n})"
  echo
  echo "## 优先信号"
  echo
  if [[ -s "$sorted" ]]; then
    echo "| ID | 级别 | 说明 |"
    echo "|----|------|------|"
    awk -F'\t' '{printf "| %s | %s | %s |\n", $1, $2, $3}' "$sorted"
  else
    echo "无自动信号。请结合原文日志由 AI 做开放式诊断。"
  fi
  echo
  echo "## 缺失采集"
  echo
  if ((${#missing[@]})); then
    printf -- "- %s\n" "${missing[@]}"
  else
    echo "- 无"
  fi
} > "$summary"

# machine-readable pointer file
cat > "${base}/cleaned.meta" <<EOF
run_id=${run_id}
profile=${profile}
coverage_status=${coverage_status}
kinds_found=${found}
signal_count=${sig_n}
high=${high_n}
medium=${med_n}
low=${low_n}
cleaned=${cleaned}
summary=${summary}
signals=${sorted}
EOF

echo "###KAFKA_TS_CLEANSED run_id=${run_id} coverage=${coverage_status} signals=${sig_n}###"
cat "$summary"
echo "###KAFKA_TS_CLEANSED_BODY###"
# keep AI payload bounded
head -c 180000 "$cleaned"
echo
echo "###END_KAFKA_TS_CLEANSED###"
exit 0
