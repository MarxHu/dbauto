# Redis Cluster 故障注入 — 完整说明

> 仓库地址：**https://github.com/MarxHu/dbauto**  
> 脚本目录：**https://github.com/MarxHu/dbauto/tree/main/redis_fault_injection**

本文档说明：如何获取脚本、如何配置密码、注入 Bot 与排障 Bot 如何协作、**post-check 验收**、以及**每个场景对应的完整命令**。

---

## 1. 这套东西是什么

| 项目 | 说明 |
|---|---|
| **交付物** | Shell 脚本 + 场景清单 + 环境检查清单 |
| **验收范围** | 只验收**故障是否被成功注入**（现象、持续、自动恢复） |
| **不包含** | SOPS 排障、五路采集、AI 诊断（由你方独立 Bot/流程负责） |
| **运行位置** | 注入 Bot 跑在 **docker-node** |
| **故障路径** | Redis 用 Docker 容器**模拟 VM**（容器内二进制 Redis）；主机/网络/磁盘类 → **`docker exec`**；Redis 类 → Bot **`redis-cli`** |

### 1.1 部署拓扑（实验室默认）

```text
┌──────────────────────────┐   docker exec    ┌─────────────────────────────┐
│  docker-node（注入 Bot）   │ ───────────────► │  container ≈ VM1            │
│  redis-cli + docker +    │                  │  IP 10.10.26.144 redis:6379 │
│  scripts                 │ ───────────────► ├─────────────────────────────┤
└────────────┬─────────────┘                  │  container ≈ VM2 :145       │
             │ redis-cli :6379                ├─────────────────────────────┤
             └────────────────────────────────►│  container ≈ VM3 :146       │
                                               └─────────────────────────────┘
```

**要点**：

- `INJECT_BACKEND=docker`（默认）；不要再依赖对 144/145/146 的 SSH
- 配置 **`REDIS_CONTAINER_MAP`**（IP→容器名），或保证容器网络 IP 与 `REDIS_NODES` 一致以便自动发现
- 主机级故障：`--target-host <容器IP>` 或 `--target-container <容器名>`
- **F09 reboot** = `docker restart <container>`（模拟 VM 重启）
- **F28**：仅 preflight 三容器全就绪（`.state/docker_all_nodes.ok`）时启用
- **`REDIS_DATA_DIR=auto`**：自动用 `CONFIG GET dir`（如 `/var/lib/redis/6379`）

---

## 2. 怎么拿到脚本（GitHub）

### 2.1 克隆仓库

```bash
git clone https://github.com/MarxHu/dbauto.git
cd dbauto/redis_fault_injection
```

### 2.2 仓库里有什么

```
redis_fault_injection/
├── README.md                 ← 本文档
├── PREREQUISITES.md          ← 环境前提清单
├── SCENARIOS.md              ← 场景速查表
├── config.env.example        ← 配置模板（无密码）
├── run.sh                    ← 统一入口
├── lib/common.sh             ← 公共函数、锁、密码加载
└── scripts/
    ├── preflight.sh          ← 跑前检查
    ├── inject_host.sh        ← 主机 CPU/内存/重启
    ├── inject_redis.sh       ← Redis 进程/配置/流量/协议
    ├── inject_network.sh     ← 网络 Bus/丢包/分区
    ├── inject_disk.sh        ← 持久化/磁盘 IO
    ├── inject_composite.sh   ← 组合场景
    └── inject_degrade.sh     ← 降级场景
```

### 2.3 什么不会上 GitHub（敏感信息）

| 文件 | 是否提交 Git | 说明 |
|---|---|---|
| `config.env` | **否**（已 `.gitignore`） | 放 Redis 密码、节点 IP 等 |
| `config.env.example` | **是** | 只有模板，`REDIS_PASSWORD=""` |
| `.state/` | **否** | 运行时锁文件、MISCONF 状态 |

**密码不会通过 GitHub 传递。** 你在本机创建 `config.env` 并填入密码即可。

---

## 3. 怎么配置（含密码）

```bash
cd redis_fault_injection
cp config.env.example config.env
chmod +x run.sh scripts/*.sh lib/common.sh
```

编辑 `config.env`（示例）：

