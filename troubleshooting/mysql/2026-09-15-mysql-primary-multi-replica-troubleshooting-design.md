# MySQL 一主多从故障排查流程设计

> 状态：设计稿（含优化约束，可直接指导脚本落地）  
> 日期：2026-09-15  
> 对齐：仓库内 Kafka 排障 Bot（五路并行采集 → 覆盖判定 → 清洗/降级清洗 → AI）  
> 拓扑基线：MySQL 8.0 / 8.4，GTID 一主多从，默认开启半同步；实验室参考 `172.30.0.11` primary + `.12` / `.13` replica

本文是 **5 分钟排障 Bot** 的设计，不是人工 runbook。目标：采集 3 分钟内完成，清洗 1 分钟，AI 1 分钟，输出可执行结论。

---

## 1. 目标与非目标

### 1.1 目标

一次作业跑完后，必须能回答：

1. 复制线程还活着吗？（IO / SQL）
2. 是 **所有从库一起坏**，还是 **单台从库坏**？
3. 慢在 **IO 收日志**、**SQL 回放**，还是 **主库写入 / 半同步 ACK / 网络**？
4. 现在该 **止损** 还是 **继续观察**？缺哪些证据？

输出固定结构：根因假设（带场景 ID）→ 关键证据 → 影响面 → 立即止损 → 验证步骤 → 证据缺口。

### 1.2 非目标（5 分钟内明确不做）

| 不做 | 原因 |
|---|---|
| `pt-table-checksum` / 全表行数对账 | 分钟级到小时级，超出时间盒 |
| 全量 `mysqlbinlog` 解码 | binlog 体积不可控 |
| 全量 slow log / general log 入库 | I/O 与 AI 上下文都会爆 |
| 自动 failover / 自动修数据 | 本流程只诊断，不变更 |
| 把原始 my.cnf、error log、InnoDB status 全文丢给模型 | 1 分钟 AI 吃不下，且会幻觉 |

这些标为 **P1 补充采集**，主路径只输出 `EVIDENCE_GAP`。

---

## 2. 优化原则（相对 Kafka v1 / 朴素五路采集）

Kafka v2 YAML 采集超时 600–900s、清洗/AI 各 300s，墙钟远超 5 分钟。MySQL 流程 **禁止复用这套 timeout**。

| # | 优化 | 不优化时的后果 |
|---|---|---|
| O1 | **硬时间盒**：预检 10s + 采集 90s + 清洗 50s + AI 50s + 余量 20s | 作业跑 15 分钟才出结论 |
| O2 | **按角色采集**，先识别当前主库，不信任部署 YAML 里的静态 role | 切换后在旧主上查 Replica Status，结论全反 |
| O3 | **每台节点本地并行**，禁止诊断机串行 SSH 扫所有从库 | 5 个从库时 3 分钟采集必破 |
| O4 | **`SHOW REPLICA STATUS` 只跑一次**，字段拆给指标和运行状态两份产物 | 重复连库把 90s 预算吃掉 |
| O5 | **用 `performance_schema` 单值查询**，避免 `mysql -N` + `\G` 解析空值 | 本仓库 MySQL 8.4 部署已踩过：IO/SQL 状态误判为空 |
| O6 | **GTID 用 `GTID_SUBSET` / 差集大小，禁止 `RECEIVED == gtid_executed`** | 从库 initialize UUID 会导致误报不一致 |
| O7 | **清洗做交叉对比**，AI 只吃信号，不负责从原文里发现「全员 vs 单台」 | AI 1 分钟给散文，无法验收 |
| O8 | **配置解析关键项，日志 `tail+grep`** | 原文过大，AI 超时或编造 |
| O9 | **采集失败 `exit 0` + `ignore_error`**，走降级清洗 + 启发式诊断 | P1 时 mysqld 已挂，排障流程自己失败 |
| O10 | **兼容 8.0/8.4 命名**（`SHOW SLAVE/REPLICA`、`semi_sync_master/source`） | 8.4 实验室与 8.0 生产混用时整路空结果 |

---

## 3. 时间盒（验收红线）

墙钟取并行最大值，不是五路相加。

```text
0s        10s              100s             150s            200s       220s
|---------|----------------|----------------|---------------|----------|
 预检       五路并行采集        覆盖判定+清洗      AI / 启发式      余量
 ≤10s      硬超时 90s         ≤50s            ≤50s          20s
```

