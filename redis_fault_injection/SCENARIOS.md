# Redis Cluster 故障注入场景总表

> **验收范围**：仅验收**故障注入行为**（现象是否发生、持续、恢复）。  
> **排障链路**（SOPS/清洗/K3）独立建设、独立验收，不在本文范围。  
> **运行模式**：注入 Bot 与排障 Bot 在**同一台机器**执行脚本；默认本地运行（`TARGET_HOST` 为空）。  
> **环境前提**：见 [`PREREQUISITES.md`](PREREQUISITES.md)，跑前执行 `./scripts/preflight.sh`。  
> **持续时间**：持续型故障默认 **`--duration 600`（10 分钟）**，可用入参覆盖。到期自动恢复，无需 recover 命令。  
> **互斥**：同一时刻只允许一个注入 action（`flock` 锁）；场景之间等上一场景恢复完再跑。

## 脚本分类（6 + preflight）

| 脚本 | 职责 |
|---|---|
| `scripts/preflight.sh` | 环境前提检查 |
| `scripts/inject_host.sh` | 主机 CPU/内存/重启/基线 |
| `scripts/inject_redis.sh` | Redis 进程、配置、流量、协议错误 |
| `scripts/inject_network.sh` | Cluster Bus、丢包、Master 分区 |
| `scripts/inject_disk.sh` | 持久化失败、磁盘 IO |
| `scripts/inject_composite.sh` | 三个组合场景 |
| `scripts/inject_degrade.sh` | 采集不可达、工具缺失 |

```bash
cp config.env.example config.env
./scripts/preflight.sh
./scripts/inject_host.sh --action cpu --duration 600
```

---

## 一、主机资源 → `inject_host.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F01 | 基线 | `./scripts/inject_host.sh --action baseline` |
| F02 | CPU 持续高压 | `./scripts/inject_host.sh --action cpu --duration 600` |
| F04 | 内存压力 | `./scripts/inject_host.sh --action memory --duration 600` |
| F06 | CPU 尖峰 | `./scripts/inject_host.sh --action cpu-spike --duration 600` |
| F09 | 主机重启 | `./scripts/inject_host.sh --action reboot --confirm YES` |
| F28 | 多节点 CPU | `./scripts/inject_host.sh --action multi-cpu --duration 600` |

---

## 二、Redis → `inject_redis.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F07 | 进程停止 | `./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6381 --duration 600` |
| F10 | maxmemory/OOM | `./scripts/inject_redis.sh --action maxmemory --node ... --duration 600 --maxmemory 64mb` |
| F12 | maxclients | `./scripts/inject_redis.sh --action maxclients --node ... --duration 600` |
| F14 | 慢命令 | `./scripts/inject_redis.sh --action slow-command --node ... --duration 600` |
| F15 | 热 Key | `./scripts/inject_redis.sh --action hot-key --node ... --duration 600` |
| F16 | 大 Key | `./scripts/inject_redis.sh --action big-key --node ... --duration 600` |
| F17 | 冷缓存 | `./scripts/inject_redis.sh --action cache-expire --node ... --expire-key mykey --duration 600` |
| F18 | 缓存穿透 | `./scripts/inject_redis.sh --action cache-penetrate --node ... --duration 600` |
| F19 | 协议脉冲 | `./scripts/inject_redis.sh --action error-pulse --node ... --error-type NOAUTH` |
| F29 | 历史 MISCONF | `./scripts/inject_redis.sh --action historical-misconf --node 10.10.26.146:6381` |

**F19 说明**：有界脉冲固定 `5s × 18 = 90s`（与 V1.2 一致），`--duration` 只限制最大窗口；脚本会打印 pulse 前后 `INFO ERRORSTATS`。

**F29 说明**：先只读数据目录触发 MISCONF，再恢复写权限并 `BGSAVE`；留下历史计数，**不自动清理**（需人工或重启 Redis）。

---

## 三、网络 → `inject_network.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F20 | Bus 阻断 | `./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6381 --duration 600` |
| F22 | 丢包 | `./scripts/inject_network.sh --action packet-loss --duration 600 --loss 30 --net-dev eth0` |
| F30 | Master 分区 | `./scripts/inject_network.sh --action master-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 600` |

---

## 四、磁盘 → `inject_disk.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F24 | 持久化失败 | `./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6381 --duration 600` |
| F26 | 磁盘 IO | `./scripts/inject_disk.sh --action io-stress --duration 600` |

---

## 五、组合 → `inject_composite.sh`

| ID | 场景 | 命令 |
|---|---|---|
| C01 | 内存 + 历史 MISCONF | `./scripts/inject_composite.sh --action memory-plus-misconf --duration 600` |
| C02 | 写拒绝 + CPU | `./scripts/inject_composite.sh --action write-reject-plus-cpu --duration 600` |
| C03 | Master 停 + 远端内存 | `./scripts/inject_composite.sh --action master-stop-plus-memory --duration 600` |

---

## 六、降级 → `inject_degrade.sh`

| ID | 场景 | 命令 |
|---|---|---|
| D01 | 单节点不可达 | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --blocked-port 6381 --duration 600` |
| D02 | 隐藏 iostat/pidstat | `./scripts/inject_degrade.sh --action hide-tools --duration 600` |

---

## 七、Bot 编排建议

```text
注入 Bot:
  1. preflight.sh
  2. inject_*.sh --action ... --duration 600
  3. 等待脚本退出（= 故障已自动恢复）

排障 Bot（独立）:
  在注入持续期间或之后任意时刻触发外部 SOPS（与本目录无关）

注意:
  - 不要并行跑两个 inject action（锁会拒绝）
  - C01 先 historical-misconf（瞬时）再 memory（600s）
  - F29 跑完后若要做基线，需先清理 MISCONF 背景或换节点
```

---

## 八、参数速查

```text
--action <name>          必填
--duration <seconds>     默认 600（10 分钟），入参可改
--node <ip:port>
--target-host <ip>       可选；单机模式留空
--error-type             NOAUTH|WRONGPASS|MOVED|CROSSSLOT
```