```bash
export INJECT_BACKEND="docker"
export REDIS_NODES="10.10.26.144:6379 10.10.26.145:6379 10.10.26.146:6379"
export REDIS_PASSWORD="你的密码"          # 必填，勿提交 Git
export REDIS_DATA_DIR="auto"            # 自动 CONFIG GET dir（如 /var/lib/redis/6379）
export REDIS_CONTAINER_MAP="10.10.26.144:redis-144 10.10.26.145:redis-145 10.10.26.146:redis-146"
export FAULT_DURATION_SEC=600
```

查容器名与 IP：

```bash
docker inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(docker ps -q)
```

跑前检查（**三容器 docker exec 可达 + Redis PING 全 PASS**）：

```bash
./scripts/preflight.sh
```

必须 **FAIL=0** 再开始注入。通过后写入 `.state/docker_all_nodes.ok`，F28 才可用。

---

## 4. Post-check 与 Bot 解析

脚本在故障启动后会做 **post-check**，并输出统一结果行供注入 Bot 解析：

```text
INJECT_RESULT scenario=<id> status=pass|fail detail=<...>
```

| 场景 | Post-check 条件 |
|---|---|
| F02 cpu | 容器内 `vmstat` 3 次采样，CPU avg **≥80%** |
| F04 memory | cgroup 或 `/proc/meminfo`，可用内存 **≤15%** |
| F07 process-stop | Bot `redis-cli PING` **无响应** |
| F19 error-pulse | `INFO ERRORSTATS` 对应计数 **递增** |
| F29 historical-misconf | MISCONF 计数 **递增** |

Post-check **失败**时：脚本立即 cleanup 并 `exit 1`，`INJECT_RESULT status=fail`。

Bot 示例：

```bash
out=$(./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600 2>&1)
echo "$out" | grep 'INJECT_RESULT scenario=cpu status=pass'
```

---

## 5. 数据怎么传递（注入 Bot ↔ 排障 Bot）

**脚本之间不通过文件/API 传 JSON。** 协作方式是：

```text
┌─────────────────────────────────────────────────────────────┐
│  docker-node（注入 Bot）                                      │
├─────────────────────────────────────────────────────────────┤
│  注入 Bot                         排障 Bot（独立）            │
│  1. preflight.sh                  1. 触发外部 SOPS/采集       │
│  2. docker exec / redis-cli 注入  2. 读 Redis/容器真实状态    │
│  3. post-check → INJECT_RESULT    3. 清洗 + AI（不在本目录）  │
│  4. duration 到期 auto-recover                               │
└─────────────────────────────────────────────────────────────┘
```

### 5.1 推荐编排时序

```text
T0   注入 Bot: ./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600
T0+  排障 Bot: 触发 SOPS（故障仍在持续中）
T600 注入 Bot: post-check 已通过，脚本阻塞至 duration 结束并 auto-recover
```

### 5.2 场景之间避免干扰

- 同一时刻 **只能一个** `inject_*.sh`（`flock` 锁：`.state/inject.lock`）
- 上一场景脚本 **完全退出**（= 已恢复）后再跑下一场景
- F29 历史 MISCONF 会污染计数 → 测完跑 cleanup（C01 自动 cleanup）

### 5.3 给 Bot 的参数传递方式

```bash
cd /path/to/dbauto/redis_fault_injection
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600
./run.sh host --action memory --target-host 10.10.26.145 --duration 600
./run.sh redis --action maxmemory --node 10.10.26.144:6379 --duration 600
```

---

## 6. 通用参数

| 参数 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `--action` | 是 | — | 场景类型 |
| `--duration` | 否 | `600` | 秒；到期自动恢复 |
| `--node` | 部分 | 第一个节点 | `ip:port` |
| `--target-host` | 主机类 | — | 容器 IP（映射到 docker 容器） |
| `--target-container` | 主机类 | — | 直接指定容器名 |
| `--error-type` | F19 | `NOAUTH` | `NOAUTH\|WRONGPASS\|MOVED\|CROSSSLOT` |
| `--maxmemory` | F10 | `64mb` | |
| `--maxclients` | F12 | `10` | |
| `--loss` | F22 | `30` | 丢包百分比 |
| `--net-dev` | F22 | `eth0` | 网卡名 |
| `--confirm YES` | F09 | — | 主机重启确认 |

