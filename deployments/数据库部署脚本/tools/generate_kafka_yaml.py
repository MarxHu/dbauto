#!/usr/bin/env python3
"""从 kafka38-kraft-3node 规范生成 SOPS schema v1 YAML（与 Redis 模板结构对齐）。"""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "output" / "kafka38-kraft-3node.yaml"

COMMON_IP_BLOCK = '''
node1=$1; node2=$2; node3=$3
error() { echo "[ERROR][__STAGE__][$target_ip] $*" >&2; exit 1; }
info() { echo "[INFO][__STAGE__][$target_ip] $*"; }
local_ips=$(hostname -I 2>/dev/null) || error "无法读取本机IP"
target_ip=""
for ip in "$node1" "$node2" "$node3"; do
  [[ " $local_ips " == *" $ip "* ]] && target_ip=$ip && break
done
[[ -n "$target_ip" ]] || error "本机IP不在节点列表中: ${node1},${node2},${node3}"
'''.strip()


def ip_block(stage: str) -> str:
    return COMMON_IP_BLOCK.replace("__STAGE__", stage)


def indent_script(body: str) -> str:
    return "\n".join("            " + line for line in body.strip("\n").splitlines())


def activity(node_id, stage_name, script, job_ip_list, job_param, timeout, next_id, can_retry=True):
    return {
        "id": node_id,
        "stage_name": stage_name,
        "script": script,
        "job_ip_list": job_ip_list,
        "job_param": job_param,
        "timeout": timeout,
        "next": next_id,
        "can_retry": can_retry,
    }


stages = []
ids = [f"kafka38-kraft_node{i}" for i in range(2, 12)]

# 1 环境预检
precheck = f'''#!/bin/bash
set -Eeuo pipefail
umask 077
{ip_block("环境预检")}
kafka_port="9092"
controller_port="9093"
nofile_min="65535"
java_min_major="17"
replication_factor=$4
min_insync_replicas=$5
required_commands="java curl tar sha512sum ss pgrep systemctl hostname"
[[ $(id -u) -eq 0 ]] || error "必须由root作业账户执行"
valid_ip() {{
  local ip=$1 part
  [[ "$ip" =~ ^([0-9]{{1,3}}\\.){{3}}[0-9]{{1,3}}$ ]] || return 1
  IFS=. read -r -a parts <<<"$ip"
  for part in "${{parts[@]}}"; do ((part >= 0 && part <= 255)) || return 1; done
}}
for ip in "$node1" "$node2" "$node3"; do valid_ip "$ip" || error "节点IP非法: $ip"; done
[[ "$node1" != "$node2" && "$node1" != "$node3" && "$node2" != "$node3" ]] || error "三节点IP必须互不相同"
(( replication_factor >= 1 && replication_factor <= 3 )) || error "replication.factor=$replication_factor 应为1-3"
(( min_insync_replicas >= 1 && min_insync_replicas < replication_factor )) || error "min.insync.replicas=$min_insync_replicas 必须 < replication.factor=$replication_factor"
java_major=$(java -version 2>&1 | awk -F '[".]' '/version/ {{print $2; exit}}')
[[ -n "$java_major" && "$java_major" -ge "$java_min_major" ]] || error "Java版本不满足 >= $java_min_major"
read -r -a commands <<<"$required_commands"
missing_commands=()
for command in "${{commands[@]}}"; do command -v "$command" >/dev/null 2>&1 || missing_commands+=("$command"); done
((${{#missing_commands[@]}} == 0)) || error "缺少必需命令: ${{missing_commands[*]}}"
for port in "$kafka_port" "$controller_port"; do
  ss -lnt | awk '{{print $4}}' | grep -q ":${{port}}$" && error "端口 ${{port}} 已被占用"
done
current_nofile=$(ulimit -n)
(( current_nofile >= nofile_min )) || error "ulimit -n=${{current_nofile}}，需要 >= ${{nofile_min}}"
pgrep -f 'kafka\\.Kafka' >/dev/null 2>&1 && error "已存在 kafka 进程，请先清理"
info "环境预检通过"
'''
stages.append(activity(ids[0], "环境预检", precheck,
    "${kafka_node_ips}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}' '${kafka_replication_factor}' '${kafka_min_insync_replicas}'",
    "1800", ids[1]))

# 2 内核参数
sysctl = f'''#!/bin/bash
set -Eeuo pipefail
umask 077
{ip_block("内核参数")}
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-kafka.conf <<'EOF'
vm.max_map_count = 262144
vm.swappiness = 1
fs.file-max = 1000000
EOF
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-kafka.conf >/dev/null
current=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
(( current >= 262144 )) || error "vm.max_map_count=${{current}}，需要 >= 262144"
info "sysctl 配置完成"
'''
stages.append(activity(ids[1], "内核参数", sysctl, "${kafka_node_ips}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}'", "600", ids[2]))

