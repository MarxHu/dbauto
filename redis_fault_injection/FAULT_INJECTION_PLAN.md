# Redis Cluster 完整故障注入方案

> 仓库：`redis_fault_injection/`  
> 分支：`cursor/redis-fault-injection-catalog-eccc`（合并后以 `main` 为准）  
> **验收范围**：只验收故障是否成功注入（现象、持续、自动恢复）。  
> **不包含**：SOPS / 五路采集 / AI 诊断（排障 Bot 独立）。

---

## 1. 目标与原则

| 项 | 约定 |
|---|---|
| 交付物 | Shell 脚本 + 场景清单 + lab 规范 + preflight |
| 运行位置 | **注入 Bot 只在 `docker-node` 执行** |
| 故障对象 | Docker 容器模拟 VM（容器内二进制 Redis） |
| 主机类故障 | `docker exec` → 容器（`--target-host` IP 或 `--target-container`） |
| Redis 类故障 | Bot 侧 `redis-cli` → `REDIS_NODES` |
| 互斥 | 同一时刻只跑一个 inject（`flock`）；组合场景内部跳过锁 |
| 持续 | 默认 `--duration 600`（10 分钟），到期自动恢复 |
| Bot 解析 | 日志行 `INJECT_RESULT scenario=... status=pass\|fail detail=...` |

---

## 2. 实验室拓扑（NODE_SPEC）

```text
docker-node (10.10.26.10)  注入机
  ├── redis-cli → 144/145/146:6379
  └── docker exec → redis-n1 / n2 / n3

redis-n1  10.10.26.144:6379   mem_limit 1536m   NET_ADMIN
redis-n2  10.10.26.145:6379   mem_limit 1536m   NET_ADMIN
redis-n3  10.10.26.146:6379   mem_limit 1536m   NET_ADMIN
集群：3 Master，replicas=0；dir=/var/lib/redis/6379
```

### 2.1 必装工具

| 节点 | 必装 |
|---|---|
| **docker-node** | `bash`≥4、`flock`、`redis-cli`、`docker` CLI（挂 docker.sock） |
| **redis-n1/n2/n3** | `stress-ng`、`vmstat`、`chmod`、`dd`、`iptables`、`tc`、`bash`、`redis-server` |

### 2.2 配置（`config.env`，gitignore）

```bash
export INJECT_BACKEND="docker"
export REDIS_NODES="10.10.26.144:6379 10.10.26.145:6379 10.10.26.146:6379"
export REDIS_CONTAINER_MAP="10.10.26.144:redis-n1 10.10.26.145:redis-n2 10.10.26.146:redis-n3"
export REDIS_PASSWORD="..."
export REDIS_DATA_DIR="auto"
export FAULT_DURATION_SEC=600
export CLUSTER_BUS_PORT=16379
```

### 2.3 重建与门控

```bash
cd redis_fault_injection/lab && ./recreate.sh   # 删旧 → 建 4 节点 → 建集群
# 宿主机：sudo modprobe sch_netem   # F22 需要
docker exec -it docker-node bash
cd /workspace/redis_fault_injection
./scripts/preflight.sh   # 必须 FAIL=0；写入 docker_all_nodes.ok 后 F28/F30 可用
```

---

## 3. 脚本架构

| 脚本 | 职责 |
|---|---|
| `scripts/preflight.sh` | 环境检查、SSH/Docker 门控 |
| `scripts/inject_host.sh` | 主机 CPU/内存/重启/基线 |
| `scripts/inject_redis.sh` | Redis 进程/配置/流量/协议 |
| `scripts/inject_network.sh` | Bus / 丢包 / Master 分区 |
| `scripts/inject_disk.sh` | 持久化失败 / 磁盘 IO |
| `scripts/inject_composite.sh` | 组合场景 C01–C03 |
| `scripts/inject_degrade.sh` | 降级 D01–D02 |
| `lib/common.sh` | 锁、docker exec、post-check、`INJECT_RESULT` |
| `run.sh` | 统一入口：`./run.sh host --action cpu ...` |

