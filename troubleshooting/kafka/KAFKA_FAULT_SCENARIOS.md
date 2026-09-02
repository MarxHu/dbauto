# Kafka KRaft 故障场景全表

> **拓扑基线**：Apache Kafka **3.8.1**，KRaft 三节点（`process.roles=broker,controller`），副本因子 3，`min.insync.replicas=2`，PLAINTEXT `9092`，CONTROLLER `9093`。  
> **实验室 IP**：`10.10.26.144/145/146`（`kafka-n1/n2/n3`）。  
> **排障流程**：[`README.md`](./README.md)（五路采集 → 清洗 → AI）。  
> **注入方案**：[`../../kafka_fault_injection/`](../../kafka_fault_injection/README.md)。

本文是 **全部 Kafka 故障场景** 的单一清单（现象、证据落在哪路采集、是否实验室可注入）。ID 全局唯一，清洗节点与 AI prompt 使用同一套 ID。

---

## 0. 使用约定

| 项 | 说明 |
|---|---|
| ID | `KF` + 三位数字 |
| 级别 | P1 集群不可用/丢数据风险；P2 吞吐/延迟/部分分区异常；P3 配置隐患/可观测性降级 |
| 采集列 | M 监控指标 / C 配置 / L 日志 / H 主机 / N 网络 / P 预检 |
| 注入 | `Y` 本仓库脚本可注入；`P` 部分可注入或需人工确认；`N` 当前实验室不适用 |
| 默认持续 | 注入 `--duration 600`，到期自动恢复（重启/损坏类除外） |

---

## 1. 基线

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF001** | 正常基线 | - | 产消成功，无 URP/Offline，quorum Leader 稳定 | M C H N | Y | `host --action baseline` |

---

## 2. 主机资源

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF002** | CPU 持续高压 | P2 | 负载高、请求延迟升、ISR 可能收缩 | H M L | Y | `host --action cpu` |
| **KF003** | CPU 瞬时尖峰 | P3 | 周期性延迟毛刺 | H | Y | `host --action cpu-spike` |
| **KF004** | 主机内存压力 | P2 | swap/GC、page fault、broker 变慢 | H | Y | `host --action memory` |
| **KF005** | 主机 OOM killer | P1 | kafka 进程被杀、systemd 重启 | H L | P | 内存注入加码或 `kafka --action heap-oom` |
| **KF006** | 主机重启 | P1 | 节点短暂消失、Leader 迁移 | M N H | Y | `host --action reboot --confirm YES` |
| **KF007** | 多节点 CPU | P1 | 全集群变慢 | H | Y | `host --action multi-cpu` |
| **KF008** | Run queue 打满 | P2 | 调度延迟 | H | P | CPU 注入 |
| **KF009** | Swap 颠簸 | P2 | 延迟尖刺 | H | P | memory 注入 |
| **KF010** | 时钟偏移 | P2 | 会话/重平衡异常、日志时间错乱 | H | Y | `host --action clock-skew` |
| **KF011** | 文件句柄耗尽 | P1 | `Too many open files`、accept 失败 | H L | Y | `kafka --action fd-exhaust` |
| **KF012** | inode 耗尽 | P1 | 无法建 log segment | H L | Y | `disk --action inode-exhaust` |
| **KF013** | DNS/hosts 失败 | P2 | UnknownHost、advertised 不可达 | N L C | Y | `network --action dns-fail` |
| **KF014** | ulimit 过小 | P2 | 连接/FD 提前打满 | H C | P | 需改 systemd，实验室用 KF011 近似 |

---

## 3. 进程 / JVM

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF015** | Broker 进程停止 | P1 | 端口消失、副本掉线 | M H N L | Y | `kafka --action process-stop` |
| **KF016** | SIGSTOP 挂起 | P1 | 端口还在但 API 卡住 | M N L | Y | `kafka --action process-freeze` |
| **KF017** | JVM Heap OOM | P1 | OOM Error、进程退出 | L H | Y | `kafka --action heap-oom` |
| **KF018** | 长时间 GC / 停顿 | P2 | 延迟、会话超时、ISR 收缩 | H L M | Y | `kafka --action gc-storm` |
| **KF019** | Metaspace 耗尽 | P2 | 类加载 OOM | L H | N | 需改 JVM 参数，实验室不作为默认 |
| **KF020** | 线程死锁 | P1 | 请求挂死 | H L | N | 难稳定注入 |
| **KF021** | systemd 重启循环 | P2 | 反复掉线 | C H L | P | process-stop + Restart=always |
| **KF022** | FD 泄漏 | P2 | fd 计数持续涨 | H | P | KF011 |
| **KF023** | 错误堆参数 | P2 | 启动慢/频繁 GC | C H | P | 改 KAFKA_HEAP_OPTS |
| **KF024** | 启动失败（配置语法/缺 Java） | P1 | 服务起不来 | C P L | P | 破坏 server.properties |

