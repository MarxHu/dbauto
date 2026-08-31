# mysql84-gtid-primary-replicas-3node-083102 部署说明（全新节点版）

## 适用场景

**全新虚机 / 空 datadir** 的一主两从 GTID 部署测试。不适用于已有坏 datadir 的就地修复。

## 阶段顺序（重要）

MySQL 8.4 临时密码态 **只允许 ALTER USER**，因此：

1. 初始化与启动
2. **临时密码改密**（仅 ALTER USER）
3. **启动后验收**（gtid_mode / server_id，用新密码）
4. 建复制用户 → 建复制 → 加固

**禁止**在改密前执行任何 SELECT（含 `@@gtid_mode`），否则 ERROR 1820。

## Runner 坑：wait_replication + mysql -Nse + \G

`mysql -N` 会去掉列名；`SHOW REPLICA STATUS\G` 再交给 awk 匹配 `Replica_IO_Running:` 会得到空值。

YAML 已改为用 `performance_schema` 单值查询（`-N` 下也能比），不再依赖 `wait_replication`。

## assert_sql 坑：RECEIVED == gtid_executed

从库 `gtid_executed` = **本机 initialize UUID:1** + **主库传来的 UUID:…**；
`RECEIVED_TRANSACTION_SET` 只有主库传来的部分。二者 **天然不相等**，用相等判断会误杀（got=1 expect=0）。

正确用法：

```sql
SELECT GTID_SUBSET(RECEIVED_TRANSACTION_SET, @@GLOBAL.gtid_executed);  -- 期望 1
```

## 现有失败现场（复制已通、保护未装）——不重置

在 **.12 / .13** 执行：

```sql
INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';
SET GLOBAL rpl_semi_sync_replica_enabled = ON;
SET GLOBAL read_only = ON;
SET GLOBAL super_read_only = ON;
```

在 **.11** 执行：

```sql
INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';
SET GLOBAL rpl_semi_sync_source_wait_for_replica_count = 1;
SET GLOBAL rpl_semi_sync_source_timeout = 10000;
SET GLOBAL rpl_semi_sync_source_enabled = ON;
```

## 相对旧版的关键变化

| 问题 | 旧版 | 新版 |
|------|------|------|
| cnf 未加载 | 只写 `my.cnf.d`，主配置无 includedir | 先 `ensure_mycnf_includedir` |
| ERROR 1777 | init 时 GTID 实际 OFF | init 前写入 GTID cnf + 启动后验收 |
| init 报 unknown variable | cnf 含半同步变量 | init cnf 仅 GTID/server_id；半同步运行期 SQL |
| ERROR 1820 | 改密前跑 SELECT | 先 ALTER USER |
| ERROR 2061 | 缺 GET_SOURCE_PUBLIC_KEY | 已包含 |

## init 配置（/etc/my.cnf.d/mysql-cluster.cnf）

**主库**：`server-id`、`gtid_mode`、`enforce_gtid_consistency`、`log_bin`、`binlog_format`、`log_replica_updates`

**从库**：`server-id`、`gtid_mode`、`enforce_gtid_consistency`、`log_replica_updates`、`relay_log`、`replica_preserve_commit_order`

**不含**：`plugin_load_add`、`rpl_semi_sync_*`、`read_only`（从库只读在复制就绪后 SET GLOBAL）

## 部署前检查

- 三台均为 **全新节点**，`/var/lib/mysql` 为空或不存在
- 无残留 `mariadb-libs`（预检会自动卸无依赖包）
- 参数已填：`root_password`、`repl_password`

## 下载

https://raw.githubusercontent.com/MarxHu/dbauto/cursor/fix-mysql84-temp-password-order-cded/deployments/%E6%95%B0%E6%8D%AE%E5%BA%93%E9%83%A8%E7%BD%B2%E8%84%9A%E6%9C%AC/output/mysql84-gtid-primary-replicas-3node-083102.yaml

```bash
curl -L -o mysql84-gtid-primary-replicas-3node-083102.yaml \
  "https://raw.githubusercontent.com/MarxHu/dbauto/cursor/fix-mysql84-temp-password-order-cded/deployments/%E6%95%B0%E6%8D%AE%E5%BA%93%E9%83%A8%E7%BD%B2%E8%84%9A%E6%9C%AC/output/mysql84-gtid-primary-replicas-3node-083102.yaml"
```