---

## 7. 全部场景与完整命令

> 以下命令均在 `redis_fault_injection/` 目录下执行。  
> 默认 `--duration 600`（10 分钟），可按需改为 `--duration 300` 等。

### 7.0 环境检查

| ID | 场景 | 脚本 | 完整命令 |
|---|---|---|---|
| — | 跑前检查 | `scripts/preflight.sh` | `./scripts/preflight.sh` |

---

### 7.1 主机资源 — `scripts/inject_host.sh`

| ID | 场景 | 等级 | 完整命令 |
|---|---|---|---|
| F01 | 正常基线 | L1 | `./scripts/inject_host.sh --action baseline` |
| F02 | CPU 持续高压 | L1 | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600` |
| F04 | 主机内存压力 | L1 | `./scripts/inject_host.sh --action memory --target-host 10.10.26.144 --duration 600` |
| F06 | CPU 瞬时尖峰 | L2 | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 600` |
| F09 | 主机重启 | L1 | `./scripts/inject_host.sh --action reboot --target-container <name> --confirm YES` |
| F28 | 多节点 CPU 高 | L1 | `./scripts/inject_host.sh --action multi-cpu --duration 600`（需 docker_all_nodes.ok） |

**验收要点**：F02 → 容器内 CPU avg≥80%；F04 → 可用内存≤15%；F09 = `docker restart`。

---

### 7.2 Redis 进程与配置 — `scripts/inject_redis.sh`

| ID | 场景 | 等级 | 完整命令 |
|---|---|---|---|
| F07 | Redis 进程停止 | L1 | `./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6379 --duration 600` |
| F10 | maxmemory / OOM | L1 | `./scripts/inject_redis.sh --action maxmemory --node 10.10.26.144:6379 --duration 600 --maxmemory 64mb` |
| F12 | maxclients 打满 | L1 | `./scripts/inject_redis.sh --action maxclients --node 10.10.26.144:6379 --duration 600 --maxclients 10` |
| F14 | 慢命令 | L1 | `./scripts/inject_redis.sh --action slow-command --node 10.10.26.144:6379 --duration 600` |
| F15 | 热 Key / 热分片 | L2 | `./scripts/inject_redis.sh --action hot-key --node 10.10.26.145:6379 --duration 600` |
| F16 | 大 Key 线索 | L2 | `./scripts/inject_redis.sh --action big-key --node 10.10.26.145:6379 --duration 600` |
| F17 | 冷缓存（单 key） | 应用向 | `./scripts/inject_redis.sh --action cache-expire --node 10.10.26.144:6379 --expire-key mykey --duration 600` |
| F17* | 冷缓存（FLUSHDB） | 危险 | `./scripts/inject_redis.sh --action cache-expire --node 10.10.26.144:6379 --duration 60` |
| F18 | 缓存穿透 | 应用向 | `./scripts/inject_redis.sh --action cache-penetrate --node 10.10.26.144:6379 --duration 600 --request-count 100000` |
| F19-NOAUTH | 错误密码脉冲 | L1 | `./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 600 --error-type NOAUTH` |
| F19-WRONGPASS | ACL 错密码 | L1 | `./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 600 --error-type WRONGPASS` |
| F19-MOVED | MOVED 脉冲 | L1 | `./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 600 --error-type MOVED` |
| F19-CROSSSLOT | 跨 Slot 脉冲 | L1 | `./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --duration 600 --error-type CROSSSLOT` |
| F29 | 历史 MISCONF 背景 | 背景 | `./scripts/inject_redis.sh --action historical-misconf --node 10.10.26.146:6379` |
| F29c | 清理 MISCONF | 清理 | `./scripts/inject_redis.sh --action historical-misconf-cleanup --node 10.10.26.146:6379` |

**F19**：脉冲固定 5s×18=90s，日志会打印 pulse 前后 `INFO ERRORSTATS`。  
**F29**：测完必须 F29c；C01 组合会自动 F29c。

---

### 7.3 网络 — `scripts/inject_network.sh`

