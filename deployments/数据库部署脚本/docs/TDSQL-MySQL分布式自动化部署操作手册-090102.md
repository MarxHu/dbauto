# TDSQL MySQL 分布式三段式部署操作手册

## 1. 适用范围

| 项目 | 交付口径 |
|---|---|
| 产品 | 腾讯云数据库 TDSQL MySQL 分布式版 V10.3.22.6 |
| 管控版本 | V22.9 前适用 |
| 操作系统 | CentOS 7.8/7.9 x86_64 |
| 物理拓扑 | 3 台管控 + 3 台 DB + 2 台 Proxy，共 8 台 |
| 业务实例 | 2 分片，每分片一主两备 |
| 业务入口 | 两个 Proxy IP:PORT，不部署 LVS/VIP |
| 自动化平台 | 蓝鲸标准运维（SOPS）+ JOB |

本手册只采用腾讯安装材料中的“安装数据库（命令行部署）”顺序。完整流程为：

> Part 1 自动部署 → 赤兔平台初始化 → Part 2 自动部署 → 赤兔创建业务分布式实例 → Part 3 自动验收

赤兔操作由实施人员完成；JOB 脚本不等待人工输入、不操作浏览器，也不猜测赤兔内部 API。

## 2. 交付文件

| 文件 | 用途 |
|---|---|
| `tdsql-distributed-part1-090102.yaml` | 环境检查、三制品分发、配置生成、官方 PreCheck、Part 1 核心部署 |
| `tdsql-distributed-part2-090102.yaml` | 校验 Part 1 状态、回填监控库参数、执行 Part 2、验证实际角色组连通性 |
| `tdsql-distributed-part3-090102.yaml` | 在业务实例创建后验证两个 Proxy 的登录、写入、更新和跨 Proxy 读取 |
| `TDSQL-MySQL分布式自动化部署操作手册-090102.md` | 现场输入、两段赤兔操作、失败处理和交付验收说明 |

不得跳过、合并或调换上述五个环节。Part 1 和 Part 2 必须使用同一个 `tdsql_deploy_run_id` 和完全相同、有序的 `tdsql_control_ips`。

## 3. 节点与实例规划

### 3.1 物理节点

| 节点 | 角色 |
|---|---|
| control1 | 唯一 Ansible 执行主控、ZK1、Scheduler1、OSS1、赤兔1、Monitor1；Part 3 验收发起机 |
| control2 | ZK2、Scheduler2、OSS2、赤兔2、Monitor2 |
| control3 | ZK3 |
| db1、db2、db3 | TDSQL DB 资源池 |
| proxy1、proxy2 | 同一网关组中的两个业务 Proxy |

### 3.2 业务实例

- 创建类型：分布式实例。
- 分片数：2。
- 每分片节点数：3，即一主两备。
- 副本放置：同一分片的三个副本必须分布在 db1、db2、db3；不得把同一分片的主备放在同一物理机。
- 主节点分散：创建完成后确认两个分片的主节点没有全部集中在同一 DB。
- 同步方式：强同步；是否允许退化按现场高可用策略选择并记录。
- 接入层：选择同时包含 proxy1、proxy2 的网关组。
- 业务侧：连接池必须配置两个 Proxy 地址，禁止只配置其中一个。

分片和副本拓扑以赤兔实例详情为权威证据。当前材料没有正式拓扑查询 CLI/API，因此 Part 3 不自动推测拓扑。

## 4. 自动化和人工边界

自动完成：

- 检查 CentOS 7.8/7.9、x86_64、root JOB 账户和必要命令；
- 分发并校验 TDSQL 安装包、腾讯官方 PreCheck 包和 License；
- 生成 3+3+2 Inventory，安全写入 `tdsql_os_pass`；
- 执行官方 PreCheck、`install_ansible.sh`、`tdsql_part1_site.yml`；
- 通过批次指纹衔接 Part 1 和 Part 2；
- 安全回填监控库参数，执行 `tdsql_part2_site.yml`；
- 只验证实际 TDSQL 角色组，不 ping 安装包里的无效占位主机；
- 业务实例创建后，从 control1 分别连接两个 Proxy 并执行临时库表读写。

人工完成：

- 赤兔首次登录和安全改密；
- 赤兔六步初始化、资源上报、监控库、配置库和 License；
- Part 2 后创建 2 分片 × 一主两备业务实例；
- 在赤兔确认拓扑并保存截图；
- 运行集群巡检和自动化演练并归档报告。

