# mysql84-gtid-primary-replicas-3node-083102 修复说明

## 问题

MySQL 8.4 使用临时 root 密码登录后，会话处于 **must change password** 状态，除 `ALTER USER` 外其它语句均会报：

```
ERROR 1820 (HY000): You must reset your password using ALTER USER statement before executing this statement.
```

## 修复（临时密码阶段 SQL 顺序）

**错误顺序（修复前）：**

```sql
SELECT @@global.gtid_executed;
SET SESSION sql_log_bin = 0;
ALTER USER 'root'@'localhost' IDENTIFIED BY '{{ root_password }}';
```

**正确顺序（修复后）：**

```sql
ALTER USER 'root'@'localhost' IDENTIFIED BY '{{ root_password }}';
SET SESSION sql_log_bin = 0;
SELECT @@global.gtid_executed;
```

## 参数

使用 YAML `parameters.root_password`（或你本地模板中的等价变量）作为 `ALTER USER` 的目标密码。

## 问题 2：从库复制 IO 报 2061

MySQL 8 默认复制用户认证插件为 `caching_sha2_password`。复制链路未启用 SSL 时，从库 IO 线程会报：

```
ERROR 2061 (HY000): Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection.
```

## 修复（从库 CHANGE REPLICATION SOURCE TO）

在 `CHANGE REPLICATION SOURCE TO` 中增加 `GET_SOURCE_PUBLIC_KEY=1`，让从库向主库索取 RSA 公钥完成密码认证：

```sql
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='172.30.0.11',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='...',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;
```

## 文件位置与下载

- 仓库路径：`deployments/数据库部署脚本/output/mysql84-gtid-primary-replicas-3node-083102.yaml`
- 直接下载（PR 分支 raw）：
  https://raw.githubusercontent.com/MarxHu/dbauto/cursor/fix-mysql84-temp-password-order-cded/deployments/%E6%95%B0%E6%8D%AE%E5%BA%93%E9%83%A8%E7%BD%B2%E8%84%9A%E6%9C%AC/output/mysql84-gtid-primary-replicas-3node-083102.yaml

## 重跑

虚机可保留；若上次卡在改密前，用修复后的 YAML 直接重跑即可。
