# Kafka Cluster 完整故障注入方案

> 验收范围：故障是否成功注入（现象、持续、自动恢复）。  
> **不包含**：SOPS 五路采集 / 清洗 / AI（见 `troubleshooting/kafka/`）。

## 1. 原则

| 项 | 约定 |
|---|---|
| 交付物 | Shell + 场景清单 + preflight + 节点规范 |
| 注入 Bot | 仅 `docker-node` |
| 故障对象 | Docker 容器模拟 VM，容器内二进制 Kafka 3.8.1 KRaft |
| 互斥 | 同时只跑一个 inject（组合内部 skip lock） |
| 持续 | 默认 600s 自动恢复 |
| 解析 | `INJECT_RESULT scenario=KF0xx status=pass\|fail` |

## 2. 实验室拓扑

同 Redis 实验室网段 `10.10.26.0/24`：

- 注入机 `10.10.26.10`
- kafka-n1/n2/n3 = 144/145/146，`mem_limit` 建议 1536m+，`NET_ADMIN`，`ulimit nofile=65535`
- 数据目录 `/var/lib/kafka/data`，日志 `/var/log/kafka`，配置 `/etc/kafka/server.properties`

## 3. 脚本架构

| 脚本 | 职责 |
|---|---|
| `preflight.sh` | 容器、工具、Broker API、quorum |
| `inject_host.sh` | CPU/内存/重启/时钟/基线 |
| `inject_kafka.sh` | 进程/JVM/元数据/主题/流量 |
| `inject_network.sh` | 9092/9093、分区、丢包、延迟、限速 |
| `inject_disk.sh` | 磁盘满/只读/IO/inode |
| `inject_composite.sh` | KF111–KF116 |
| `inject_degrade.sh` | 采集降级 |
| `lib/common.sh` | 锁、docker exec、post-check、`INJECT_RESULT` |

## 4. Post-check 要点

| 场景 | 条件 |
|---|---|
| KF002 cpu | vmstat 平均 CPU ≥80% |
| KF004 memory | cgroup 可用 ≤15% 或已用 ≥85% |
| KF015 process-stop | 目标 `kafka-broker-api-versions` 失败 |
| KF036/039 isr-shrink | `--under-replicated-partitions` 非空 |
| KF075 packet-loss | `tc qdisc` 含 netem loss |
| KF083 disk-full | `df` log.dirs 尽量 ≥80%（小盘尽力） |

## 5. 回归顺序

见 [`KAFKA_FAULT_SCENARIOS.md`](./KAFKA_FAULT_SCENARIOS.md)「推荐首跑」。破坏性（KF006 reboot、KF027/087 corrupt）放在隔离实验末尾，且需要 `--confirm YES`。

## 6. 排障线索（给排障 Bot）

| ID | 预期线索 |
|---|---|
| KF002 | host CPU 高 |
| KF004 | 内存紧张 |
| KF015 | 9092 不监听、API 失败 |
| KF025/072 | quorum voter 缺、9093 不通 |
| KF026 | 元数据命令失败 |
| KF036 | URP |
| KF053/044 | 产消探针失败、NotEnoughReplicas |
| KF071 | TCP 9092 fail |
| KF083 | df 高、No space 日志 |
| KF117/118 | 清洗 coverage=degraded |