| 阶段 | 墙钟上限 | 单命令 timeout | 失败策略 |
|---|---|---|---|
| 采集预检 | 10s | 3s | 记 `MY170`，继续 |
| M 指标 | 90s | 5–15s | `CMD_TIMEOUT` 信号，exit 0 |
| S 运行状态 | 90s | 5–15s | 同上 |
| C 配置 | 90s | 10s | 同上 |
| L 日志 | 90s | 15s | 只 tail 最近 8000 行 |
| H 主机网络 | 90s | ping 3 次 / iostat 1 3 | 同上 |
| 清洗 | 50s | 禁止调模型 | 输出 summary + 场景 ID |
| AI | 50s | HTTP 45s | 失败则启发式诊断仍算出 |

**硬规则：**

- 任一采集脚本 `set -uo pipefail`，**禁止 `set -e`**，最终 `exit 0`。
- SOPS 节点全部 `ignore_error: true`。
- `iostat 1 3` 不是 `1 30`；`ping -c 3` 不是 `-c 20`。
- 日志禁止 `cat` 整文件；配置禁止把整个 `my.cnf` 塞进 AI prompt。
- 清洗输入是各节点 `.signals` + 截断摘要，不是 10MB 原文。

`job_script_timeout` 建议值（含 SSH 开销，仍远小于 Kafka）：

| 节点 | timeout |
|---|---|
| 预检 | 30s |
| 五路采集各路 | 120s |
| 清洗 / 降级清洗 | 60s |
| AI | 60s |

脚本内部仍按 90/50/50 自裁，作业超时只是外壳。

---

## 4. 流程

```text
Start
  ├─ 采集预检（工具、进程、3306、角色候选）
  └─ ParallelGateway 五路并行（每节点本地）
        ├─ M  MySQL 指标
        ├─ S  运行状态（与 M 共享一次复制快照）
        ├─ C  配置关键项
        ├─ L  过滤日志
        └─ H  主机 + 网络（合并一路，避免第六路吃掉编排余量）
  → ConvergeGateway
  → 覆盖判定 ExclusiveGateway
        ├─ 覆盖足够 → 数据清洗与交叉对比
        └─ 覆盖不足 → 降级清洗
  → AI 诊断（失败则启发式）
  → End
```

**优化：** Kafka 把主机和网络拆成两路。MySQL 5 分钟预算下合并为 **H 主机网络**，与产品经理的五个分类一致（指标 / 运行状态 / 日志 / 配置 / 主机网络）。指标与运行状态在逻辑上分开、在采集上共享连接。

### 4.1 多节点汇聚

SOPS 按 IP 下发时节点无共享盘。清洗若只看见本机产物，交叉对比为零。

必须二选一（实验室与作业平台都要写进 YAML 注释）：

1. 作业平台把各 IP 的 `###MYSQL_TS_ARTIFACT` 块拼到清洗节点 stdin  
2. 诊断机 `run_flow.sh` 从各节点拉取 `/tmp/mysql-troubleshoot/<run_id>/` 再清洗  

汇聚时间计入 20s 余量，不能另开 3 分钟。

---

## 5. 角色识别

每台机器采集开始时先判角色，后续查询按角色分支。

```sql
SELECT @@global.read_only AS ro,
       @@global.super_read_only AS sro,
       @@global.server_id AS server_id,
       @@global.hostname AS host;
```

再查是否存在复制通道（8.4 优先）：

```sql
SELECT SERVICE_STATE AS io_state
FROM performance_schema.replication_connection_status LIMIT 1;

SELECT SERVICE_STATE AS sql_state
FROM performance_schema.replication_applier_status_by_coordinator LIMIT 1;
```

| 判定 | 角色 |
|---|---|
| 无复制通道且 `read_only=0` | `primary` 候选 |
| 有复制通道 | `replica` |
| 有 Dump 线程且无复制通道 | `primary` |
| 冲突（两台都像主、零台像主） | 信号 `MY048` 拓扑异常，两套查询都跑，不猜测 |

**优化：** 不要用部署参数 `host.role` 当运行时真相。VIP / 人工切换后静态角色会错。

