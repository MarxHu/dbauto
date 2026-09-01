# Redis Lab Docker 节点规范

实验室用 **4 个 Docker 节点**（3× Redis 模拟 VM + 1× 注入机），固定在自定义网段 `10.10.26.0/24`。

| 容器名 | 角色 | IP | 端口 |
|---|---|---|---|
| `redis-n1` | Redis 节点（模拟 VM） | `10.10.26.144` | `6379` / bus `16379` |
| `redis-n2` | Redis 节点（模拟 VM） | `10.10.26.145` | `6379` / bus `16379` |
| `redis-n3` | Redis 节点（模拟 VM） | `10.10.26.146` | `6379` / bus `16379` |
| `docker-node` | 注入机 | `10.10.26.10` | — |

---

## 1. Redis 节点（redis-n1 / n2 / n3）必装工具

| 工具 | 用途 |
|---|---|
| `stress-ng` | CPU / 内存故障（F02/F04/F06/F28） |
| `vmstat`（procps） | CPU post-check（F02） |
| `chmod`（coreutils） | 数据目录只读（F24/F29） |
| `dd`（coreutils） | 磁盘 IO（F26） |
| `iptables` | Bus 阻断 / 分区（F20/F30） |
| `tc`（iproute2） | 丢包（F22） |
| `bash` | `docker exec … bash -lc` |
| `redis-server` | 二进制 Redis（集群） |

容器能力：`NET_ADMIN`（或 privileged），以便 iptables/tc。

**内存配额**：每 Redis 容器 **`mem_limit: 1536m`**（与 `--vm-bytes 85%` 配套；F04 验收 cgroup ≤15% 可用或 ≥85% 已用）。

数据目录：`/var/lib/redis/6379`（与 `CONFIG GET dir` 一致）。

---

## 2. 注入机（docker-node）必装工具

| 工具 | 用途 |
|---|---|
| `redis-cli` | Redis 级注入 / PING |
| `flock`（util-linux） | 注入互斥锁 |
| `bash` ≥ 4 | 跑注入脚本 |
| `docker` CLI | `docker exec` 进 redis-n\*（挂载宿主机 docker.sock） |

脚本与 `config.env` 放在注入机；**只在 docker-node（或挂载了同一套脚本的宿主机）跑 preflight / inject**。

---

## 3. 一键重建

在 **Docker 宿主机**（本虚拟机）执行：

```bash
cd redis_fault_injection/lab
./recreate.sh
```

会删除旧的 `redis-n1/n2/n3`、`docker-node`，按本规范重建并初始化 3 Master 集群。
