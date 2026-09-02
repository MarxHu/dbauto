# Redis Cluster 故障场景全表

> **仓库路径**：`redis_fault_injection/REDIS_FAULT_SCENARIOS.md`  
> **GitHub**：https://github.com/MarxHu/dbauto/blob/cursor/redis-fault-injection-catalog-eccc/redis_fault_injection/REDIS_FAULT_SCENARIOS.md  
> **配套方案**：[`FAULT_INJECTION_PLAN.md`](./FAULT_INJECTION_PLAN.md)（拓扑、环境、回归顺序）  
> **节点规范**：[`lab/NODE_SPEC.md`](./lab/NODE_SPEC.md)

本文档是 **全部 Redis 故障注入场景** 的单一清单：每个场景「怎么注入、跑哪个脚本、完整命令、验收、恢复」。

---

## 0. 使用约定

| 项 | 说明 |
|---|---|
| 执行位置 | **仅在 `docker-node`**（注入机），目录 `redis_fault_injection/` |
| 拓扑 | `redis-n1`=`10.10.26.144:6379`，`redis-n2`=`145`，`redis-n3`=`146`；注入机 `10.10.26.10` |
| 主机类故障 | `docker exec` 进容器（`--target-host` IP 或 `--target-container` 名） |
| Redis 类故障 | Bot 上 `redis-cli` 连集群 |
| 默认持续 | `--duration 600`（10 分钟），到期自动恢复（F09/F29 等除外，见各条） |
| 互斥 | 同时只跑一个 inject（`flock`） |
| Bot 解析 | `INJECT_RESULT scenario=<id> status=pass\|fail detail=...` |
| 跑前 | `./scripts/preflight.sh`（必须 FAIL=0） |

统一入口示例：

```bash
./run.sh host --action cpu --target-host 10.10.26.144 --duration 600
./run.sh redis --action process-stop --node 10.10.26.144:6379 --duration 600
```

---

## 1. 主机资源 — `scripts/inject_host.sh`

| ID | 场景 | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|
| **F01** | 正常基线 | 三节点 `PING`，不打故障 | `inject_host.sh` / `baseline` | `./scripts/inject_host.sh --action baseline` | 全部 PONG | 无 |
| **F02** | CPU 持续高压 | 容器内 `stress-ng --cpu 0 --cpu-load 90` | `inject_host.sh` / `cpu` | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600` | vmstat 1 4 跳过 since-boot，CPU avg **≥80%** | duration 到期 `pkill stress-ng` |
| **F04** | 主机内存压力 | `stress-ng --vm 2 --vm-bytes 85%`（相对容器 `mem_limit`） | `inject_host.sh` / `memory` | `./scripts/inject_host.sh --action memory --target-host 10.10.26.145 --duration 600` | cgroup 可用 **≤15%** 或 已用 **≥85%** | 到期杀 stress-ng |
| **F06** | CPU 瞬时尖峰 | 周期短时 CPU burst | `inject_host.sh` / `cpu-spike` | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 600` | 启动即 pass | 到期停 burst |
| **F09** | 主机重启 | `docker restart` 模拟 VM 重启 | `inject_host.sh` / `reboot` | `./scripts/inject_host.sh --action reboot --target-container redis-n1 --confirm YES` | 需确认；**无自动恢复** | 人工/容器自启 |
| **F28** | 多节点 CPU | 三节点并行 F02 | `inject_host.sh` / `multi-cpu` | `./scripts/inject_host.sh --action multi-cpu --duration 600` | 需 `.state/docker_all_nodes.ok` | 各节点到期恢复 |

**环境**：F04 依赖容器 `mem_limit=1536m`；F28 依赖 preflight 三容器就绪。

---

## 2. Redis 进程 / 配置 / 流量 / 协议 — `scripts/inject_redis.sh`

