# Elasticsearch 7.x 三节点故障排查流程设计

> 状态：设计稿（审查锁定，可直接指导脚本落地）  
> 日期：2026-09-15  
> 对齐：仓库内 MySQL 5 分钟排障 Bot（五路并行采集 → 覆盖判定 → 清洗 → AI）  
> 拓扑基线：Elasticsearch **7.x**（实验室钉 **7.17.x**），三节点全角色（master-eligible + data + ingest），索引默认 `number_of_replicas=1`，HTTP `9200` + transport `9300`  
> 实验室参考 IP：`10.10.26.144` / `.145` / `.146`（与 Kafka/Redis 实验室同段，实现时从 `config.env` 读，禁止写死）

本文是 **5 分钟排障 Bot** 的设计，不是人工 runbook，也 **不是故障注入方案**。不创建 `elasticsearch_fault_injection/`，不在采集/清洗路径里执行 kill、iptables、填盘、reroute。

目标：采集 90s 内完成，清洗 50s，AI 50s，输出可展示的 Markdown 与（若成功）诊断结论。

---

## 0. 已锁定决策（审查结论）

| # | 决策 | 锁定值 |
|---|---|---|
| D1 | 范围 | 只做故障排查，不做注入、不自动修集群 |
| D2 | 版本 | 实验室 7.17.x；命令用 7.0–7.17 交集 API。不用 8.x 默认安全/data stream 当 P0；不用 6.x `discovery.zen.minimum_master_nodes` 当法定人数依据 |
| D3 | 拓扑 | 三节点全角色，副本 1。专主、hot-warm、CCR、协调节点记 N/A |
| D4 | 时间盒 | 预检 10s + 五路并行 90s + 清洗 50s + AI 50s + 汇聚余量 20s |
| D5 | 五路 | M 指标 / S 运行状态 / C 配置 / L 日志 / H 主机网络。禁止拆成第六路 |
| D6 | 集群 API | health / settings / explain **只从多数派认同的 master 视图节点打一次**。**每台必须本地**打 `localhost:9200` 看自己眼里的 elected master |
| D7 | Master | 只信运行时。YAML / 部署清单的 node-1 不当真相 |
| D8 | `NO_MASTER` | **三台都采到，且都没有 elected master** 才出集群级 `NO_MASTER`。两台有主、一台没有或认另一个 → 分区/不一致，不是 `NO_MASTER`。有节点没采到 → 不下集群级 `NO_MASTER`，只出观察结果 + `EVIDENCE_GAP` |
| D9 | 无主时 | 不 `sleep` 等选举，不重启，不 `_cluster/reroute`，不改 voting。unassigned explain 标不可靠/跳过 |
| D10 | 交叉对比 | 清洗用规则算死 ALL/ONE 等组合信号，禁止丢给 AI 自己发现 |
| D11 | 认证 | `ES_USER` / `ES_PASS` 可空；空则裸打 9200，有则 `curl -u`。TLS / API key 不进 P0 |
| D12 | 汇聚 | 平台拼接 `###ES_TS_ARTIFACT`，或 `run_flow.sh` 拉取 `/tmp/es-troubleshoot/<run_id>/`。汇聚计入 20s 余量 |
| D13 | 场景 | 瘦 P0；CCR/ILM/snapshot/hot-warm/ingest/安全TLS/混大版本只记 N/A |
| D14 | AI | **最后一节点**。超时/HTTP/模型异常 → **该节点失败**。不把启发式写成作业成功 |
| D15 | 可视化 | 清洗节点先写出 Markdown：`summary.md` + `signals.txt`。人看清洗产物；AI 成功则另出诊断 Markdown |
| D16 | 本次交付 | 只入库本 design.md（及目录 README）。脚本 / SOPS YAML 另开任务 |

---

## 1. 目标与非目标

### 1.1 目标

一次作业跑完后，必须能回答：

1. 有没有 **稳定的 elected master**？（三台本地视图交叉对比，而不是只问第一台 9200）
2. 是 **掉了节点**，还是 **三台都在但副本分配被卡住**？
3. 写入被拒是 **集群块（flood / read_only_allow_delete）**、**线程池 reject**，还是 **单节点 heap/breaker**？
4. `9200` 通但 `9300` 不通是否在把节点从集群里孤立？
5. 缺哪些证据？**不要改集群**。

清洗输出固定 Markdown。AI 若成功，再输出：根因假设（带场景 ID）→ 关键证据 → 影响面 → 止损建议（纯文案）→ 验证步骤 → 证据缺口。

### 1.2 非目标（5 分钟内明确不做）

| 不做 | 原因 |
|---|---|
| 故障注入（杀进程、填盘、丢包） | 本任务只排查 |
| `_cluster/reroute`、开 `allocation.enable`、取消 read_only 块 | 只诊断，不变更 |
| `sleep` 等待选举 / 滚动重启 | 排查 Bot 不是运维编排 |
| 全量 `_cluster/state` 丢给模型 | 体积不可控，AI 50s 必爆 |
| 未 `filter_path` 的 `_nodes/stats` | 同上 |
| 整份 `elasticsearch.yml` / 整份 gc.log | 清洗 50s 与 AI 上下文都会爆 |
| 对每个 unassigned 分片跑 explain | 上限 N=5，其余记缺口 |
| snapshot / restore / reindex / forcemerge | 超出时间盒 |
| CCR、ILM、ingest pipeline 定性 | 当前拓扑与瘦 P0 不做 |
| TLS 握手、API key、PKI | 认证只做可选 basic |