| ID | 场景 | 等级 | 完整命令 |
|---|---|---|---|
| F20 | Cluster Bus 阻断 | L1 | `./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6379 --duration 600` |
| F22 | 客户端丢包 | L2 | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.144 --duration 600 --loss 30 --net-dev eth0` |
| F30 | 两 Master 分区 | L1 | `./scripts/inject_network.sh --action master-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 600` |

---

### 7.4 磁盘 — `scripts/inject_disk.sh`

| ID | 场景 | 等级 | 完整命令 |
|---|---|---|---|
| F24 | 持久化失败 / MISCONF 链 | L1 | `./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6379 --duration 600` |
| F26 | 磁盘 IO 高 | L2 | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 600` |

---

### 7.5 组合场景 — `scripts/inject_composite.sh`

| ID | 场景 | 完整命令 | 说明 |
|---|---|---|---|
| C01 | 内存 + 历史 MISCONF | `./scripts/inject_composite.sh --action memory-plus-misconf --duration 600` | 144 内存 10min；146 MISCONF 背景；结束自动 cleanup |
| C02 | 写拒绝 + CPU | `./scripts/inject_composite.sh --action write-reject-plus-cpu --write-node 10.10.26.144:6379 --duration 600` | 同节点持久化失败 + CPU |
| C03 | Master 停 + 远端内存 | `./scripts/inject_composite.sh --action master-stop-plus-memory --stop-node 10.10.26.144:6379 --mem-node 10.10.26.146:6379 --duration 600` | 144 停 Redis；146 内存压力 |

---

### 7.6 降级场景 — `scripts/inject_degrade.sh`

| ID | 场景 | 完整命令 |
|---|---|---|
| D01 | 单节点 Redis 不可达 | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --blocked-port 6381 --duration 600` |
| D02 | 隐藏 iostat/pidstat | `./scripts/inject_degrade.sh --action hide-tools --duration 600` |
| D03 | K3 失败 | 无脚本；排障侧联调时断 K3 网络 |

---

### 7.7 当前环境不适用（L3，无脚本）

| 场景 | 原因 |
|---|---|
| 复制中断 | 3 Master 无 Replica |
| 自动 Failover | 无 Replica |
| Slot 迁移中断 | 需 resharding 运维窗口 |

---

## 8. 推荐首跑顺序（实验室 docker-node）

```bash
# 0. 配置 + preflight（填 REDIS_CONTAINER_MAP）
cp config.env.example config.env
./scripts/preflight.sh

# 1. 基线
./scripts/inject_host.sh --action baseline

# 2. 主机资源（docker exec 进容器）
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 120
./scripts/inject_host.sh --action memory --target-host 10.10.26.144 --duration 120

# 3. Redis / 网络抽样
./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6379 --duration 120
./scripts/inject_redis.sh --action error-pulse --node 10.10.26.146:6379 --error-type NOAUTH
./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6379 --duration 120
```

**合并条件**：实验室 `preflight.sh` **FAIL=0** 且抽样 `INJECT_RESULT status=pass` 后合并到 `main`。

---

## 9. 相关文档

| 文档 | 内容 |
|---|---|
| [PREREQUISITES.md](./PREREQUISITES.md) | 环境前提、必装工具、按场景额外条件 |
| [SCENARIOS.md](./SCENARIOS.md) | 场景速查（精简版） |
| [config.env.example](./config.env.example) | 配置模板 |

---

## 10. FAQ

**Q：密码放 GitHub 吗？**  
A：不放。只在机器本地 `config.env`，已 gitignore。

**Q：注入 Bot 和排障 Bot 怎么对接？**  
A：不对接文件。注入 Bot 改真实环境；排障 Bot 读真实 Redis/主机状态。时间上建议注入开始后立刻触发 SOPS。

**Q：duration 怎么改？**  
A：命令行 `--duration 300` 或改 `config.env` 里 `FAULT_DURATION_SEC`。

**Q：脚本退出代表什么？**  
A：持续型故障已自动恢复（F09 重启、F29 背景除外，见上文 cleanup）。

**Q：注入 Bot 和 Redis 必须在同一台机器吗？**  
A：Bot 跑在 docker-node；Redis 在同机 Docker 容器内。主机故障用 `docker exec`，Redis 故障用 `redis-cli`。

**Q：PR 合并后路径变吗？**  
A：合并到 `main` 后路径为 `dbauto/redis_fault_injection/`，命令不变。