| ID | 场景 | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|
| **F07** | Redis 进程停止 | 注入前 `docker update --restart=no`；`SHUTDOWN NOSAVE` | `inject_redis.sh` / `process-stop` | `./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6379 --duration 600` | PING **5s 内 ≥3s 不可达** | 到期拉起 redis + 恢复 Restart 策略 |
| **F10** | maxmemory / OOM | `CONFIG SET maxmemory` + 写填 key | `inject_redis.sh` / `maxmemory` | `./scripts/inject_redis.sh --action maxmemory --node 10.10.26.144:6379 --duration 600 --maxmemory 64mb` | 配置已生效 | 恢复原 maxmemory |
| **F12** | maxclients 打满 | `CONFIG SET maxclients` + 并发连接 | `inject_redis.sh` / `maxclients` | `./scripts/inject_redis.sh --action maxclients --node 10.10.26.144:6379 --duration 600 --maxclients 10` | 配置已生效 | 恢复原 maxclients |
| **F14** | 慢命令 | 周期 `DEBUG SLEEP` | `inject_redis.sh` / `slow-command` | `./scripts/inject_redis.sh --action slow-command --node 10.10.26.144:6379 --duration 600` | DEBUG 可用 | 停循环 |
| **F15** | 热 Key | 高频 SET/GET | `inject_redis.sh` / `hot-key` | `./scripts/inject_redis.sh --action hot-key --node 10.10.26.145:6379 --duration 600` | 流量已启动 | 停流量 |
| **F16** | 大 Key（单 Hash） | 2 万 field × 256B ≈ 5MB；默认 key `fault:hotkey`（槽在 145） | `inject_redis.sh` / `big-key` | `./scripts/inject_redis.sh --action big-key --node 10.10.26.145:6379 --duration 300` | seed 完成即 pass | 默认 DEL（可用 `--no-cleanup-bigkey`） |
| **F17** | 冷缓存（单 key） | `EXPIRE`/`DEL` 指定 key | `inject_redis.sh` / `cache-expire` | `./scripts/inject_redis.sh --action cache-expire --node 10.10.26.144:6379 --expire-key mykey --duration 600` | — | 不自动恢复数据 |
| **F17\*** | 冷缓存 FLUSHDB | `FLUSHDB`（危险，仅实验室） | 同上，省略 `--expire-key` | `./scripts/inject_redis.sh --action cache-expire --node 10.10.26.144:6379 --duration 60` | — | 不自动恢复 |
| **F18** | 缓存穿透 | 大量 GET 不存在 key | `inject_redis.sh` / `cache-penetrate` | `./scripts/inject_redis.sh --action cache-penetrate --node 10.10.26.144:6379 --duration 600 --request-count 100000` | 流量已启动 | 停流量 |
| **F19-NOAUTH** | 无密码脉冲 | 无 auth 客户端 PING | `inject_redis.sh` / `error-pulse` | `./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 90 --error-type NOAUTH` | ERRORSTATS 递增 | 脉冲结束即止 |
| **F19-WRONGPASS** | ACL 错密码 | 错误密码 | 同上 | `... --error-type WRONGPASS` | ERRORSTATS 递增 | 同上 |
| **F19-MOVED** | MOVED 脉冲 | 非 cluster 模式写 | 同上 | `... --error-type MOVED` | ERRORSTATS 递增 | 同上 |
| **F19-CROSSSLOT** | 跨 Slot 脉冲 | 跨 hash-tag MGET | 同上 | `... --error-type CROSSSLOT` | ERRORSTATS 递增 | 同上 |
| **F29** | 历史 MISCONF 背景 | 目录只读触发 MISCONF 计数 | `inject_redis.sh` / `historical-misconf` | `./scripts/inject_redis.sh --action historical-misconf --node 10.10.26.146:6379` | MISCONF **递增** | **必须**再跑 F29c |
| **F29c** | 清理 MISCONF | 恢复配置 + 可选重启清 ERRORSTATS | `inject_redis.sh` / `historical-misconf-cleanup` | `./scripts/inject_redis.sh --action historical-misconf-cleanup --node 10.10.26.146:6379` | PING up | — |

---

## 3. 网络 — `scripts/inject_network.sh`

| ID | 场景 | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|
| **F20** | Cluster Bus 阻断 | 容器内 iptables DROP bus 端口（默认 16379） | `inject_network.sh` / `bus-block` | `./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6379 --duration 600` | 规则已加 | 到期删 iptables 规则 |
| **F22** | 客户端丢包 | `tc qdisc replace … root netem loss 30%`（不用 HTB） | `inject_network.sh` / `packet-loss` | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.146 --duration 600 --loss 30 --net-dev eth0` | `tc qdisc show` 含 netem loss | `tc qdisc del` |
| **F30** | 两 Master 分区 | 双向 iptables DROP | `inject_network.sh` / `master-partition` | `./scripts/inject_network.sh --action master-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 600` | 需 `docker_all_nodes.ok` | 到期删规则 |

**环境**：容器 `NET_ADMIN`；F22 宿主机需 `modprobe sch_netem`。

---

## 4. 磁盘 — `scripts/inject_disk.sh`

| ID | 场景 | 注入方式 | 脚本 / action | 完整命令 | Post-check | 恢复 |
|---|---|---|---|---|---|---|
| **F24** | 持久化失败 / MISCONF | 数据目录+文件 chmod 只读 → `BGSAVE` | `inject_disk.sh` / `persistence-fail` | `./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6379 --duration 600` | **MISCONF 计数递增** | 到期恢复写权限 |
| **F26** | 磁盘 IO 高 | `dd` 写到 **`<redis dir>/fault_io`**（非 `/tmp`） | `inject_disk.sh` / `io-stress` | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 600` | IO 已启动 | 到期删 fault_io |

---

## 5. 组合 — `scripts/inject_composite.sh`

内部再调用上面脚本；组合期间跳过 flock。