# 3 防火墙
firewall = f'''#!/bin/bash
set -Eeuo pipefail
umask 077
{ip_block("防火墙放行")}
kafka_port=$4
controller_port=$5
open_firewall_port() {{
  local port=$1
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${{port}}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    info "firewalld 已放行 ${{port}}/tcp"
  elif command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
    ufw allow "${{port}}/tcp" >/dev/null
    info "ufw 已放行 ${{port}}/tcp"
  else
    info "未检测到 active 的 firewalld/ufw，跳过本地防火墙配置"
  fi
}}
open_firewall_port "$kafka_port"
open_firewall_port "$controller_port"
info "本机防火墙配置完成"
'''
stages.append(activity(ids[2], "防火墙放行", firewall, "${kafka_node_ips}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}' '${kafka_port}' '${kafka_controller_port}'",
    "600", ids[3]))

# 4 安装
install = f'''#!/bin/bash
set -Eeuo pipefail
umask 077
{ip_block("下载解压安装")}
kafka_version=$4
scala_version=$5
tarball_url=$6
tarball_sha512=$7
install_prefix=$8
work_dir="/tmp/kafka-install"
if [[ -x "${{install_prefix}}/bin/kafka-server-start.sh" ]]; then
  info "已安装 ${{install_prefix}}/bin/kafka-server-start.sh，跳过"
  exit 0
fi
mkdir -p "$work_dir" "$(dirname "$install_prefix")"
cd "$work_dir"
tarball="kafka_${{scala_version}}-${{kafka_version}}.tgz"
if [[ ! -f "$tarball" ]]; then
  info "下载 ${{tarball_url}}"
  curl -fsSL "$tarball_url" -o "$tarball"
fi
[[ -n "$tarball_sha512" ]] || error "未配置 tar.gz SHA512"
tarball_sha512=$(echo "${{tarball_sha512}}" | tr '[:upper:]' '[:lower:]')
echo "${{tarball_sha512}}  ${{tarball}}" | sha512sum -c -
rm -rf "kafka_${{scala_version}}-${{kafka_version}}"
tar -xzf "$tarball"
src_dir="kafka_${{scala_version}}-${{kafka_version}}"
[[ -d "$src_dir" ]] || error "解压后目录不存在: $src_dir"
rm -rf "$install_prefix"
mv "$src_dir" "$install_prefix"
[[ -x "${{install_prefix}}/bin/kafka-server-start.sh" ]] || error "install 后缺少 kafka-server-start.sh"
[[ -x "${{install_prefix}}/bin/kafka-storage.sh" ]] || error "install 后缺少 kafka-storage.sh"
info "二进制安装完成: ${{install_prefix}}"
'''
stages.append(activity(ids[3], "下载解压安装", install, "${kafka_node_ips}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}' '${kafka_version}' '${kafka_scala_version}' '${kafka_tarball_url}' '${kafka_tarball_sha512}' '${kafka_install_prefix}'",
    "3600", ids[4]))

