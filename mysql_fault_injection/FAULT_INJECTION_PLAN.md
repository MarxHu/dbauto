# MySQL 一主多从完整故障注入方案

> 仓库：`mysql_fault_injection/`  
> **验收范围**：只验收故障是否成功注入（现象、持续、自动恢复）。  
> **不包含**：SOPS / 五路采集 / AI 诊断（见 `troubleshooting/mysql/`）。  
> **场景全表**：[`MYSQL_FAULT_SCENARIOS.md`](./MYSQL_FAULT_SCENARIOS.md)

---

## 1. 目标与原则

对齐 Redis Cluster 注入（`redis_fault_injection/`）和 Kafka KRaft 注入（`kafka_fault_injection/`）：同一套 Bot 模型、同一套 `INJECT_RESULT`、同一套 flock / duration / docker exec。

| 项 | 约定 |
|---|---|
| 交付物 | 场景清单（本 PR）→ Shell 脚本 + preflight + lab 规范（后续 PR） |
| 运行位置 | **注入 Bot 只在注入机**（Docker 实验室 = `docker-node`） |
| 故障对象 | Docker 容器模拟 VM（容器内 mysqld）；或 SOPS 节点 SSH |
| 主机类故障 | `docker exec` → 容器（`--target-host` / `--target-container`） |
| MySQL / 复制类 | Bot 侧 `mysql` 客户端 → `MYSQL_NODES` |
| 互斥 | 同一时刻只跑一个 inject（`flock`）；组合内部 skip lock |
| 持续 | 默认 `--duration 600`，到期自动恢复 |
| 解析 | `INJECT_RESULT scenario=<MY id> status=pass\|fail detail=...` |
| 8.0 / 8.4 | 注入 SQL 双写关键字，命中即用 |

### 1.1 相对 Redis 必须改的三条

1. **复制是一等公民**。Redis 实验室是 3 主 0 从，目录明确「复制中断不适用」。MySQL 一主两从要把 IO/SQL 独立停、全员 vs 单从、binlog purge、从库误写做成默认场景。  
2. **主和从不是对等角色**。同样 `stress-ng` / `dd`，打主 → 两从延迟同类（MY194）；打一台从 → 离群（MY195）。脚本默认目标不能是「第一个节点」。  
3. **半同步 wait_count=1**。只隔离一台从 **不会** 卡住主库写入。MY102 必须拖住全部 ACK 从，或临时把 wait_count 调到 2。

---

## 2. 实验室拓扑

### 2.1 Docker 模拟 VM（与 Redis/Kafka 同网段）

```text
docker-node (10.10.26.10)  注入机
  ├── mysql 客户端 → 144/145/146:3306
  └── docker exec → mysql-n1 / n2 / n3

mysql-n1  10.10.26.144:3306   PRIMARY   server_id=11   mem_limit 1536m   NET_ADMIN
mysql-n2  10.10.26.145:3306   REPLICA   server_id=12   mem_limit 1536m   NET_ADMIN
mysql-n3  10.10.26.146:3306   REPLICA   server_id=13   mem_limit 1536m   NET_ADMIN
GTID ON，半同步 wait_for_replica_count=1，timeout=10s
datadir 建议 /var/lib/mysql ，非 tmpfs
```

### 2.2 SOPS 交付对照

`deployments/数据库部署脚本/output/mysql84-gtid-primary-replicas-3node-083102.yaml`：

| IP | 角色 | server_id |
|---|---|---|
| 172.30.0.11 | primary | 11 |
| 172.30.0.12 | replica | 12 |
| 172.30.0.13 | replica | 13 |

`INJECT_BACKEND=ssh` 时用这组 IP；场景 ID 不变。

### 2.3 必装工具

| 节点 | 必装 |
|---|---|
| **注入机** | `bash`≥4、`flock`、`mysql` 客户端、`docker` CLI（docker 后端） |
| **mysql-n1/n2/n3** | `stress-ng`、`vmstat`、`chmod`、`dd`、`iptables`、`tc`、`iostat`、`mysqld` |

### 2.4 配置（`config.env`，gitignore）

见 [`config.env.example`](./config.env.example)。

---

## 3. 脚本架构（落地时）