---

## 4. 全场景清单

约定：命令均在 `redis_fault_injection/` 下、于 **docker-node** 执行。默认 duration=600，可按需改短。

### 4.1 主机资源 — `inject_host.sh`

| ID | 场景 | 等级 | 注入方式 | Post-check | 完整命令 |
|---|---|---|---|---|---|
| **F01** | 正常基线 | L1 | 三节点 PING | 全部 PONG | `./scripts/inject_host.sh --action baseline` |
| **F02** | CPU 持续高压 | L1 | 容器内 `stress-ng --cpu 0 --cpu-load 90` | vmstat 1 4 跳过 since-boot，CPU avg **≥80%** | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600` |
| **F04** | 主机内存压力 | L1 | `stress-ng --vm 2 --vm-bytes 85%`（相对容器 mem_limit） | cgroup 可用 **≤15%** 或 已用 **≥85%** | `./scripts/inject_host.sh --action memory --target-host 10.10.26.145 --duration 600` |
| **F06** | CPU 瞬时尖峰 | L2 | 周期 burst `stress-ng` | 启动即 pass（无硬门限） | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 600` |
| **F09** | 主机重启 | L1 | `docker restart`（模拟 VM 重启） | 需 `--confirm YES`；**无自动恢复** | `./scripts/inject_host.sh --action reboot --target-container redis-n1 --confirm YES` |
| **F28** | 多节点 CPU | L1 | 三节点并行 F02 | 需 `docker_all_nodes.ok` | `./scripts/inject_host.sh --action multi-cpu --duration 600` |

**环境前提**：F04 依赖 `mem_limit=1536m`；F28 依赖 preflight 三容器就绪。

---

### 4.2 Redis 进程与配置 — `inject_redis.sh`

| ID | 场景 | 等级 | 注入方式 | Post-check | 完整命令 |
|---|---|---|---|---|---|
| **F07** | Redis 进程停止 | L1 | `SHUTDOWN NOSAVE`；注入前 `docker update --restart=no` | PING **5s 内 ≥3s 不可达** | `./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6379 --duration 600` |
| **F10** | maxmemory / OOM | L1 | `CONFIG SET maxmemory` + 写填 | 配置已生效 | `./scripts/inject_redis.sh --action maxmemory --node 10.10.26.144:6379 --duration 600 --maxmemory 64mb` |
| **F12** | maxclients 打满 | L1 | `CONFIG SET maxclients` + 并发 PING | 配置已生效 | `./scripts/inject_redis.sh --action maxclients --node 10.10.26.144:6379 --duration 600 --maxclients 10` |
| **F14** | 慢命令 | L1 | 周期 `DEBUG SLEEP` | DEBUG 可用 | `./scripts/inject_redis.sh --action slow-command --node 10.10.26.144:6379 --duration 600` |
| **F15** | 热 Key | L2 | 高频 SET/GET 同前缀 key | 流量已启动 | `./scripts/inject_redis.sh --action hot-key --node 10.10.26.145:6379 --duration 600` |
| **F16** | 大 Key（单 Hash） | L2 | 2 万 field × 256B ≈ 5MB；默认 key=`fault:hotkey`（槽在 145） | seed 完成即 pass；duration 后默认 DEL | `./scripts/inject_redis.sh --action big-key --node 10.10.26.145:6379 --duration 300` |
| **F17** | 冷缓存（单 key） | 应用 | `EXPIRE`/`DEL` 指定 key | — | `./scripts/inject_redis.sh --action cache-expire --node 10.10.26.144:6379 --expire-key mykey --duration 600` |
| **F17\*** | 冷缓存 FLUSHDB | 危险 | `FLUSHDB` | 仅实验室 | `./scripts/inject_redis.sh --action cache-expire --node 10.10.26.144:6379 --duration 60` |
| **F18** | 缓存穿透 | 应用 | 大量 GET 不存在 key | 流量已启动 | `./scripts/inject_redis.sh --action cache-penetrate --node 10.10.26.144:6379 --duration 600 --request-count 100000` |
| **F19** | 协议错误脉冲 | L1 | NOAUTH / WRONGPASS / MOVED / CROSSSLOT，5s×18 | `INFO ERRORSTATS` **递增** | 见下表 |
| **F29** | 历史 MISCONF 背景 | 背景 | 只读目录触发 MISCONF 计数 | MISCONF **递增**；测完必 cleanup | `./scripts/inject_redis.sh --action historical-misconf --node 10.10.26.146:6379` |
| **F29c** | 清理 MISCONF | 清理 | 恢复配置 + 可选重启清 ERRORSTATS | PING up | `./scripts/inject_redis.sh --action historical-misconf-cleanup --node 10.10.26.146:6379` |