## 5. 执行前准备

### 5.1 蓝鲸和主机

- 目标蓝鲸环境已验证支持 YAML v1、“快速执行脚本”v1.2、“快速分发文件”v3.0。
- 8 台服务器位于同一个蓝鲸业务，JOB 可以 root 账户执行。
- 8 台均为 CentOS 7.8/7.9 x86_64，IP 互不重复。
- control1 到全部 8 台已配置 root SSH BatchMode 互信。
- 主机名、时间同步、磁盘、端口、防火墙和 SELinux 已按腾讯 PreCheck 要求整改。
- `/data` 空间满足安装包、解压目录、数据库及日志需求。
- control1 已离线安装兼容 MySQL 客户端，`command -v mysql` 返回有效路径。
- 目标机器不存在来源不明的旧 TDSQL 安装或业务数据。

流程不安装系统依赖，不关闭防火墙或 SELinux，不改 GRUB，不自动重启，也不自动清理旧实例。

### 5.2 三个用户输入制品

| 制品 | 来源要求 | 校验 |
|---|---|---|
| TDSQL 安装包 | 腾讯交付的 V10.3.22.6 x86_64 包 | 用户输入文件源和 SHA256；不限制固定文件名 |
| PreCheck | 腾讯官方 `Precheck_tianxun` x86 包 | 用户输入文件源和 SHA256；解压后必须存在 `pre_autotest_install_v1.1.sh` |
| License | 腾讯提供的授权文件包 | 用户输入文件源和 SHA256 |

TDSQL 安装包仅支持 `zip`、`tar.gz`、`tgz` 或 `tar`。流程只检查实际要调用的 `tdsql_install`、Inventory、变量文件及 Part 1/Part 2 入口，不校验固定包名。

## 6. 静态模拟

```bash
ruby tools/simulate_tdsql_delivery.rb \
  --flavor distributed \
  --control-ips 10.0.0.1,10.0.0.2,10.0.0.3 \
  --db-ips 10.0.1.1,10.0.1.2,10.0.1.3 \
  --proxy-ips 10.0.2.1,10.0.2.2 \
  --part1-recap 'failed=0 unreachable=0' \
  --part2-recap 'failed=0 unreachable=0' \
  --part3-result 'proxy1=ok proxy2=ok cross_proxy=ok cleanup=ok' \
  --metadb-ip 10.0.2.1 --metadb-port 15001 \
  --metadb-ip-bak 10.0.2.2 --metadb-port-bak 15001 \
  --metadb-user tdsql_monitor --metadb-password 'ReplaceWithControlledSecret'
```

模拟器校验三份 YAML、3+3+2 Inventory、监控库格式和五个流程检查点。它不连接服务器、不解压真实安装包、不执行 Ansible 或 SQL，不能作为真实安装成功证据。

## 7. Part 1：自动部署核心平台

### 7.1 启动参数

| 参数 | 填写要求 |
|---|---|
| `tdsql_deploy_run_id` | 唯一部署批次，例如 `TDSQL_20260901_01` |
| `tdsql_cluster_name` | 唯一集群名称，英文字母开头 |
| `tdsql_control_ips` | 3 个有序 IP，第一个固定为 control1 |
| `tdsql_db_ips` | 3 个有序 DB IP |
| `tdsql_proxy_ips` | 2 个有序 Proxy IP |
| `tdsql_package_source` / `tdsql_package_sha256` | TDSQL 文件源及 64 位摘要 |
| `tdsql_precheck_source` / `tdsql_precheck_sha256` | 官方 PreCheck 文件源及摘要 |
| `tdsql_license_source` / `tdsql_license_sha256` | License 文件源及摘要 |
| `tdsql_os_password` | tdsql 操作系统账户密码；通过受控参数页填写 |

三组 IP 合计必须为 8 个不同地址，不允许空格。不要把任何密码写进任务名、备注或工单正文。

### 7.2 执行和成功条件

依次导入并运行 Part 1。五个阶段均不可直接重试。成功条件：

- 8 台系统和架构检查通过；
- 三个制品 SHA256 通过；
- Inventory 映射为 3 管控、3 DB、2 Proxy；
- 官方 PreCheck 两个动作成功；
- Part 1 recap 同时出现 `failed=0`、`unreachable=0`；
- `/data/tdsql_sops/<run_id>/state/part1.success` 和 `cluster.fingerprint` 存在。