这些标为 **N/A** 或 **`EVIDENCE_GAP`**。止损写在 Markdown 里给人看，脚本不执行。

---

## 2. 优化原则（相对 Kafka v1 / 朴素全量采集）

Kafka v2 YAML 采集超时 600–900s、清洗/AI 各 300s，墙钟远超 5 分钟。ES 流程 **禁止复用这套 timeout**。对齐 MySQL 设计的 O1–O9，映射如下。

| # | 优化 | 不优化时的后果 |
|---|---|---|
| O1 | **硬时间盒**：预检 10s + 采集 90s + 清洗 50s + AI 50s + 余量 20s | 作业跑 15 分钟才出结论 |
| O2 | **Master 只信运行时**，且 **每台本地视图**；禁止 YAML 静态「node-1 是主」 | 选举已换或分区时，explain 打到孤立节点，结论全反 |
| O3 | **每台节点本地并行**；集群级 health/settings/explain 只打一次 | 三台各拉一份 cluster 视图，90s 与清洗都爆 |
| O4 | **`_nodes/_local/stats` 必须 `filter_path`**，禁止无过滤 JSON | 单次响应就能吃掉 AI 上下文 |
| O5 | **7.0–7.17 交集 API**（`write` 线程池，不是 6.x 的 `index` 池；`discovery.seed_hosts` 与 7.0 残留 zen unicast 都读） | 7.0 实验室或 7.17 生产混用时空结果 |
| O6 | **`NO_MASTER` 必须三台交叉**，禁止「第一台 9200 没主 = 集群没主」 | 打到分区节点会误报全集群无主 |
| O7 | **清洗做交叉对比**，AI 只吃信号 | AI 1 分钟给散文，无法验收 |
| O8 | **配置解析关键项，日志 `tail+grep`** | 原文过大 |
| O9 | **采集失败 `exit 0` + `ignore_error`**，走降级清洗 | P1 时 ES 已挂，排障流程自己失败 |
| O10 | **AI 是最后节点，异常则该节点失败**；清洗 Markdown 必须已经可看 | 与 MySQL「启发式仍算出成功」不同，按审查锁定 |

---

## 3. 时间盒（验收红线）

墙钟取并行最大值，不是五路相加。

```text
0s        10s              100s             150s            200s       220s
|---------|----------------|----------------|---------------|----------|
 预检       五路并行采集        覆盖判定+清洗      AI             余量
 ≤10s      硬超时 90s         ≤50s            ≤50s          20s
```

| 阶段 | 墙钟上限 | 单命令 timeout | 失败策略 |
|---|---|---|---|
| 采集预检 | 10s | 3s | 记 `ES170`，继续 |
| M 指标 | 90s | 5–15s | `CMD_TIMEOUT` 信号，exit 0 |
| S 运行状态 | 90s | 5–15s | 同上；explain 单次 5s，最多 5 个 |
| C 配置 | 90s | 10s | 同上 |
| L 日志 | 90s | 15s | 只 tail 最近 8000 行 |
| H 主机网络 | 90s | ping 3 次 / iostat 1 3 | 同上 |
| 清洗 | 50s | **禁止调模型** | 必须写出 `summary.md` |
| AI | 50s | HTTP 45s | **失败则 AI 节点失败**（非 0 退出） |

**硬规则：**

- 采集脚本 `set -uo pipefail`，**禁止 `set -e`**，最终 **`exit 0`**。
- SOPS 采集节点全部 `ignore_error: true`。
- **AI 节点不要 `ignore_error`**（或等价：该步失败要体现在作业失败上）。
- `iostat 1 3` 不是 `1 30`；`ping -c 3` 不是 `-c 20`。
- 禁止 `GET /_cluster/state` 无 filter；禁止 `GET /_nodes/stats` 无 `filter_path`。
- 日志禁止 `cat` 整文件；配置禁止把整个 yml 塞进 AI prompt。
- 清洗输入是各节点 `.signals` + 截断摘要，不是 10MB 原文。
- 无主时 **禁止** 为了「等选举」而 sleep。

`job_script_timeout` 建议值（含 SSH 开销，仍远小于 Kafka）：

| 节点 | timeout |
|---|---|
| 预检 | 30s |
| 五路采集各路 | 120s |
| 清洗 / 降级清洗 | 60s |
| AI | 60s |

脚本内部仍按 90/50/50 自裁，作业超时只是外壳。

---

## 4. 流程

```text
Start
  ├─ 采集预检（curl、进程、9200、本地 master 视图）
  └─ ParallelGateway 五路并行（每节点本地）
        ├─ M  ES 指标
        ├─ S  运行状态（每台本地 master 视图；集群 explain 仅多数派节点）
        ├─ C  配置关键项
        ├─ L  过滤日志
        └─ H  主机 + 网络（含 9200/9300 分端口）
  → ConvergeGateway（20s 余量汇聚）
  → 覆盖判定 ExclusiveGateway
        ├─ 覆盖足够 → 数据清洗与交叉对比 → summary.md
        └─ 覆盖不足 → 降级清洗 → summary.md（标明缺口）
  → AI 诊断（成功 → 诊断 Markdown；失败 → 该节点失败）
  → End
```

清洗成功与 AI 失败可以同时成立：作业平台仍能展示清洗节点的 Markdown。

### 4.1 多节点汇聚

SOPS 按 IP 下发时节点无共享盘。清洗若只看见本机产物，交叉对比为零，`NO_MASTER` 规则也无法执行。

必须二选一（实验室与作业平台都要写进 YAML 注释）：

