# MySQL 一主多从排障

设计稿（5 分钟时间盒、五路采集、交叉对比、AI/启发式）：

[`2026-09-15-mysql-primary-multi-replica-troubleshooting-design.md`](./2026-09-15-mysql-primary-multi-replica-troubleshooting-design.md)

实现脚本尚未落地。流程对齐 `troubleshooting/kafka/`，但 **禁止复用 Kafka 的 600–900s 采集超时**。