Part 1 失败时保留现场，不在失败节点点“重试”。先查看标准运维输出、`part1.log` 和 `/var/log/ansible.log`。

## 8. 赤兔人工操作一：平台初始化

Part 1 成功后，访问 `http://<赤兔节点IP>/tdsqlpcloud`。管理员初始密码以腾讯交付包或现场密码信封为准，本手册不记录默认密码。首次登录后立即修改密码。

### 8.1 六步初始化

1. **许可协议**：阅读并接受许可协议。
2. **环境检测**：全部检查项通过后继续；失败项先整改，不允许跳过。
3. **集群接入**：
   - 集群命名填写本次唯一名称；
   - OSS 列表逐行填写 control1、control2 的 `IP:PORT`，默认端口通常为 8080，以实际 `group_vars/all` 为准；
   - 点击“测试服务连接”；
   - Zookeeper 列表逐行填写 3 个 `IP:PORT`，端口读取 `tdsql_zk_clientport`，原厂示例为 2118；
   - Zookeeper 根节点读取 `tdsql_zk_rootdir`，原厂示例为 `/tdsqlzk`；
   - 核对自动展示的集群信息。
4. **集群初始化**：
   - 创建有意义的 IDC 英文简称，权重通常保持 100；
   - 按实际故障域填写机架信息；
   - 创建 DB 机型：CPU 填逻辑核，内存通常按实际值 75%，数据盘和日志盘按现场规划；
   - 数据目录建议 `/data1/tdengine/data`，日志目录建议 `/data1/tdengine/log`；
   - 安装包目录保持 `/data/home/tdsql/tdsqlinstall`，数据库安装目录保持 `/data/tdsql_run`；
   - 上报 db1、db2、db3，IP 必须与 Part 1 Inventory 一致；
   - 上报 proxy1、proxy2，创建一个包含这两个指定 IP 的网关组。
5. **为系统配置数据库**：
   - 点击“创建实例”，创建业务描述为“监控库”的非分布式实例；
   - 推荐规格可从 4 核、8 GB、数据盘 200 GB、日志盘 60 GB起，最终按实例规模调整；
   - 容灾选择一主两备、强同步；三个节点分布在至少两个故障域；
   - 初始化时字符集按项目要求，表名大小写默认不敏感，`innodb_page_size` 默认 16384；
   - 选择“使用 TDSQL 实例”，配置库名和监控库名保持赤兔默认；
   - 自定义监控库账号，避免 `tdsql`、`root`、`admin` 等高危名称；
   - 点击“测试数据库连接”，只有显示成功才开始安装。
6. **软件授权**：上传腾讯 License；如现场决定稍后导入，必须记录并在正式验收前补齐。

### 8.2 Part 2 交接参数

进入“实例管理 → 监控实例 → 实例详情 → 网关列表（proxy_host）”，记录主备 Proxy：

```text
tdsql_deploy_run_id：与 Part 1 相同
tdsql_control_ips：与 Part 1 相同且顺序不变
tdsql_metadb_ip / tdsql_metadb_port：监控库主 proxy_host
tdsql_metadb_ip_bak / tdsql_metadb_port_bak：监控库备 proxy_host
tdsql_metadb_user：初始化时创建的监控库账号
tdsql_metadb_password：通过受控参数页填写，不写入交接文档
```

## 9. Part 2：自动部署后端组件

导入 Part 2，确认阶段为“更新赤兔监控库配置 → Part2 自动化安装 → 最终验证”。三个阶段均不可直接重试。

流程会验证 Part 1 成功状态、集群指纹和有序 control IP，然后安全更新监控库参数并执行 `tdsql_part2_site.yml`。成功条件：

- Part 2 recap 同时出现 `failed=0`、`unreachable=0`；
- clouddba、onlineddl、collector 安装无失败；
- ZK、Scheduler、OSS、赤兔、Monitor、DB、Proxy 实际角色组全部 ping 成功；
- `/data/tdsql_sops/<run_id>/state/part2.success` 存在。

Part 2 失败时不得重新执行赤兔初始化，也不得直接重试失败节点。保留日志并按腾讯恢复方式处理。

## 10. 赤兔人工操作二：创建业务分布式实例

Part 2 成功后执行以下操作：

