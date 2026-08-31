# 故障注入环境前提（Preflight Checklist）

> **范围**：只验收故障注入行为。排障 Bot / SOPS 独立建设。  
> **实验室模型（默认）**：注入 Bot 跑在 **docker-node**；Redis 以二进制跑在 **Docker 容器**（用容器模拟 VM）。  
> 「主机故障」= `docker exec` 进容器注入（CPU/内存/磁盘/iptables），不是 SSH 到 144/145/146。

---

## 1. 拓扑

```text
docker-node (注入 Bot)
  ├── redis-cli → 10.10.26.144:6379 / 145 / 146
  └── docker exec → container(redis-144) / (redis-145) / (redis-146)
         └── 容器内二进制 redis-server + stress-ng / iptables / ...
```

| 项 | 要求 |
|---|---|
| Bot 机器 | docker-node，能 `docker` + `redis-cli` |
| 容器 | 三台模拟 VM 的 Redis 容器正在运行 |
| 映射 | `REDIS_CONTAINER_MAP` 或容器网络 IP = `REDIS_NODES` 的 IP |
| 权限 | Bot 用户可 `docker exec`；网络故障需容器 `NET_ADMIN`/`privileged` |

---

## 2. 必装工具

### Bot（docker-node）

| 工具 | 用途 |
|---|---|
| `docker` | 主机级故障入口 |
| `redis-cli` | Redis 级故障 / PING |
| `flock` / `bash`≥4 | 锁与脚本 |

### 每个 Redis 容器内

| 工具 | 场景 |
|---|---|
| `stress-ng` | F02/F04/F06/F28 |
| `vmstat` | F02 post-check |
| `iptables` | F20/F30（需 NET_ADMIN） |
| `tc` | F22 |
| `dd` | F26 |
| `redis-cli` / `redis-server` | 进程停/启、MISCONF |

---

## 3. config.env 关键项

```bash
export INJECT_BACKEND="docker"
export REDIS_NODES="10.10.26.144:6379 10.10.26.145:6379 10.10.26.146:6379"
export REDIS_PASSWORD="..."
export REDIS_DATA_DIR="auto"   # 自动用 CONFIG GET dir（如 /var/lib/redis/6379）

# 推荐显式映射（IP → 容器名）
export REDIS_CONTAINER_MAP="10.10.26.144:<name1> 10.10.26.145:<name2> 10.10.26.146:<name3>"
# 或按 REDIS_NODES 顺序：
# export REDIS_CONTAINERS="name1 name2 name3"
```

查容器名与 IP：

```bash
docker ps --format 'table {{.Names}}\t{{.ID}}'
docker inspect -f '{{.Name}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(docker ps -q)
```

---

## 4. Preflight 门控

```bash
./scripts/preflight.sh
```

必须 **FAIL=0**。通过后写入 `.state/docker_all_nodes.ok`，F28 / F30 才启用。

| 检查 | 失败含义 |
|---|---|
| 无 container for IP | 填 `REDIS_CONTAINER_MAP` |
| stress-ng missing | 在镜像/容器内安装 |
| iptables/tc WARN | 网络场景不可用，直至装好并给 NET_ADMIN |

---

## 5. 场景与注入路径

| 类型 | 路径 |
|---|---|
| Redis 级（maxmemory、error-pulse…） | Bot `redis-cli` → 节点 |
| 主机级（CPU/内存/重启） | `docker exec` → `stress-ng` / `docker restart` |
| 进程停止 | `docker exec` → `SHUTDOWN`，到期再起 redis |
| 网络 | `docker exec` → `iptables`/`tc` |
| 磁盘 | `docker exec` → `chmod`/`dd` |

F09 reboot = **`docker restart <container>`**（模拟 VM 重启）。

---

## 6. Post-check

| 场景 | 条件 |
|---|---|
| F02 | 容器内 vmstat CPU avg ≥ 80% |
| F04 | 可用内存 ≤ 15%（优先 cgroup，否则 /proc/meminfo） |
| F07 | PING 失败 |
| F19/F29 | ERRORSTATS 递增 |

输出：`INJECT_RESULT scenario=... status=pass|fail`

---

## 7. 备选后端

| `INJECT_BACKEND` | 用途 |
|---|---|
| `docker`（默认） | 本实验室 |
| `ssh` | 真 VM + SSH |
| `local` | Bot 与 Redis 同机 |
