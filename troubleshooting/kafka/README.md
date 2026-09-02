# Kafka 排障流程（参考 Redis 五路采集 + 清洗 + AI）

本目录是 **Kafka KRaft 三节点排障 Bot** 的 SOPS 流程与采集脚本。故障注入在独立目录 `kafka_fault_injection/`（与 Redis 的 `redis_fault_injection/` 对位）。

## 流程

```text
Start
  ├─ (v2) 采集预检
  └─ ParallelGateway 五路并行
        ├─ K1 监控指标（Broker API / URP / Offline / KRaft quorum / 消费组 / log.dirs / 产消探针）
        ├─ K2 配置信息（server.properties / systemd / JVM / topic configs / voters / min.isr）
        ├─ K3 过滤日志（server/controller/state-change 关键字 → KF 场景 ID）
        ├─ K4 主机资源（CPU 内存 磁盘 FD inode JVM GC 时钟）
        └─ K5 主机网络（9092/9093 连通、分区、tc、防火墙、advertised）
  → ConvergeGateway
  → (v2) 覆盖判定 ExclusiveGateway
        ├─ 正常 → 数据清洗与信号映射
        └─ 不足 → 降级清洗
  → AI 诊断分析
  → End
```

采集节点全部 `ignore_error: true`：Broker 已挂仍要进入清洗和 AI。

## 文件

| 路径 | 说明 |
|------|------|
| `kafka38-kraft-troubleshoot.yaml` | v1 排障 YAML（五路采集 → 清洗 → AI） |
| `kafka38-kraft-troubleshoot-v2.yaml` | 覆盖复盘后的优化 YAML |
| `KAFKA_FAULT_SCENARIOS.md` | 全量故障场景清单 |
| `COVERAGE_REVIEW.md` | 场景 vs 流程覆盖复盘 |
| `scripts/` | 采集 / 清洗 / AI / 实验室汇聚 `run_flow.sh` |
| `tools/generate_yaml.py` | 从脚本生成自包含 SOPS YAML |

部署目录同步副本：`deployments/数据库部署脚本/output/kafka38-kraft-troubleshoot*.yaml`。

## 产物

节点本地（及实验室汇聚后）：

```text
/tmp/kafka-troubleshoot/<run_id>/
  metrics.<ip>.txt + .signals
  config.<ip>.txt
  logs.<ip>.txt
  host.<ip>.txt
  network.<ip>.txt
  cleaned.txt  summary.md  signals.uniq.tsv
  ai_prompt.md  heuristic_diagnosis.md  ai_diagnosis.md
```

stdout 以 `###KAFKA_TS_ARTIFACT` / `###KAFKA_TS_CLEANSED` / `###KAFKA_TS_AI_DIAGNOSIS` 包裹，供作业平台拼接。

## 实验室汇聚

SOPS 多 IP 作业没有共享磁盘时，在注入机执行：

```bash
export INJECT_BACKEND=docker
export KAFKA_CONTAINER_MAP="10.10.26.144:kafka-n1 10.10.26.145:kafka-n2 10.10.26.146:kafka-n3"
TS_PROFILE=v2 ./scripts/run_flow.sh
```

## 与 Redis 排障的对应

| Redis | Kafka |
|-------|-------|
| INFO / CLUSTER | Broker API + metadata quorum + topics describe |
| CONFIG GET / redis.conf | server.properties + kafka-configs |
| redis 日志 | /var/log/kafka/*.log |
| 主机 CPU/MEM/DISK | 同左 + JVM jstat |
| 6379/16379 网络 | 9092 / 9093 |
| 清洗 + AI | 同结构，信号映射 KF\* 场景 |