8.0 无 `replication_applier_status_by_coordinator` 时回退 `SHOW REPLICA STATUS` / `SHOW SLAVE STATUS`，用 `mysql --table` 或 python 解析，**不要** `mysql -N ...\G`。

---

## 6. 五路采集规格

每路产物：

```text
/tmp/mysql-troubleshoot/<run_id>/
  metrics.<ip>.txt      metrics.<ip>.signals
  status.<ip>.txt       status.<ip>.signals
  config.<ip>.txt       config.<ip>.signals
  logs.<ip>.txt         logs.<ip>.signals
  hostnet.<ip>.txt      hostnet.<ip>.signals
```

信号格式与 Kafka 对齐：`ID<TAB>severity<TAB>note`。

共享约定：

- 同一节点 M 与 S 共用一次「复制快照文件」`snapshot.<ip>.json`，避免连两次。
- 所有 `SHOW GLOBAL STATUS/VARIABLES` 用 `WHERE Variable_name IN (...)`，禁止无过滤全量。
- 8.0/8.4 变量名都查：查不到记 `NA`，不报错退出。

### 6.1 预检（≤10s）

| 检查 | 失败信号 |
|---|---|
| `mysqld` 进程是否存在 | `MY030` |
| `ss/netstat` 是否在听 3306 | `MY031` |
| `mysql` 客户端是否存在 | `MY171` |
| 本地 socket / 账号能否 `SELECT 1`（3s） | `MY032` |
| `timeout`/`iostat` 是否可用 | `MY171` low |

预检失败仍启动五路：进程没了，H/L/N 仍有证据。

### 6.2 M — MySQL 指标（P0，≤90s）

**从库（复制快照字段）：**

| 字段 | 含义 | 信号 |
|---|---|---|
| IO/SQL `SERVICE_STATE` | 线程是否 Yes | `MY040` / `MY041` |
| `LAST_ERROR_NUMBER/MESSAGE`（IO 与 SQL） | 断因 | `MY042` / `MY043` |
| `Seconds_Behind_Source`（或 Master） | 粗延迟 | `MY060` 超阈值 |
| `Read_Source_Log_Pos` vs `Exec_Source_Log_Pos` + 文件名 | 收慢 vs 放慢 | `MY061` / `MY062` |
| `GTID_SUBTRACT(RECEIVED, EXECUTED)` 体积 | 真实未应用量 | `MY063` |
| `Relay_Log_Space` | SQL 积压 | `MY064` |

**GTID 优化（必须写进脚本）：**

```sql
SELECT GTID_SUBSET(
  (SELECT RECEIVED_TRANSACTION_SET
     FROM performance_schema.replication_connection_status LIMIT 1),
  @@GLOBAL.gtid_executed
) AS received_subset_of_executed;   -- 期望 1

-- 未应用量用 SUBTRACT 的字符串长度/事务区间数，禁止 RECEIVED == gtid_executed
```

从库 `gtid_executed` 含 initialize UUID，和 `RECEIVED_TRANSACTION_SET` **天然不相等**。

**主库：**

| 指标 | 含义 | 信号 |
|---|---|---|
| Dump 线程数 | 应对上在线从库数 | `MY044` 偏少 |
| `Rpl_semi_sync_source/master_status` | 是否降级异步 | `MY100` |
| `yes_tx` / `no_tx` | 超时走异步比例 | `MY101` |
| `wait_sessions` | 会话卡在等 ACK | `MY102` |
| `clients` | ACK 从库数 | `MY103` |
| `Threads_running` / `Threads_connected` / `Max_used_connections` | 堆积 / 打满 | `MY080` / `MY081` |
| `Binlog_cache_disk_use` | 大事务打盘 | `MY082` |
| `Innodb_log_waits` | redo 跟不上 | `MY083` |
| `Innodb_row_lock_waits` / `Innodb_row_lock_time` | 行锁 | `MY084` |
| `Innodb_buffer_pool_reads` / `read_requests` | 命中率 | `MY085` |
| `Innodb_deadlocks`（若有） | 死锁 | `MY086` |

长事务（主从都采，LIMIT 10）：

```sql
SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s
FROM information_schema.innodb_trx
ORDER BY trx_started ASC
LIMIT 10;
```

`age_s >= 5` → `MY087`；`>= 30` → `MY087` high。

