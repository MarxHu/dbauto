# Kafka 注入场景速查

完整命令见 [`KAFKA_FAULT_SCENARIOS.md`](./KAFKA_FAULT_SCENARIOS.md)。排障全场景 127 条见 [`troubleshooting/kafka/KAFKA_FAULT_SCENARIOS.md`](../troubleshooting/kafka/KAFKA_FAULT_SCENARIOS.md)。

```bash
cp config.env.example config.env
./scripts/preflight.sh
./run.sh host --action cpu --target-host 10.10.26.144 --duration 120
./run.sh kafka --action process-stop --node 10.10.26.144:9092 --duration 120
./run.sh network --action packet-loss --target-host 10.10.26.146 --duration 60
./run.sh disk --action io-stress --target-host 10.10.26.144 --duration 120
```