1. 作业平台把各 IP 的 `###ES_TS_ARTIFACT` 块拼到清洗节点 stdin
2. 诊断机 `run_flow.sh` 从各节点拉取 `/tmp/es-troubleshoot/<run_id>/` 再清洗

汇聚时间计入 20s 余量，不能另开 3 分钟。

---

## 5. Master 识别（运行时，每台本地）

每台机器采集开始时，对 **本机** `127.0.0.1:9200`（timeout 3s）取 elected master 视图。不要用部署参数 `host.role`。

首选（7.x 全系列可用）：

```text
GET /_cat/master?h=id,host,ip,node&format=json
```

辅助（同一 timeout 内，失败记 NA）：

```text
GET /_cat/nodes?h=id,name,ip,master,node.role&format=json
```

`master` 列值为 `*` 的是 **本集群视角下的 elected master**（若该 HTTP 端口连的是一个已加入的节点）。

| 本机结果 | 记录 |
|---|---|
| 3s 内返回一行 master | `local_master=<node>` `local_master_ip=<ip>` |
| 连接失败 / 空 / 明确无主（日志或 503 类 master_not_discovered） | `local_master=` 空 |
| 认证失败 | `ES032`，`local_master=NA`，不当「无主」 |

清洗阶段（必须三台产物到齐才下集群结论）：

| 条件 | 信号 | 含义 |
|---|---|---|
| 3/3 采到，且三台 `local_master` 都空 | `ES050` + `ES191 NO_MASTER` | **唯一**允许的集群级「没有稳定主节点」 |
| 2 台相同 master，1 台空或不同 | `ES051` + `ES199`（若 9200/9300 分叉则加强） | 分区 / 脑裂观感，**不是** `NO_MASTER` |
| 2 台相同 master，1 台产物缺失 | 有稳定主（观察），`ES172` + `EVIDENCE_GAP` | **不下** `NO_MASTER` |
| 仅 1 台或 0 台采到且其 `local_master` 空 | `NO_MASTER_OBSERVED` + `EVIDENCE_GAP` | **不下** 集群级 `ES050` |
| 三台都指向同一 master | 正常；后续 health/explain 走该 master 所在节点（若其 9200 可达） | |

**无主（ES050）时：** 跳过或降权 `allocation/explain` 与依赖 cluster state 的定性；H/L/M 本地 JVM/磁盘仍有效。Bot 不等待选举。

集群级 API（health、settings、最多 5 次 explain）的执行节点：

1. 若存在多数派 master 视图，选 **持有该视图且 9200 可达** 的节点打一次。
2. 否则（ES050 或无法形成多数派）**不打 explain**，health 可对各可达节点各打一次仅作对照，清洗标明「非权威」。

---

## 6. 五路采集规格

每路产物：

```text
/tmp/es-troubleshoot/<run_id>/
  metrics.<ip>.txt       metrics.<ip>.signals
  status.<ip>.txt        status.<ip>.signals
  config.<ip>.txt        config.<ip>.signals
  logs.<ip>.txt          logs.<ip>.signals
  hostnet.<ip>.txt       hostnet.<ip>.signals
  master.<ip>.json       # 本地 _cat/master 原始（截断）
```

信号格式：`ID severity note`（与 Kafka/MySQL 对齐，TAB 分隔）。

HTTP 封装：

```text
es_curl() {
  # ES_USER 空：无 -u；否则 curl -u "$ES_USER:$ES_PASS"
  # 一律 -sS --max-time <n> --connect-timeout 3
}
```

7.x 兼容：不传 `include_type_name`；不调用 8.x 才稳定的 `_security` / `_license` 当 P0。

### 6.1 预检（≤10s）

| 检查 | 失败信号 |
|---|---|
| `curl` 是否存在 | `ES171` |
| Java / elasticsearch 进程是否存在（`pgrep` 或 `systemctl is-active`） | `ES030` |
| `ss/netstat` 是否在听 `9200` | `ES031` |
| 本机 `GET /`（3s，可选 `-u`）是否 JSON | `ES032` |
| `timeout` / `iostat` 是否可用 | `ES171` low |

预检失败仍启动五路：进程没了，H/L 仍有证据。

### 6.2 M — ES 指标（P0，≤90s）

**集群数字（只在选定的一次集群查询节点写一份 `cluster.health.json`，其它节点记 `cluster_health=delegated`）：**

```text
GET /_cluster/health?filter_path=status,number_of_nodes,number_of_data_nodes,active_primary_shards,active_shards,relocating_shards,initializing_shards,unassigned_shards,delayed_unassigned_shards,number_of_pending_tasks,task_max_waiting_in_queue_millis,active_shards_percent_as_number,timed_out
```

| 字段 | 含义 | 信号 |
|---|---|---|
| `status` red/yellow/green | 有无主分片 / 副本 | 清洗组合，不单点定性 |
| `number_of_nodes` | 已加入集群的节点数 | 与期望 3 对比 → `ES052`/`ES053` |
| `unassigned_shards` | 未分配 | >0 必须在 S 用 explain 抽样，禁止只报 yellow |
| `delayed_unassigned_shards` | 重启宽限 | `ES055`，与「真红了」区分 |
| `relocating_shards` / `initializing_shards` | 搬迁/初始化 | 长时间不降 → `ES057` |
| `number_of_pending_tasks` / `task_max_waiting_in_queue_millis` | Master 任务排队 | 升高 → `ES056` |

**每台本地节点统计（必须 `filter_path`，timeout 8s）：**