---

## 4. KRaft 集群 / Controller

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF025** | 单 Controller 失联 | P2 | quorum 少 1 voter，仍可写 | M N L | Y | `network --action controller-block` 或停 1 节点 |
| **KF026** | 法定人数丢失（≥2 Controller） | P1 | 元数据不可用、创建 Topic/选举失败 | M N | Y | `kafka --action quorum-loss` |
| **KF027** | 元数据日志损坏 | P1 | 节点无法加入、反复崩溃 | L C | P | `kafka --action metadata-corrupt` |
| **KF028** | cluster.id 不匹配 | P1 | 拒绝加入 | L C | P | 改 meta.properties |
| **KF029** | node.id 冲突 | P1 | Duplicate broker registration | L C | P | 复制配置到错误节点 |
| **KF030** | 元数据脑裂观感 | P1 | 客户端看到不一致 Leader | M N | P | 双分区 KF073 |
| **KF031** | Controller 选举风暴 | P2 | 频繁 Resign/Become | L M | P | 抖动 9093 |
| **KF032** | metadata snapshot 失败 | P2 | 磁盘/权限 | L H | P | KF084 |
| **KF033** | voters 配置不一致 | P1 | 部分节点选不出 Leader | C M | P | 改 server.properties |
| **KF034** | 新节点无法加入 | P2 | 注册失败 | C M L | N | 需扩容拓扑 |
| **KF035** | IBP/feature 不兼容 | P2 | 互通失败 | C L | N | 需多版本 |

---

## 5. Topic / 分区 / 副本

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF036** | UnderReplicatedPartitions | P2 | `--under-replicated-partitions` 非空 | M L | Y | 停 broker / 堵网 / IO |
| **KF037** | Offline / unavailable 分区 | P1 | `--unavailable-partitions` 非空 | M L | Y | 停多数副本 |
| **KF038** | Leader 不可用 | P1 | NotLeader、LEADER_NOT_AVAILABLE | M L | Y | 停 leader broker |
| **KF039** | ISR 收缩 | P2 | ISR 变短、min.isr 风险 | M L | Y | `kafka --action isr-shrink` |
| **KF040** | 副本落后 | P2 | replica lag | M | P | 限速/IO |
| **KF041** | 首选副本倾斜 | P3 | 流量不均 | M | Y | `kafka --action leader-skew` |
| **KF042** | 分区重分配卡住 | P2 | reassignment 长期未完成 | M L | N | 需运维窗口 |
| **KF043** | RF > 存活 broker | P1 | 无法满足副本 | M C | Y | 停节点使存活 < RF |
| **KF044** | min.isr > 当前 ISR | P1 | NotEnoughReplicas | M C | Y | `kafka --action min-isr-breach` |
| **KF045** | Unclean leader election | P1 | 可能丢数据 | C L | P | 需打开 unclean（实验室默认关） |
| **KF046** | 无 Leader 分区 | P1 | 生产失败 | M | Y | 同 KF037 |
| **KF047** | 热点分区 | P2 | 单分区流量打满 | M H | Y | `kafka --action hot-partition` |
| **KF048** | 分区数过多 | P3 | 控制器/HEAP 压力 | C M | N | 需建大量分区 |
| **KF049** | Topic 删除卡住 | P2 | 标记删除不落地 | L M | N | |
| **KF050** | 未知 Topic | P2 | UNKNOWN_TOPIC_OR_PARTITION | M L | Y | `kafka --action unknown-topic` |
| **KF051** | auto.create=false 生产失败 | P2 | 主题不存在 | C M | Y | 同 KF050（基线已关闭自动建） |

---

## 6. 生产者

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF052** | 生产超时 | P2 | request timeout、探针失败 | M L | Y | 丢包/冻结/停 Leader |
| **KF053** | NotEnoughReplicas | P1 | acks=all 被拒 | M L | Y | min-isr-breach / 停副本 |
| **KF054** | NotEnoughReplicasAfterAppend | P1 | 追加后 ISR 不够 | M L | P | 写入中杀副本 |
| **KF055** | 消息过大 | P2 | RecordTooLarge | L M | Y | `kafka --action oversized-record` |
| **KF056** | acks=all 写入阻塞 | P2 | 客户端阻塞 | M | P | KF044 |
| **KF057** | 幂等 Producer epoch 错误 | P2 | InvalidPidMapping | L | N | 需精确客户端时序 |
| **KF058** | 事务超时/abort | P2 | Txn abort | L M | P | `kafka --action txn-abort` |
| **KF059** | 压缩/魔数不匹配 | P2 | 脏数据 | L | N | |
| **KF060** | Produce Quota | P3 | throttle | M L | Y | `kafka --action produce-quota` |

