# MySQL 一主多从故障注入场景速查

> **全部场景完整清单（推荐）**：[`MYSQL_FAULT_SCENARIOS.md`](./MYSQL_FAULT_SCENARIOS.md)  
> **完整方案**：[`FAULT_INJECTION_PLAN.md`](./FAULT_INJECTION_PLAN.md)

默认 `--duration 600`。成功行：`INJECT_RESULT scenario=MY… status=pass`。

## 主机 `inject_host.sh`

| ID | action | 命令 |
|---|---|---|
| MY001 | baseline | `./scripts/inject_host.sh --action baseline` |
| MY010 | cpu（打主） | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600` |
| MY010-R | cpu（打从） | `... --target-host 10.10.26.145 --duration 600` |
| MY011 | memory | `./scripts/inject_host.sh --action memory --target-host 10.10.26.145 --duration 600` |
| MY010-S | cpu-spike | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 600` |
| MY035 | reboot | `./scripts/inject_host.sh --action reboot --target-container mysql-n1 --confirm YES` |
| MY010-M | multi-cpu | `./scripts/inject_host.sh --action multi-cpu --duration 600` |
| MY014 | clock-skew | `./scripts/inject_host.sh --action clock-skew --target-host 10.10.26.145 --duration 600` |

## MySQL `inject_mysql.sh`

| ID | action | 命令 |
|---|---|---|
| MY030 | process-stop（从） | `./scripts/inject_mysql.sh --action process-stop --node 10.10.26.145:3306 --duration 600` |
| MY030-P | process-stop（主） | `... --node 10.10.26.144:3306 --duration 600` |
| MY036 | process-freeze | `./scripts/inject_mysql.sh --action process-freeze --node 10.10.26.144:3306 --duration 300` |
| MY081 | max-connections | `./scripts/inject_mysql.sh --action max-connections --node 10.10.26.144:3306 --duration 600 --max-connections 10` |
| MY080 | slow-query | `./scripts/inject_mysql.sh --action slow-query --node 10.10.26.144:3306 --duration 600` |
| MY084 | hot-row | `./scripts/inject_mysql.sh --action hot-row --node 10.10.26.144:3306 --duration 600` |
| MY082 | big-trx | `./scripts/inject_mysql.sh --action big-trx --node 10.10.26.144:3306 --duration 300` |
| MY087 | long-trx | `./scripts/inject_mysql.sh --action long-trx --node 10.10.26.144:3306 --duration 600` |
| MY205 | error-pulse | `./scripts/inject_mysql.sh --action error-pulse --node 10.10.26.146:3306 --error-type WRONGPASS --duration 90` |

## 复制 / 半同步 `inject_repl.sh`

| ID | action | 命令 |
|---|---|---|
| MY040 | stop-io 单从 | `./scripts/inject_repl.sh --action stop-io --scope one --node 10.10.26.145:3306 --duration 600` |
| MY190 | stop-io 全从 | `./scripts/inject_repl.sh --action stop-io --scope all --duration 600` |
| MY041 | stop-sql 单从 | `./scripts/inject_repl.sh --action stop-sql --scope one --node 10.10.26.145:3306 --duration 600` |
| MY192 | stop-sql 全从 | `./scripts/inject_repl.sh --action stop-sql --scope all --duration 600` |
| MY046 | binlog-purge | `./scripts/inject_repl.sh --action binlog-purge --replica 10.10.26.145:3306 --confirm YES` |
| MY110 | replica-writable | `./scripts/inject_repl.sh --action replica-writable --node 10.10.26.145:3306 --duration 600` |
| MY130 | replica-1062 | `./scripts/inject_repl.sh --action replica-1062 --node 10.10.26.145:3306 --confirm YES` |
| MY102 | semi-sync-wait-ack | `./scripts/inject_repl.sh --action semi-sync-wait-ack --duration 300` |
| MY100 | semi-sync-degrade | `./scripts/inject_repl.sh --action semi-sync-degrade --duration 600` |

## 网络 `inject_network.sh`

| ID | action | 命令 |
|---|---|---|
| MY144 | repl-block 单从 | `./scripts/inject_network.sh --action repl-block --node 10.10.26.145:3306 --duration 600` |
| MY190-N | repl-block 全从 | `./scripts/inject_network.sh --action repl-block --scope all --duration 600` |
| MY140 | packet-loss | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.146 --loss 30 --duration 600` |
| MY140-L | latency | `./scripts/inject_network.sh --action latency --target-host 10.10.26.146 --delay-ms 200 --duration 600` |
| MY142 | rate-limit 主出口 | `./scripts/inject_network.sh --action rate-limit --target-host 10.10.26.144 --rate 1mbit --duration 600` |
| MY144-P | primary-replica-partition | `./scripts/inject_network.sh --action primary-replica-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 600` |

## 磁盘 `inject_disk.sh`

| ID | action | 命令 |
|---|---|---|
| MY160 | disk-full 主 | `./scripts/inject_disk.sh --action disk-full --target-host 10.10.26.144 --duration 300` |
| MY160-R | disk-full 从 | `... --target-host 10.10.26.145 --duration 300` |
| MY164 | datadir-readonly | `./scripts/inject_disk.sh --action datadir-readonly --node 10.10.26.146:3306 --duration 600` |
| MY162 | io-stress 从 | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.145 --duration 600` |
| MY162-P | io-stress 主 | `... --target-host 10.10.26.144 --duration 600` |
| MY161 | inode-exhaust | `./scripts/inject_disk.sh --action inode-exhaust --target-host 10.10.26.144 --duration 180` |

## 组合 / 降级

| ID | action | 命令 |
|---|---|---|
| MY196 | long-trx-plus-lag | `./scripts/inject_composite.sh --action long-trx-plus-lag --duration 600` |
| MY197 | ack-plus-net | `./scripts/inject_composite.sh --action ack-plus-net --duration 300` |
| MY198 | disk-plus-sql-stop | `./scripts/inject_composite.sh --action disk-plus-sql-stop --replica-host 10.10.26.145 --duration 300` |
| C01 | primary-stop-plus-memory | `./scripts/inject_composite.sh --action primary-stop-plus-memory --duration 600` |
| MY172 | job-unreachable | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --blocked-port 3306 --duration 600` |
| MY171 | hide-tools | `./scripts/inject_degrade.sh --action hide-tools --duration 600` |
