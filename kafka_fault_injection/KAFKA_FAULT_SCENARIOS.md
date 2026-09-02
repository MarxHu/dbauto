# Kafka 注入场景命令表

对照排障总表 [`troubleshooting/kafka/KAFKA_FAULT_SCENARIOS.md`](../troubleshooting/kafka/KAFKA_FAULT_SCENARIOS.md)。下列为 **实验室可执行** 命令（默认在 `kafka_fault_injection/`、docker-node 上）。

统一：`--duration 600` 可改短；成功行 `INJECT_RESULT scenario=... status=pass`。

## 主机 `inject_host.sh`

| ID | 动作 | 命令 |
|---|---|---|
| KF001 | baseline | `./scripts/inject_host.sh --action baseline` |
| KF002 | cpu | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600` |
| KF003 | cpu-spike | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 600` |
| KF004 | memory | `./scripts/inject_host.sh --action memory --target-host 10.10.26.145 --duration 600` |
| KF006 | reboot | `./scripts/inject_host.sh --action reboot --target-container kafka-n1 --confirm YES` |
| KF007 | multi-cpu | `./scripts/inject_host.sh --action multi-cpu --duration 600` |
| KF010 | clock-skew | `./scripts/inject_host.sh --action clock-skew --target-host 10.10.26.144 --duration 600` |

## Kafka `inject_kafka.sh`

| ID | 动作 | 命令 |
|---|---|---|
| KF015 | process-stop | `./scripts/inject_kafka.sh --action process-stop --node 10.10.26.144:9092 --duration 600` |
| KF016 | process-freeze | `./scripts/inject_kafka.sh --action process-freeze --node 10.10.26.144:9092 --duration 300` |
| KF017 | heap-oom | `./scripts/inject_kafka.sh --action heap-oom --node 10.10.26.144:9092 --duration 300` |
| KF018 | gc-storm | `./scripts/inject_kafka.sh --action gc-storm --node 10.10.26.144:9092 --duration 300` |
| KF011 | fd-exhaust | `./scripts/inject_kafka.sh --action fd-exhaust --node 10.10.26.144:9092 --duration 300` |
| KF026 | quorum-loss | `./scripts/inject_kafka.sh --action quorum-loss --duration 180` |
| KF036/039 | isr-shrink | `./scripts/inject_kafka.sh --action isr-shrink --node 10.10.26.144:9092 --duration 300` |
| KF044/053 | min-isr-breach | `./scripts/inject_kafka.sh --action min-isr-breach --node 10.10.26.144:9092 --duration 300` |
| KF101 | bad-min-isr | `./scripts/inject_kafka.sh --action bad-min-isr --duration 300` |
| KF047 | hot-partition | `./scripts/inject_kafka.sh --action hot-partition --duration 300` |
| KF050 | unknown-topic | `./scripts/inject_kafka.sh --action unknown-topic --duration 60` |
| KF055 | oversized-record | `./scripts/inject_kafka.sh --action oversized-record --duration 60` |
| KF062 | consumer-lag | `./scripts/inject_kafka.sh --action consumer-lag --duration 300` |
| KF061 | rebalance-storm | `./scripts/inject_kafka.sh --action rebalance-storm --duration 180` |
| KF063 | offset-oor | `./scripts/inject_kafka.sh --action offset-oor --duration 180` |
| KF060 | produce-quota | `./scripts/inject_kafka.sh --action produce-quota --duration 180` |
| KF097 | max-connections | `./scripts/inject_kafka.sh --action max-connections --node 10.10.26.144:9092 --duration 120` |
| KF041 | leader-skew | `./scripts/inject_kafka.sh --action leader-skew --duration 60` |
| KF027 | metadata-corrupt | `./scripts/inject_kafka.sh --action metadata-corrupt --node 10.10.26.144:9092 --confirm YES` |
| KF087 | log-corrupt | `./scripts/inject_kafka.sh --action log-corrupt --node 10.10.26.146:9092 --confirm YES` |

## 网络 `inject_network.sh`

