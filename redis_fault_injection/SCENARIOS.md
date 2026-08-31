# Redis Cluster 故障注入场景总表

> 环境默认：`10.10.26.144:6381`、`10.10.26.145:6381`、`10.10.26.146:6381`  
> 使用前：`cp config.env.example config.env` 并按实验室改参数  
> 通用约定：
> - 持续型故障建议 `DURATION=240`（≥4 分钟，覆盖诊断采集+30s 差分）
> - 远端注入：`TARGET_HOST=<节点IP>`（脚本经 SSH 在该机执行）
> - 恢复：同一脚本加 `recover` 子命令

## 一、基线与恢复

| ID | 场景 | 等级 | 注入脚本 | 恢复脚本 | 预期诊断信号 |
|---|---|---|---|---|---|
| F01 | 正常基线 | L1 | `./scripts/F01_baseline_check.sh` | 无需 | 无当前 CPU/内存索引；历史累计仅 context |
| F02 | 主机 CPU 持续高压 | L1 | `TARGET_HOST=10.10.26.144 DURATION=240 ./scripts/F02_host_cpu_stress.sh inject` | `./scripts/F02_host_cpu_stress.sh recover` | `host_cpu_used_pct_avg>=80`，主问题 host_resource |
| F03 | CPU 恢复 | L1 | 无（停止 F02 即可） | `TARGET_HOST=10.10.26.144 ./scripts/F02_host_cpu_stress.sh recover` | 不再生成 CPU 活动索引 |
| F04 | 主机内存压力 | L1 | `TARGET_HOST=10.10.26.144 DURATION=240 ./scripts/F04_host_memory_stress.sh inject` | `./scripts/F04_host_memory_stress.sh recover` | `memory_available_pct<=15`，主问题 host_resource |
| F05 | 内存恢复 | L1 | 无 | `TARGET_HOST=10.10.26.144 ./scripts/F04_host_memory_stress.sh recover` | 不再输出当前内存压力 |
| F06 | CPU 瞬时尖峰 | L2 | `TARGET_HOST=10.10.26.144 DURATION=240 ./scripts/F06_host_cpu_spike.sh inject` | `./scripts/F06_host_cpu_spike.sh recover` | max>=80 且 avg<80，通常进关注 |

## 二、Redis 进程与配置

| ID | 场景 | 等级 | 注入脚本 | 恢复脚本 | 预期诊断信号 |
|---|---|---|---|---|---|
| F07 | Redis 进程停止 | L1 | `NODE=10.10.26.144:6381 ./scripts/F07_redis_process_stop.sh inject` | `NODE=10.10.26.144:6381 ./scripts/F07_redis_process_stop.sh recover` | 进程/端口/PING/Cluster 连续性 S1 |
| F08 | Redis 进程恢复 | L1 | 无 | 同 F07 recover | 节点恢复后 Cluster 视图正常 |
| F09 | 主机重启 | L1 | `CONFIRM=YES TARGET_HOST=10.10.26.144 ./scripts/F09_host_reboot.sh inject` | 等待主机起来后跑诊断 | JOB 缺失/not_received + 节点不可用链 |
| F10 | Redis maxmemory/OOM 写拒绝 | L1 | `NODE=10.10.26.144:6381 MAXMEMORY=64mb DURATION=240 ./scripts/F10_redis_maxmemory_limit.sh inject` | `NODE=... ./scripts/F10_redis_maxmemory_limit.sh recover` | OOM/MISCONF/evicted_keys，S2 |
| F11 | maxmemory 恢复 | L1 | 无 | 同 F10 recover | 写拒绝消失 |
| F12 | 连接数打满 maxclients | L1 | `NODE=10.10.26.144:6381 MAXCLIENTS=10 DURATION=240 ./scripts/F12_redis_clients_limit.sh inject` | `NODE=... ./scripts/F12_redis_clients_limit.sh recover` | rejected_connections 30s 增量>0 |
| F13 | maxclients 恢复 | L1 | 无 | 同 F12 recover | 连接拒绝消失 |
| F14 | 慢命令 | L1 | `NODE=10.10.26.144:6381 DURATION=240 ./scripts/F14_redis_slow_command.sh inject` | `./scripts/F14_redis_slow_command.sh recover` | 15min slowlog 有明确条目 |
| F15 | 热 Key / 热分片 | L2 | `NODE=10.10.26.145:6381 DURATION=240 ./scripts/F15_redis_hot_key.sh inject` | `./scripts/F15_redis_hot_key.sh recover` | Redis 进程 CPU/延迟，L2 可接受 |
| F16 | 大 Key 线索 | L2 | `NODE=10.10.26.145:6381 ./scripts/F16_redis_big_key_seed.sh inject` | `./scripts/F16_redis_big_key_seed.sh recover` | 内存/慢命令/大 Key 线索 |

