# MySQL 一主多从故障注入场景全表

> **仓库路径**：`mysql_fault_injection/MYSQL_FAULT_SCENARIOS.md`  
> **对照 Redis**：[`redis_fault_injection/REDIS_FAULT_SCENARIOS.md`](https://github.com/MarxHu/dbauto/blob/cursor/redis-fault-injection-catalog-eccc/redis_fault_injection/REDIS_FAULT_SCENARIOS.md)（3 主 0 从 Cluster）  
> **配套方案**：[`FAULT_INJECTION_PLAN.md`](./FAULT_INJECTION_PLAN.md)  
> **排障 ID**：与 `troubleshooting/mysql/` 共用 `MY*`（清洗 / AI / 注入同一套）  
> **拓扑基线**：MySQL 8.0 / 8.4，GTID 一主两从，默认半同步 `wait_for_replica_count=1`、`timeout=10s`

本文是 **全部可注入场景** 的单一清单：每个场景怎么注入、打在主还是从、Redis 有没有对应项、post-check、恢复。  
**验收只看故障是否注入成功**；排障 Bot 独立（五路采集不在本文）。

脚本已落地：`scripts/inject_*.sh` + `run.sh`。无实验室时可 `INJECT_DRY_RUN=1 ./tools/test_scripts.sh` 做 CLI 自测；真实注入仍需 mysqld 拓扑。

---

## 0. 使用约定

| 项 | 说明 |
|---|---|
| 执行位置 | 仅注入机（Docker 实验室 = `docker-node`） |
| 实验室拓扑 | `mysql-n1`=`10.10.26.144:3306` **主**，`mysql-n2`=`145` **从**，`mysql-n3`=`146` **从**；注入机 `10.10.26.10` |
| SOPS 对照 | `172.30.0.11` 主 + `.12` / `.13` 从（`mysql84-gtid-primary-replicas-3node`） |
| 主机类故障 | `docker exec`（`--target-host` IP 或 `--target-container` 名）；`INJECT_BACKEND=ssh` 时走 SSH |
| MySQL / 复制类 | 注入机 `mysql` 客户端连 `3306`（8.0/8.4 语句双写，优先 `REPLICA` / `rpl_semi_sync_source`） |
| 默认持续 | `--duration 600`（10 分钟），到期自动恢复（重启 / PURGE / 数据分叉类除外） |
| 互斥 | 同时只跑一个 inject（`flock`）；组合内部 skip lock |
| Bot 解析 | `INJECT_RESULT scenario=<MY id> status=pass\|fail detail=...` |
| 跑前 | `./scripts/preflight.sh`（必须 FAIL=0） |
| 8.0 / 8.4 | 注入 SQL 两种关键字都试；文档只写 8.4 名，括号内为 8.0 别名 |

统一入口示例：

```bash
./run.sh host --action cpu --target-host 10.10.26.144 --duration 600
./run.sh mysql --action process-stop --node 10.10.26.145:3306 --duration 600
./run.sh repl --action stop-sql --scope one --node 10.10.26.145:3306 --duration 600
```

**一主多从相对 Redis Cluster（3 主 0 从）的增量**：Redis 目录第 7 节写明「复制中断 / 自动 Failover」当前环境不适用。MySQL **能做复制中断、全员 vs 单从对照、半同步拖主库**；本拓扑 **没有** Orchestrator / MHA / Group Replication，自动 Failover 仍不做。

---

## 1. 主机资源 — `scripts/inject_host.sh`（几乎 1:1 复用 Redis）

对主、对从现象不同，必须带 `--target-host`，禁止默认打到「随便一台」。

| ID | 场景 | Redis | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|---|
| **MY001** | 正常基线 | F01 | 三节点 `SELECT 1`；两从 IO/SQL=`ON`；半同步 ON | `inject_host.sh` / `baseline` | `./scripts/inject_host.sh --action baseline` | 全员可达且复制 ON | 无 |
| **MY010** | CPU 持续高压 | F02 | 容器内 `stress-ng --cpu 0 --cpu-load 90` | `cpu` | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600` | vmstat 1 4 跳过 since-boot，CPU avg **≥80%** | 到期 `pkill stress-ng` |
| **MY010-R** | 单从 CPU 高压 | F02 | 同上，打 **一台从** | `cpu` | `... --target-host 10.10.26.145 --duration 600` | 同上；另一从 CPU 正常 | 同上 |
| **MY011** | 主机内存压力 | F04 | `stress-ng --vm 2 --vm-bytes 85%`（相对 `mem_limit`） | `memory` | `./scripts/inject_host.sh --action memory --target-host 10.10.26.145 --duration 600` | cgroup 可用 **≤15%** 或已用 **≥85%** | 到期杀 stress-ng |
| **MY010-S** | CPU 瞬时尖峰 | F06 | 周期短时 CPU burst | `cpu-spike` | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 600` | 启动即 pass | 到期停 burst |
| **MY035** | 主机重启 | F09 | `docker restart` 模拟 VM 重启 | `reboot` | `./scripts/inject_host.sh --action reboot --target-container mysql-n1 --confirm YES` | 需确认；**无自动恢复** | 容器自启 / 人工 |
| **MY010-M** | 多节点 CPU | F28 | 三节点并行 F02 | `multi-cpu` | `./scripts/inject_host.sh --action multi-cpu --duration 600` | 需 `.state/docker_all_nodes.ok` | 各节点到期恢复 |
| **MY014** | 时钟偏移 | Kafka KF010 | `date -s` 把从库拨快 120s | `clock-skew` | `./scripts/inject_host.sh --action clock-skew --target-host 10.10.26.145 --duration 600 --skew-sec 120` | `timedatectl` 偏移 **≥60s** | 到期拨回 |

**环境**：MY011 依赖容器 `mem_limit=1536m`。  
**定责提示**：CPU 打在主库 → 全员延迟同类（MY194）；打在一台从 → 该从离群（MY195）。这是 Redis 3 主对等拓扑里不明显的点。

---

## 2. MySQL 进程 / 连接 / SQL — `scripts/inject_mysql.sh`

对齐 Redis `inject_redis.sh`（进程停、打满连接、慢命令、热点、大对象）。缓存穿透 / FLUSHDB / Cluster 协议错误 **不适用**。

| ID | 场景 | Redis | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|---|
| **MY030** | mysqld 进程停止（从） | F07 | 注入前 `docker update --restart=no`；`mysqladmin shutdown` 或 `systemctl stop mysqld` | `process-stop` | `./scripts/inject_mysql.sh --action process-stop --node 10.10.26.145:3306 --duration 600` | `SELECT 1` **5s 内 ≥3s 失败**；主库 Dump 少 1 | 到期拉起 mysqld + 恢复 Restart |
| **MY030-P** | mysqld 进程停止（主） | F07 | 同上，打 **主库** | `process-stop` | `... --node 10.10.26.144:3306 --duration 600` | 主库不可达；从库 IO 将报错 | 到期拉起（复制需检查是否自动重连） |
| **MY036** | mysqld SIGSTOP 挂起 | Kafka KF016 | `kill -STOP $(pidof mysqld)`；端口仍在 | `process-freeze` | `./scripts/inject_mysql.sh --action process-freeze --node 10.10.26.144:3306 --duration 300` | `ss` 仍听 3306，但 `SELECT 1` 超时 | `kill -CONT` |
| **MY081** | 连接打满 | F12 | `SET GLOBAL max_connections=N` + 并发占连接 | `max-connections` | `./scripts/inject_mysql.sh --action max-connections --node 10.10.26.144:3306 --duration 600 --max-connections 10` | 新连接 `Too many connections` | 恢复原 `max_connections` 并断注入连接 |
| **MY080** | 慢 SQL / 会话堆积 | F14 | 周期 `SELECT SLEEP(n)` 或 `BENCHMARK` | `slow-query` | `./scripts/inject_mysql.sh --action slow-query --node 10.10.26.144:3306 --duration 600` | processlist 有非 Sleep 的 sleep/benchmark | 停循环 / `KILL QUERY` |
| **MY084** | 热行（行锁） | F15 | 两会话抢同一主键 `UPDATE` | `hot-row` | `./scripts/inject_mysql.sh --action hot-row --node 10.10.26.144:3306 --duration 600` | `Innodb_row_lock_waits` 递增或 `data_lock_waits` 非空 | 提交/回滚注入事务 |
| **MY082** | 大事务 / binlog cache 打盘 | F16 | 单事务更新大量行或大 BLOB | `big-trx` | `./scripts/inject_mysql.sh --action big-trx --node 10.10.26.144:3306 --duration 300` | `Binlog_cache_disk_use` 增加或 trx age 上升 | 提交/回滚 |
| **MY087** | 长事务不提交 | — | `BEGIN; UPDATE ...;` 持有 **≥30s** | `long-trx` | `./scripts/inject_mysql.sh --action long-trx --node 10.10.26.144:3306 --duration 600` | `innodb_trx.age_s ≥ 30` | `ROLLBACK` |
| **MY085** | buffer pool 过小 | F10 | `SET GLOBAL innodb_buffer_pool_size` 降到很小 + 扫大表 | `buffer-pool-shrink` | `./scripts/inject_mysql.sh --action buffer-pool-shrink --node 10.10.26.144:3306 --duration 600` | 命中率下降或配置已生效 | 恢复原 size（部分版本需重启，标 P） |
| **MY205** | 鉴权失败脉冲 | F19-NOAUTH/WRONGPASS | 错密码 / 无密码连 3306 | `error-pulse` | `./scripts/inject_mysql.sh --action error-pulse --node 10.10.26.146:3306 --duration 90 --error-type WRONGPASS` | error log `Access denied` 递增 | 脉冲结束即止 |
| **MY034** | 内存触发 OOM | F10/F04 | 叠加 MY011，或 `innodb_buffer_pool` 过大 | `oom` | `./scripts/inject_mysql.sh --action oom --node 10.10.26.144:3306 --confirm YES` | dmesg/OOM 或 mysqld 退出 | **P，需确认**；不默认跑 |

**明确不做（Redis 有、MySQL 无对应产品语义）**：

| Redis | 原因 |
|---|---|
| F17 冷缓存 / FLUSHDB | MySQL 不是缓存层；`FLUSH TABLES`/`RESET` 会误伤实验室数据，不作为默认场景 |
| F18 缓存穿透 | 应用层「查不存在行」不是实例故障 |
| F19-MOVED / CROSSSLOT | Cluster 协议，一主多从不涉及 |
| F29 历史 MISCONF | Redis 特有 ERRORSTATS；磁盘只读见 MY160 / 第 6 节 |

---

## 3. 复制 — `scripts/inject_repl.sh`（Redis 当前环境做不了，本拓扑核心）

一主**两从**才能区分「全员」和「单台」。`replica_count=1` 时清洗必须注明，禁止把 MY190 写成多从结论。

| ID | 场景 | 注入点 | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|---|
| **MY040** | 单从停 IO 线程 | 一台从 | `STOP REPLICA IO_THREAD`（`STOP SLAVE IO_THREAD`） | `stop-io` | `./scripts/inject_repl.sh --action stop-io --scope one --node 10.10.26.145:3306 --duration 600` | 该从 IO≠ON，另一从 IO=ON → 组合 **MY191** | `START REPLICA IO_THREAD` |
| **MY190** | 所有从停 IO | 两从 | 两从并行 `STOP REPLICA IO_THREAD` | `stop-io` | `./scripts/inject_repl.sh --action stop-io --scope all --duration 600` | ≥2 从 IO≠ON → **MY190** | 各从 START IO |
| **MY041** | 单从停 SQL 线程 | 一台从 | `STOP REPLICA SQL_THREAD` | `stop-sql` | `./scripts/inject_repl.sh --action stop-sql --scope one --node 10.10.26.145:3306 --duration 600` | 该从 SQL≠ON，IO 仍 ON，另一从正常 → **MY193** | `START REPLICA SQL_THREAD` |
| **MY192** | 所有从停 SQL | 两从 | 两从并行停 SQL | `stop-sql` | `./scripts/inject_repl.sh --action stop-sql --scope all --duration 600` | ≥2 从 SQL≠ON | 各从 START SQL |
| **MY044** | Dump 数不匹配 | 停一台从 mysqld 或 IO | 复用 MY030 / MY040 | （由上面覆盖） | — | 主库 Dump 线程数 < 从库数 | 随上层恢复 |
| **MY046** | 主库 binlog 已被 purge | 主 + 先停从 IO | 停从 IO → 主库写流量 → `PURGE BINARY LOGS TO/BEFORE` 越过从库需要的文件 | `binlog-purge` | `./scripts/inject_repl.sh --action binlog-purge --replica 10.10.26.145:3306 --confirm YES` | 从库 IO 报 `Could not find first log file` | **无自动恢复**；需重新 CHANGE SOURCE / clone |
| **MY110** | 从库去掉只读 | 一台从 | `SET GLOBAL super_read_only=0; SET GLOBAL read_only=0;` | `replica-writable` | `./scripts/inject_repl.sh --action replica-writable --node 10.10.26.145:3306 --duration 600` | `@@read_only=0` | 恢复只读 |
| **MY130** | 从库误写导致 1062 | 一台从 | MY110 后对复制表插入主库已有主键 | `replica-1062` | `./scripts/inject_repl.sh --action replica-1062 --node 10.10.26.145:3306 --confirm YES` | SQL errno=1062，SQL≠ON → **MY043+MY193** | **无自动恢复数据**；实验室可 `RESET` 重建从库 |
| **MY111** | `server_id` 重复 | 一台从 | 运行时无法安全改 `server_id`（只读）；改 cnf + 重启从库使与主相同 | `dup-server-id` | `./scripts/inject_repl.sh --action dup-server-id --node 10.10.26.146:3306 --confirm YES --duration 600` | Dump 拒绝 / 日志 Duplicate server id | 改回唯一 server_id 并重启 |
| **MY065** | 关掉并行复制 | 一台从 | `SET GLOBAL replica_parallel_workers=0`（`slave_parallel_workers`）+ 主库连续小事务 | `serial-apply` | `./scripts/inject_repl.sh --action serial-apply --node 10.10.26.145:3306 --duration 600` | workers=0 且该从延迟高于另一从 | 恢复原 workers |
| **MY063** | SQL 积压（IO 已跟上） | 一台从 | 停 SQL 期间主库持续写入，再只观察不立刻 START | `sql-backlog` | `./scripts/inject_repl.sh --action sql-backlog --node 10.10.26.145:3306 --duration 300` | `GTID_SUBTRACT(RECEIVED, EXECUTED)` 变长 / relay 增大 | START SQL |
| **MY132** | GTID 空洞（危险） | 一台从 | `SET GTID_NEXT` 注入空事务或 skip；仅实验室 | `gtid-skip` | `./scripts/inject_repl.sh --action gtid-skip --node 10.10.26.145:3306 --confirm YES` | `gtid_executed` 出现跳号 | **P**；测完重建从库 |
| **MY042** | 复制账号错误 | 一台从 | `CHANGE REPLICATION SOURCE ... PASSWORD='wrong'` 后 `START REPLICA` | `bad-repl-auth` | `./scripts/inject_repl.sh --action bad-repl-auth --node 10.10.26.146:3306 --duration 600` | IO 错误 1045 / 鉴权失败 | 改回正确密码并 START |
| **MY047** | 复制指向错误主机 | 一台从 | `CHANGE SOURCE TO SOURCE_HOST=无效IP` | `bad-source-host` | `./scripts/inject_repl.sh --action bad-source-host --node 10.10.26.146:3306 --duration 600` | IO 连不上 | CHANGE 回主库 IP |
| **MY066** | `SQL_DELAY` 人为延迟 | 一台从 | `CHANGE SOURCE TO SOURCE_DELAY=30` | `sql-delay` | `./scripts/inject_repl.sh --action sql-delay --node 10.10.26.145:3306 --duration 600 --delay-sec 30` | `Seconds_Behind_Source` 稳定在 delay 附近 | `SOURCE_DELAY=0` |

**GTID 验收硬规则（与排障设计一致）**：禁止用 `RECEIVED == gtid_executed` 判断一致。从库 `gtid_executed` 含 initialize UUID。用 `GTID_SUBSET(RECEIVED, @@gtid_executed)` 和 `GTID_SUBTRACT` 体积。

---

## 4. 半同步 — `scripts/inject_repl.sh`（一主多从特有）

默认 `wait_for_replica_count=1`：**只隔离一台从，另一台仍能 ACK，主库写入不应卡住**。要打出「主库等 ACK」，必须让 **所有能 ACK 的从** 都变慢/断开，或临时把 `wait_for_replica_count` 调到 2。

| ID | 场景 | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|
| **MY100** | 半同步降级异步 | 两从丢包/延迟 > `rpl_semi_sync_source_timeout`（默认 10s），或关从库 semi-sync | `semi-sync-degrade` | `./scripts/inject_repl.sh --action semi-sync-degrade --duration 600` | `Rpl_semi_sync_source_status=OFF` 或 `no_tx` 上升 | 恢复网络 / 插件 |
| **MY102** | 主库会话等 ACK | `SET GLOBAL rpl_semi_sync_source_timeout` 放大 + 两从 `tc netem delay`；或 `--wait-count 2` 再隔离一台 | `semi-sync-wait-ack` | `./scripts/inject_repl.sh --action semi-sync-wait-ack --duration 300` | 主库 `wait_sessions>0` 或写入明显变慢；组合 **MY197** | 恢复 timeout / 网络 |
| **MY103** | ACK 从库数量不足 | 停一台从 IO，同时 `wait_for_replica_count=2` | `semi-sync-under-ack` | `./scripts/inject_repl.sh --action semi-sync-under-ack --duration 300` | `clients` < wait count | 恢复 wait count + START IO |
| **MY101** | 仅 `no_tx` 上升 | timeout 短（如 1000ms）+ 轻丢包 | `semi-sync-timeout-pulse` | `./scripts/inject_repl.sh --action semi-sync-timeout-pulse --duration 300` | `no_tx` 递增，status 可能仍 ON | 恢复 timeout / tc |

**反例（注入失败）**：`wait_count=1` 时只对 `.145` 丢包，`.146` 仍 ACK → 不能报 MY102。这是一主多从相对一主一从必须写进脚本的分支。

---

## 5. 网络 — `scripts/inject_network.sh`

Redis 的 Cluster Bus（F20）在本拓扑对应 **主从 3306 Dump / ACK**，不是 16379。

| ID | 场景 | Redis | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|---|
| **MY144** | 单从到主库 3306 阻断 | F20 | 从库容器内 iptables DROP 到主 `:3306` | `repl-block` | `./scripts/inject_network.sh --action repl-block --node 10.10.26.145:3306 --duration 600` | 规则已加；该从 IO 断，另一从正常 → **MY191** | 到期删规则 |
| **MY190-N** | 所有从到主 3306 阻断 | F20×N | 两从都 DROP 主 3306 | `repl-block` | `./scripts/inject_network.sh --action repl-block --scope all --duration 600` | ≥2 从 IO 断 → **MY190** | 到期删规则 |
| **MY140** | 单从丢包 | F22 | `tc qdisc replace … root netem loss 30%`（不用 HTB） | `packet-loss` | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.146 --duration 600 --loss 30 --net-dev eth0` | `tc qdisc show` 含 netem loss | `tc qdisc del` |
| **MY140-L** | 单从延迟 | Kafka KF076 | `tc netem delay 200ms` | `latency` | `./scripts/inject_network.sh --action latency --target-host 10.10.26.146 --delay-ms 200 --duration 600` | qdisc 含 delay | 到期删 |
| **MY142** | 主库出口限速（扇出） | Kafka KF077 | 主库 `tc` 限速（一主两从特有：binlog dump×2） | `rate-limit` | `./scripts/inject_network.sh --action rate-limit --target-host 10.10.26.144 --rate 1mbit --duration 600` | qdisc 含 rate；两从延迟同类 → **MY194** | 到期删 |
| **MY144-P** | 主从双向分区 | F30 | 主↔指定从 双向 iptables DROP | `primary-replica-partition` | `./scripts/inject_network.sh --action primary-replica-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 600` | 需 `docker_all_nodes.ok` | 到期删规则 |
| **MY141** | 单向丢 ACK | Kafka KF082 | 只丢从→主 或 主→从 单向 | `one-way-drop` | `./scripts/inject_network.sh --action one-way-drop --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 180` | 规则已加；半同步可能 MY102 | 到期删 |
| **MY031** | 主库 3306 对客户端阻断 | F20 变体 | 主库 DROP 3306（复制口可另开，实验室同口则 Dump 一并死） | `client-block` | `./scripts/inject_network.sh --action client-block --target-host 10.10.26.144 --duration 300` | 注入机连 3306 失败 | 到期删 |

**环境**：容器 `NET_ADMIN`；丢包/延迟需宿主机 `modprobe sch_netem`。

---

## 6. 磁盘 — `scripts/inject_disk.sh`

| ID | 场景 | Redis | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|---|
| **MY160** | 磁盘满（主 datadir/binlog） | F24 近亲 | `dd` 填 datadir 所在文件系统到 ≥90% | `disk-full` | `./scripts/inject_disk.sh --action disk-full --target-host 10.10.26.144 --duration 300` | `df` ≥90% 或 error log `No space` | 删填充文件 |
| **MY160-R** | 磁盘满（从 relay/datadir） | 同上 | 打 **一台从** | `disk-full` | `... --target-host 10.10.26.145 --duration 300` | 该从 SQL 可能停 → **MY041+MY198** | 删填充文件 |
| **MY164** | 数据目录只读 | F24 | `chmod a-w` datadir / binlog / relay | `datadir-readonly` | `./scripts/inject_disk.sh --action datadir-readonly --node 10.10.26.146:3306 --duration 600` | 写失败 / error log OS error | 恢复权限 |
| **MY162** | 磁盘 IO 高 | F26 | `dd` 写到 **`<datadir>/fault_io`**（非 `/tmp`） | `io-stress` | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.145 --duration 600` | IO 已启动；单从则 **MY195** | 到期删 fault_io |
| **MY162-P** | 主库 IO 高 | F26 | 打主库 datadir | `io-stress` | `... --target-host 10.10.26.144 --duration 600` | 两从延迟同类 → **MY194** | 到期删 |
| **MY161** | inode 耗尽 | Kafka KF012 | 数据目录大量小文件 | `inode-exhaust` | `./scripts/inject_disk.sh --action inode-exhaust --target-host 10.10.26.144 --duration 180` | `df -i` 使用率高 | 删小文件 |

---

## 7. 组合 — `scripts/inject_composite.sh`

内部再调上面脚本；组合期间 skip flock。优先覆盖排障清洗的 MY196–MY199。

| ID | 场景 | Redis/清洗 | 组成 | 脚本 / action | 完整命令 |
|---|---|---|---|---|---|
| **MY196** | 长事务 + 全员延迟 | MY087+MY194 | 主库 `long-trx` + 主库持续写入 | `long-trx-plus-lag` | `./scripts/inject_composite.sh --action long-trx-plus-lag --duration 600` |
| **MY197** | 半同步等 ACK + 从网络差 | C 变体 | `semi-sync-wait-ack`（两从 delay 或 wait_count=2） | `ack-plus-net` | `./scripts/inject_composite.sh --action ack-plus-net --duration 300` |
| **MY198** | 磁盘满 + SQL 停止 | — | 从库 `disk-full` | `disk-plus-sql-stop` | `./scripts/inject_composite.sh --action disk-plus-sql-stop --replica-host 10.10.26.145 --duration 300` |
| **MY199** | 时钟偏移 + 仅秒级延迟 | — | 从库 `clock-skew`（不打真实积压） | `clock-plus-lag-metric` | `./scripts/inject_composite.sh --action clock-plus-lag-metric --duration 300` |
| **C01** | 主停 + 远端从内存 | Redis C03 | MY030-P + MY011（.146） | `primary-stop-plus-memory` | `./scripts/inject_composite.sh --action primary-stop-plus-memory --duration 600` |
| **C02** | 写拒绝 + CPU | Redis C02 | MY164 + MY010 同节点 | `write-reject-plus-cpu` | `./scripts/inject_composite.sh --action write-reject-plus-cpu --target-host 10.10.26.144 --duration 600` |
| **C03** | 单从 IO 断 + 另一从 CPU | — | MY040(.145) + MY010(.146) | `one-io-plus-other-cpu` | `./scripts/inject_composite.sh --action one-io-plus-other-cpu --duration 600` |

---

## 8. 降级 — `scripts/inject_degrade.sh`（注入机本机，对齐 Redis D01–D02）

| ID | 场景 | Redis | 注入方式 | 脚本 / action | 完整命令 | 恢复 |
|---|---|---|---|---|---|---|
| **MY172** | 单节点对排障作业不可达 | D01 | Bot 本机 iptables 阻断到 MySQL IP:3306 | `job-unreachable` | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --blocked-port 3306 --duration 600` | 到期删规则 |
| **MY171** | 隐藏采集工具 | D02 | 临时移走 `iostat` / `mysql` / `pidstat` | `hide-tools` | `./scripts/inject_degrade.sh --action hide-tools --duration 600` | 到期还原 |
| **MY174** | 命令超时 | D03 近亲 | 无注入脚本；排障侧把单命令 timeout 打满 | — | — | — |

---

## 9. 当前环境不做（无脚本）

| 场景 | 原因 | Redis 对照 |
|---|---|---|
| 自动 Failover / VIP 切主 | 本拓扑无 MHA / Orchestrator / InnoDB Cluster | Redis「自动 Failover」同样 N（无 Replica） |
| Group Replication / Paxos 脑裂 | 不是 GR 拓扑 | F30 在 Redis 是双 Master 分区；MySQL 经典复制没有双写法定人数 |
| Slot 迁移中断 | 无 | Redis 第 7 节 |
| 全量 `pt-table-checksum` / 证明无分叉 | 超出注入验收；最多制造 MY130 症状 | — |
| ProxySQL / 读写分离误路由 | 实验室无中间件 | — |
| 备份窗口抢 IO（xtrabackup 真跑） | 用 MY162 近似 | — |
| 跨版本复制 / 多源复制 | 需额外拓扑 | — |

---

## 10. Redis → MySQL 对照速查

| Redis ID | Redis 场景 | MySQL | 备注 |
|---|---|---|---|
| F01 | 基线 | MY001 | 增加复制/半同步检查 |
| F02 | CPU | MY010 / MY010-R | **必须区分打主还是打从** |
| F04 | 内存 | MY011 | 同工具 |
| F06 | CPU 尖峰 | MY010-S | 同工具 |
| F07 | 进程停止 | MY030 / MY030-P | 从 vs 主 |
| F09 | 重启 | MY035 | `docker restart` |
| F10 | maxmemory | MY085 / MY034 | buffer pool；不是 maxmemory |
| F12 | maxclients | MY081 | `max_connections` |
| F14 | DEBUG SLEEP | MY080 | `SELECT SLEEP` |
| F15 | 热 Key | MY084 | 热行锁 |
| F16 | 大 Key | MY082 / MY087 | 大事务 / 大行 |
| F17 / F18 | 冷缓存 / 穿透 | **N** | 产品语义不同 |
| F19 NOAUTH/WRONGPASS | 协议脉冲 | MY205 | Access denied |
| F19 MOVED/CROSSSLOT | Cluster | **N** | |
| F20 | Cluster Bus 阻断 | MY144 | 改为 3306 Dump |
| F22 | 丢包 | MY140 | 同 `tc netem` |
| F24 | 持久化只读 | MY164 | datadir chmod |
| F26 | 磁盘 IO | MY162 / MY162-P | 打从=离群，打主=全员 |
| F28 | 多节点 CPU | MY010-M | 同 |
| F29 / F29c | MISCONF | **N** | 用 MY160/MY164 |
| F30 | 两 Master 分区 | MY144-P | 改为主从分区 |
| C01 | 内存+MISCONF | C02 近亲 | 写拒绝+CPU |
| C02 | 写拒绝+CPU | C02 | |
| C03 | Master 停+内存 | C01 | 主停+从内存 |
| D01 | 作业不可达 | MY172 | 端口 3306 |
| D02 | 藏工具 | MY171 | 加 `mysql` 客户端 |
| （无） | 复制 IO/SQL | **MY040–MY047, MY190–MY193** | Redis 3 主 0 从做不了 |
| （无） | 半同步 | **MY100–MY103, MY197** | Redis 无 |
| （无） | binlog purge | **MY046** | Redis 无 |
| （无） | 从库误写 1062 | **MY110+MY130** | Redis 无 |
| （无） | 全员 vs 单从延迟 | **MY194 / MY195** | 一主多从交叉对比 |

---

## 11. 脚本对照速查

| 脚本 | 覆盖场景 |
|---|---|
| `scripts/preflight.sh` | 环境检查（非注入） |
| `scripts/inject_host.sh` | MY001, MY010*, MY011, MY014, MY035 |
| `scripts/inject_mysql.sh` | MY030*, MY034, MY036, MY080–MY085, MY087, MY205 |
| `scripts/inject_repl.sh` | MY040–MY047, MY063, MY065, MY066, MY100–MY103, MY110, MY111, MY130, MY132, MY190, MY192 |
| `scripts/inject_network.sh` | MY031, MY140*, MY141, MY142, MY144* |
| `scripts/inject_disk.sh` | MY160*, MY161, MY162*, MY164 |
| `scripts/inject_composite.sh` | MY196–MY199, C01–C03 |
| `scripts/inject_degrade.sh` | MY171, MY172 |

---

## 12. 推荐首跑顺序（排障最小故障集）

对齐 `troubleshooting/mysql` 设计稿 §14.2：这些注入必须能打出对应 MY ID。优先实现，再铺全表。

```bash
./scripts/preflight.sh

# 基线 + 主机（复用 Redis 工具链）
./scripts/inject_host.sh --action baseline
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 300

# 进程：停一台从库 mysqld → MY030 + MY191/MY044
./scripts/inject_mysql.sh --action process-stop --node 10.10.26.145:3306 --duration 300

# 复制：单从停 SQL → MY041 + MY193
./scripts/inject_repl.sh --action stop-sql --scope one --node 10.10.26.145:3306 --duration 300

# 主库长事务 → MY087 + MY194/MY196
./scripts/inject_mysql.sh --action long-trx --node 10.10.26.144:3306 --duration 300

# 半同步：等 ACK（注意 wait_count=1 必须拖住全部 ACK 从）→ MY102 + MY140 + MY197
./scripts/inject_repl.sh --action semi-sync-wait-ack --duration 180

# 单从 IO 高 → MY162 + MY061 + MY195
./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.145 --duration 300

# 降级：采集时 mysqld 已死 / 工具缺失 → 流程仍 exit 0
./scripts/inject_degrade.sh --action hide-tools --duration 120

# 破坏性（隔离实验末尾，需 --confirm YES）
# ./scripts/inject_repl.sh --action binlog-purge --replica 10.10.26.145:3306 --confirm YES
# ./scripts/inject_repl.sh --action replica-1062 --node 10.10.26.145:3306 --confirm YES
```

每条命令 stdout 应出现：`INJECT_RESULT scenario=... status=pass`。

---

## 13. 场景 ↔ 排障线索（参考，非注入验收）

| ID | 预期可观测线索 |
|---|---|
| MY010 打主 | 主库 CPU 高；两从延迟同类（MY194） |
| MY010 打一从 | 该从 CPU 高；延迟离群（MY195） |
| MY030 从 | 该从 SELECT 失败；主 Dump 少 1（MY044）；MY191 |
| MY030 主 | 写入全失败；从 IO 报连不上 |
| MY040 单从 | 仅该从 IO≠ON（MY191），不能报主库 binlog 打满 |
| MY041 单从 | SQL≠ON、IO 仍 ON（MY193） |
| MY046 | error log `Could not find first log file` |
| MY081 | `Too many connections` |
| MY087 | innodb_trx 长事务；全员延迟 |
| MY100/MY102 | 半同步 OFF / wait_sessions；主库写入慢是等 ACK 不是慢 SQL |
| MY110+MY130 | 从库可写 + 1062 |
| MY140 单从 | 丢包/RTT；不要判成全员 |
| MY142 | 主库出口打满；两从一起慢 |
| MY160 | No space left |
| MY162 单从 | iowait 高 + SQL 落后（MY061） |
| MY171/MY172 | 清洗 coverage=degraded |
| MY196–MY199 | 清洗组合信号 |

---

## 14. 相关文件

| 文件 | 用途 |
|---|---|
| [`FAULT_INJECTION_PLAN.md`](./FAULT_INJECTION_PLAN.md) | 拓扑、原则、落地顺序 |
| [`PREREQUISITES.md`](./PREREQUISITES.md) | 环境前提 |
| [`SCENARIOS.md`](./SCENARIOS.md) | 精简速查（指向本文） |
| [`config.env.example`](./config.env.example) | 配置模板 |
| [`../troubleshooting/mysql/MYSQL_FAULT_SCENARIOS.md`](../troubleshooting/mysql/MYSQL_FAULT_SCENARIOS.md) | 排障视角（采集路 / Y·P·N） |
