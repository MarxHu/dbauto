# dbauto

数据库自动化相关工具与脚本。

## Redis Cluster 故障注入

完整说明、场景命令、Bot 协作方式：

- **文档**： [redis_fault_injection/README.md](./redis_fault_injection/README.md)
- **环境前提**： [redis_fault_injection/PREREQUISITES.md](./redis_fault_injection/PREREQUISITES.md)
- **场景速查**： [redis_fault_injection/SCENARIOS.md](./redis_fault_injection/SCENARIOS.md)

快速开始：

```bash
git clone https://github.com/MarxHu/dbauto.git
cd dbauto/redis_fault_injection
cp config.env.example config.env   # 填入 REDIS_PASSWORD，勿提交
./scripts/preflight.sh
./scripts/inject_host.sh --action cpu --duration 600
```