History list：从 `SHOW ENGINE INNODB STATUS` **只抽** `History list length` 一行（timeout 8s）。过大 → `MY088`。

阈值默认（可参数化，清洗用同一套）：

| 项 | warning | high |
|---|---|---|
| `Seconds_Behind_Source` | ≥5s | ≥30s |
| Relay_Log_Space | ≥256MB | ≥1GB |
| Threads_running | ≥32 | ≥64 或接近 max_connections |
| 命中率 `1-reads/requests` | <95% | <90% |
| semi-sync `no_tx` 增量 | >0 | 持续增加或 status=OFF |
| History list | ≥1e5 | ≥1e6 |

### 6.3 S — 运行状态（P0）

与 M 共享快照，本路只解释「卡在哪」：

| 采集 | 截断规则 | 信号 |
|---|---|---|
| `SHOW PROCESSLIST` | 只保留非 Sleep；优先 Dump / ACK / lock / clone / backup | `MY045` Dump 缺失；`MY102` 等 ACK |
| `innodb_trx` 已在 M 采集，这里附阻塞关系 | `data_lock_waits` LIMIT 20，timeout 8s | `MY089` |
| `SHOW ENGINE INNODB STATUS` | 只切 `DEADLOCK` / `LOG` / `FILE I/O` 三段，全文上限 64KB | `MY086` / `MY083` |
| `read_only` / `super_read_only` | 从库必须为 1 | `MY110` 从库可写 |
| 当前 DDL / 备份会话 | processlist 关键字 | `MY090` |

**优化：** 不要把完整 InnoDB status 交给 AI。三段标题 + 各 80 行足够定死锁/redo/IO。

### 6.4 C — 配置（P0，解析不 dump）

`SHOW VARIABLES WHERE Variable_name IN (...)` + 必要时 `mysqld --print-defaults` 的关键行。

| 变量 | 检查 |
|---|---|
| `server_id` | 全局唯一，交叉对比 |
| `gtid_mode` / `enforce_gtid_consistency` | 必须 ON |
| `binlog_format` | ROW |
| `sync_binlog` + `innodb_flush_log_at_trx_commit` | 非双 1 记 `MY112`（隐患，不一定是当前根因） |
| `binlog_expire_logs_seconds` / `expire_logs_days` | 过短 + IO 报找不到日志 → `MY046` |
| `replica_parallel_workers` | 0/1 且 SQL 落后 → `MY065` |
| `rpl_semi_sync_*` / timeout / wait_for_replica_count | 与运行 status 对照 |
| `max_connections` / `innodb_buffer_pool_size` | 和打满、命中率对照 |
| `time_zone` / `character_set_server` / `sql_mode` / `lower_case_table_names` | 主从不一致 → `MY113` |
| `read_only` / `super_read_only` | 从库关闭 → `MY110` |

产物是 `key=value` 列表 + 差异表，不是整份 cnf。

### 6.5 L — 日志（P0，tail+关键字）

路径候选：`@@log_error`、`/var/log/mysqld.log`、`datadir/*.err`。  
只取最近 8000 行（约 15 分钟窗口），timeout 15s。

关键字 → 场景：

| 模式 | ID |
|---|---|
| `Could not find first log file` / `purged binary logs` | `MY046` |
| `Replica.*stopped` / `Slave.*stopped` / reconnect | `MY040` `MY041` |
| `Duplicate entry` / `1062` | `MY130` |
| `Table .* doesn't exist` / `1146` | `MY131` |
| GTID 不一致 / `executed GTID` | `MY132` |
| `semi-sync` timeout / OFF / degenerat | `MY100` |
| `InnoDB:.*crash` / recovery / `Out of memory` | `MY033` `MY034` |
| `Too many connections` | `MY081` |
| `OS error.*28` / `No space left` | `MY160` |

Slow log：**若存在**，只统计窗口内条数 + 最慢 5 条（`mysqldumpslow -t 5` 或 `tail` 解析）。全量不采。  
General log：默认不采。

### 6.6 H — 主机网络（P0）

主机（timeout 合计 ≤15s）：