---

## 7. 消费者 / Group

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF061** | 重平衡风暴 | P2 | PreparingRebalance 频繁 | M L | Y | `kafka --action rebalance-storm` |
| **KF062** | 消费 Lag | P2 | group describe LAG 高 | M | Y | `kafka --action consumer-lag` |
| **KF063** | OffsetOutOfRange | P2 | 重置策略触发 | L M | Y | `kafka --action offset-oor` |
| **KF064** | Coordinator 不可用 | P2 | 组查询失败 | M N | Y | 停 offsets 所在节点 |
| **KF065** | max.poll.interval 被踢 | P2 | 成员离开 | L | P | 慢消费模拟 |
| **KF066** | 毒消息 | P2 | 反序列化死循环 | L | N | 应用层 |
| **KF067** | 消费组卡死 | P2 | 不前进 | M | P | KF062 |
| **KF068** | Fetch Quota | P3 | throttle | M | P | 配额 |
| **KF069** | 静态成员重复 | P2 | 互踢 | L | N | |
| **KF070** | 同组错误实例 | P3 | 分区抢占 | M | N | |

---

## 8. 网络

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF071** | 9092 客户端/内部阻断 | P1 | TCP_FAIL 9092 | N M | Y | `network --action broker-block` |
| **KF072** | 9093 Controller 阻断 | P1 | quorum 异常 | N M | Y | `network --action controller-block` |
| **KF073** | 两 Broker 双向分区 | P1 | 互不可达、ISR/quorum 异常 | N M | Y | `network --action broker-partition` |
| **KF074** | 仅客户端到单节点隔离 | P2 | 采集/客户端降级 | N | Y | `degrade --action job-unreachable` |
| **KF075** | 丢包 | P2 | 超时重试 | N | Y | `network --action packet-loss` |
| **KF076** | 延迟/抖动 | P2 | 高 p99 | N | Y | `network --action latency` |
| **KF077** | 带宽限速 | P2 | 吞吐下降、副本落后 | N | Y | `network --action rate-limit` |
| **KF078** | advertised.listeners 错误 | P2 | 客户端连错地址 | C N | P | 改配置 |
| **KF079** | 防火墙 DROP | P2 | 同 KF071/072 | N | Y | iptables 类动作 |
| **KF080** | TLS 握手失败 | P2 | SSL handshake | L N | N | 实验室 PLAINTEXT |
| **KF081** | TIME_WAIT 打满 | P3 | 建连失败 | N | N | |
| **KF082** | 非对称路由 | P2 | 单向通 | N | P | 单向 DROP |

---

## 9. 磁盘 / 日志段

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF083** | log.dirs 磁盘满 | P1 | No space、分区离线 | H L M | Y | `disk --action disk-full` |
| **KF084** | log.dirs 只读/权限 | P1 | 无法 flush | H L | Y | `disk --action logdir-readonly` |
| **KF085** | 磁盘 IO 饱和 | P2 | await 高、生产超时 | H | Y | `disk --action io-stress` |
| **KF086** | 慢盘 | P2 | fsync 慢 | H L | P | `network` 不合适，用 io-stress |
| **KF087** | 日志段损坏 | P1 | checksum、无法恢复 | L | P | `kafka --action log-corrupt` |
| **KF088** | 多 log.dirs 坏一块 | P1 | 部分分区离线 | H L | N | 单盘实验室 |
| **KF089** | retention 过短 | P2 | 数据“丢失”观感、OOR | C M | P | 改 retention |
| **KF090** | compact 卡住 | P3 | cleaner 落后 | L | N | |
| **KF091** | checkpoint 失败 | P2 | 恢复慢 | L H | P | 只读 |
| **KF092** | 同 KF012 inode | P1 | 无法建段 | H | Y | inode-exhaust |
| **KF093** | fsync 超时 | P2 | 刷盘告警 | L H | P | io-stress |

---

## 10. 安全 / 配额 / 连接

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF094** | SASL 失败 | P2 | auth fail | L | N | PLAINTEXT 实验室 |
| **KF095** | ACL 拒绝 | P2 | unauthorized | L | N | 未开 ACL |
| **KF096** | 证书过期 | P2 | TLS | L | N | |
| **KF097** | 连接打满 | P2 | Too many connections | H N L | Y | `kafka --action max-connections` |
| **KF098** | 请求队列打满 | P2 | 延迟、拒绝 | L H | P | 压测 |
| **KF099** | 请求/带宽配额 | P3 | throttle time | M L | Y | produce-quota |
| **KF100** | 未授权管理操作 | P3 | describe 失败 | L | N | |

