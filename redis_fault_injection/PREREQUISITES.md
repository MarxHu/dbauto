# 故障注入环境前提（Preflight Checklist）

> **节点规范**：见 [`lab/NODE_SPEC.md`](lab/NODE_SPEC.md)。  
> **重建实验室**：`cd lab && ./recreate.sh`（含 `mem_limit: 1536m`、FORWARD、sch_netem）。

## 4 节点约定

| 容器 | 角色 | IP | 必装 |
|---|---|---|---|
| `redis-n1` / `n2` / `n3` | Redis 模拟 VM | `10.10.26.144/145/146` | `stress-ng` `vmstat` `chmod` `dd` `iptables` `tc` |
| `docker-node` | 注入机 | `10.10.26.10` | `redis-cli` `flock` `bash`≥4 + `docker` CLI |

只在 **docker-node** 跑 `./scripts/preflight.sh` 和 `inject_*.sh`。

---

## 验收 / 注入优化要点（2026-09）

| 场景 | 环境 | 脚本 |
|---|---|---|
| **F04 memory** | 容器 `mem_limit=1536m` | cgroup 可用≤15% **或** 已用≥85%；abort 必出 `INJECT_RESULT` |
| **F22 packet-loss** | 宿主机 `modprobe sch_netem` | 单层 `tc qdisc replace … root netem`（不用 HTB） |
| **F24 persistence** | — | chmod 目录+文件 + BGSAVE，验 MISCONF 递增 |
| **F26 io-stress** | 数据盘非 tmpfs | 默认 `IO_DIR=<redis dir>/fault_io` |
| **F07 process-stop** | — | 注入前 `docker update --restart=no`，PING 连续 3s 不可达 |

---

## 快速开始

```bash
cd redis_fault_injection/lab
./recreate.sh
docker exec -it docker-node bash
cd /workspace/redis_fault_injection
./scripts/preflight.sh
```

密码见 `lab/redis.conf`（实验室 `Redis@1314`），写入 gitignored `config.env`。