# 5 配置
configure = f'''#!/bin/bash
set -Eeuo pipefail
umask 077
{ip_block("生成配置与systemd")}
kafka_version=$4
install_prefix=$5
kafka_port=$6
controller_port=$7
replication_factor=$8
min_insync_replicas=$9
kafka_heap_opts=${{10}}
conf_dir="/etc/kafka"
data_dir="/var/lib/kafka/data"
log_dir="/var/log/kafka"
node_id=""
case "$target_ip" in
  "$node1") node_id=1 ;;
  "$node2") node_id=2 ;;
  "$node3") node_id=3 ;;
  *) error "本机IP不在节点列表中" ;;
esac
voters="1@${{node1}}:${{controller_port}},2@${{node2}}:${{controller_port}},3@${{node3}}:${{controller_port}}"
mkdir -p "$conf_dir" "$data_dir" "$log_dir"
cat > "${{conf_dir}}/server.properties" <<EOF
process.roles=broker,controller
node.id=${{node_id}}
controller.quorum.voters=${{voters}}
listeners=PLAINTEXT://${{target_ip}}:${{kafka_port}},CONTROLLER://${{target_ip}}:${{controller_port}}
advertised.listeners=PLAINTEXT://${{target_ip}}:${{kafka_port}}
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
inter.broker.listener.name=PLAINTEXT
controller.listener.names=CONTROLLER
num.network.threads=8
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=${{data_dir}}
num.partitions=3
num.recovery.threads.per.data.dir=1
offsets.topic.replication.factor=${{replication_factor}}
transaction.state.log.replication.factor=${{replication_factor}}
transaction.state.log.min.isr=${{min_insync_replicas}}
default.replication.factor=${{replication_factor}}
min.insync.replicas=${{min_insync_replicas}}
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
group.initial.rebalance.delay.ms=0
auto.create.topics.enable=false
delete.topic.enable=true
EOF
cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka ${{kafka_version}} KRaft Node
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Group=root
Environment=LOG_DIR=${{log_dir}}
Environment=KAFKA_HEAP_OPTS=${{kafka_heap_opts}}
ExecStart=${{install_prefix}}/bin/kafka-server-start.sh ${{conf_dir}}/server.properties
ExecStop=/bin/kill -TERM \\$MAINPID
Restart=always
RestartSec=5
LimitNOFILE=65535
TimeoutStartSec=180
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable kafka
info "配置写入 ${{conf_dir}}/server.properties (node.id=${{node_id}})"
'''
stages.append(activity(ids[4], "生成配置与systemd", configure, "${kafka_node_ips}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}' '${kafka_version}' '${kafka_install_prefix}' '${kafka_port}' '${kafka_controller_port}' '${kafka_replication_factor}' '${kafka_min_insync_replicas}' '${kafka_heap_opts}'",
    "600", ids[5]))

# 6 format
format_s = f'''#!/bin/bash
set -Eeuo pipefail
umask 077
{ip_block("KRaft存储格式化")}
install_prefix=$4
cluster_id=$5
conf_dir="/etc/kafka"
storage_sh="${{install_prefix}}/bin/kafka-storage.sh"
[[ -x "$storage_sh" ]] || error "缺少 kafka-storage.sh"
[[ -f "${{conf_dir}}/server.properties" ]] || error "缺少 ${{conf_dir}}/server.properties"
data_dir=$(grep -E '^log\\.dirs=' "${{conf_dir}}/server.properties" | cut -d= -f2- | tr -d ' ')
[[ -n "$data_dir" ]] || error "server.properties 缺少 log.dirs"
if [[ -f "${{data_dir}}/meta.properties" ]]; then
  info "存储已格式化，跳过"
  exit 0
fi
"$storage_sh" format -t "$cluster_id" -c "${{conf_dir}}/server.properties" --ignore-formatted
[[ -f "${{data_dir}}/meta.properties" ]] || error "格式化后缺少 meta.properties"
info "KRaft 存储格式化完成"
'''
stages.append(activity(ids[5], "KRaft存储格式化", format_s, "${kafka_node_ips}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}' '${kafka_install_prefix}' '${kafka_cluster_id}'",
    "600", ids[6]))

# 7 start
start = f'''#!/bin/bash
set -Eeuo pipefail
umask 077
{ip_block("启动kafka")}
systemctl restart kafka
sleep 5
systemctl is-active --quiet kafka || error "kafka.service 未 active"
info "kafka.service active"
'''
stages.append(activity(ids[6], "启动kafka", start, "${kafka_node_ips}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}'", "600", ids[7]))

# 8 wait - node1 only
wait_nodes = '''#!/bin/bash
set -Eeuo pipefail
umask 077
node1=$1; node2=$2; node3=$3
install_prefix=$4
kafka_port=$5
controller_port=$6
wait_timeout_sec=$7
kafka_broker_api="${install_prefix}/bin/kafka-broker-api-versions.sh"
error() { echo "[ERROR][等待全部节点就绪] $*" >&2; exit 1; }
info() { echo "[INFO][等待全部节点就绪] $*"; }
[[ -x "$kafka_broker_api" ]] || error "缺少 $kafka_broker_api"
wait_port() {
  local host=$1 port=$2
  local deadline=$((SECONDS + wait_timeout_sec))
  while (( SECONDS < deadline )); do
    timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null && { info "${host}:${port} 端口可达"; return 0; }
    sleep 2
  done
  error "等待 ${host}:${port} 超时 (${wait_timeout_sec}s)"
}
wait_broker_api() {
  local host=$1 bootstrap="${host}:${kafka_port}"
  local deadline=$((SECONDS + wait_timeout_sec))
  while (( SECONDS < deadline )); do
    "$kafka_broker_api" --bootstrap-server "$bootstrap" >/dev/null 2>&1 && { info "${bootstrap} Broker API 就绪"; return 0; }
    sleep 3
  done
  error "等待 ${bootstrap} Broker API 超时 (${wait_timeout_sec}s)"
}
for node in "$node1" "$node2" "$node3"; do
  wait_port "$node" "$kafka_port"
  wait_port "$node" "$controller_port"
done
for node in "$node1" "$node2" "$node3"; do
  wait_broker_api "$node"
done
info "全部节点已就绪"
'''
stages.append(activity(ids[7], "等待全部节点就绪", wait_nodes, "${kafka_node1_ip}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}' '${kafka_install_prefix}' '${kafka_port}' '${kafka_controller_port}' '${kafka_wait_timeout_sec}'",
    "1800", ids[8]))