| ID | 场景 | 组成 | 脚本 / action | 完整命令 |
|---|---|---|---|---|
| **C01** | 内存 + 历史 MISCONF | F29(146) → F04(144) → F29c | `inject_composite.sh` / `memory-plus-misconf` | `./scripts/inject_composite.sh --action memory-plus-misconf --duration 600 --memory-node 10.10.26.144:6379 --misconf-node 10.10.26.146:6379` |
| **C02** | 写拒绝 + CPU | F24 + F02 同节点并行 | `inject_composite.sh` / `write-reject-plus-cpu` | `./scripts/inject_composite.sh --action write-reject-plus-cpu --write-node 10.10.26.144:6379 --duration 600` |
| **C03** | Master 停 + 远端内存 | F07(144) + F04(146) 并行 | `inject_composite.sh` / `master-stop-plus-memory` | `./scripts/inject_composite.sh --action master-stop-plus-memory --stop-node 10.10.26.144:6379 --mem-node 10.10.26.146:6379 --duration 600` |

---

## 6. 降级 — `scripts/inject_degrade.sh`（Bot 本机）

| ID | 场景 | 注入方式 | 脚本 / action | 完整命令 | 恢复 |
|---|---|---|---|---|---|
| **D01** | 单节点不可达 | Bot 本机 iptables 阻断到 Redis | `inject_degrade.sh` / `job-unreachable` | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --blocked-port 6379 --duration 600` | 到期删规则 |
| **D02** | 隐藏采集工具 | 临时移走 `iostat`/`pidstat` | `inject_degrade.sh` / `hide-tools` | `./scripts/inject_degrade.sh --action hide-tools --duration 600` | 到期还原 |
| **D03** | K3 失败 | 无注入脚本；排障侧断 K3 | — | — | — |

---

## 7. 当前环境不适用（无脚本）

| 场景 | 原因 |
|---|---|
| 复制中断 | 3 Master 无 Replica |
| 自动 Failover | 无 Replica |
| Slot 迁移中断 | 需 resharding 运维窗口 |

---

## 8. 脚本对照速查

| 脚本 | 覆盖场景 |
|---|---|
| `scripts/preflight.sh` | 环境检查（非注入） |
| `scripts/inject_host.sh` | F01, F02, F04, F06, F09, F28 |
| `scripts/inject_redis.sh` | F07, F10, F12, F14, F15, F16, F17, F18, F19, F29, F29c |
| `scripts/inject_network.sh` | F20, F22, F30 |
| `scripts/inject_disk.sh` | F24, F26 |
| `scripts/inject_composite.sh` | C01, C02, C03 |
| `scripts/inject_degrade.sh` | D01, D02 |

---

## 9. 推荐首跑顺序

```bash
./scripts/preflight.sh

# 基线 + 主机
./scripts/inject_host.sh --action baseline
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 300
./scripts/inject_host.sh --action memory --target-host 10.10.26.145 --duration 300

# Redis
./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6379 --duration 300
./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --error-type NOAUTH --duration 90
./scripts/inject_redis.sh --action big-key --node 10.10.26.145:6379 --duration 300

# 网络 / 磁盘
./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6379 --duration 300
./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.146 --duration 120 --loss 30
./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6379 --duration 300
./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 300

# 组合 / 降级
./scripts/inject_composite.sh --action memory-plus-misconf --duration 300 \
  --memory-node 10.10.26.144:6379 --misconf-node 10.10.26.146:6379
./scripts/inject_degrade.sh --action hide-tools --duration 300
```

每条命令 stdout 应出现：`INJECT_RESULT scenario=... status=pass`。

---

## 10. 场景 ↔ 排障线索（参考，非注入验收）

| ID | 预期可观测线索 |
|---|---|
| F02 | 节点 CPU 高 |
| F04 | 内存紧张 / cgroup 压力 |
| F07 | PING 失败、节点可能 fail |
| F10 | OOM / 驱逐 / 写失败 |
| F12 | ERR max number of clients |
| F14 | 延迟升高、slowlog |
| F15 | 单 key/分片热点 |
| F16 | bigkeys / HGETALL 大包 |
| F19 | ERRORSTATS 对应错误 |
| F20 | cluster bus 不通 |
| F22 | 客户端超时/重试 |
| F24/F29 | MISCONF、写拒绝 |
| F26 | 磁盘 util 高 |
| F28 | 多节点 CPU 同时高 |
| F30 | 分区/脑裂症状 |
| C01–C03 | 多根因叠加 |
| D01–D02 | 采集降级 |

---

## 11. 相关文件

| 文件 | 用途 |
|---|---|
| [`FAULT_INJECTION_PLAN.md`](./FAULT_INJECTION_PLAN.md) | 完整方案（拓扑、原则、回归） |
| [`PREREQUISITES.md`](./PREREQUISITES.md) | 环境前提 |
| [`lab/NODE_SPEC.md`](./lab/NODE_SPEC.md) | 4 节点 Docker 规范 |
| [`SCENARIOS.md`](./SCENARIOS.md) | 精简速查（指向本文） |
| [`config.env.example`](./config.env.example) | 配置模板 |
| `lab/recreate.sh` | 一键重建 4 节点 + 集群 |