| 命令 | 信号 |
|---|---|
| `df -h` / `df -i`（datadir、binlog、relay 目录） | `MY160` 空间；`MY161` inode |
| `iostat -x 1 3` | `MY162` await/util 高；`MY163` iowait |
| `free -m` / `vmstat 1 3` | `MY011` 内存；`MY012` swap |
| `uptime` / 单核是否被 SQL 线程打满 | `MY010` |
| `ls /proc/<pid>/fd \| wc -l` vs `ulimit -n` | `MY013` |
| `timedatectl` 或 `chronyc tracking` | `MY014` 时钟偏移 |

网络（timeout 合计 ≤20s）：

| 命令 | 信号 |
|---|---|
| `ss -lntp \| grep 3306` | `MY031` |
| 从库 `ping -c 3 <primary>`；主库对每个从库 `ping -c 3` | `MY140` 丢包/RTT |
| `ss -s` / 重传（`nstat` 或 `/proc/net/netstat` 的 `RetransSegs` 采样 1s） | `MY141` |
| 主库网卡 `rx/tx` 1 秒增量 | `MY142` 出口打满（一主多从特有） |
| 探测 3306 直连 vs VIP（若提供 vip 参数） | `MY143` VIP 掐 dump |
| `iptables/nft` 粗看 DROP | `MY144` |

**优化：** 主从 RTT 必须 **按边** 采，不能只采本机网卡。交叉对比依赖这些边。

---

## 7. 交叉对比（清洗核心，禁止丢给 AI 自己发现）

清洗节点读取 **所有 IP** 的 `.signals` 和复制快照后，生成组合信号。这是一主多从相对单机排障的唯一关键增量。

| 组合条件 | 输出信号 | 定责方向 |
|---|---|---|
| ≥2 台从库 IO 非 ON | `MY190 ALL_REPLICA_IO_DOWN` | 主库、VIP、防火墙、binlog purge |
| 仅 1 台 IO 非 ON | `MY191 ONE_REPLICA_IO_DOWN` | 该从库网络/账号/本机 mysqld |
| ≥2 台 SQL 非 ON | `MY192 ALL_REPLICA_SQL_DOWN` | 主库发出的坏事件/DDL；或批量误写 |
| 仅 1 台 SQL 非 ON | `MY193 ONE_REPLICA_SQL_DOWN` | 该从库数据分叉/被写过 |
| 所有从库延迟同量级（差值 < 20%） | `MY194 LAG_ALL_SIMILAR` | 主库大事务、主库磁盘、主库出口 |
| 一台延迟显著高于其他（>3× 且 >10s） | `MY195 LAG_ONE_OUTLIER` | 该从库磁盘/读流量/并行度 |
| IO 位点贴近主库、SQL 位点落后 | `MY061 IO_CAUGHT_UP_SQL_BEHIND` | 从库回放 |
| IO 位点也落后主库最新 binlog | `MY062 IO_BEHIND_PRIMARY` | dump/网络/主库 I/O |
| 半同步 status OFF 或 `no_tx` 上升 | `MY100 SEMI_SYNC_DEGRADED` | 从库/网络拖主库写入 |
| 主库 `wait_sessions>0` | `MY102 PRIMARY_WAIT_ACK` | 先查 ACK 从库网络，而不是 SQL |
| Dump 数 < 从库数 | `MY044 DUMP_COUNT_MISMATCH` | 有从库没连上 |
| error log `Could not find first log file` | `MY046 BINLOG_PURGED` | 过期策略 + 从库断连窗口 |
| 从库 `read_only=0` | `MY110 REPLICA_WRITABLE` | 误写导致 1062 的前置 |
| `server_id` 重复 | `MY111` | dump 拒绝 |
| 时钟偏移 >2s | `MY014` | 不信任 `Seconds_Behind_Source` 绝对值 |

从库数为 1 时，`ALL_*` 与 `ONE_*` 同时成立。清洗必须注明 `replica_count=1`，AI 不得把「全员」写成多从结论。

---

## 8. 场景目录（MY ID）

清洗与 AI 使用同一套 ID。级别：P1 不可写/复制停/丢数据风险；P2 延迟/降级；P3 隐患。

### 8.1 基线

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY001 | 基线正常 | - | 复制 ON、无组合告警、预检通过 |