---

## 11. 配置隐患

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF101** | min.isr ≥ RF | P1 | 永远 NotEnoughReplicas | C M | Y | `kafka --action bad-min-isr` |
| **KF102** | RF=1（HA 失效） | P2 | 单点 | C | P | 建 RF=1 topic |
| **KF103** | network/io threads 过小 | P2 | 排队 | C H | N | |
| **KF104** | message.max.bytes 不匹配 | P2 | 大消息失败 | C | P | KF055 |
| **KF105** | replica.fetch.max.bytes 过小 | P2 | 副本追不上大消息 | C | N | |
| **KF106** | unclean.leader.election.enable=true | P1 | 丢数据风险 | C | P | 改配置 |
| **KF107** | log.flush 过频 | P2 | IO 打满 | C H | N | |
| **KF108** | auto.create 与客户端预期不一致 | P2 | 误建或不建 | C | 基线 false | KF050 |
| **KF109** | listener 配错 | P1 | 监听缺失 | C N | P | 改 listeners |
| **KF110** | 保留过短导致 offset 失效 | P2 | OOR | C M | P | KF063 |

---

## 12. 组合故障

| ID | 场景 | 级别 | 组成 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF111** | 磁盘满 + CPU | P1 | KF083+KF002 | H M | Y | `composite --action disk-plus-cpu` |
| **KF112** | 网络分区 + ISR | P1 | KF073+KF039 | N M | Y | `composite --action partition-plus-isr` |
| **KF113** | Broker 停 + 远端内存 | P1 | KF015+KF004 | M H | Y | `composite --action stop-plus-memory` |
| **KF114** | GC + 重平衡 | P2 | KF018+KF061 | H M | Y | `composite --action gc-plus-rebalance` |
| **KF115** | Controller 失联 + URP | P1 | KF025+KF036 | M N | Y | `composite --action controller-plus-urp` |
| **KF116** | 磁盘 IO + 生产超时 | P2 | KF085+KF052 | H M | Y | `composite --action io-plus-produce` |

---

## 13. 采集降级（排障 Bot 自身）

| ID | 场景 | 级别 | 现象 | 采集 | 注入 | 注入动作 |
|---|---|---|---|---|---|---|
| **KF117** | 诊断机到单节点不通 | P3 | 该节点产物缺失 | N P | Y | `degrade --action job-unreachable` |
| **KF118** | 采集工具缺失 | P3 | iostat/jstat/CLI 无 | P H | Y | `degrade --action hide-tools` |
| **KF119** | JMX/jstat 不可用 | P3 | 无 GC 视图 | H P | P | hide-tools |
| **KF120** | 部分节点采集失败 | P3 | kinds_found < 3，走降级清洗 | 清洗 | P | 停节点 + 跑排障 |

---

## 14. 当前环境不适用（记录以免漏检）

| ID | 场景 | 原因 |
|---|---|---|
| **KF121** | ZooKeeper 会话过期 | 本部署为 KRaft，无 ZK |
| **KF122** | ZK 集群不可用 | 同上 |
| **KF123** | MirrorMaker 中断 | 未部署 MM2 |
| **KF124** | Connect worker 失败 | 未部署 Connect |
| **KF125** | Schema Registry 不可用 | 未部署 |
| **KF126** | Kafka Streams 重平衡 | 无 Streams 作业 |
| **KF127** | 跨 AZ / rack 副本缺失 | 实验室单网段无 rack |

---

## 15. 场景统计

| 类别 | ID 范围 | 条数 |
|---|---|---|
| 基线 | KF001 | 1 |
| 主机 | KF002–KF014 | 13 |
| 进程/JVM | KF015–KF024 | 10 |
| KRaft | KF025–KF035 | 11 |
| 分区副本 | KF036–KF051 | 16 |
| 生产 | KF052–KF060 | 9 |
| 消费 | KF061–KF070 | 10 |
| 网络 | KF071–KF082 | 12 |
| 磁盘 | KF083–KF093 | 11 |
| 安全配额 | KF094–KF100 | 7 |
| 配置隐患 | KF101–KF110 | 10 |
| 组合 | KF111–KF116 | 6 |
| 采集降级 | KF117–KF120 | 4 |
| 环境 N/A | KF121–KF127 | 7 |
| **合计** | KF001–KF127 | **127** |

实验室默认 **可注入 Y**：见 `kafka_fault_injection/KAFKA_FAULT_SCENARIOS.md` 命令表。
