# MySQL 故障注入环境前提

> 场景全表：[`MYSQL_FAULT_SCENARIOS.md`](./MYSQL_FAULT_SCENARIOS.md)  
> 节点工具基线对齐 Redis：`deployments/数据库部署脚本/docs/redis-docker-node-spec.md`（stress-ng / iptables / tc / dd）。

## 节点约定

| 容器 / 主机 | 角色 | IP | 必装 |
|---|---|---|---|
| `mysql-n1` | 主 | `10.10.26.144` | `stress-ng` `vmstat` `chmod` `dd` `iptables` `tc` `mysqld` |
| `mysql-n2` | 从 | `10.10.26.145` | 同上 |
| `mysql-n3` | 从 | `10.10.26.146` | 同上 |
| 注入机 `docker-node` | Bot | `10.10.26.10` | `mysql` 客户端 `flock` `bash`≥4 + `docker` CLI |

SOPS 拓扑把 IP 换成 `172.30.0.11/12/13`，工具要求相同。

只在 **注入机** 跑 `preflight.sh` 和 `inject_*.sh`。

## 注入优化要点（从 Redis 实验室继承）

| 场景 | 环境 | 脚本 |
|---|---|---|
| MY011 memory | 容器 `mem_limit=1536m` | cgroup 可用≤15% **或** 已用≥85% |
| MY140 packet-loss | 宿主机 `modprobe sch_netem` | 单层 `tc qdisc replace … root netem`（不用 HTB） |
| MY162 io-stress | 数据盘非 tmpfs | 默认 `IO_DIR=<datadir>/fault_io` |
| MY030 process-stop | — | 注入前 `docker update --restart=no`，`SELECT 1` 连续 3s 失败 |
| MY102 semi-sync-wait-ack | `wait_for_replica_count=1` | **禁止**只隔离一台从；必须两从延迟/断开或临时 wait_count=2 |

## 复制验收

- 8.4 用 `performance_schema.replication_*`，不要 `mysql -N ...\G`。  
- GTID：用 `GTID_SUBSET` / `GTID_SUBTRACT`，禁止 `RECEIVED == gtid_executed`。  
- 从库必须 `read_only=1` 且 `super_read_only=1`（注入 MY110 前记录原值）。
