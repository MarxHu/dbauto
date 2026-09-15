# MySQL 一主多从排障场景（注入对照）

> **注入命令与手法**：[`../../mysql_fault_injection/MYSQL_FAULT_SCENARIOS.md`](../../mysql_fault_injection/MYSQL_FAULT_SCENARIOS.md)  
> **5 分钟排障设计**：见分支 `cursor/mysql-primary-replica-ts-design-44dd` 的 `troubleshooting/mysql/2026-09-15-mysql-primary-multi-replica-troubleshooting-design.md`  
> **拓扑**：MySQL 8.0 / 8.4 GTID 一主两从，默认半同步。

本文是排障视角：每个 MY ID 落在哪路采集、实验室能否注入。ID 与注入全表相同。

图例：采集列 M 指标 / S 运行状态 / C 配置 / L 日志 / H 主机网络 / P 预检。  
注入列：`Y` 可注入（CLI 已冻结） / `P` 需 `--confirm YES` 或部分可注入 / `N` 当前拓扑不做。

---

## 基线 / 主机

| ID | 场景 | 级 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|
| MY001 | 基线正常 | - | M S H | Y | `host --action baseline` |
| MY010 | CPU 饱和 | P2 | H M | Y | `host --action cpu`（打主 vs 打从现象不同） |
| MY011 | 内存压力 | P2 | H | Y | `host --action memory` |
| MY012 | swap | P2 | H | P | 加强 memory |
| MY013 | FD / ulimit | P1 | H L | P | 后续 `mysql --action fd-exhaust` |
| MY014 | 时钟偏移 | P3 | H | Y | `host --action clock-skew` |
| MY160 | 磁盘满 | P1 | H L | Y | `disk --action disk-full` |
| MY161 | inode 满 | P1 | H | Y | `disk --action inode-exhaust` |
| MY162 | 磁盘延迟高 | P2 | H | Y | `disk --action io-stress` |
| MY163 | iowait 高 | P2 | H | P | io-stress |

## 进程与实例

| ID | 场景 | 级 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|
| MY030 | mysqld 不在 | P1 | P H | Y | `mysql --action process-stop` |
| MY031 | 3306 未监听 | P1 | P H | Y | process-stop / `network --action client-block` |
| MY032 | 无法 SELECT 1 | P1 | P | Y | process-stop / freeze |
| MY033 | crash / recovery | P1 | L | P | kill -9（非默认） |
| MY034 | OOM | P1 | L H | P | `mysql --action oom --confirm YES` |
| MY035 | 反复重启 | P2 | L H | Y | `host --action reboot` |
| MY036 | SIGSTOP 挂起 | P1 | M H | Y | `mysql --action process-freeze` |

## 复制

| ID | 场景 | 级 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|
| MY040 | IO 非 ON | P1 | M S L | Y | `repl --action stop-io --scope one\|all` |
| MY041 | SQL 非 ON | P1 | M S L | Y | `repl --action stop-sql --scope one\|all` |
| MY042 | IO 鉴权/连不上 | P1 | M L H | Y | `repl --action bad-repl-auth` / `bad-source-host` |
| MY043 | SQL 1062/1146/GTID | P1 | M L | Y | `repl --action replica-1062` |
| MY044 | Dump 数不匹配 | P1 | S | Y | 停一台从 mysqld / IO |
| MY045 | 主库无 Dump | P1 | S H | Y | 主库 client-block 或停全部从 IO |
| MY046 | binlog 已被 purge | P1 | L C | P | `repl --action binlog-purge --confirm YES` |
| MY047 | 复制指向错误主机 | P1 | M L | Y | `repl --action bad-source-host` |
| MY048 | 角色冲突 | P1 | S C | N | 需人工造双主，默认不做 |

## 延迟

| ID | 场景 | 级 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|
| MY060 | 秒级延迟超阈 | P2 | M | Y | long-trx / io-stress / rate-limit |
| MY061 | SQL 回放落后 | P2 | M | Y | stop-sql 积压 / 单从 io-stress |
| MY062 | IO 收日志落后 | P2 | M H | Y | repl-block / packet-loss / 主限速 |
| MY063 | GTID 未应用积压 | P2 | M | Y | `repl --action sql-backlog` |
| MY064 | relay 堆积 | P2 | M H | P | sql-backlog + 写流量 |
| MY065 | 并行复制关闭 | P2 | C M | Y | `repl --action serial-apply` |
| MY066 | SQL_DELAY | P2 | M | Y | `repl --action sql-delay` |

## 主库写入 / 半同步