| 脚本 | 职责 | Redis 对照 |
|---|---|---|
| `scripts/preflight.sh` | 三节点可达、角色识别、复制 ON、半同步、工具 | `preflight.sh` |
| `scripts/inject_host.sh` | CPU/内存/重启/时钟/基线 | 同名，几乎可复用 |
| `scripts/inject_mysql.sh` | 进程/连接/慢 SQL/热行/长事务 | `inject_redis.sh` |
| `scripts/inject_repl.sh` | IO/SQL 停、purge、1062、半同步、GTID | **新增** |
| `scripts/inject_network.sh` | 3306 Dump 阻断、丢包、延迟、限速、分区 | Bus→3306 |
| `scripts/inject_disk.sh` | 磁盘满/只读/IO/inode | 同名，路径改 datadir |
| `scripts/inject_composite.sh` | MY196–MY199、C01–C03 | 同名 |
| `scripts/inject_degrade.sh` | 采集降级 | 同名，端口 3306 |
| `lib/common.sh` | 锁、docker exec、mysql 封装、post-check、`INJECT_RESULT` | 同名 |
| `run.sh` | `./run.sh repl --action stop-sql ...` | 同名 |

本 PR **先冻结 CLI 与场景 ID**，脚本在实验室节点就绪后按第 6 节顺序实现。禁止先写 YAML 再补注入：Kafka v1 的缺口就是「流程有了、定责信号没有」；注入侧同样禁止空壳 action。

---

## 4. 角色识别（注入前必做）

不要信任部署 YAML 的静态 `host.role`。每条复制类注入先跑：

```sql
SELECT @@global.read_only, @@global.super_read_only, @@global.server_id;
-- 8.4 优先
SELECT SERVICE_STATE FROM performance_schema.replication_connection_status LIMIT 1;
SELECT SERVICE_STATE FROM performance_schema.replication_applier_status_by_coordinator LIMIT 1;
```

| 判定 | 角色 |
|---|---|
| 无复制通道且 `read_only=0` | primary |
| 有复制通道 | replica |
| 冲突 | 中止注入，emit fail `MY048` |

---

## 5. Post-check 要点

| 场景 | 条件 |
|---|---|
| MY001 baseline | 三节点 `SELECT 1`；两从 IO/SQL ON；`GTID_SUBSET(RECEIVED, gtid_executed)=1` |
| MY010 cpu | vmstat 平均 CPU ≥80%（跳过 since-boot 行） |
| MY011 memory | cgroup 可用 ≤15% 或已用 ≥85% |
| MY030 process-stop | 5s 内 ≥3s `SELECT 1` 失败 |
| MY040 stop-io `--scope one` | **仅**目标从 IO≠ON，另一从仍 ON |
| MY041 stop-sql `--scope one` | 目标 SQL≠ON 且 IO 仍 ON |
| MY102 semi-sync-wait-ack | `wait_sessions>0` 或 `no_tx` 升 **且** 不是「只隔离一台、wait_count=1」 |
| MY140 packet-loss | `tc qdisc show` 含 netem loss |
| MY162 io-stress | datadir 下 `fault_io` 正在写 |
| MY194/MY195 | 组合场景才强制；单场景只验本机注入成功 |

失败也要尽量 `INJECT_RESULT status=fail`（`inject_begin` trap），禁止无行退出。

---

## 6. 实现顺序

| 批次 | 内容 | 原因 |
|---|---|---|
| **本 PR** | 场景全表 + 方案 + 契约 + catalog 校验 | 先对齐 Redis 目录，避免脚本 action 名漂移 |
| P0 脚本 | preflight、host（cpu/memory/baseline）、mysql process-stop、repl stop-io/stop-sql、disk io-stress、degrade hide-tools | 排障 §14.2 最小故障集 |
| P1 | 半同步 wait-ack（含 wait_count 分支）、long-trx、packet-loss、repl-block `--scope one\|all` | 一主多从交叉对比 |
| P2 | binlog-purge / replica-1062（`--confirm YES`）、disk-full、组合 MY196–MY199 | 破坏性放后面 |
| P3 | freeze、clock-skew、inode、rate-limit、gtid-skip | 增强，非最小集 |

---

## 7. 时序（与排障 Bot）

```text
T0     注入 Bot: inject_*.sh --duration 600
T0+    见 INJECT_RESULT status=pass 后 → 排障 Bot 触发（故障仍持续）
T600   注入到期 auto-recover
T600+  可选 baseline；PURGE/1062/gtid-skip 先重建从库再 F01
```

硬规则：

1. 同时只跑一个 inject（组合除外）。  
2. 禁止中途 kill 注入进程（避免无 `INJECT_RESULT`）。  
3. MY046 / MY130 / MY132 测完必须重建从库再跑 baseline。  
4. 只在注入机跑脚本。

---

## 8. 一句话总览

**在注入机上**：preflight → 按全表逐场景注入 → 解析 `INJECT_RESULT` → 故障窗口内由排障 Bot 独立采集 → duration 到期自动恢复。主机/网络/磁盘复用 Redis 手法；**增量全在复制线程、半同步 ACK、全员 vs 单从对照**。