## 三、缓存语义（对齐 ChaosBlade/ChaosMesh）

| ID | 场景 | 等级 | 注入脚本 | 恢复脚本 | 说明 |
|---|---|---|---|---|---|
| F17 | Key 过期 / 冷缓存 | 应用向 | `NODE=10.10.26.144:6381 KEY=mykey ./scripts/F17_redis_cache_expire.sh inject` | 应用重建缓存 | 测缓存 miss 风暴，不是 Redis 宕机 |
| F18 | 缓存穿透 | 应用向 | `NODE=10.10.26.144:6381 REQUEST_COUNT=100000 DURATION=60 ./scripts/F18_redis_cache_penetration.sh inject` | `./scripts/F18_redis_cache_penetration.sh recover` | Redis 本身可能健康，下游 DB 承压 |

## 四、协议/客户端错误（V1.2 有界脉冲）

| ID | 场景 | 等级 | 注入脚本 | 预期 |
|---|---|---|---|---|
| F19-NOAUTH | 错误密码脉冲 | L1 | `NODE=10.10.26.146:6381 ERROR_TYPE=NOAUTH ./scripts/F19_redis_error_pulse.sh inject` | errorstats 30s 增量 |
| F19-WRONGPASS | ACL 密码错误 | L1 | `ERROR_TYPE=WRONGPASS ...` | 同上 |
| F19-MOVED | 非 Cluster 客户端访问 | L1 | `ERROR_TYPE=Moved ...` | MOVED/ASK 类增量 |
| F19-CROSSSLOT | 跨 Slot 多键 | L1 | `ERROR_TYPE=CROSSSLOT ...` | CROSSSLOT 增量 |
| F29 | 纯历史 MISCONF 背景 | 背景 | `NODE=10.10.26.146:6381 ./scripts/F29_seed_historical_misconf.sh inject` | 后续诊断应为 historical_inactive |

脉冲参数固定：`PULSE_INTERVAL=5`，`PULSE_MAX=18`（90 秒）。

## 五、网络

| ID | 场景 | 等级 | 注入脚本 | 恢复脚本 | 预期 |
|---|---|---|---|---|---|
| F20 | Cluster Bus 阻断 (16379) | L1 | `NODE=10.10.26.144:6381 ./scripts/F20_network_cluster_bus_block.sh inject` | `./scripts/F20_network_cluster_bus_block.sh recover` | PFAIL/FAIL/视图不一致 |
| F22 | 客户端→Redis 定向丢包 | L2 | `NODE=10.10.26.144:6381 LOSS=30 NET_DEV=eth0 ./scripts/F22_network_client_packet_loss.sh inject` | `./scripts/F22_network_client_packet_loss.sh recover` | 超时/错误，L2 安全首判 |
| F30 | 两 Master 网络分区 | L1 | `NODE_A=10.10.26.144 NODE_B=10.10.26.145 ./scripts/F30_network_master_partition.sh inject` | `./scripts/F30_network_master_partition.sh recover` | 少数派 fail/停写 |

## 六、磁盘与持久化

