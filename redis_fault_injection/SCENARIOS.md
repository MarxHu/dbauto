# Redis Cluster 故障注入场景总表

> 环境默认：`10.10.26.144:6381`、`10.10.26.145:6381`、`10.10.26.146:6381`  
> 使用前：`cp config.env.example config.env`  
> **约定：所有故障脚本在 `--duration` 到期后自动恢复，无需单独 recover 命令。**

## 脚本分类（6 个）

| 脚本 | 职责 |
|---|---|
| `scripts/inject_host.sh` | 主机 CPU/内存/重启/基线 |
| `scripts/inject_redis.sh` | Redis 进程、配置、流量、协议错误 |
| `scripts/inject_network.sh` | Cluster Bus、丢包、Master 分区 |
| `scripts/inject_disk.sh` | 持久化失败、磁盘 IO |
| `scripts/inject_composite.sh` | V1.2 三个组合场景 |
| `scripts/inject_degrade.sh` | JOB 失联、工具缺失 |

统一入口：

```bash
./run.sh host --action cpu --target-host 10.10.26.144 --duration 240
./run.sh redis --action maxmemory --node 10.10.26.144:6381 --duration 240
```

---

## 一、基线与主机资源 → `inject_host.sh`

| ID | 场景 | 命令 | 默认 duration |
|---|---|---|---|
| F01 | 正常基线 | `./scripts/inject_host.sh --action baseline` | 无 |
| F02 | CPU 持续高压 | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 240` | 240 |
| F04 | 内存压力 | `./scripts/inject_host.sh --action memory --target-host 10.10.26.144 --duration 240` | 240 |
| F06 | CPU 尖峰 | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 240` | 240 |
| F09 | 主机重启 | `./scripts/inject_host.sh --action reboot --target-host 10.10.26.144 --confirm YES` | 无自动恢复 |
| F28 | 多节点 CPU | `./scripts/inject_host.sh --action multi-cpu --duration 240` | 240 |

F03/F05（CPU/内存恢复）= 等待 duration 结束即自动恢复，或 `Ctrl+C` 触发 trap 清理。

---

## 二、Redis 进程与配置 → `inject_redis.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F07 | 进程停止 | `./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6381 --duration 240` |
| F10 | maxmemory/OOM | `./scripts/inject_redis.sh --action maxmemory --node 10.10.26.144:6381 --duration 240 --maxmemory 64mb` |
| F12 | maxclients | `./scripts/inject_redis.sh --action maxclients --node 10.10.26.144:6381 --duration 240 --maxclients 10` |
| F14 | 慢命令 | `./scripts/inject_redis.sh --action slow-command --node 10.10.26.144:6381 --duration 240` |
| F15 | 热 Key | `./scripts/inject_redis.sh --action hot-key --node 10.10.26.145:6381 --duration 240` |
| F16 | 大 Key | `./scripts/inject_redis.sh --action big-key --node 10.10.26.145:6381 --duration 240` |
| F17 | 冷缓存 | `./scripts/inject_redis.sh --action cache-expire --node 10.10.26.144:6381 --expire-key mykey --duration 60` |
| F18 | 缓存穿透 | `./scripts/inject_redis.sh --action cache-penetrate --node 10.10.26.144:6381 --duration 60 --request-count 100000` |
| F19 | 协议错误脉冲 | `./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6381 --duration 90 --error-type NOAUTH` |
| F29 | 历史 MISCONF | `./scripts/inject_redis.sh --action historical-misconf --node 10.10.26.146:6381` |

`error-type` 可选：`NOAUTH` / `WRONGPASS` / `MOVED` / `CROSSSLOT`

特殊说明：
- `cache-expire` 不带 `--expire-key` 会 `FLUSHDB`，**不会自动恢复 key**
- `historical-misconf` 为一次性背景，**不自动清计数**

---

## 三、网络 → `inject_network.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F20 | Cluster Bus 阻断 | `./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6381 --duration 240` |
| F22 | 客户端丢包 | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.144 --duration 120 --loss 30` |
| F30 | Master 分区 | `./scripts/inject_network.sh --action master-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 240` |

---

## 四、磁盘 → `inject_disk.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F24 | 持久化失败 | `./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6381 --duration 240` |
| F26 | 磁盘 IO 高 | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 240` |

---

## 五、组合场景 → `inject_composite.sh`

| ID | 场景 | 命令 | 期望主次 |
|---|---|---|---|
| C01 | 内存 + 历史 MISCONF | `./scripts/inject_composite.sh --action memory-plus-misconf --duration 240` | 内存主 |
| C02 | 写拒绝 + CPU | `./scripts/inject_composite.sh --action write-reject-plus-cpu --write-node 10.10.26.144:6381 --duration 240` | 写拒绝 S2 主 |
| C03 | Master 停 + 远端内存 | `./scripts/inject_composite.sh --action master-stop-plus-memory --stop-node 10.10.26.144:6381 --mem-node 10.10.26.146:6381 --duration 240` | 连续性 S1 主 |

---

## 六、降级场景 → `inject_degrade.sh`

| ID | 场景 | 命令 |
|---|---|---|
| D01 | JOB 失联 | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --duration 240` |
| D02 | 隐藏 iostat/pidstat | `./scripts/inject_degrade.sh --action hide-tools --duration 240` |
| D03 | K3 失败 | 无脚本；联调时断 K3 网络 |

---

## 七、L3 不适用（无脚本）

| 场景 | 原因 |
|---|---|
| 复制中断 / 自动 Failover / Slot 迁移 | 当前 3 Master 无 Replica |

---

## 八、联调推荐顺序

1. `inject_host.sh --action baseline` ×3  
2. CPU / 内存各 2 次（`--duration 240`）  
3. `inject_redis.sh` / `inject_network.sh` / `inject_disk.sh` 单场景各 1 次  
4. `inject_composite.sh` 三个组合各 1 次  
5. `inject_degrade.sh` 两个降级各 1 次  

## 九、参数速查

```text
--action <name>         故障类型（必填）
--duration <seconds>    故障持续时间，到期自动恢复（默认 240）
--target-host <ip>      主机级故障目标 VM
--node <ip:port>        Redis 节点
--duration 建议 >= 240  覆盖五路采集 + 30s 差分
```

收到 `SIGINT/SIGTERM` 或脚本异常退出时，也会通过 `trap` 执行清理。