### 8.2 主机

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY010 | CPU 饱和（含 SQL 单核打满） | P2 | H |
| MY011 | 内存压力 | P2 | H |
| MY012 | swap | P2 | H |
| MY013 | FD / ulimit | P1 | H L |
| MY014 | 时钟偏移 | P3 | H |
| MY160 | 磁盘满 / 只读挂载 | P1 | H L |
| MY161 | inode 满 | P1 | H |
| MY162 | 磁盘延迟高 | P2 | H |
| MY163 | iowait 高 | P2 | H |

### 8.3 进程与实例

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY030 | mysqld 进程不在 | P1 | P H |
| MY031 | 3306 未监听 | P1 | P N |
| MY032 | 本地无法 `SELECT 1` | P1 | P |
| MY033 | crash / InnoDB recovery | P1 | L |
| MY034 | OOM | P1 | L H |
| MY035 | 反复重启 | P2 | L H |

### 8.4 复制线程与位点

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY040 | IO 线程非 ON | P1 | M S L |
| MY041 | SQL 线程非 ON | P1 | M S L |
| MY042 | IO 错误（连不上/鉴权/SSL） | P1 | M L N |
| MY043 | SQL 错误（1062/1146/GTID） | P1 | M L |
| MY044 | Dump 线程数不匹配 | P1 | S |
| MY045 | 主库无 Dump | P1 | S N |
| MY046 | 主库 binlog 已被 purge | P1 | L C |
| MY048 | 角色冲突 / 双主观感 | P1 | S C |

### 8.5 延迟

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY060 | 秒级延迟超阈 | P2 | M |
| MY061 | SQL 回放落后（IO 已跟上） | P2 | M |
| MY062 | IO 收日志落后 | P2 | M N |
| MY063 | GTID 未应用积压 | P2 | M |
| MY064 | relay log 堆积 | P2 | M H |
| MY065 | 并行复制未开，回放跟不上 | P2 | C M |

### 8.6 主库写入路径

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY080 | Threads_running 堆积 | P2 | M S |
| MY081 | 连接打满 | P1 | M L |
| MY082 | binlog cache 打盘（大事务） | P2 | M |
| MY083 | redo / log waits | P2 | M S |
| MY084 | 行锁等待 | P2 | M S |
| MY085 | buffer pool 命中率下降 | P2 | M |
| MY086 | 死锁 | P2 | S L |
| MY087 | 长事务 | P1/P2 | M S |
| MY088 | History list 过长 | P2 | M |
| MY089 | 锁等待链 | P2 | S |
| MY090 | DDL / 备份抢资源 | P2 | S H |

### 8.7 半同步

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY100 | 半同步降级异步 | P1 | M L |
| MY101 | `no_tx` 上升 | P2 | M |
| MY102 | 主库会话等 ACK | P1 | M S |
| MY103 | ACK 从库数量不足 | P1 | M N |

### 8.8 配置

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY110 | 从库未只读 | P1 | C S |
| MY111 | `server_id` 重复 | P1 | C |
| MY112 | 非双 1（crash 分叉风险） | P3 | C |
| MY113 | 时区/字符集/sql_mode 不一致 | P2 | C |
| MY114 | binlog 保留过短 | P2 | C L |

### 8.9 数据分叉（只报症状，5 分钟不证明无分叉）

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY130 | 主键冲突（从库被写或分叉） | P1 | L S |
| MY131 | 对象缺失 | P1 | L |
| MY132 | GTID 空洞 / 不一致 | P1 | M L |
| MY133 | 复制已恢复但一致性未核 | P3 | 清洗固定附加 |

### 8.10 网络

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY140 | 主从丢包 / RTT 高 | P2 | H |
| MY141 | TCP 重传 | P2 | H |
| MY142 | 主库出口带宽打满 | P2 | H M |
| MY143 | VIP/SLB 掐长连接 dump | P2 | H L |
| MY144 | 防火墙 / 安全组 | P1 | H L |

### 8.11 采集降级

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| MY170 | 预检失败 | P3 | P |
| MY171 | 客户端/工具缺失 | P3 | P |
| MY172 | 节点不可达 | P1 | 汇聚 |
| MY173 | 部分节点采集失败 | P2 | 汇聚 |
| MY174 | 命令超时 | P3 | 各路 `CMD_TIMEOUT` |

### 8.12 组合（清洗生成）