| ID | 场景 | 等级 | 注入脚本 | 恢复脚本 | 预期 |
|---|---|---|---|---|---|
| F24 | 持久化失败 / MISCONF 链 | L1 | `NODE=10.10.26.146:6381 REDIS_DATA_DIR=/var/lib/redis ./scripts/F24_disk_persistence_fail.sh inject` | `./scripts/F24_disk_persistence_fail.sh recover` | persistence_failure + 写拒绝 |
| F26 | 磁盘 IO 高（无 iostat 场景） | L2 | `TARGET_HOST=10.10.26.144 DURATION=240 ./scripts/F26_disk_io_stress.sh inject` | `./scripts/F26_disk_io_stress.sh recover` | iowait/diskstats 事实 |

## 七、多节点

| ID | 场景 | 等级 | 注入脚本 | 恢复 |
|---|---|---|---|---|
| F28 | 多节点同类 CPU 高 | L1 | `DURATION=240 ./scripts/F28_multi_node_cpu_stress.sh inject` | `./scripts/F28_multi_node_cpu_stress.sh recover` |

## 八、组合场景（V1.2 必测）

| ID | 场景 | 注入脚本 | 期望主次 |
|---|---|---|---|
| C01 | 内存高 + 历史 MISCONF | `./scripts/C01_memory_plus_historical_misconf.sh inject` | 内存主；MISCONF 不展示 |
| C02 | 写拒绝 + CPU 高 | `./scripts/C02_write_reject_plus_cpu.sh inject` | 写拒绝 S2 主；CPU S3 次 |
| C03 | Master 停 + 另一节点内存高 | `./scripts/C03_master_stop_plus_remote_memory.sh inject` | 连续性 S1 主；内存 S3 次 |

## 九、降级/质量场景

| ID | 场景 | 注入脚本 | 期望 |
|---|---|---|---|
| D01 | 单节点 JOB 失联 | `BLOCKED_HOST=10.10.26.146 ./scripts/D01_simulate_job_unreachable.sh inject` | 清洗 not_received，不判 Redis 宕机 |
| D02 | 缺少 iostat/pidstat | `./scripts/D02_hide_iostat_pidstat.sh inject` | /proc 兜底或 collection_issues |
| D03 | K3 临时失败 | 无注入；联调时断 K3 网络或 mock 429 | ai_status=failed，不伪造结论 |

## 十、当前环境不适用（L3）

| ID | 场景 | 说明 |
|---|---|---|
| L3-01 | 复制中断 | 3 Master 无 Replica |
| L3-02 | 自动 Failover | 无 Replica 无法验证 |
| L3-03 | Slot 迁移中断 | 需 resharding/ASM 运维窗口 |

## 十一、推荐执行顺序（联调）

1. F01 基线 ×3  
2. F02/F04 CPU/内存 各 ×2（含 recover）  
3. F07、F10、F12、F14、F20、F24 各 ×1  
4. F19 四类脉冲各 ×1  
5. C01/C02/C03 组合各 ×1  
6. D01/D02/D03 降级各 ×1  

## 十二、脚本与 Chaos 平台对照

| 本仓库脚本 | ChaosBlade | ChaosMesh/Chaosd |
|---|---|---|
| F10 | `blade create redis cache-limit` | `chaosd attack redis cache-limit` |
| F12 | `blade create redis clients-limit` | 无专用（可用连接压测） |
| F15 | `blade create redis cache-hot-key` | 无专用 |
| F17 | `blade create redis cache-expire` | `chaosd attack redis cache-expiration` |
| F18 | 无 | `chaosd attack redis cache-penetration` |
| F02/F04 | `blade create cpu load` / `blade create mem load` | Chaosd pressure |
| F20/F22/F30 | `blade create network delay/loss` | NetworkChaos / 未来 redis-cluster-failure |
| F07 | `blade create process kill` | PodChaos / process kill |

## 十三、权限说明

以下脚本需要 root 或 sudo：

- F09 主机重启
- F20/F22/F30 网络 iptables/tc
- F24 数据目录 chmod
- D01/D02 运维模拟

实验室外请勿直接运行 F09、F17（FLUSHDB）、F29。