```text
GET /_nodes/_local/stats?filter_path=nodes.*.name,nodes.*.jvm.mem.heap_used_percent,nodes.*.jvm.gc.collectors,nodes.*.thread_pool.write,nodes.*.thread_pool.search,nodes.*.breakers.parent,nodes.*.breakers.request,nodes.*.breakers.fielddata,nodes.*.fs.total,nodes.*.indices.indexing.index_total,nodes.*.indices.indexing.index_time_in_millis,nodes.*.indices.search.query_total,nodes.*.indices.search.query_time_in_millis,nodes.*.os.cpu
```

7.0 若无 `thread_pool.write`（不应发生：write 池自 6.4 起），回退读 `thread_pool.index` 并在信号里注明 `pool=index_legacy`。

| 指标 | 含义 | 信号 |
|---|---|---|
| `heap_used_percent` | JVM 堆占用 | ≥85 `ES034` warn；≥95 high |
| GC collectors `collection_time_in_millis` | 需两次采样间隔 ≥1s 算增量，禁止只看绝对值 | 窗口内占用过高 → `ES035` |
| `thread_pool.write.rejected` | 写入拒绝累计 | 窗口增量 >0 → `ES036` |
| `thread_pool.search.rejected` | 查询拒绝 | 增量 >0 → `ES037` |
| `breakers.*.tripped` / `overhead` | 熔断 | tripped 增或 parent 接近 95% → `ES038` |
| `fs.total` available vs total | 数据盘水位 | 对照 C 的 watermark；flood → `ES070` |
| indexing / search time | 耗时升、速率降 | 给清洗用，不单独定 P1 |

阈值默认（可参数化，清洗用同一套）：

| 项 | warning | high |
|---|---|---|
| heap_used_percent | ≥85 | ≥95 |
| write/search rejected 增量 | >0 | 持续增加 |
| parent breaker used % | ≥85 | ≥95 或 tripped |
| pending_tasks | ≥1 | ≥10 或 wait_ms ≥5000 |
| 磁盘可用（相对 flood-stage 默认 95%） | 进入 high watermark | flood-stage / 只读块 |

### 6.3 S — 运行状态（P0）

每台都做：

| 采集 | 截断规则 | 信号 |
|---|---|---|
| 本地 `_cat/master` | JSON 一行 | 见第 5 节 |
| `_cat/nodes` 本地视角 | 只留 name,ip,master,node.role | 角色应含 `m` 与 `d`（全角色） |

仅 **集群查询节点**（多数派 master 视图）做：

| 采集 | 截断规则 | 信号 |
|---|---|---|
| `_cluster/health` 已在 M | 共享文件，S 不重复打 | — |
| `_cat/shards?h=index,shard,prirep,state,unassigned.reason,node` | **只保留** UNASSIGNED / RELOCATING / INITIALIZING，上限 200 行 | 无主则跳过 |
| `GET /_cluster/allocation/explain?include_yes_decisions=false` | 对未分配抽样最多 **5** 个（优先主分片），每次 timeout 5s | 见下表 |
| 集群块 | `_cluster/state/blocks` **禁止**；改用 `_cluster/health` + 抽样 `GET /_alias` 不需要；用 `GET /_all/_settings?filter_path=**.index.blocks` 上限 32KB，或从日志/settings 推断 `read_only_allow_delete` | `ES071` |

无主（将在清洗确认 ES050）时：采集节点若本地已无 master，**不要** 强打 explain；写 `EXPLAIN_SKIPPED=no_local_master`。

explain 首因映射（清洗认这些字符串，大小写不敏感）：

| explain / unassigned.reason | ID |
|---|---|
| `NODE_LEFT` / `NODE_RESTART` | `ES052` 方向 |
| `DECIDERS_NO` 且含 disk / watermark | `ES061` |
| `DECIDERS_NO` 且含 filter / awareness / enable | `ES062` / `ES058` |
| `ALLOCATION_FAILED` | `ES063` |
| `CLUSTER_RECOVERED` / `INDEX_CREATED` 且 delayed | `ES055` |

### 6.4 C — 配置（P0，解析不 dump）

本地文件 + 一次集群 settings（仍只在集群查询节点）。

**本地解析**（存在哪个读哪个，不把全文进 AI）：

| 文件 | 键 |
|---|---|
| `elasticsearch.yml` | `cluster.name` `node.name` `network.host` `http.port` `transport.port` `path.data` `discovery.seed_hosts` `cluster.initial_master_nodes` `discovery.zen.ping.unicast.hosts`（7.0 残留）`discovery.zen.minimum_master_nodes`（残留则 `ES110` P3） |
| `jvm.options` | `-Xms` `-Xmx`；两者不等 → `ES112` |

**集群（`include_defaults=false`，只要覆盖项）：**

```text
GET /_cluster/settings?include_defaults=false&flat_settings=true&filter_path=transient.cluster.routing.allocation.*,persistent.cluster.routing.allocation.*,transient.cluster.max_shards_per_node,persistent.cluster.max_shards_per_node,transient.cluster.blocks.*,persistent.cluster.blocks.*
```

| 变量 | 检查 |
|---|---|
| `cluster.routing.allocation.enable` | 非 `all`（含空以外的 primaries/none）→ `ES058` |
| `cluster.routing.allocation.disk.watermark.*` | 与节点 `fs` 对照 → `ES072`/`ES070` |
| `cluster.max_shards_per_node` | 接近上限且有 unassigned → `ES059` |
| 三台 `cluster.name` | 不一致 → `ES060`（节点可能根本不在同一集群） |
| `discovery.seed_hosts` / zen unicast | 少于 3 个对端 → `ES111` P3（隐患，不一定当前根因） |