| ID | 场景 |
|---|---|
| MY190 | ALL_REPLICA_IO_DOWN |
| MY191 | ONE_REPLICA_IO_DOWN |
| MY192 | ALL_REPLICA_SQL_DOWN |
| MY193 | ONE_REPLICA_SQL_DOWN |
| MY194 | LAG_ALL_SIMILAR |
| MY195 | LAG_ONE_OUTLIER |
| MY196 | 长事务 + 全员延迟 |
| MY197 | 半同步等 ACK + 单从网络差 |
| MY198 | 磁盘满 + SQL 停止 |
| MY199 | 时钟偏移 + 仅秒级延迟告警（降权 MY060） |

---

## 9. 清洗（≤50s）

输入：所有节点 artifact + signals。  
输出：

```text
cleaned.txt          # 截断后的关键原文，上限 64KB
summary.md           # 给人看的一页纸
signals.uniq.tsv     # 去重后的 MY ID
cleaned.meta         # coverage_status=ok|degraded replica_count=N primary_ip=...
```

清洗步骤（纯规则，禁止 HTTP）：

1. 解析角色，选出 `primary_ip`。冲突则 `MY048`，`coverage=degraded`。
2. 合并 signals，同 ID 取最高 severity，note 拼接节点 IP。
3. 跑第 7 节交叉对比，写入 MY190–MY199。
4. 若只有 MY060 且存在 MY014，把 MY060 降为 low，并加 MY199。
5. `summary.md` 固定小节：拓扑、复制表（每从库 IO/SQL/延迟/GTID 差/relay）、主库半同步、Top 信号、证据缺口。
6. 原文只保留：每路 artifact 的 `SIGNAL` 行 + `CMD_FAIL` + 错误日志命中行。

覆盖判定：

| 条件 | coverage |
|---|---|
| 主库 + 至少 1 个从库的 M 快照都在 | ok |
| 缺主库或所有从库 M 快照 | degraded → 降级清洗 |
| 仅主机/日志 | degraded |

降级清洗：仍输出 summary，明确「未看见主库复制快照」等，不编造延迟数字。

---

## 10. AI 诊断契约（≤50s）

Prompt 只含：

1. 角色说明：MySQL 8.x GTID 一主多从，可能半同步  
2. 本文件第 8 节场景目录（压缩表）  
3. `summary.md` 全文  
4. `signals.uniq.tsv`  
5. `cleaned.txt` 截断 32KB  

要求模型输出（失败则启发式按同一模板填）：

```markdown
## 根因假设（按置信度）
1. MY... — ...
## 关键证据
## 影响面（写路径 / 读路径 / 数据风险）
## 立即止损（不自动执行）
## 验证步骤
## 证据缺口（5 分钟未做项）
```

硬约束：

- 禁止编造未出现的指标。
- 禁止宣称「主从数据一致」；最多写 MY133。
- 有 MY190/MY194 时，根因必须打到主库或公共链路，不能只点名一台从库。
- 有 MY102/MY197 时，必须把「主库写入慢」解释为等 ACK，而不是 SQL 慢查询。
- 启发式：按 severity 排序取前 5 个 ID，用固定中文模板，保证无模型时 5 分钟仍有结论。

---

## 11. 8.0 / 8.4 兼容

| 概念 | 8.0 | 8.4 |
|---|---|---|
| 复制状态 | `SHOW SLAVE STATUS` / `SHOW REPLICA STATUS` | `SHOW REPLICA STATUS` + P_S |
| 半同步插件 | `rpl_semi_sync_master/slave` | `rpl_semi_sync_source/replica` |
| STATUS 名 | `Rpl_semi_sync_master_*` | `Rpl_semi_sync_source_*` |
| 延迟字段 | `Seconds_Behind_Master` | `Seconds_Behind_Source` |
| dump 线程 | `Binlog Dump GTID` | 同左 |

采集脚本对每组名字都试，命中即用。清洗只认归一化字段：`io_running`、`sql_running`、`lag_s`、`semi_status`。

---

## 12. 产物与作业平台

节点 stdout 包裹，便于 SOPS 拼接：

```text
###MYSQL_TS_ARTIFACT kind=metrics node=172.30.0.12 file=...
...正文...
###MYSQL_TS_SIGNALS kind=metrics node=172.30.0.12
MY041	high	SQL thread OFF errno=1062
###END_MYSQL_TS_ARTIFACT###
```