**F19 子场景：**

```bash
./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 90 --error-type NOAUTH
./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 90 --error-type WRONGPASS
./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 90 --error-type MOVED
./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 90 --error-type CROSSSLOT
```

---

### 4.3 网络 — `inject_network.sh`

| ID | 场景 | 等级 | 注入方式 | Post-check | 完整命令 |
|---|---|---|---|---|---|
| **F20** | Cluster Bus 阻断 | L1 | 容器内 iptables DROP bus 端口（默认 16379） | 规则已加 | `./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6379 --duration 600` |
| **F22** | 客户端丢包 | L2 | **`tc qdisc replace … root netem loss 30%`**（不用 HTB） | `tc qdisc show` 含 netem loss | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.146 --duration 600 --loss 30 --net-dev eth0` |
| **F30** | 两 Master 分区 | L1 | 双向 iptables DROP | 需三节点 docker_all_nodes.ok | `./scripts/inject_network.sh --action master-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 600` |

**环境前提**：容器 `NET_ADMIN`；F22 宿主机 `modprobe sch_netem`。

---

### 4.4 磁盘 — `inject_disk.sh`

| ID | 场景 | 等级 | 注入方式 | Post-check | 完整命令 |
|---|---|---|---|---|---|
| **F24** | 持久化失败 / MISCONF | L1 | 数据目录+文件 chmod 只读 → BGSAVE | **MISCONF 计数递增** | `./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6379 --duration 600` |
| **F26** | 磁盘 IO 高 | L2 | `dd` 写到 **`<redis dir>/fault_io`**（非 `/tmp`） | IO 已启动 | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 600` |

---

### 4.5 组合 — `inject_composite.sh`

| ID | 场景 | 组成 | 完整命令 |
|---|---|---|---|
| **C01** | 内存 + 历史 MISCONF | F29(146) → F04(144) → F29c | `./scripts/inject_composite.sh --action memory-plus-misconf --duration 600` |
| **C02** | 写拒绝 + CPU | F24 + F02 同节点并行 | `./scripts/inject_composite.sh --action write-reject-plus-cpu --write-node 10.10.26.144:6379 --duration 600` |
| **C03** | Master 停 + 远端内存 | F07(144) + F04(146) 并行 | `./scripts/inject_composite.sh --action master-stop-plus-memory --stop-node 10.10.26.144:6379 --mem-node 10.10.26.146:6379 --duration 600` |

> 组合脚本默认节点端口若仍写 6381，执行时请显式传 `--*-node …:6379`。

---

### 4.6 降级 — `inject_degrade.sh`（Bot 本机）