产物是 `key=value` 列表 + 三节点差异表，不是整份 yml。

### 6.5 L — 日志（P0，tail+关键字）

路径候选：`/var/log/elasticsearch/<cluster>.log`、`path.logs`、journald `elasticsearch.service`（仅 grep 关键字，禁止 journalctl 无限制）。

只取最近 8000 行，timeout 15s。gc.log：**只统计** 最近窗口 pause 次数/最大 pause，不贴原文。

关键字 → 场景：

| 模式 | ID |
|---|---|
| `master not discovered` / `have not received` / `master_not_discovered_exception` | `ES050` 候选（仍须清洗三台交叉） |
| `failed to send join request` / `join validation` | `ES051`/`ES060` |
| `circuit_breaking_exception` / `Data too large` | `ES038` |
| `rejected execution` / `queue capacity` | `ES036`/`ES037` |
| `flood stage` / `exceeded flood-stage` | `ES070` |
| `index read-only` / `read_only_allow_delete` | `ES071` |
| `high disk watermark` / `low disk watermark` | `ES072` |
| `OutOfMemoryError` / `Java heap space` | `ES034` |
| `failed to ping` / `handshake failed` 且含 transport | `ES091` |
| `corrupt` / `TranslogCorrupted` | `ES063` 方向，5 分钟不修 |

### 6.6 H — 主机网络（P0）

主机（timeout 合计 ≤15s）：

| 命令 | 信号 |
|---|---|
| `df -h` / `df -i`（`path.data`） | `ES015` 空间；`ES016` inode |
| `iostat -x 1 3` | `ES017` await/util；`ES018` iowait |
| `free -m` / `vmstat 1 3` | `ES011` 内存；`ES012` swap |
| `uptime` | `ES010` CPU |
| `ls /proc/<java-pid>/fd \| wc -l` vs `ulimit -n` | `ES013` |
| `timedatectl` 或 `chronyc tracking` | `ES014` 时钟偏移 |

网络（timeout 合计 ≤20s）：

| 命令 | 信号 |
|---|---|
| `ss -lntp` 看 `9200` 与 `9300` | `ES031` 无 9200；无 9300 → `ES091` 候选 |
| 本机对另外两台 `ping -c 3` | `ES090` |
| 本机对另外两台探测 **9200** 与 **9300**（`nc -z -w 2` 或 `timeout 2 bash -c '>/dev/tcp/ip/port'`） | 9200 通、9300 不通 → **`ES091`**（必须单独成信号） |
| `nstat` 或 `/proc/net/netstat` `RetransSegs` 采样 1s | `ES093` |
| `iptables/nft` 粗看 DROP | `ES094` |

**优化：** 边探测必须按「本机→对端 IP + 端口」采，不能只看本机网卡计数。交叉对比依赖这些边。

---

## 7. 交叉对比（清洗核心，禁止丢给 AI 自己发现）

清洗节点读取 **所有 IP** 的 `.signals`、`master.<ip>.json`、health 数字后，生成组合信号。这是三节点相对单机排障的唯一关键增量。

期望节点数 `expected_nodes=3`（可配置）。`node_count=1` 时禁止输出「全员」结论。

| 组合条件 | 输出信号 | 定责方向 |
|---|---|---|
| 3/3 采到且三台均无 elected master | `ES191 NO_MASTER`（=ES050 集群结论） | 法定人数/发现/传输全断；**先报这个，不要解释 unassigned** |
| health `number_of_nodes` 少于 3，且缺失 IP：9200/9300 不通或无 Java 进程 | `ES190 NODE_DOWN_ONE`（若缺 2 台则 ES053） | 掉节点，不是业务 QPS |
| 3 个节点都在集群内（health=3 且三台本地都见到同一 master），yellow，unassigned 仅为副本 | `ES192 YELLOW_ALLOC_NOT_DOWN` | 水位 / `allocation.enable` / `max_shards`，不是掉节点 |
| health red 且已确认 ES191 | `ES053` 方向 | 丢法定人数；explain 不可靠 |
| 仅 1 台 heap/breaker 高 | `ES193 HEAP_ONE_OUTLIER` | 该节点热点或本机 JVM |
| ≥2 台 heap/reject 同量级（差值相对较小） | `ES194 HEAP_ALL_SIMILAR` / `ES196 REJECT_ALL` | 集群容量或查询/写入风暴 |
| 仅 1 台 write/search reject 增量 >0 | `ES195 REJECT_ONE` | 该节点队列/热点 |
| 仅 1 台 flood-stage / `read_only_allow_delete` | `ES197 FLOOD_ONE` | 该节点磁盘 |
| ≥2 台 flood 或集群块 | `ES198 FLOOD_ALL` | 集群只读块 |
| 本机 master 视图与多数派不一致，或 9200 通、9300 不通 | `ES199 TRANSPORT_PARTITION` | 传输层分区 / 脑裂观感 |
| explain 首因 `NODE_LEFT` | 与 ES190 互证 | 掉节点 |
| explain 首因 `DECIDERS_NO` disk | `ES061` + 倾向 ES192 | 水位 |
| explain 首因 `ALLOCATION_FAILED` | `ES063` | 分配失败，不是「没节点」 |
| 仅 ES014 时钟偏移 + 延迟类观感 | 降权时间相关结论 | 不信任跨节点时间差 |

