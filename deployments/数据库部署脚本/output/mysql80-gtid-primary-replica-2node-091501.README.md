# mysql80-gtid-primary-replica-2node-091501

MySQL **8.0.42** GTID **一主一从**（2 节点）SOPS 部署 YAML。

## 拓扑

| IP | 角色 | server_id |
|----|------|-----------|
| 172.30.0.11 | primary | 11 |
| 172.30.0.12 | replica | 12 |

## 必填参数

```yaml
root_password: "<root目标密码>"
repl_password: "<复制账号密码>"
# repl_user 默认 repl
# semi_sync_wait_replica_count 默认 1
# semi_sync_timeout_ms 默认 10000
```

## 前置条件

- 两台空机（建议 CentOS 7.9 + systemd），无残留 MySQL/MariaDB
- 可访问 8.0.42 RPM 源（由 SOPS `install_mysql_rpm` 拉取）
- `.12` 能连 `.11:3306`

## 阶段顺序（不可打乱）

1. 环境预检 → 安装 RPM  
2. 补 `!includedir` → 写 GTID cnf（**不含半同步**）→ init → 启动  
3. **临时密码改密**（仅 `ALTER USER`）  
4. 启动后验收 `gtid_mode` / `server_id` / `version`  
5. 主库建 `repl` → 从库 `CHANGE REPLICATION SOURCE` + `START REPLICA`  
6. 断言复制就绪 → 装半同步 + 从库只读  
7. 部署验收  

## 合格标准

- 主：`gtid_mode=ON`、半同步 ON、1 条 Binlog Dump  
- 从：IO/SQL=ON、`read_only=1`、`super_read_only=1`、半同步 ON  

## 文件

- YAML：`mysql80-gtid-primary-replica-2node-091501.yaml`
