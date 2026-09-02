# Kafka 注入实验室节点规范

在 Kafka SOPS 三节点规范之上，注入场景额外要求：

| 节点 | IP | 额外工具 |
|---|---|---|
| docker-node（注入机） | 10.10.26.10 | bash≥4、flock、docker、Kafka CLI（`KAFKA_HOME`）、python3、timeout |
| kafka-n1/n2/n3 | 144/145/146 | **必须** `stress-ng` `vmstat` `chmod` `dd` `iptables` `tc` `java`；`NET_ADMIN`；建议 `mem_limit=1536m` |

数据节点仍按部署 YAML 安装 Kafka 到 `/opt/kafka/3.8.1`，`log.dirs=/var/lib/kafka/data`。

验收：

```bash
# 数据节点
for c in stress-ng vmstat chmod dd iptables tc java; do command -v "$c"; done
# 注入机
command -v docker flock
test -x /opt/kafka/3.8.1/bin/kafka-topics.sh
```

部署节点规范见 `deployments/数据库部署脚本/lab/kafka38-kraft-3node/NODE_SPEC.md`（kafka-sops 分支）。