清洗必须在 `summary.md` 写明：`nodes_collected=`、`expected_nodes=`、`majority_master=`、`coverage=`。

---

## 8. 场景目录（ES ID）

清洗与（若成功）AI 使用同一套 ID。级别：P1 不可写/无主/丢数据风险；P2 延迟/降级/部分分片；P3 隐患或采集降级。

### 8.1 基线

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| ES001 | 基线正常 | - | green、三台同一 master、无组合告警、预检通过 |

### 8.2 主机

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| ES010 | CPU 饱和 | P2 | H |
| ES011 | 内存压力 | P2 | H |
| ES012 | swap | P2 | H |
| ES013 | FD / ulimit | P1 | H L |
| ES014 | 时钟偏移 | P3 | H |
| ES015 | 磁盘满 / 只读挂载 | P1 | H L |
| ES016 | inode 满 | P1 | H |
| ES017 | 磁盘延迟高 | P2 | H |
| ES018 | iowait 高 | P2 | H |

### 8.3 进程与 JVM

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| ES030 | elasticsearch/java 进程不在 | P1 | P H |
| ES031 | 9200 未监听 | P1 | P H |
| ES032 | 本地 HTTP 失败（含认证失败） | P1 | P |
| ES033 | fatal / 反复崩溃（日志） | P1 | L |
| ES034 | heap 高 / OOM | P1 | M L |
| ES035 | GC 风暴 | P2 | M L |
| ES036 | write 线程池 reject | P2 | M L |
| ES037 | search 线程池 reject | P2 | M L |
| ES038 | circuit breaker | P1/P2 | M L |
| ES039 | 反复重启 | P2 | L H |

### 8.4 集群 / Master / 分片

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| ES050 | 三台均无 elected master（集群级 NO_MASTER） | P1 | S 交叉 |
| ES051 | master 视图不一致 | P1 | S H |
| ES052 | 掉 1 个节点，副本未分配（NODE_LEFT） | P2 | M S H |
| ES053 | 掉 ≥2 节点 / 红且无主 | P1 | M S |
| ES054 | 主分片未分配（有主时） | P1 | M S |
| ES055 | delayed unassigned（重启宽限） | P3 | M |
| ES056 | pending tasks / master 排队 | P2 | M |
| ES057 | relocating/initializing 卡住 | P2 | M S |
| ES058 | `allocation.enable` 非 all | P1 | C S |
| ES059 | `max_shards_per_node` | P2 | C M |
| ES060 | `cluster.name` 不一致 | P1 | C S |
| ES061 | unassigned：DECIDERS_NO disk | P1 | S H |
| ES062 | unassigned：DECIDERS_NO filter/enable | P2 | S C |
| ES063 | ALLOCATION_FAILED / 损坏线索 | P1 | S L |

### 8.5 磁盘水位与集群块

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| ES070 | flood-stage | P1 | M L H |
| ES071 | `read_only_allow_delete` | P1 | C L M |
| ES072 | high watermark（副本不分配） | P2 | C M S |
| ES073 | path.data 权限 | P1 | H L |

### 8.6 网络

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| ES090 | 节点间 ping 失败 / RTT 高 | P2 | H |
| ES091 | 9200 通、9300 不通 | P1 | H S |
| ES092 | 9300 通、9200 不通 | P2 | H |
| ES093 | TCP 重传 | P2 | H |
| ES094 | 防火墙 / 安全组 | P1 | H L |

### 8.7 配置隐患

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| ES110 | 残留 `discovery.zen.minimum_master_nodes` | P3 | C |
| ES111 | seed_hosts / unicast 不全 | P3 | C |
| ES112 | Xms ≠ Xmx | P3 | C |
| ES113 | watermark 被改得过激 | P2 | C |
| ES114 | http/transport 端口与探测不一致 | P2 | C H |

### 8.8 采集降级

| ID | 场景 | 级 | 主证据 |
|---|---|---|---|
| ES170 | 预检失败 | P3 | P |
| ES171 | curl/工具缺失 | P3 | P |
| ES172 | 节点不可达（汇聚缺产物） | P1 | 汇聚 |
| ES173 | 部分节点采集失败 | P2 | 汇聚 |
| ES174 | 命令超时 | P3 | 各路 `CMD_TIMEOUT` |

### 8.9 组合（清洗生成）

| ID | 场景 |
|---|---|
| ES190 | NODE_DOWN_ONE（或缺节点 + 进程/端口证据） |
| ES191 | NO_MASTER（三台均无主） |
| ES192 | YELLOW_ALLOC_NOT_DOWN |
| ES193 | HEAP_ONE_OUTLIER |
| ES194 | HEAP_ALL_SIMILAR |
| ES195 | REJECT_ONE |
| ES196 | REJECT_ALL |
| ES197 | FLOOD_ONE |
| ES198 | FLOOD_ALL |
| ES199 | TRANSPORT_PARTITION（含 9200/9300 分叉或 master 视图分裂） |

### 8.10 当前环境不适用（只记账，不采集）

| ID | 场景 | 原因 |
|---|---|---|
| ES200 | CCR / 跨集群复制 | 未部署 |
| ES201 | ILM 卡住 | 瘦 P0；5 分钟不够定性 |
| ES202 | snapshot 仓库失败 | 超出时间盒 |
| ES203 | hot-warm / data tiers | 三节点全角色无温层 |
| ES204 | ingest pipeline 失败 | 非 P0 |
| ES205 | mapping 爆炸 / cluster state 体积 | 禁止拉全量 state；只留 `ES056` 缺口 |
| ES206 | TLS / PKI / API key | 认证仅可选 basic |
| ES207 | 6.x/8.x 混部 | 范围是 7.x |
| ES208 | 专主 vs 数据角色分离 | 拓扑 A 全角色 |
| ES209 | 自动 reroute / 开分配 | 本 Bot 不变更 |
| ES210 | searchable snapshot / frozen | 7.x 实验室默认无 |