清洗后：

```text
###MYSQL_TS_CLEANSED
###MYSQL_TS_AI_DIAGNOSIS
```

实验室：`troubleshooting/mysql/scripts/run_flow.sh`，`BACKEND=ssh|docker|local`，逻辑对齐 Kafka。

---

## 13. 落地文件（下一步实现，本文不写代码）

```text
troubleshooting/mysql/
  2026-09-15-mysql-primary-multi-replica-troubleshooting-design.md  # 本文
  README.md
  MYSQL_FAULT_SCENARIOS.md          # 实现阶段扩成与注入对位的全表
  scripts/
    _lib.sh                         # begin_artifact / emit_cmd_timeout / signal / exit 0
    collect_precheck.sh
    collect_metrics.sh              # 含角色识别 + 复制快照
    collect_status.sh               # 读同一 snapshot
    collect_config.sh
    collect_logs.sh
    collect_hostnet.sh
    cleanse.sh
    cleanse_degraded.sh
    ai_diagnose.sh                  # 启发式兜底
    run_flow.sh
  tools/generate_yaml.py            # 生成 SOPS YAML
```

对照部署拓扑：`deployments/数据库部署脚本/output/mysql84-gtid-primary-replicas-3node-083102.yaml`（`.11` 主，`.12/.13` 从，半同步 wait=1，timeout=10s）。

---

## 14. 验收标准

### 14.1 时间

在 1 主 2 从、SSH 可达、error log < 200MB 的实验室：

- 五路采集墙钟 **≤90s**（取最慢一路）
- 清洗 **≤50s**
- AI 或启发式 **≤50s**
- 端到端 **≤5min**（含汇聚）

用 `date +%s` 打点写进 `cleaned.meta`，超时即验收失败，不论结论对不对。

### 14.2 正确性（最小故障集）

| 注入/故障 | 必须打出的 ID |
|---|---|
| 停一台从库 mysqld | MY030 + MY191/MY044 |
| 从库 `STOP REPLICA SQL_THREAD` | MY041 + MY193 |
| 主库 `PURGE BINARY LOGS` 到从库需要的文件之前 | MY046 + MY190/MY040 |
| 从库去掉 `read_only` 后写入造成 1062 | MY110 + MY043 + MY130 + MY193 |
| 半同步 ACK 从库网络丢包 | MY102 + MY140 + MY197（主库写入变慢） |
| 仅一台从库 `iowait` 高 | MY162 + MY061 + MY195 |
| 主库长事务 | MY087 + MY194/MY196 |
| 采集时 mysqld 已死 | 流程仍出启发式诊断，含 MY030，exit 0 |

### 14.3 反例（打出算失败）

- 用 `RECEIVED == gtid_executed` 误报分叉  
- `mysql -N` + `\G` 把 IO/SQL 读成空并报复制全断  
- 只有 MY060、无视 MY014 时钟  
- 宣称数据一致  
- 单从延迟却输出「主库 binlog 打满所有从库」且无 MY142/MY194 证据  

---

## 15. 风险

| 风险 | 处理 |
|---|---|
| 从库很多（>5）主库 ping 边数变多 | H 路对从库列表 `xargs -P` 并行 ping，总超时仍 20s |
| error log 被 logrotate 刚切走 | 预检列出 `log_error` 与 `.err-YYYYMMDD`，tail 最新文件 |
| 账号只有从库只读、无 `PROCESS` | 记 MY171，Dump 线程看不到，coverage=degraded |
| 半同步未部署 | 半同步指标全 `NA`，不报 MY100 |
| AI 端点慢 | 45s kill，启发式顶上 |

---

## 16. 实现顺序建议

1. `_lib.sh` + 角色识别 + 复制快照（P_S 优先）  
2. 五路 P0 命令 + 单命令 timeout + 信号  
3. 清洗交叉对比 MY190–MY199  
4. 启发式诊断（无 AI 也能验收 14.2）  
5. SOPS YAML + `run_flow.sh` 汇聚  
6. 再接 AI 端点  
7. 最后才做故障注入全表（`MYSQL_FAULT_SCENARIOS.md`）

不要先写 YAML 再补采集：Kafka v1 的主要缺口就是「流程有了、定责信号没有」。
