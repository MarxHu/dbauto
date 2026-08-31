# mysql84-gtid-primary-replicas-3node-083102 修复与加固说明

## 1. 临时密码阶段（ERROR 1820）

临时密码登录后须先 `ALTER USER`，再执行其它 SQL。

```sql
ALTER USER 'root'@'localhost' IDENTIFIED BY '{{ root_password }}';
SET SESSION sql_log_bin = 0;
SELECT @@global.gtid_executed;
```

## 2. 从库复制认证（ERROR 2061）

无 SSL 复制时，`CHANGE REPLICATION SOURCE TO` 须加 `GET_SOURCE_PUBLIC_KEY=1`。

## 3. 从库只读保护

从库须设置：

```sql
SET GLOBAL read_only = ON;
SET GLOBAL super_read_only = ON;
```

并在 `my.cnf` 持久化 `read_only=1`、`super_read_only=1`，防止重启后从库可写。

## 4. 半同步复制

| 节点 | 插件 | 运行时变量 |
|------|------|-----------|
| 主库 11 | `rpl_semi_sync_source` | `rpl_semi_sync_source_enabled=ON` |
| 从库 12/13 | `rpl_semi_sync_replica` | `rpl_semi_sync_replica_enabled=ON` |

启用顺序：**先从库、后主库**（避免主库开启半同步时无从库 ACK）。

参数（可在 YAML `parameters` 调整）：

- `semi_sync_wait_replica_count`：默认 `1`（一主两从至少等 1 台 ACK）
- `semi_sync_timeout_ms`：默认 `10000`

## 5. 已有环境手工加固（不必重建）

若复制已通但保护未配，在 **12/13** 执行：

```sql
INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';
SET GLOBAL rpl_semi_sync_replica_enabled = ON;
SET GLOBAL read_only = ON;
SET GLOBAL super_read_only = ON;
```

在 **11** 执行：

```sql
INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';
SET GLOBAL rpl_semi_sync_source_wait_for_replica_count = 1;
SET GLOBAL rpl_semi_sync_source_timeout = 10000;
SET GLOBAL rpl_semi_sync_source_enabled = ON;
```

验收：

```sql
-- 从库：应 ON / ON / ON
SELECT @@read_only, @@super_read_only, @@rpl_semi_sync_replica_enabled;

-- 主库：半同步 ON，且 2 条复制连接
SELECT @@rpl_semi_sync_source_enabled;
SELECT COUNT(*) FROM performance_schema.replication_connection_status WHERE SERVICE_STATE='ON';
```

## 文件位置与下载

- 仓库路径：`deployments/数据库部署脚本/output/mysql84-gtid-primary-replicas-3node-083102.yaml`
- 直接下载（PR 分支 raw）：
  https://raw.githubusercontent.com/MarxHu/dbauto/cursor/fix-mysql84-temp-password-order-cded/deployments/%E6%95%B0%E6%8D%AE%E5%BA%93%E9%83%A8%E7%BD%B2%E8%84%9A%E6%9C%AC/output/mysql84-gtid-primary-replicas-3node-083102.yaml