# 9 bootstrap topic
bootstrap = '''#!/bin/bash
set -Eeuo pipefail
umask 077
node1=$1
install_prefix=$2
kafka_port=$3
topic_name=$4
replication_factor=$5
partitions=$6
kafka_topics="${install_prefix}/bin/kafka-topics.sh"
bootstrap="${node1}:${kafka_port}"
error() { echo "[ERROR][创建验收Topic] $*" >&2; exit 1; }
info() { echo "[INFO][创建验收Topic] $*"; }
if "$kafka_topics" --bootstrap-server "$bootstrap" --list 2>/dev/null | grep -qx "$topic_name"; then
  info "Topic ${topic_name} 已存在，跳过"
  exit 0
fi
"$kafka_topics" --bootstrap-server "$bootstrap" \
  --create --topic "$topic_name" \
  --partitions "$partitions" \
  --replication-factor "$replication_factor" \
  --if-not-exists
info "Topic ${topic_name} 创建完成"
'''
stages.append(activity(ids[8], "创建验收Topic", bootstrap, "${kafka_node1_ip}",
    "'${kafka_node1_ip}' '${kafka_install_prefix}' '${kafka_port}' '${kafka_verify_topic}' '${kafka_replication_factor}' '${kafka_partitions}'",
    "1800", ids[9], can_retry=False))

# 10 verify
verify = '''#!/bin/bash
set -Eeuo pipefail
umask 077
node1=$1; node2=$2; node3=$3
install_prefix=$4
kafka_port=$5
topic_name=$6
replication_factor=$7
bootstrap="${node1}:${kafka_port}"
kafka_topics="${install_prefix}/bin/kafka-topics.sh"
kafka_producer="${install_prefix}/bin/kafka-console-producer.sh"
kafka_consumer="${install_prefix}/bin/kafka-console-consumer.sh"
kafka_broker_api="${install_prefix}/bin/kafka-broker-api-versions.sh"
error() { echo "[ERROR][部署验收] $*" >&2; exit 1; }
info() { echo "[INFO][部署验收] $*"; }
"$kafka_broker_api" --bootstrap-server "$bootstrap" >/dev/null
describe=$("$kafka_topics" --bootstrap-server "$bootstrap" --describe --topic "$topic_name")
printf '%s\n' "$describe"
echo "$describe" | grep -q "Topic: ${topic_name}" || error "Topic ${topic_name} 不存在"
echo "$describe" | grep -q "ReplicationFactor: ${replication_factor}" || error "副本因子不符合期望 ${replication_factor}"
test_msg="sops-kafka-verify-$(date +%s)"
printf '%s\n' "$test_msg" | "$kafka_producer" --bootstrap-server "$bootstrap" --topic "$topic_name" >/dev/null
consumed=$("$kafka_consumer" --bootstrap-server "$bootstrap" --topic "$topic_name" --from-beginning --max-messages 1 --timeout-ms 15000 2>/dev/null | tail -n1)
[[ "$consumed" == "$test_msg" ]] || error "消费验收失败: got=${consumed}"
for node in "$node1" "$node2" "$node3"; do
  timeout 5 bash -c "echo >/dev/tcp/${node}/${kafka_port}" || error "节点 ${node}:${kafka_port} 不可达"
done
info "验收通过"
'''
stages.append(activity(ids[9], "部署验收", verify, "${kafka_node1_ip}",
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}' '${kafka_install_prefix}' '${kafka_port}' '${kafka_verify_topic}' '${kafka_replication_factor}'",
    "600", "kafka38-kraft_node12"))

lines = [
    "---",
    "schema_version: v1",
    "meta:",
    "  name: Kafka KRaft三节点高可用部署",
    "  id: kafka38-kraft",
    "  description: 二进制安装Apache Kafka 3.8.1 KRaft三节点（broker+controller合一），副本因子3，min.insync.replicas=2；经本地模拟验证。",
    "spec:",
    "  nodes:",
    "  - id: kafka38-kraft_node1",
    "    type: EmptyStartEvent",
    "    next:",
    "    - kafka38-kraft_node2",
]

