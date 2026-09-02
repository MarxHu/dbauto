# Kafka SOPS 模拟交付节点规范

实验室用 **3 个 Docker 节点** 模拟虚拟机，固定在自定义网段 `10.10.26.0/24`。
节点间 ICC 打开，FORWARD 放行，作为 SOPS `job_fast_execute_script` 的执行目标。

| 容器名 | 角色 | IP | 端口 |
|------|------|-----|------|
| `kafka-n1` | Kafka KRaft 节点（模拟 VM） | `10.10.26.144` | `9092` / controller `9093` |
| `kafka-n2` | Kafka KRaft 节点（模拟 VM） | `10.10.26.145` | `9092` / controller `9093` |
| `kafka-n3` | Kafka KRaft 节点（模拟 VM） | `10.10.26.146` | `9092` / controller `9093` |

## 1. 镜像预装（SOPS 预检只检查，不现场补包）

| 工具 | 用途 |
|------|------|
| `java` ≥ 17 | Kafka 运行时 |
| `curl` / `tar` / `sha512sum` | 下载与校验官方 tarball |
| `ss` / `pgrep` / `hostname` | 预检、端口与本机 IP |
| `systemctl` | YAML 启停 `kafka.service`（容器内为兼容 shim） |
| `ulimit -n` ≥ 65535 | 由 `docker --ulimit nofile` 固化 |

镜像 **不预装** Kafka 二进制。SOPS「下载解压安装」阶段必须产出 `/opt/kafka/3.8.1/bin/kafka-server-start.sh`。

## 2. 网络策略

- Docker bridge `kafka_lab`，子网 `10.10.26.0/24`，`enable_icc=true`
- 宿主机 `FORWARD` 策略 `ACCEPT`，保证容器互访
- 节点间必须互通 `9092/tcp` 与 `9093/tcp`

## 3. 交付方式

宿主机把 SOPS YAML 里的 `job_content` 按 `job_ip_list` 用 `docker exec` 下发到对应容器，参数来自 `job_script_param`，模拟蓝鲸作业「快速执行脚本」。

```bash
cd deployments/数据库部署脚本/lab/kafka38-kraft-3node
./recreate.sh
../../tools/sops_docker_exec.py --yaml ../../output/kafka38-kraft-3node.yaml
```
