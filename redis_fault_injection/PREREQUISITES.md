# 故障注入环境前提（Preflight Checklist）

> **范围说明**：本目录只验收**故障注入行为**是否按预期发生。  
> Redis Cluster AI 排障链路（SOPS/清洗/K3）**独立建设、独立验收**，不在本文范围内。

> **部署模式**：注入 Bot 与排障 Bot 在**同一台机器**上执行脚本；默认 `TARGET_HOST` 为空（本地执行）。  
> 一次只跑一个注入 action，避免场景互相干扰。

---

## 1. 机器与权限

| 项 | 要求 | 验证命令 |
|---|---|---|
| 操作系统 | Linux（与实验室 Redis VM 一致） | `uname -a` |
| 权限 | 注入 Bot 能 `sudo` 或使用 root（iptables/tc/chmod） | `sudo -n true` |
| 并发 | 同一时刻仅一个注入脚本（内置 flock 锁） | 见 `preflight.sh` |
| 场景间隔 | 上一场景 auto-recover 完成后再跑下一个 | 人工/Bot 编排 |

---

## 2. 必装工具

| 工具 | 用途 | 验证 |
|---|---|---|
| `redis-cli` | Redis/Cluster 操作 | `redis-cli --version` |
| `stress-ng` | CPU/内存压力 | `stress-ng --version` |
| `iptables` | 网络阻断/分区 | `sudo iptables -L -n` |
| `tc` + `iproute2` | 丢包注入 | `tc qdisc help` |
| `flock` | 注入互斥锁 | `flock --version` |
| `bash` ≥ 4 | 脚本运行 | `bash --version` |

可选（部分场景）：

| 工具 | 场景 |
|---|---|
| `systemctl` | process-stop 恢复 |
| `dd` | io-stress |

---

## 3. Redis 集群

| 项 | 要求 | 说明 |
|---|---|---|
| 拓扑 | 3 Master，端口如 `6381` | 与 `config.env` 中 `REDIS_NODES` 一致 |
| 连通 | 注入机可 PING 全部节点 | `./scripts/preflight.sh` |
| 密码 | 若启用 `requirepass`/ACL，写入 `REDIS_PASSWORD` / `REDIS_ACL_USER` | NOAUTH/WRONGPASS 场景依赖 |
| `DEBUG SLEEP` | **未**禁用 | 慢命令场景 F14 |
| 数据目录 | 确认真实路径，写入 `REDIS_DATA_DIR` | 默认 `/var/lib/redis` 常需改 |
| 配置文件 | 确认 `REDIS_CONF`、`REDIS_SERVICE` | process-stop 恢复用 |
| `stop-writes-on-bgsave-error` | 持久化/MISCONF 场景可写 CONFIG | persistence-fail / historical-misconf |

---

## 4. 网络与命名

| 项 | 要求 |
|---|---|
| 网卡名 | 写入 `NET_DEV`（默认 `eth0`，按 `ip link` 实际值） |
| Cluster Bus | 默认 client_port+10000，或 `CLUSTER_BUS_PORT` |
| 本机防火墙 | 允许注入脚本临时添加 iptables/tc 规则 |

---

## 5. 按场景额外前提

| 场景 | 额外条件 |
|---|---|
| F19 NOAUTH | Redis 已设密码；脉冲用**无密码**客户端 |
| F19 WRONGPASS | 已启用 ACL；配置 `REDIS_ACL_USER` |
| F19 MOVED | 使用**非 cluster 模式** `redis-cli`（脚本已处理） |
| F19 CROSSSLOT | Cluster 模式；跨 hash tag 的 key |
| F10 maxmemory | 当前 used memory < 目标 maxmemory，否则先清理 |
| F17 cache-expire (FLUSHDB) | **仅实验室**；会清空当前 DB |
| F29 historical-misconf | 可写 `REDIS_DATA_DIR`；会留下历史 MISCONF 计数 |
| F09 reboot | 需 `--confirm YES`；**无自动恢复** |
| D01 job-unreachable | 本机模式：阻断到指定 Redis 端口的本地/outbound 连接（见脚本） |
| D02 hide-tools | 本机存在 `iostat`/`pidstat` 可隐藏 |

---

## 6. 推荐准备流程（单机）

```bash
cp config.env.example config.env
# 编辑 REDIS_NODES / REDIS_DATA_DIR / REDIS_PASSWORD / NET_DEV

./scripts/preflight.sh
# 全部 PASS 后再交给注入 Bot 跑 SCENARIOS.md 中的命令
```

---

## 7. 注入 Bot vs 排障 Bot

| Bot | 职责 | 脚本范围 |
|---|---|---|
| **注入 Bot** | 启动故障 → 等待 `--duration` → 自动恢复 | `inject_*.sh` |
| **排障 Bot** | 独立触发 SOPS/诊断（不在本目录） | 外部流程 |

两者可并行在同一机器上，但：

1. 注入 Bot **持锁期间**不要启动第二个注入 action  
2. 排障 Bot **不应**修改 iptables/maxmemory 等注入态（除非在验收排障本身）  
3. 组合场景（C01/C02/C03）仍由注入 Bot **串行**调用子 action  

---

## 8. 默认持续时间

持续型故障默认 **`--duration 600`（10 分钟）**，可通过入参覆盖：

```bash
./scripts/inject_host.sh --action cpu --duration 600
./scripts/inject_host.sh --action cpu --duration 300   # 临时改 5 分钟
```

脉冲型（error-pulse）默认在 600s 窗口内按 5s×18 有界发送；可通过 `--duration` 拉长窗口。