1. 进入“实例管理”，点击“创建分布式实例”。
2. 基础设置中填写业务描述、数据库版本、已上架 DB 机型和业务规格。
3. 设置分片数为 **2**。
4. 每个分片设置为 **一主两备**，同步方式选择强同步；退化策略按现场批准口径填写。
5. IDC/Zone 放置必须使同一分片的三个副本落在 db1、db2、db3，不允许同机主备。
6. 接入配置选择前面创建的双 Proxy 网关组。
7. 按项目要求设置字符集和表名大小写；如出现 `innodb_page_size`，保持批准值，默认推荐 16384。
8. 点击开始创建，等待实例状态变为正常。创建过程中不要反复点击提交。
9. 进入实例详情确认：实例类型为分布式、分片数为 2、每分片 3 个节点、两个分片的主节点合理分散。
10. 保存实例详情和拓扑截图，截图中不得出现明文密码。
11. 在网关/接入配置中记录两个不同的 Proxy `IP:PORT`。
12. 取得该实例管理员账号和密码；密码只在 Part 3 受控参数页输入。

如果当前赤兔补丁版本的字段名称与本手册略有差异，以页面展示和腾讯同版本交付说明为准，但不得改变“2 分片、每分片一主两备、双 Proxy”的验收目标。

## 11. Part 3：自动验收业务实例

### 11.1 参数

| 参数 | 填写要求 |
|---|---|
| `tdsql_acceptance_run_id` | 新的唯一验收批次，3～32 位字母、数字、下划线或短横线 |
| `tdsql_deploy_run_id` | 与 Part 1/Part 2 完全一致 |
| `tdsql_control_ips` | 与 Part 1 完全一致且顺序不变 |
| `tdsql_proxy1_ip` / `tdsql_proxy1_port` | 业务实例第一个 Proxy |
| `tdsql_proxy2_ip` / `tdsql_proxy2_port` | 业务实例第二个 Proxy，不能与第一个端点相同 |
| `tdsql_instance_admin_user` | 业务实例管理员账号 |
| `tdsql_instance_admin_password` | 管理员密码，仅通过受控参数页填写 |

### 11.2 动作和成功条件

Part 3 在 control1：

1. 检查 Part 2 回执、MySQL 客户端和两个 Proxy TCP 端口；
2. 使用权限为 `0600` 的临时 option 文件保存连接凭据；
3. 分别登录两个 Proxy；
4. 通过 Proxy1 创建 `tdsql_sops_<acceptance_run_id>` 临时库及 `sops_owner` 所有权表；
5. 通过 Proxy1 写入和更新，通过 Proxy2 查询并核对结果；
6. 成功后验证所有权标记，删除临时库，写入 `acceptance.success`；
7. 擦除并删除临时凭据文件。

只有双 Proxy 登录、写入、更新、跨 Proxy 读取和临时库清理全部通过，Part 3 才成功。Part 3 成功不替代赤兔拓扑截图。

## 12. Part 3 失败处理

- 失败时自动清除临时凭据文件，但保留临时数据库和非敏感日志用于排查。
- 不允许直接删除同名未知数据库；临时库必须包含与本次验收批次一致的 `sops_owner.run_id`。
- 重跑 Part 3 时使用新的 `tdsql_acceptance_run_id`。
- 人工清理前先连接实例并执行：

```sql
SELECT run_id FROM tdsql_sops_<验收批次>.sops_owner;
```

只有返回值与验收批次完全一致，才允许由 DBA 执行：

```sql
DROP DATABASE `tdsql_sops_<验收批次>`;
```

## 13. 最终交付检查表

- [ ] Part 1、Part 2 和 Part 3 均有成功回执。
- [ ] 3 个 Zookeeper、2 个 Scheduler、2 个 OSS、2 个赤兔、2 个 Monitor 正常。
- [ ] 3 台 DB 和 2 台 Proxy 在赤兔中状态正常。
- [ ] 业务实例为 2 分片，每分片一主两备，拓扑截图已归档。
- [ ] 两个 Proxy 均通过 Part 3 SQL 验收，业务连接池配置了双地址。
- [ ] 监控库、配置库、clouddba、onlineddl、collector 正常。
- [ ] 赤兔集群巡检和自动化演练报告已保存。
- [ ] 默认管理员账号已按现场制度改密、停用或删除；手册和工单无默认密码。
- [ ] License 状态符合正式交付要求。

## 14. 验证边界

仓库测试、YAML 校验、Bash 语法检查和模拟器只能证明交付文件的静态合同。生产执行前仍必须使用腾讯实际 V10.3.22.6 x86_64 安装包和官方 PreCheck，在同版本 CentOS 7.8/7.9 的 3+3+2 隔离环境完整预演。
