# Kafka 排障流程覆盖复盘

对照 [`KAFKA_FAULT_SCENARIOS.md`](./KAFKA_FAULT_SCENARIOS.md)（KF001–KF127）审查 v1 YAML，并说明 v2 如何补齐。

## 1. v1 流程（用户要求的骨架）

并行采集：**监控指标、配置、过滤日志、主机、网络** → **数据清洗** → **AI 诊断**。

这已经覆盖 Redis 排障 Bot 的「五路采集 + 清洗 + AI」。下面按故障域看 **证据是否进得去 AI**。

## 2. 覆盖矩阵

图例：● 主证据在该路；○ 辅助；– 基本看不到。

| 故障域 | 场景 | M 指标 | C 配置 | L 日志 | H 主机 | N 网络 | v1 结论 | v2 补强 |
|---|---|---|---|---|---|---|---|---|
| 基线 | KF001 | ● | ○ | ○ | ● | ● | 覆盖（缺产消探针） | 增加 produce/consume probe |
| CPU/MEM/重启 | KF002–KF009 | ○ | – | ○ | ● | – | 覆盖 | jstat/load 阈值信号 |
| 时钟 | KF010 | – | – | ○ | ○ | – | **缺口** | host 增加 timedatectl/NTP 信号 |
| FD/inode/ulimit | KF011/012/014 | – | – | ● | ● | – | 部分（无 fd 计数） | `/proc/pid/fd` + `df -i` |
| DNS | KF013 | – | ○ | ● | – | ● | 部分 | 解析 advertised + getent |
| 进程停/挂起 | KF015/016 | ● | – | ● | ● | ● | 覆盖 | 预检 PROCESS_DOWN |
| JVM OOM/GC | KF017/018 | – | ○ | ● | ○ | – | 日志可中，缺 GC 数值 | jstat/jcmd |
| 启动失败 | KF024 | – | ● | ● | – | – | 覆盖 | 预检 Java/CLI |
| 单 Controller | KF025 | ○ | ○ | ● | – | ● | **缺口：无 quorum 命令** | `kafka-metadata-quorum.sh` |
| 法定人数丢失 | KF026 | ○ | – | ● | – | ● | 同上 | quorum status/replication |
| cluster.id / node.id / voters | KF028/029/033 | – | ● | ● | – | – | 配置+日志可中 | 显式解析 voters vs 三 IP |
| URP / Offline / 无 Leader | KF036–038/046 | ○ | – | ● | – | – | **缺口：无 URP 专用查询** | `--under-replicated-partitions` / `--unavailable-partitions` |
| ISR / min.isr | KF039/044/053/101 | ○ | ● | ● | – | – | 配置可中 min.isr，缺 ISR 实时 | topics describe + min-isr 信号 |
| 热点分区 | KF047 | – | – | – | ○ | – | **弱** | 产消探针 + 流量场景靠注入侧 |
| 未知 Topic | KF050/051 | ○ | ● | ● | – | – | 部分 | topics list + auto.create 解析 |
| 生产超时/过大 | KF052/055 | – | – | ● | – | ○ | 日志可中 | 产消探针失败 → KF052 |
| 消费组/lag/coordinator | KF061–064 | – | – | ● | – | ○ | **缺口** | consumer-groups --describe |
| 9092/9093 阻断与分区 | KF071–077 | ○ | – | ○ | – | ● | 覆盖 | 对等 TCP 探测 + tc qdisc 信号 |
| advertised | KF078 | – | ● | – | – | ○ | 部分 | 探测 advertised 端点 |
| 磁盘满/只读/IO | KF083–085/093 | – | ○ | ● | ● | – | 覆盖 df/iostat | log.dirs `df` 阈值信号 + log-dirs API |
| 日志损坏 | KF087 | – | – | ● | – | – | 日志关键字 | 保持 |
| SASL/ACL/TLS | KF094–096 | – | ○ | ● | – | ○ | 实验室 PLAINTEXT，记录 N/A | 日志关键字保留，避免误报 |
| 连接/配额 | KF097/099 | – | ○ | ● | ○ | ● | 弱 | ss 连接数；配额需 JMX/注入 |
| 组合 | KF111–116 | ● | – | ● | ● | ● | 清洗无组合规则 | 启发式组合规则 |
| 采集降级 | KF117–120 | – | – | – | – | ● | **缺口：采集失败会打断流程** | ignore_error + 预检 + ExclusiveGateway 降级清洗 |
| ZK/Connect/SR 等 | KF121–127 | – | – | – | – | – | 正确标 N/A | AI catalog 注明不适用 |

## 3. v1 必须改的问题

1. **KRaft 法定人数没有一等公民采集** → KF025/026 只能靠端口和日志猜。  
2. **没有 URP/Offline 专用 API** → KF036/037 容易漏。  
3. **没有消费组** → KF061–064 几乎只能看日志。  
4. **采集脚本 `set -e` 或作业失败会卡死** → 真实故障时排障流自己挂。  
5. **无共享盘时清洗只看见本机产物** → 三节点 host/logs 无法进 AI（实验室用 `run_flow.sh` 汇聚）。  
6. **清洗不输出场景 ID** → AI 与注入验收无法对表。  
7. **无降级路径** → 工具缺失（KF118）与节点不可达（KF117）没有单独节点。

## 4. v2 优化要点

| 改动 | 覆盖的场景 |
|---|---|
| 采集预检节点 | KF015、KF118、KF119、KF120 |
| 全部采集 `ignore_error: true` 且脚本 `exit 0` | 任意 P1 仍能进 AI |
| `kafka-metadata-quorum.sh describe --status/--replication` | KF025 KF026 KF031 |
| topics `--under-replicated-partitions` / `--unavailable-partitions` | KF036 KF037 KF038 KF046 |
| consumer-groups list/describe | KF061 KF062 KF064 |
| log-dirs API + `df log.dirs` | KF083 KF085 |
| jstat/jcmd + fd + inode + NTP | KF017 KF018 KF011 KF012 KF010 |
| 9092/9093 对等探测、tc、iptables、advertised TCP | KF071–079 |
| 产消探针 | KF001 KF052 KF053 |
| 配置解析 min.isr/RF/voters/unclean/auto.create | KF033 KF101 KF102 KF106 KF108 |
| 日志关键字 → KF ID | 几乎所有 L 列 ● 的场景 |
| 清洗去重 + 组合规则 KF111–116 | 组合域 |
| ExclusiveGateway 降级清洗 | KF117–120 |
| AI prompt 内置 KF 目录 + 启发式对照 | 全表可映射 |

## 5. 仍不宣称「脚本能单独确诊」的场景

这些即使 v2 也只能 **部分证据**，需要 AI 结合变更史或注入侧：

- KF020 死锁、KF042 reassignment 卡住、KF048 海量分区、KF057 幂等 epoch、KF066 毒消息、KF080/094–096 安全栈（实验室未开）、KF121–127 未部署组件。

对应策略：场景清单标 `N`/`P`，AI 输出「证据不足 / 环境不适用」，而不是编造根因。

## 6. 结论

- **v1** 满足「指标 + 配置 + 日志 + 主机网络 → 清洗 → AI」交付形态，对主机/进程/磁盘/基础网络可用，但对 **KRaft quorum、URP、消费组、采集降级** 不够。  
- **v2**（`kafka38-kraft-troubleshoot-v2.yaml`）作为排障主流程。  
- 与注入脚本的对位验收见 `kafka_fault_injection/`。