---

## 9. 清洗（≤50s）

输入：所有节点 artifact + signals。  
输出（**必须 Markdown 可展示**）：

```text
summary.md           # 给人看的一页纸（清洗节点可视化的主文件）
signals.txt          # 去重后的 ES ID（可 TSV）
cleaned.txt          # 截断后的关键原文，上限 64KB
cleaned.meta         # coverage_status=ok|degraded nodes_collected=N majority_master=...
```

清洗步骤（纯规则，**禁止 HTTP 调模型**）：

1. 解析每台 `local_master`，按第 5 节下 `ES050`/`ES051`/`EVIDENCE_GAP`。
2. 合并 signals，同 ID 取最高 severity，note 拼接节点 IP。
3. 跑第 7 节交叉对比，写入 ES190–ES199。
4. 若 ES191 成立：在 summary 置顶「无稳定主节点」，**不要** 用 unassigned 数字编造分片故事。
5. `summary.md` 固定小节（见 9.1）。
6. 原文只保留：每路 `SIGNAL` 行 + `CMD_FAIL` + 日志命中行 + explain 抽样。

覆盖判定：

| 条件 | coverage |
|---|---|
| 3/3 节点有本地 master 视图 + 至少 1 份 cluster health | ok |
| 缺 ≥1 台 master 视图，或无任何 health | degraded → 降级清洗 |
| 仅主机/日志 | degraded |

降级清洗：仍输出 `summary.md`，明确缺哪台、哪些 API，不编造 `number_of_nodes`、不编造「全员 heap」。

### 9.1 `summary.md` 固定结构

```markdown
# ES 7.x 三节点排查摘要

- run_id / 时间窗
- expected_nodes / nodes_collected / coverage
- majority_master（或 NO_MASTER / UNKNOWN+GAP）

## 集群健康
- status / number_of_nodes / unassigned / delayed / pending_tasks

## 各节点 master 视图
| IP | local_master | 9200 | 9300 | heap% | write_rejected_delta | disk |

## Top 信号
（按 severity，含 ES190–ES199）

## 交叉对比结论
（人话 + ID：掉节点 vs 无主 vs 分配卡住 vs 单点 JVM vs 集群块）

## 证据缺口
```

清洗节点 stdout 同时打印 `summary.md`，方便作业平台直接展示。

---

## 10. AI 诊断契约（≤50s，最后一节点）

**与 MySQL 设计的差异（审查锁定）：**

- 清洗 **不** 用启发式代替 AI 成功。
- AI 超时、HTTP 非 2xx、空响应、解析失败 → **AI 节点以失败结束**。
- 失败后平台仍展示清洗节点 `summary.md` / `signals.txt`。

Prompt 只含：

1. 角色说明：ES 7.x 三节点全角色，副本 1，本流程只诊断不变更  
2. 本文件第 8 节场景目录（压缩表，不含 N/A 详述）  
3. `summary.md` 全文  
4. `signals.txt`  
5. `cleaned.txt` 截断 32KB  

成功时模型必须输出 Markdown：

```markdown
## 根因假设（按置信度）
1. ES... — ...
## 关键证据
## 影响面（集群可用性 / 写入 / 查询 / 数据风险）
## 立即止损（不自动执行）
## 验证步骤
## 证据缺口（5 分钟未做项）
```

硬约束：

- 禁止编造未出现的指标。
- 禁止在未满足第 5 节三台条件时写「集群没有 master」。
- 有 `ES191` 时，根因必须先打到选举/发现/传输，不能只凭 yellow/unassigned 说「缺副本」。
- 有 `ES192` 时，禁止写成「节点掉了」。
- 有 `ES193`/`ES195`/`ES197` 时，禁止写成全集群容量问题。
- 有 `ES194`/`ES196`/`ES198` 时，禁止只点名一台。
- 有 `ES199` 时，必须提到 9300 / transport，不能只说 HTTP 正常所以集群正常。
- 止损是建议文案：例如「检查该节点进程与 9300」、「不要在无主时强行 reroute」。脚本不执行。

AI 节点 stdout 包裹 `###ES_TS_AI_DIAGNOSIS`。失败时 stderr 写原因，exit ≠ 0。

---

## 11. 7.0–7.17 兼容

| 概念 | 做法 |
|---|---|
| 线程池 | 优先 `thread_pool.write`；缺失再试 `index` 并标记 legacy |
| 发现配置 | 同时解析 `discovery.seed_hosts` 与 `discovery.zen.ping.unicast.hosts` |
| `minimum_master_nodes` | 仅当 yml 仍出现时报 `ES110`；**不** 用它判断法定人数 |
| 集群 bootstrap | 可读 `cluster.initial_master_nodes`，不在运行时去改 |
| 认证 | 可选 HTTP basic；7.x 默认发行版可能关安全，空用户即裸打 |
| cat API | `format=json`；部分 7.0 无某列则记 NA |
| 分配 explain | 7.x `GET/POST _cluster/allocation/explain` 都试，2xx 即用 |
| 禁止 | `_security` 当 P0、ILM explain、8.x `?pretty` 大对象当输入 |