| ID | 动作 | 命令 |
|---|---|---|
| KF071 | broker-block | `./scripts/inject_network.sh --action broker-block --target-host 10.10.26.144 --duration 300` |
| KF072 | controller-block | `./scripts/inject_network.sh --action controller-block --target-host 10.10.26.144 --duration 300` |
| KF073 | broker-partition | `./scripts/inject_network.sh --action broker-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 300` |
| KF075 | packet-loss | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.146 --loss 30 --duration 120` |
| KF076 | latency | `./scripts/inject_network.sh --action latency --target-host 10.10.26.146 --delay-ms 200 --duration 120` |
| KF077 | rate-limit | `./scripts/inject_network.sh --action rate-limit --target-host 10.10.26.145 --rate 1mbit --duration 120` |
| KF013 | dns-fail | `./scripts/inject_network.sh --action dns-fail --target-host 10.10.26.144 --duration 120` |
| KF082 | one-way-drop | `./scripts/inject_network.sh --action one-way-drop --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 180` |

## 磁盘 `inject_disk.sh`

| ID | 动作 | 命令 |
|---|---|---|
| KF083 | disk-full | `./scripts/inject_disk.sh --action disk-full --target-host 10.10.26.146 --duration 300` |
| KF084 | logdir-readonly | `./scripts/inject_disk.sh --action logdir-readonly --node 10.10.26.146:9092 --duration 300` |
| KF085 | io-stress | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 300` |
| KF012 | inode-exhaust | `./scripts/inject_disk.sh --action inode-exhaust --target-host 10.10.26.144 --duration 180` |

## 组合 `inject_composite.sh`

| ID | 动作 | 命令 |
|---|---|---|
| KF111 | disk-plus-cpu | `./scripts/inject_composite.sh --action disk-plus-cpu --duration 300` |
| KF112 | partition-plus-isr | `./scripts/inject_composite.sh --action partition-plus-isr --duration 300` |
| KF113 | stop-plus-memory | `./scripts/inject_composite.sh --action stop-plus-memory --duration 300` |
| KF114 | gc-plus-rebalance | `./scripts/inject_composite.sh --action gc-plus-rebalance --duration 300` |
| KF115 | controller-plus-urp | `./scripts/inject_composite.sh --action controller-plus-urp --duration 300` |
| KF116 | io-plus-produce | `./scripts/inject_composite.sh --action io-plus-produce --duration 300` |

## 降级 `inject_degrade.sh`

| ID | 动作 | 命令 |
|---|---|---|
| KF117/074 | job-unreachable | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --duration 300` |
| KF118/119 | hide-tools | `./scripts/inject_degrade.sh --action hide-tools --duration 300` |

## 由相近动作覆盖的 ID（别名，不再单独做脚本）

| ID | 覆盖方式 |
|---|---|
| KF005 | `heap-oom` / 加强 `memory` |
| KF008 KF009 | `cpu` / `memory` |
| KF014 KF022 | `fd-exhaust` |
| KF021 | `process-stop` + systemd Restart |
| KF023 KF024 | 配置类，见 `bad-min-isr` / 预检 |
| KF025 KF031 | `controller-block` |
| KF028 KF029 KF030 KF032 KF033 | `metadata-corrupt` / 配置篡改（P） |
| KF037 KF038 KF043 KF046 | `isr-shrink` / `process-stop` / `quorum-loss` |
| KF040 | `rate-limit` / `io-stress` |
| KF045 KF106 | 需打开 unclean，默认不注入 |
| KF051 | `unknown-topic` |
| KF052 KF054 KF056 | `min-isr-breach` / `process-freeze` / `io-stress` |
| KF064 | `process-stop`（coordinator 所在节点） |
| KF065 KF067 KF068 | `rebalance-storm` / `consumer-lag` / `produce-quota` |
| KF078 KF109 | 改 advertised/listeners（P，无默认脚本） |
| KF086 KF091 KF093 | `io-stress` / `logdir-readonly` |
| KF089 KF110 | `offset-oor` |
| KF092 | `inode-exhaust` |
| KF098 KF099 | `max-connections` / `produce-quota` |
| KF102 KF104 | 建 RF=1 topic / `oversized-record` |
| KF120 | 停节点后跑排障流 |

## 推荐首跑

```bash
./scripts/preflight.sh
./scripts/inject_host.sh --action baseline
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 120
./scripts/inject_kafka.sh --action process-stop --node 10.10.26.144:9092 --duration 120
./scripts/inject_network.sh --action controller-block --target-host 10.10.26.144 --duration 120
./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 120
./scripts/inject_degrade.sh --action hide-tools --duration 60
```