| ID | 场景 | 级 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|
| MY080 | Threads_running 堆积 | P2 | M S | Y | `mysql --action slow-query` |
| MY081 | 连接打满 | P1 | M L | Y | `mysql --action max-connections` |
| MY082 | 大事务打盘 | P2 | M | Y | `mysql --action big-trx` |
| MY083 | redo / log waits | P2 | M S | P | 大事务 + io-stress |
| MY084 | 行锁 | P2 | M S | Y | `mysql --action hot-row` |
| MY085 | buffer pool 命中率 | P2 | M | P | `mysql --action buffer-pool-shrink` |
| MY086 | 死锁 | P2 | S L | P | 两会话交叉锁（非默认） |
| MY087 | 长事务 | P1/P2 | M S | Y | `mysql --action long-trx` |
| MY088 | History list | P2 | M | P | 长事务不提交 |
| MY100 | 半同步降级 | P1 | M L | Y | `repl --action semi-sync-degrade` |
| MY101 | no_tx 上升 | P2 | M | Y | `repl --action semi-sync-timeout-pulse` |
| MY102 | 主库等 ACK | P1 | M S | Y | `repl --action semi-sync-wait-ack`（勿只隔离一台） |
| MY103 | ACK 从数量不足 | P1 | M H | Y | `repl --action semi-sync-under-ack` |

## 配置 / 分叉 / 网络 / 降级

| ID | 场景 | 级 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|
| MY110 | 从库未只读 | P1 | C S | Y | `repl --action replica-writable` |
| MY111 | server_id 重复 | P1 | C | P | `repl --action dup-server-id --confirm YES` |
| MY112 | 非双 1 | P3 | C | N | 改持久化参数，默认不注入 |
| MY113 | 时区/字符集不一致 | P2 | C | P | 改会话/全局变量 |
| MY114 | binlog 保留过短 | P2 | C L | P | 配合 MY046 |
| MY130 | 主键冲突 1062 | P1 | L S | P | `repl --action replica-1062 --confirm YES` |
| MY131 | 对象缺失 1146 | P1 | L | P | 从库 DROP TABLE（破坏性） |
| MY132 | GTID 空洞 | P1 | M L | P | `repl --action gtid-skip --confirm YES` |
| MY140 | 丢包 / RTT | P2 | H | Y | `network --action packet-loss` / `latency` |
| MY141 | TCP 重传 | P2 | H | P | packet-loss |
| MY142 | 主库出口打满 | P2 | H M | Y | `network --action rate-limit`（打主） |
| MY143 | VIP 掐 dump | P2 | H L | N | 实验室无 VIP |
| MY144 | 防火墙 / 分区 | P1 | H L | Y | `network --action repl-block` / `primary-replica-partition` |
| MY171 | 工具缺失 | P3 | P | Y | `degrade --action hide-tools` |
| MY172 | 节点不可达 | P1 | 汇聚 | Y | `degrade --action job-unreachable` |
| MY174 | 命令超时 | P3 | 各路 | N | 排障侧 timeout，不注入 |

## 组合（清洗生成，注入侧有对应复合动作）

| ID | 场景 | 注入 |
|---|---|---|
| MY190 | ALL_REPLICA_IO_DOWN | `repl --action stop-io --scope all` 或 `network --action repl-block --scope all` |
| MY191 | ONE_REPLICA_IO_DOWN | `stop-io --scope one` / `repl-block` 单从 |
| MY192 | ALL_REPLICA_SQL_DOWN | `stop-sql --scope all` |
| MY193 | ONE_REPLICA_SQL_DOWN | `stop-sql --scope one` |
| MY194 | LAG_ALL_SIMILAR | 主库 long-trx / 主库 io-stress / 主库 rate-limit |
| MY195 | LAG_ONE_OUTLIER | 单从 io-stress / 单从 CPU |
| MY196 | 长事务 + 全员延迟 | `composite --action long-trx-plus-lag` |
| MY197 | 半同步等 ACK + 从网络差 | `composite --action ack-plus-net` |
| MY198 | 磁盘满 + SQL 停止 | `composite --action disk-plus-sql-stop` |
| MY199 | 时钟偏移 + 仅秒级延迟 | `composite --action clock-plus-lag-metric` |

## 排障最小故障集（必须先能注入）

| 注入 | 必须打出的 ID |
|---|---|
| 停一台从库 mysqld | MY030 + MY191/MY044 |
| 从库 `STOP REPLICA SQL_THREAD` | MY041 + MY193 |
| 主库 PURGE 越过从库需要的 binlog | MY046 + MY190/MY040 |
| 从库去掉只读后写入造成 1062 | MY110 + MY043 + MY130 + MY193 |
| 半同步 ACK 路径网络差（两从或 wait_count=2） | MY102 + MY140 + MY197 |
| 仅一台从库 iowait 高 | MY162 + MY061 + MY195 |
| 主库长事务 | MY087 + MY194/MY196 |
| 采集时 mysqld 已死 / 藏工具 | MY030 或 MY171，流程 exit 0 |
