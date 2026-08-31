# Redis 所属 Docker 节点规范

> 适用范围：Redis Cluster 部署 / 自动化测试 / 故障注入  
> 节点每次由镜像重新生成，**所有依赖必须固化在镜像中**，禁止依赖现场临时安装。  
> 版本基线：Redis 7.2.x（二进制源码编译，默认 jemalloc）

---

## 1. 节点角色

| 角色 | 用途 | 典型数量 |
|------|------|----------|
| **Redis 数据节点** | 运行 `redis-server`（Cluster shard） | 3（三主零从测试拓扑） |
| **注入机节点** | 压测、故障注入、集群探测（不跑业务数据） | ≥1 |

两类节点可使用不同镜像，也可基于同一基础镜像分层安装；**禁止**把注入工具只装在数据节点却期望注入机可用。

---

## 2. Redis 数据节点规范

### 2.1 角色定义

- 承载 Redis Cluster 进程（端口默认 `6379` + 总线 `16379`）
- 支持 SOPS 部署脚本：预检 → sysctl → 编译安装 → 配置 → 启动 → 建集群 → 验收
- 支持自动化测试中的资源压测与网络故障模拟

### 2.2 必须预装的系统工具

| 工具 | 用途 | 验收命令 |
|------|------|----------|
| `stress-ng` | CPU/内存/IO 压测 | `command -v stress-ng` |
| `vmstat` | 内存/进程运行态观测 | `command -v vmstat` |
| `chmod` | 权限调整（coreutils） | `command -v chmod` |
| `dd` | 磁盘 IO / 填充类故障场景 | `command -v dd` |
| `iptables` | 丢包/拒绝/端口阻断 | `command -v iptables` |
| `tc` | 延迟、限速、网络抖动（iproute2） | `command -v tc` |

> `chmod` / `dd` 通常随 `coreutils` 提供；镜像中仍需显式验收，避免精简镜像裁掉。

### 2.3 编译安装 Redis（jemalloc）所需依赖

每次节点重建后需在节点内源码编译 Redis，**默认使用自带 jemalloc**（`deps/jemalloc`），不依赖系统 `jemalloc-devel` 作为主路径，但编译链路必须完整。

| 类别 | 包/命令 | 说明 |
|------|---------|------|
| 编译器 | `gcc`、`g++`、`make` | 编译 Redis / jemalloc |
| 脚本 | `bash`、`curl`、`tar`、`sha256sum` | 拉包、解压、校验 |
| 构建辅助 | `tcl`（`tclsh`） | Redis 测试/部分构建脚本 |
| 进程与网络 | `ss` / `ip`、`pgrep`、`systemctl` | 预检、启停、端口检查 |
| 内核调优 | `sysctl` | `vm.overcommit_memory` 等 |

**镜像构建建议（RPM 系示例）：**

```bash
yum install -y gcc gcc-c++ make tcl curl tar which \
  procps-ng iproute iptables stress-ng \
  sysstat coreutils
# sysstat 提供 vmstat；iproute 提供 tc/ss
```

**编译约定（写入部署脚本，节点规范强制）：**

```bash
# 干净目录；先编 deps，再编主程序，避免 release.h / jemalloc 半残构建
make -C deps jemalloc hiredis linenoise lua
make -j"$(nproc)" BUILD_TLS=no
# 若并行偶发 release.h 缺失，降级：make BUILD_TLS=no
make PREFIX=/opt/redis/<version> install
```

- **分配器**：默认 **jemalloc**（官方默认，测试更贴近生产）
- **禁止**默认使用 `MALLOC=libc`，除非规范另行批准
- 构建失败（如 `jemalloc.h` / `release.h` / `je_*` 隐式声明）视为**镜像或构建脚本不合格**，不得跳过进入建集群阶段

### 2.4 运行时与内核要求

| 项 | 要求 |
|----|------|
| 权限 | 允许 root 作业账户执行部署脚本 |
| 文件句柄 | `ulimit -n` ≥ `65535`（可在容器/ systemd 中固化） |
| 内核参数 | 支持设置 `vm.overcommit_memory=1`；THP 可关则关 |
| 端口 | `6379`、`16379` 未被占用；节点间互通 |
| 持久化目录 | 可写，如 `/var/lib/redis`、`/var/log/redis`、`/opt/redis` |

### 2.5 数据节点验收清单（镜像发布门禁）

