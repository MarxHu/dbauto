# Kafka 故障注入环境前提

在 `./scripts/preflight.sh` 得到 **FAIL=0** 之前不要注入。

## 注入机（docker-node）

| 项 | 要求 |
|---|---|
| bash | ≥ 4 |
| flock | 必须 |
| docker CLI | `INJECT_BACKEND=docker`，可访问 daemon |
| Kafka CLI | `${KAFKA_HOME}/bin/kafka-broker-api-versions.sh` 等 |
| timeout / python3 | 部分场景（超大消息、灌消息） |

## Kafka 数据节点（kafka-n1/n2/n3）

| 项 | 要求 |
|---|---|
| java ≥ 17 | 运行 Kafka |
| Kafka 已部署 | systemd `kafka.service`，端口 9092/9093 |
| stress-ng vmstat chmod dd iptables tc | 主机/网络/磁盘注入 |
| NET_ADMIN | iptables/tc |
| mem_limit | KF004 建议 1536m |
| 可写 log.dirs | `/var/lib/kafka/data` |

## 集群

- 三节点 KRaft，`controller.quorum.voters` 含三 IP
- `auto.create.topics.enable=false`
- RF=3，min.isr=2
- 宿主机 `modprobe sch_netem`（KF075/076）

## 配置

`config.env`（不入库）：`KAFKA_CONTAINER_MAP`、`KAFKA_HOME`、`BOOTSTRAP`。
