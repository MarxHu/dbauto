# MySQL 一主多从排障

- **故障注入场景全表**（怎么注入、Redis 对照、CLI 契约）：[`../../mysql_fault_injection/MYSQL_FAULT_SCENARIOS.md`](../../mysql_fault_injection/MYSQL_FAULT_SCENARIOS.md)
- **排障 ID ↔ 采集路 ↔ 能否注入**：[`MYSQL_FAULT_SCENARIOS.md`](./MYSQL_FAULT_SCENARIOS.md)
- **5 分钟排障流程设计**（五路采集、交叉对比、时间盒）：分支 `cursor/mysql-primary-replica-ts-design-44dd`

实现采集脚本尚未落地。流程对齐 `troubleshooting/kafka/`，但 **禁止复用 Kafka 的 600–900s 采集超时**。
