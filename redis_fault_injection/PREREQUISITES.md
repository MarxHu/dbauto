# 故障注入环境前提（Preflight Checklist）

> **节点规范**：见 [`lab/NODE_SPEC.md`](lab/NODE_SPEC.md)。  
> **重建实验室**：在 Docker 宿主机执行 `cd lab && ./recreate.sh`。

## 4 节点约定

| 容器 | 角色 | IP | 必装 |
|---|---|---|---|
| `redis-n1` / `n2` / `n3` | Redis 模拟 VM | `10.10.26.144/145/146` | `stress-ng` `vmstat` `chmod` `dd` `iptables` `tc` |
| `docker-node` | 注入机 | `10.10.26.10` | `redis-cli` `flock` `bash`≥4（及 `docker` CLI + sock） |

只在 **docker-node**（或同等注入机）跑 `./scripts/preflight.sh`。

---

## 快速开始

```bash
cd redis_fault_injection/lab
./recreate.sh          # 删旧节点 → 按规范重建 → 建集群 → preflight
# 然后在 docker-node 内：
docker exec -it docker-node bash
cd /workspace/redis_fault_injection
./scripts/preflight.sh
```

密码默认实验室值见 `lab/redis.conf`（`Redis@1314`）；写入 gitignored `config.env`，勿提交。