for st in stages:
    lines += [
        f"  - id: {st['id']}",
        "    type: ServiceActivity",
        "    name: 快速执行脚本",
        f"    stage_name: {st['stage_name']}",
        "    component:",
        "      code: job_fast_execute_script",
        "      version: v1.2",
        "      data:",
        "        biz_cc_id:",
        "          name: 业务",
        "          value: ''",
        "          key: \"${biz_cc_id}\"",
        "          version: v1.2",
        "          source_tag: job_fast_execute_script.biz_cc_id",
        "        job_account:",
        "          value: root",
        "        job_content:",
        "          value: |",
        indent_script(st["script"]),
        "        job_ip_list:",
        f"          value: \"{st['job_ip_list']}\"",
        "        job_rolling_config:",
        "          value:",
        "            job_rolling_execute: []",
        "            job_rolling_expression: ''",
        "            job_rolling_mode: 1",
        "        job_script_list_general:",
        "          value: ''",
        "        job_script_list_public:",
        "          value: ''",
        "        job_script_param:",
        f"          value: {st['job_param']}",
        "        job_script_source:",
        "          value: manual",
        "        job_script_timeout:",
        f"          value: '{st['timeout']}'",
        "        job_script_type:",
        "          value: '1'",
        "        job_success_id:",
        "          value: ''",
        "    auto_retry:",
        "      enable: false",
        "      times: 1",
        "      interval: 0",
        "    ignore_error: false",
        f"    can_retry: {str(st['can_retry']).lower()}",
        "    can_skip: false",
        "    optional: false",
        "    next:",
        f"    - {st['next']}",
    ]

lines += [
    "  - id: kafka38-kraft_node12",
    "    type: EmptyEndEvent",
    "  constants:",
]

constants = [
    ("kafka_node1_ip", "Kafka节点1 IP", "10.10.26.144", "^[0-9.]+$"),
    ("kafka_node2_ip", "Kafka节点2 IP", "10.10.26.145", "^[0-9.]+$"),
    ("kafka_node3_ip", "Kafka节点3 IP", "10.10.26.146", "^[0-9.]+$"),
    ("kafka_node_ips", "Kafka三节点IP列表", "10.10.26.144,10.10.26.145,10.10.26.146", "^[0-9.,]+$"),
    ("kafka_port", "Broker服务端口", "9092", "^[0-9]+$"),
    ("kafka_controller_port", "KRaft Controller端口", "9093", "^[0-9]+$"),
    ("kafka_version", "Kafka版本", "3.8.1", "^[0-9.]+$"),
    ("kafka_scala_version", "Scala版本", "2.13", "^[0-9.]+$"),
    ("kafka_install_prefix", "二进制安装目录", "/opt/kafka/3.8.1", "^/.+"),
    ("kafka_tarball_url", "Kafka tar.gz下载地址", "https://archive.apache.org/dist/kafka/3.8.1/kafka_2.13-3.8.1.tgz", "^https?://.+"),
    ("kafka_tarball_sha512", "Kafka tar.gz SHA512(小写)", "b43fada353b7dca51c0f90acf594ec1ce06b2344c046d4059d4deab0615e0e3e76e92eccdbdfa1adad1fbde76c5f25e71acd0db013fb4b1778827448b5285edf", "^[0-9a-f]{128}$"),
    ("kafka_cluster_id", "KRaft集群ID", "4L6g3nShT-eMCtK--X86sw", "^[A-Za-z0-9_-]{16,64}$"),
    ("kafka_replication_factor", "默认副本因子", "3", "^[0-9]+$"),
    ("kafka_min_insync_replicas", "最小同步副本数", "2", "^[0-9]+$"),
    ("kafka_heap_opts", "JVM堆内存参数", "-Xms1g -Xmx1g", "^-.+"),
    ("kafka_partitions", "验收Topic分区数", "3", "^[0-9]+$"),
    ("kafka_verify_topic", "验收Topic名称", "deploy-verify", "^[a-zA-Z0-9._-]+$"),
    ("kafka_wait_timeout_sec", "等待节点就绪超时秒", "180", "^[0-9]+$"),
]
for key, name, value, validation in constants:
    lines += [
        f'    "${{{key}}}":',
        f"      name: {name}",
        f"      value: {value}",
        "      type: input",
        f"      validation: {validation}",
    ]

OUT.write_text("\n".join(lines) + "\n")
print(f"Wrote {OUT} ({OUT.stat().st_size} bytes)")