| ID | 场景 | 注入方式 | 完整命令 |
|---|---|---|---|
| **D01** | 单节点不可达 | Bot 本机 iptables 阻断到 Redis 端口 | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --blocked-port 6379 --duration 600` |
| **D02** | 隐藏采集工具 | 临时移走 `iostat`/`pidstat` | `./scripts/inject_degrade.sh --action hide-tools --duration 600` |
| **D03** | K3 失败 | 无脚本；排障侧断 K3 网络 | — |

---

### 4.7 当前环境不适用（无脚本）

| 场景 | 原因 |
|---|---|
| 复制中断 / 自动 Failover | 3 Master 无 Replica |
| Slot 迁移中断 | 需 resharding 运维窗口 |

---

## 5. 验收与 Bot 协作

### 5.1 统一结果行

```text
INJECT_RESULT scenario=<id> status=pass|fail detail=<...>
```

- 异常、SIGTERM、post-check 失败也会尽量 emit fail（`inject_begin` trap）。  
- Bot：`grep 'INJECT_RESULT' … | grep status=pass`。  
- **无该行** = 脚本崩溃/被杀，不算业务失败，需重跑。

### 5.2 时序

```text
T0     注入 Bot: inject_*.sh --duration 600
T0+    见 INJECT_RESULT status=pass 后 → 排障 Bot 触发 SOPS（故障仍持续）
T600   注入到期 auto-recover 退出
T600+  可选基线对比（F29/F24 先 cleanup）
```

### 5.3 硬规则

1. 同一时刻只跑一个 inject（组合除外，内部已 skip lock）。  
2. 禁止中途 kill 注入进程（避免无 `INJECT_RESULT`）。  
3. F29 / F24 测完必须 cleanup 再做 F01。  
4. 只在 docker-node 跑脚本，不要进 redis-n\* 跑 preflight。

---

## 6. 推荐执行顺序（回归）

```bash
# R0 环境
./scripts/preflight.sh

# R1 基线 + 主机
./scripts/inject_host.sh --action baseline
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 300
./scripts/inject_host.sh --action memory --target-host 10.10.26.145 --duration 300

# R2 Redis 主路径
./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6379 --duration 300
./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --error-type NOAUTH --duration 90
./scripts/inject_redis.sh --action big-key --node 10.10.26.145:6379 --duration 300

# R3 网络 / 磁盘
./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6379 --duration 300
./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.146 --duration 120 --loss 30
./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6379 --duration 300
./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 300

# R4 组合 / 降级
./scripts/inject_composite.sh --action memory-plus-misconf --duration 300 \
  --memory-node 10.10.26.144:6379 --misconf-node 10.10.26.146:6379
./scripts/inject_degrade.sh --action hide-tools --duration 300
```

每条命令均应出现 `INJECT_RESULT … status=pass`。

---

## 7. 场景 ↔ 排障线索（给排障 Bot，非验收项）

| ID | 预期可观测线索（参考） |
|---|---|
| F02 | 节点 CPU 高、负载高 |
| F04 | 容器/主机内存紧张、可能 swap/OOM 风险 |
| F07 | 节点 PING 失败、集群可能标 fail |
| F10 | OOM / 驱逐 / 写失败 |
| F12 | ERR max number of clients |
| F14 | 延迟升高、slowlog |
| F15 | 单 key/分片热点 |
| F16 | bigkeys / HGETALL 大包 |
| F19 | ERRORSTATS 对应错误计数 |
| F20 | cluster bus 不通、节点怀疑 |
| F22 | 客户端超时/重试增多 |
| F24/F29 | MISCONF、写拒绝 |
| F26 | 磁盘 util 高、延迟 |
| F28 | 多节点 CPU 同时高 |
| F30 | 脑裂/分区症状 |
| C01–C03 | 多根因叠加 |
| D01–D02 | 采集降级 |

---

## 8. 相关文档

| 文档 | 内容 |
|---|---|
| [`lab/NODE_SPEC.md`](lab/NODE_SPEC.md) | 4 节点 Docker 规范 |
| [`PREREQUISITES.md`](PREREQUISITES.md) | 环境前提与优化要点 |
| [`SCENARIOS.md`](SCENARIOS.md) | 场景速查 |
| [`README.md`](README.md) | 使用说明 |
| [`config.env.example`](config.env.example) | 配置模板 |

---

## 9. 一句话总览

**在 docker-node 上**：preflight → 按上表逐场景 `inject_*.sh` → 解析 `INJECT_RESULT` → 故障持续窗口内由排障 Bot 独立采集诊断 → duration 到期自动恢复。全量场景覆盖主机 / Redis / 网络 / 磁盘 / 组合 / 降级共 **F01–F30（有脚本子集）+ C01–C03 + D01–D02**。
