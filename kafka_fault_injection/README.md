# Kafka KRaft 故障注入 — 完整说明

> 仓库：**https://github.com/MarxHu/dbauto**  
> 脚本目录：`kafka_fault_injection/`  
> 场景总表（排障视角）：[`troubleshooting/kafka/KAFKA_FAULT_SCENARIOS.md`](../troubleshooting/kafka/KAFKA_FAULT_SCENARIOS.md)  
> 本目录命令表：[`KAFKA_FAULT_SCENARIOS.md`](./KAFKA_FAULT_SCENARIOS.md)

与 Redis 注入目录对位：**只验收故障是否注入成功**。排障 Bot（五路采集 / 清洗 / AI）在 `troubleshooting/kafka/`。

## 1. 拓扑

```text
docker-node（注入 Bot）  10.10.26.10
  kafka CLI + docker exec
       │
       ├─ kafka-n1  10.10.26.144  :9092 / :9093
       ├─ kafka-n2  10.10.26.145  :9092 / :9093
       └─ kafka-n3  10.10.26.146  :9092 / :9093
KRaft 三节点合一，RF=3，min.isr=2
```

| 项 | 约定 |
|---|---|
| 运行位置 | 只在 **docker-node** 跑脚本 |
| 主机/网络/磁盘 | `docker exec` 进容器 |
| Kafka 协议类 | Bot 上 `KAFKA_HOME/bin/kafka-*.sh` |
| 互斥 | `flock` `.state/inject.lock` |
| 持续 | `--duration 600` 到期自动恢复（reboot/corrupt 除外） |
| 结果行 | `INJECT_RESULT scenario=KF0xx status=pass\|fail detail=...` |

## 2. 配置

```bash
cd kafka_fault_injection
cp config.env.example config.env
# 确认 KAFKA_HOME 在注入机可用（可把 Kafka 包只装 CLI）
chmod +x run.sh scripts/*.sh lib/common.sh
./scripts/preflight.sh   # FAIL=0 后才注入
```

## 3. 入口

```bash
./run.sh host --action cpu --target-host 10.10.26.144 --duration 300
./run.sh kafka --action process-stop --node 10.10.26.144:9092 --duration 300
./run.sh network --action controller-block --target-host 10.10.26.144 --duration 300
./run.sh disk --action disk-full --target-host 10.10.26.146 --duration 300
./run.sh composite --action stop-plus-memory --duration 300
./run.sh degrade --action hide-tools --duration 300
```

## 4. 与排障 Bot 时序

```text
T0    注入脚本 --duration 600 → 见 INJECT_RESULT status=pass
T0+   排障 Bot 跑 SOPS / run_flow.sh（故障仍在）
T600  自动恢复
```

## 5. 目录

```
kafka_fault_injection/
├── README.md
├── KAFKA_FAULT_SCENARIOS.md
├── FAULT_INJECTION_PLAN.md
├── PREREQUISITES.md
├── SCENARIOS.md
├── config.env.example
├── run.sh
├── lib/common.sh
├── lab/NODE_SPEC.md
└── scripts/
    ├── preflight.sh
    ├── inject_host.sh
    ├── inject_kafka.sh
    ├── inject_network.sh
    ├── inject_disk.sh
    ├── inject_composite.sh
    └── inject_degrade.sh
```
