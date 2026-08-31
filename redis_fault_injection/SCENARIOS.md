# Redis Cluster 故障注入场景总表

> **验收**：仅注入行为（post-check / 持续 / 恢复）。排障链路不在本文。  
> **模型**：Bot 在 **docker-node**；Redis 在 Docker 容器（模拟 VM，容器内二进制）。  
> **主机故障**：`docker exec`（`--target-host` IP 或 `--target-container` 名）。  
> **配置**：`INJECT_BACKEND=docker`，`REDIS_CONTAINER_MAP`，`REDIS_DATA_DIR=auto`。  
> **门控**：`./scripts/preflight.sh` → `.state/docker_all_nodes.ok` 后 F28/F30 可用。  
> **默认 duration**：600s；互斥 flock。

```bash
cp config.env.example config.env   # 填密码 + REDIS_CONTAINER_MAP
./scripts/preflight.sh
./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600
```

Bot 解析：`grep INJECT_RESULT` → `status=pass|fail`

---

## 一、主机资源 → `inject_host.sh`（docker exec）

| ID | 场景 | 命令 |
|---|---|---|
| F01 | 基线 | `./scripts/inject_host.sh --action baseline` |
| F02 | CPU | `./scripts/inject_host.sh --action cpu --target-host 10.10.26.144 --duration 600` |
| F04 | 内存 | `./scripts/inject_host.sh --action memory --target-host 10.10.26.144 --duration 600` |
| F06 | CPU 尖峰 | `./scripts/inject_host.sh --action cpu-spike --target-host 10.10.26.144 --duration 600` |
| F09 | 重启 | `./scripts/inject_host.sh --action reboot --target-container <name> --confirm YES`（= docker restart） |
| F28 | 多节点 CPU | `./scripts/inject_host.sh --action multi-cpu --duration 600` |

---

## 二、Redis → `inject_redis.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F07 | 进程停止 | `./scripts/inject_redis.sh --action process-stop --node 10.10.26.144:6379 --duration 600` |
| F10 | maxmemory | `./scripts/inject_redis.sh --action maxmemory --node ... --duration 600 --maxmemory 64mb` |
| F12 | maxclients | `./scripts/inject_redis.sh --action maxclients --node ... --duration 600` |
| F14 | 慢命令 | `./scripts/inject_redis.sh --action slow-command --node ... --duration 600` |
| F15 | 热 Key | `./scripts/inject_redis.sh --action hot-key --node ... --duration 600` |
| F16 | 大 Key | `./scripts/inject_redis.sh --action big-key --node ... --duration 600` |
| F17 | 冷缓存 | `./scripts/inject_redis.sh --action cache-expire --node ... --expire-key mykey --duration 600` |
| F18 | 穿透 | `./scripts/inject_redis.sh --action cache-penetrate --node ... --duration 600` |
| F19 | 协议脉冲 | `./scripts/inject_redis.sh --action error-pulse --node ... --error-type NOAUTH` |
| F29 | 历史 MISCONF | `./scripts/inject_redis.sh --action historical-misconf --node 10.10.26.146:6379` |
| F29c | 清理 | `./scripts/inject_redis.sh --action historical-misconf-cleanup --node 10.10.26.146:6379` |

---

## 三、网络 → `inject_network.sh`（容器内 iptables/tc，需 NET_ADMIN）

| ID | 场景 | 命令 |
|---|---|---|
| F20 | Bus 阻断 | `./scripts/inject_network.sh --action bus-block --node 10.10.26.144:6379 --duration 600` |
| F22 | 丢包 | `./scripts/inject_network.sh --action packet-loss --target-host 10.10.26.144 --duration 600 --loss 30` |
| F30 | Master 分区 | `./scripts/inject_network.sh --action master-partition --node-a 10.10.26.144 --node-b 10.10.26.145 --duration 600` |

---

## 四、磁盘 → `inject_disk.sh`

| ID | 场景 | 命令 |
|---|---|---|
| F24 | 持久化失败 | `./scripts/inject_disk.sh --action persistence-fail --node 10.10.26.146:6379 --duration 600` |
| F26 | 磁盘 IO | `./scripts/inject_disk.sh --action io-stress --target-host 10.10.26.144 --duration 600` |

---

## 五、组合 / 降级

见 `README.md`：C01–C03、D01–D02。D01 在 **Bot 本机** iptables 阻断到 Redis；D02 隐藏 Bot 本机工具。
