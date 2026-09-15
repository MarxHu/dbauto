# MySQL 故障注入节点规范（对齐 Redis lab）

注入机 `docker-node` + 三台容器模拟 VM（一主两从）。

| 容器 | IP | 角色 | 必装 |
|---|---|---|---|
| mysql-n1 | 10.10.26.144 | primary | stress-ng vmstat chmod dd iptables tc mysqld |
| mysql-n2 | 10.10.26.145 | replica | 同上 |
| mysql-n3 | 10.10.26.146 | replica | 同上 |
| docker-node | 10.10.26.10 | 注入机 | mysql 客户端 flock bash≥4 docker CLI |

容器：`mem_limit=1536m`、`NET_ADMIN`、datadir 非 tmpfs。丢包场景宿主机 `modprobe sch_netem`。