清洗只认归一化字段：`local_master`、`heap_pct`、`write_rejected_delta`、`cluster_status`、`unassigned`、`http_ok`、`transport_ok`。

---

## 12. 产物与作业平台

节点 stdout 包裹，便于 SOPS 拼接：

```text
###ES_TS_ARTIFACT kind=metrics node=10.10.26.144 file=...
...正文...
###ES_TS_SIGNALS kind=metrics node=10.10.26.144
ES036	high	write rejected delta=12
###END_ES_TS_ARTIFACT###
```

清洗后：

```text
###ES_TS_CLEANSED
（summary.md 正文）
###END_ES_TS_CLEANSED###
```

AI 成功后：

```text
###ES_TS_AI_DIAGNOSIS
...
###END_ES_TS_AI_DIAGNOSIS###
```

实验室：`troubleshooting/elasticsearch/scripts/run_flow.sh`（**实现阶段**），`BACKEND=ssh|docker|local`，逻辑对齐 Kafka/MySQL。

认证与节点列表只在本地 `config.env`（gitignore），模板 `config.env.example`：

```bash
export ES_NODES="10.10.26.144:9200 10.10.26.145:9200 10.10.26.146:9200"
export ES_TRANSPORT_PORT=9300
export ES_USER=""
export ES_PASS=""
export EXPECTED_NODES=3
```

---

## 13. 落地文件（下一步实现，本文不写代码）

```text
troubleshooting/elasticsearch/
  2026-09-15-elasticsearch-717-multi-node-troubleshooting-design.md  # 本文
  README.md
  scripts/                    # 另开任务
    _lib.sh
    collect_precheck.sh
    collect_metrics.sh
    collect_status.sh
    collect_config.sh
    collect_logs.sh
    collect_hostnet.sh
    cleanse.sh
    cleanse_degraded.sh
    ai_diagnose.sh            # 失败须非 0 退出
    run_flow.sh
  tools/generate_yaml.py
```

**本 PR 不添加 scripts/。** 不添加 `elasticsearch_fault_injection/`。

---

## 14. 验收标准

### 14.1 时间

在 3 节点、SSH 或 docker exec 可达、日志 < 200MB 的实验室：

- 五路采集墙钟 **≤90s**（取最慢一路）
- 清洗 **≤50s** 且已有 `summary.md`
- AI **≤50s**（成功或该节点失败，不得拖过）
- 端到端 **≤5min**（含汇聚）

用 `date +%s` 打点写进 `cleaned.meta`，采集/清洗超时即验收失败，不论结论对不对。

### 14.2 正确性（最小故障集，实现阶段用人工或既有故障复现，不在本设计实现注入器）

| 观察 | 必须打出的 ID |
|---|---|
| 停 1 台 ES 进程，另外两台仍能选主 | `ES030` + `ES190`/`ES052`，**禁止** `ES191` |
| 停 2 台，剩下 1 台无主 | 仅当 **三台产物都在且都无主** 才 `ES191`；缺产物时只能 GAP，禁止瞎下 `NO_MASTER` |
| 三台都在，人为 `allocation.enable=none` 或磁盘水位导致副本不分配 | `ES192` + `ES058`/`ES061`，**禁止** `ES190` |
| 仅一台 heap ≥95% 或 breaker | `ES193`/`ES038`，禁止 `ES194` |
| 两台以上 write reject | `ES196` |
| 一台 9200 通、9300 被挡 | `ES091` + `ES199` |
| 三台 `cluster.name` 不一致 | `ES060` |
| 采集时某台 ES 已死 | 该台采集 `exit 0`，清洗仍出 `summary.md`，含 `ES030`/`ES172` |

### 14.3 反例（打出算失败）

- 只问第一台 9200 没有 master 就输出「集群没有稳定主节点」  
- 无主时编造精确的 unassigned 根因并当确信结论  
- 把 `GET /_cluster/state` 全文塞进 AI prompt  
- YAML 写 node-1 是 master，选举已在 node-2 仍采 node-1 当权威  
- 三台都在、yellow 副本，却输出「节点掉了」且无端口/进程证据  
- AI 失败却把作业标成功（清洗成功 ≠ AI 成功）  
- 排查脚本执行 reroute / 关块 / 重启  

### 14.4 AI 失败验收

- 断开 AI 端点或让其 500：AI 节点 **失败**。  
- 清洗节点 `summary.md` 仍可在平台打开，含表格与 Top 信号。  

---

## 15. 风险

| 风险 | 处理 |
|---|---|
| `_cat/master` 在无主时挂起 | `--max-time 3`，空结果按无主视图，仍须三台交叉 |
| 7.0 与 7.17 `filter_path` 个别字段名差 | 缺字段 NA，不失败退出 |
| 账号无集群权限 | `ES032`，coverage=degraded |
| 三台实际不是全角色 | 预检记录 `node.role`，与基线不符记 P3，主路径仍按全角色交叉 |
| 日志刚 logrotate | tail 最新 `*.log` |
| AI 端点慢 | 45s kill，**节点失败**，不改清洗产物 |

---

## 16. 实现顺序建议（后续任务）

1. `_lib.sh` + 每台本地 master 视图 + artifact 包裹  
2. 五路 P0 命令 + 单命令 timeout + 信号  
3. 清洗交叉对比 ES190–ES199 + `summary.md`  
4. 汇聚（平台或 `run_flow.sh`）  
5. AI 节点（失败非 0）  
6. SOPS YAML  

不要先写 YAML 再补信号：Kafka v1 的主要缺口就是「流程有了、定责信号没有」。  
不要并行做故障注入目录。
