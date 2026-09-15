# MySQL 一主多从故障注入

> 仓库：**https://github.com/MarxHu/dbauto**  
> **全部故障场景清单**：[`MYSQL_FAULT_SCENARIOS.md`](./MYSQL_FAULT_SCENARIOS.md)  
> **方案**：[`FAULT_INJECTION_PLAN.md`](./FAULT_INJECTION_PLAN.md)  
> **对照 Redis**：`redis_fault_injection/REDIS_FAULT_SCENARIOS.md`（3 主 0 从 Cluster）

## 1. 这套东西是什么

| 项目 | 说明 |
|---|---|
| **交付物（本目录）** | 场景全表 + CLI 契约 + 环境前提；脚本按方案 P0–P3 落地 |
| **验收范围** | 只验收**故障是否被成功注入** |
| **不包含** | SOPS 排障、五路采集、AI（`troubleshooting/mysql/`） |
| **运行位置** | 注入 Bot 跑在 **注入机**（Docker 实验室 = `docker-node`） |
| **故障路径** | 主机/网络/磁盘 → `docker exec`；MySQL/复制 → Bot 上 `mysql` 客户端 |

拓扑（实验室默认）：

```text
注入机 10.10.26.10
  mysql-n1 10.10.26.144:3306  PRIMARY
  mysql-n2 10.10.26.145:3306  REPLICA
  mysql-n3 10.10.26.146:3306  REPLICA
```

SOPS 交付 IP 为 `172.30.0.11/12/13`，场景 ID 相同，换 `config.env` 即可。

## 2. 和 Redis 注入的关系

- **可直接复用手法**：CPU / 内存 / 重启 / 丢包 / 磁盘 IO / 进程停 / 连接打满 / 作业不可达 / 藏工具。  
- **Redis 做不了、MySQL 必须做**：停 IO、停 SQL、全员 vs 单从、半同步等 ACK、binlog purge、从库误写 1062。  
- **不要做**：冷缓存/穿透、MOVED/CROSSSLOT、Cluster Bus 16379、自动 Failover（本拓扑没有）。

完整对照表见场景全表第 10 节。

## 3. 怎么用（脚本落地后）

```bash
cp config.env.example config.env   # 填密码与节点
./scripts/preflight.sh             # 必须 FAIL=0
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600
./scripts/inject_repl.sh --action stop-sql --scope one --node 10.10.26.145:3306 --duration 600
```

Bot 解析：`grep INJECT_RESULT` → `status=pass|fail`。

当前仓库 **CLI 已冻结、脚本待 P0 PR**。校验场景 ID 是否自洽：

```bash
python3 mysql_fault_injection/tools/validate_catalog.py
```

## 4. 目录

```
mysql_fault_injection/
├── README.md
├── MYSQL_FAULT_SCENARIOS.md   ← 全部场景（注入方式 / 命令契约 / Redis 对照）
├── FAULT_INJECTION_PLAN.md
├── PREREQUISITES.md
├── SCENARIOS.md
├── config.env.example
└── tools/validate_catalog.py
```

## 5. 敏感信息

`config.env` 含密码，**不提交 Git**。只提交 `config.env.example`。
