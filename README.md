# dbauto

数据库自动化仓库。当前 `main` 含 Redis Cluster 部署；Kafka 排障与故障注入在特性分支交付：

| 目录 | 内容 |
|------|------|
| `troubleshooting/kafka/` | Kafka 排障 SOPS YAML（五路采集 → 清洗 → AI）、故障场景总表 |
| `kafka_fault_injection/` | Kafka 故障注入脚本与命令表 |
| `deployments/数据库部署脚本/` | Redis/Kafka 部署 YAML 与脚本 |
