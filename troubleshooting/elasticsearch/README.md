# Elasticsearch 7.x 三节点排障

5 分钟排障 Bot：五路采集 → 清洗 Markdown → AI（最后节点，失败则该节点失败）。

- 设计：[`2026-09-15-elasticsearch-717-multi-node-troubleshooting-design.md`](./2026-09-15-elasticsearch-717-multi-node-troubleshooting-design.md)
- SOPS YAML：[`elasticsearch717-troubleshoot.yaml`](./elasticsearch717-troubleshoot.yaml)（`tools/generate_yaml.py` 生成）
- 实验室汇聚：`scripts/run_flow.sh`（SOPS 无共享盘时把三台 `/tmp/es-troubleshoot/<run_id>/` 拉到清洗节点）

采集节点 `ignore_error: true` 且脚本 `exit 0`。**AI 节点不 ignore_error**，端点空或 HTTP 失败则该步失败；`summary.md` 仍可展示。

超时：预检 30s，五路各 120s，清洗 60s，AI 60s。禁止复用 Kafka 的 600–900s。

本目录 **不做故障注入**。

```bash
# 再生 YAML
python3 tools/generate_yaml.py

# 交叉对比单测（不需要 ES）
python3 tools/test_cleanse.py

# 实验室（需能进三节点）
export TS_ARTIFACT_DIR=/tmp/es-troubleshoot
# 先采集+清洗；无 ES_AI_ENDPOINT 时 run_flow 会以 AI 节点失败结束
./scripts/run_flow.sh
```
