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

## 重跑

虚机可保留；若上次卡在改密前，用修复后的 YAML 直接重跑即可。
