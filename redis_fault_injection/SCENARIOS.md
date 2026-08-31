# Redis Cluster 故障注入场景总表

> **验收范围**：仅验收**故障注入行为**（现象、post-check、持续、恢复）。  
> **排障链路**（SOPS/清洗/K3）独立建设，不在本文范围。  
> **运行模式**：注入 Bot **单独跑**；主机类故障 **SSH 到 VM**（`--target-host`）；Redis 类 Bot 直连集群。  
> **环境前提**：见 [`PREREQUISITES.md`](PREREQUISITES.md)，跑前 `./scripts/preflight.sh`（三台 SSH + Redis 全 PASS）。  
> **F28**：仅 preflight 写入 `.state/ssh_all_nodes.ok` 后可用。  
> **持续时间**：默认 `--duration 600`，到期自动恢复。  
> **互斥**：同一时刻只允许一个注入 action（`flock` 锁）。

## 脚本分类（6 + preflight）

| 脚本 | 职责 |
|---|---|
| `scripts/preflight.sh` | SSH/Redis/工具检查，门控 F28 |
| `scripts/inject_host.sh` | VM CPU/内存/重启/基线 |
| `scripts/inject_redis.sh` | Redis 进程、配置、流量、协议错误 |
| `scripts/inject_network.sh` | VM 上 Bus、丢包、Master 分区 |
| `scripts/inject_disk.sh` | 持久化失败、磁盘 IO |
| `scripts/inject_composite.sh` | 三个组合场景 |
| `scripts/inject_degrade.sh` | 采集不可达、工具缺失 |

```bash
cp config.env.example config.env
./scripts/preflight.sh
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600
```

Bot 解析：`grep INJECT_RESULT` → `scenario=... status=pass|fail`

---

## 一、主机资源 → `inject_host.sh`（需 `--target-host`）

| ID | 场景 | 命令 |
|---|---|---|
| F01 | 基线 | `./scripts/inject_host.sh --action baseline` |
| F02 | CPU 持续高压 | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600` |
| F04 | 内存压力 | `./scripts/inject_host.sh --action memory --target-host 10.10.26.144 --duration 600` |
| F06 | CPU 尖峰 | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 600` |
| F09 | 主机重启 | `./scripts/inject_host.sh --action reboot --target-host 10.10.26.144 --confirm YES` |
| F28 | 多节点 CPU | `./scripts/inject_host.sh --action multi-cpu --duration 600`（preflight 三门控） |

Post-check：F02 CPU≥80%；F04 MemAvail≤15%。

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
| F29c | 清理 MISCONF | `./scripts/inject_redis.sh --action historical-misconf-cleanup --node 10.10.26.146:6381` |

Post-check：F07 PING down；F19/F29 ERRORSTATS 递增。

---

## 三、网络 → `inject_network.sh`（VM 上 iptables/tc）

| ID | 场景 | 命令 |
|---|---|---|
| F20 | Bus 阻断 | `./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6381 --duration 600` |
| F22 | 丢包 | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.144 --duration 600 --loss 30 --net-dev eth0` |
| F30 | Master 分区 | `./scripts/inject_network.sh --action master-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 600` |

---

## 四、磁盘 → `inject_disk.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F24 | 持久化失败 | `./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6381 --duration 600` |
| F26 | 磁盘 IO | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 600` |

---

## 五、组合 → `inject_composite.sh`

| ID | 场景 | 命令 |
|---|---|---|
| C01 | 内存 + 历史 MISCONF | `./scripts/inject_composite.sh --action memory-plus-misconf --duration 600` |
| C02 | 写拒绝 + CPU | `./scripts/inject_composite.sh --action write-reject-plus-cpu --duration 600` |
| C03 | Master 停 + 远端内存 | `./scripts/inject_composite.sh --action master-stop-plus-memory --duration 600` |

---

## 六、降级 → `inject_degrade.sh`（Bot 本机）

| ID | 场景 | 命令 |
|---|---|---|
| D01 | 单节点不可达 | `./scripts/inject_degrade.sh --action job-unreachable --blocked-host 10.10.26.146 --blocked-port 6381 --duration 600` |
| D02 | 隐藏 iostat/pidstat | `./scripts/inject_degrade.sh --action hide-tools --duration 600` |

---

## 七、Bot 编排建议

```text
注入 Bot:
  1. preflight.sh（FAIL=0）
  2. inject_*.sh --duration 600 [--target-host VM]
  3. 检查 INJECT_RESULT status=pass
  4. 等待脚本退出（= 故障已自动恢复）

排障 Bot（独立）:
  在注入持续期间触发外部 SOPS

注意:
  - 不要并行跑两个 inject action
  - F28 需 preflight 三门控 SSH
  - F29 跑完后 cleanup 再做基线
```

---

## 八、参数速查

```text
--action <name>          必填
--duration <seconds>     默认 600
--node <ip:port>
--target-host <VM IP>    主机/VM 网络/磁盘 IO 必填
--error-type             NOAUTH|WRONGPASS|MOVED|CROSSSLOT
```
