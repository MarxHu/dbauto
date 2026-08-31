# 故障注入环境前提（Preflight Checklist）

> **范围说明**：本目录只验收**故障注入行为**是否按预期发生。  
> Redis Cluster AI 排障链路（SOPS/清洗/K3）**独立建设、独立验收**，不在本文范围内。

> **部署模式**：**注入 Bot 单独运行**，不在 Docker 节点/模拟 VM 内。  
> Redis 以二进制部署在三台 VM（如 `10.10.26.144–146:6381`）。  
> 主机/网络/磁盘类故障通过 **SSH 到 VM** 执行；Redis 类故障 Bot 用 `redis-cli` 直连集群。  
> 一次只跑一个注入 action，避免场景互相干扰。

---

## 1. 机器与权限

| 项 | 要求 | 验证命令 |
|---|---|---|
| 注入 Bot OS | Linux，与实验室同网 | `uname -a` |
| Bot → VM SSH | **三台 VM** 免密或密钥，`BatchMode=yes` 可连 | `preflight.sh` |
| VM 权限 | root 或 sudo（iptables/tc/chmod/stress-ng） | SSH 后 `sudo -n true` |
| Bot 工具 | `redis-cli`、`ssh`、`flock`、`bash` | `preflight.sh` |
| 并发 | 同一时刻仅一个注入脚本（内置 flock 锁） | 见 `preflight.sh` |

---

## 2. 必装工具

### 2.1 注入 Bot 上

| 工具 | 用途 | 验证 |
|---|---|---|
| `redis-cli` | 连集群 Redis | `redis-cli --version` |
| `ssh` | 远程执行 VM 命令 | `ssh -V` |
| `flock` | 注入互斥锁 | `flock --version` |
| `bash` ≥ 4 | 脚本运行 | `bash --version` |

### 2.2 各 VM 上（preflight 逐台检查）

| 工具 | 用途 | 验证 |
|---|---|---|
| `stress-ng` | CPU/内存压力 F02/F04/F28 | SSH: `stress-ng --version` |
| `vmstat` | F02 post-check | SSH: `vmstat 1 1` |
| `iptables` | 网络阻断 F20/F30/D01 | SSH: `iptables -L -n` |
| `tc` + `iproute2` | 丢包 F22 | SSH: `tc qdisc help` |
| `dd` | io-stress F26 | SSH: `dd --version` |
| `systemctl` / `redis-server` | process-stop 恢复 F07 | 按实际安装 |

---

## 3. Redis 集群

| 项 | 要求 | 说明 |
|---|---|---|
| 拓扑 | 3 Master，端口如 `6381` | 与 `config.env` 中 `REDIS_NODES` 一致 |
| 连通 | Bot 可 PING 全部节点 | `./scripts/preflight.sh` |
| 密码 | 写入 `config.env` 的 **`REDIS_PASSWORD`**（gitignore） | 脚本用 `REDISCLI_AUTH` |
| `DEBUG SLEEP` | **未**禁用 | 慢命令 F14 |
| 数据目录 | 默认 **`/var/lib/redis`** | preflight 用 `CONFIG GET dir` 校验 |
| `stop-writes-on-bgsave-error` | 持久化/MISCONF 场景可写 CONFIG | F24/F29 |

---

## 4. SSH 与 F28 门控

| 项 | 要求 |
|---|---|
| `SSH_USER` | 默认 `root`，写入 `config.env` |
| 三台可达 | preflight 全部 SSH PASS → 创建 `.state/ssh_all_nodes.ok` |
| F28 multi-cpu | **仅**当 `ssh_all_nodes.ok` 存在时可用 |
| F30 master-partition | 需 SSH 可达 `--node-a` 与 `--node-b` |

---

## 5. 网络与命名

| 项 | 要求 |
|---|---|
| 网卡名 | VM 上 `NET_DEV`（默认 `eth0`，按 `ip link`） |
| Cluster Bus | 默认 client_port+10000，或 `CLUSTER_BUS_PORT=16379` |
| VM 防火墙 | 允许 SSH 会话临时添加 iptables/tc |

---

## 6. 按场景额外前提

| 场景 | 额外条件 |
|---|---|
| F02/F04/F06/F09/F26 | 必须 `--target-host <VM IP>` |
| F19 NOAUTH | Redis 已设密码；脉冲用无密码客户端 |
| F19 WRONGPASS | 已启用 ACL；配置 `REDIS_ACL_USER` |
| F29 historical-misconf | VM 上可写 `REDIS_DATA_DIR`；测完 cleanup |
| F09 reboot | `--confirm YES`；**无自动恢复** |
| D01 job-unreachable | Bot 本机 iptables 阻断到 Redis 端口 |
| D02 hide-tools | Bot 本机存在 `iostat`/`pidstat` |

---

## 7. 推荐准备流程

```bash
cp config.env.example config.env
# 必填：REDIS_PASSWORD
# 配置 Bot → 三台 VM 的 SSH 免密

./scripts/preflight.sh
# FAIL=0 且出现「all 3 VM nodes SSH reachable」后再注入
```

---

## 8. Post-check 验收

| 场景 | 条件 |
|---|---|
| F02 cpu | VM vmstat CPU avg ≥ 80% |
| F04 memory | MemAvailable ≤ 15% |
| F07 process-stop | PING 无响应 |
| F19 error-pulse | ERRORSTATS 递增 |
| F29 historical-misconf | MISCONF 递增 |

脚本输出 `INJECT_RESULT scenario=... status=pass|fail` 供 Bot 解析。

---

## 9. 注入 Bot vs 排障 Bot

| Bot | 职责 | 脚本范围 |
|---|---|---|
| **注入 Bot** | 启动故障 → post-check → 等待 `--duration` → 自动恢复 | `inject_*.sh` |
| **排障 Bot** | 独立触发 SOPS/诊断（不在本目录） | 外部流程 |

1. 注入 Bot **持锁期间**不要启动第二个注入 action  
2. 排障 Bot **不应**修改 iptables/maxmemory 等注入态  
3. 组合场景（C01/C02/C03）由注入 Bot **串行**调用子 action  

---

## 10. 默认持续时间

持续型故障默认 **`--duration 600`（10 分钟）**：

```bash
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600
```

脉冲型（error-pulse）在 duration 窗口内按 5s×18 有界发送。