```bash
set -euo pipefail
for c in stress-ng vmstat chmod dd iptables tc \
         gcc make tclsh curl tar sha256sum ss pgrep systemctl; do
  command -v "$c" >/dev/null || { echo "MISSING $c"; exit 1; }
done
# bash 版本建议 ≥ 4（与注入机对齐，避免脚本不兼容）
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo "bash < 4"; exit 1; }
echo "redis-data-node image OK"
```

---

## 3. 注入机 Docker 节点规范

### 3.1 角色定义

- 不部署业务 Redis 数据目录（可无本机 `redis-server`）
- 负责：集群探测、故障注入编排、并发锁、压测触发
- 通过网络访问 Redis 数据节点（`6379`/`16379`）

### 3.2 必须预装的工具

| 工具 | 用途 | 验收命令 |
|------|------|----------|
| `redis-cli` | 集群探测、读写验收、故障前后对比 | `command -v redis-cli` |
| `flock` | 注入任务互斥，避免并发踩踏 | `command -v flock` |
| `bash` ≥ 4 | 注入脚本语法（关联数组等） | `[[ ${BASH_VERSINFO[0]} -ge 4 ]]` |

**推荐一并具备（非强制，利于排障）：**

- `curl`、`timeout`、`nc` / `ss`
- 与数据节点一致的 `iptables`、`tc`、`stress-ng`（若注入动作下发到本机网络命名空间）

### 3.3 redis-cli 版本

- 建议与集群大版本一致（如 7.2.x），至少支持：
  - `CLUSTER INFO` / `CLUSTER NODES`
  - `-c` 集群模式
  - `REDISCLI_AUTH` / `-a` 认证

安装示例：

```bash
# 可从与数据节点相同的 PREFIX 拷贝 redis-cli，或独立安装客户端包
install -m 0755 /path/to/redis-cli /usr/local/bin/redis-cli
```

### 3.4 注入机验收清单（镜像发布门禁）

```bash
set -euo pipefail
command -v redis-cli >/dev/null || { echo "MISSING redis-cli"; exit 1; }
command -v flock >/dev/null || { echo "MISSING flock"; exit 1; }
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || { echo "bash < 4"; exit 1; }
redis-cli --version
echo "redis-injector-node image OK"
```

---

## 4. 融合基线（一张表）

| 能力 | Redis 数据节点 | 注入机节点 |
|------|----------------|------------|
| `stress-ng` | **必须** | 推荐 |
| `vmstat` | **必须** | 推荐 |
| `chmod` / `dd` | **必须** | 推荐 |
| `iptables` / `tc` | **必须** | 推荐（本机注入时必须） |
| `gcc` / `make` / jemalloc 编译链 | **必须** | 不要求 |
| `redis-server` | 部署后必须存在 | 不要求 |
| `redis-cli` | 部署后必须存在（随 PREFIX） | **镜像预装必须** |
| `flock` | 推荐 | **必须** |
| `bash` ≥ 4 | **必须** | **必须** |

---

## 5. 镜像构建与发布要求

1. **不可变**：节点每次重建，禁止「首次任务里 yum install」作为依赖来源（SOPS 预检只做检查，不现场补包，与 DM8 模板策略一致时可对齐）。
2. **分层建议**：
   - `redis-base`：编译链 + 通用工具（stress-ng/vmstat/iptables/tc/…）
   - `redis-data`：基于 base，可含空 `PREFIX` 目录约定
   - `redis-injector`：基于精简运行镜像 + `redis-cli` + `flock` + bash≥4
3. **门禁**：第 2.5 / 3.4 节脚本必须在 CI 构建末尾执行，失败不得推送镜像。
4. **与 SOPS 对齐**：部署 YAML「环境预检」应校验本节工具；「下载编译安装」应实现干净构建 + 先 `deps` 后主程序。

---

## 6. 已知不合格表现（对照）

| 现象 | 判定 |
|------|------|
| `jemalloc/jemalloc.h: No such file` | 数据节点编译链/干净构建不合格 |
| `release.h: No such file` / `je_*` 隐式声明 | 半残构建或并行依赖未满足，镜像或脚本需修 |
| 缺 `stress-ng` / `tc` / `iptables` | 数据节点镜像不合格 |
| 注入机无 `redis-cli` 或 `bash` &lt; 4 | 注入机镜像不合格 |

---

## 7. 变更记录

| 日期 | 说明 |
|------|------|
| 2026-08-31 | 首版：融合数据节点压测/网络工具、jemalloc 编译要求、注入机 redis-cli/flock/bash≥4 |
