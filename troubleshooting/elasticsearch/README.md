# Elasticsearch 7.x 三节点排障

设计稿（5 分钟时间盒、五路采集、三台交叉认 master、清洗 Markdown、AI 为最后节点）：

[`2026-09-15-elasticsearch-717-multi-node-troubleshooting-design.md`](./2026-09-15-elasticsearch-717-multi-node-troubleshooting-design.md)

实现脚本尚未落地。流程对齐 `troubleshooting/mysql/` 与 `troubleshooting/kafka/`，但 **禁止复用 Kafka 的 600–900s 采集超时**。

本目录 **不做故障注入**。AI 异常时该节点失败；清洗节点的 `summary.md` 仍用于展示采集与交叉对比结果。
