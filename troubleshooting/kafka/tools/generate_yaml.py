#!/usr/bin/env python3
"""Generate Kafka KRaft troubleshooting SOPS YAML (v1 and optimized v2).

Mirrors Redis 排障 Bot 结构: 并行五路采集 → 清洗 → AI 诊断.
Scripts are bundled from troubleshooting/kafka/scripts/ so nodes do not
need the git tree — SOPS job_content is self-contained.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "troubleshooting" / "kafka" / "scripts"
OUT_DIR = ROOT / "troubleshooting" / "kafka"
DEPLOY_OUT = ROOT / "deployments" / "数据库部署脚本" / "output"

LIB_SOURCE_SNIPPETS = (
    'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    '# shellcheck disable=SC1091',
    'source "${SCRIPT_DIR}/_lib.sh"',
)


def bundle(name: str) -> str:
    lib = (SCRIPTS / "_lib.sh").read_text()
    lib_body = "\n".join(
        line for line in lib.splitlines() if not line.startswith("#!")
    )
    src = (SCRIPTS / name).read_text()
    lines = []
    for line in src.splitlines():
        if line.strip() in LIB_SOURCE_SNIPPETS:
            continue
        if line.startswith("SCRIPT_DIR="):
            continue
        lines.append(line)
    body = "\n".join(lines)
    return f"{body.splitlines()[0]}\n{lib_body}\n" + "\n".join(body.splitlines()[1:]) + "\n"


def indent_script(body: str) -> str:
    return "\n".join("            " + line if line else "            " for line in body.strip("\n").splitlines())


def activity_block(
    node_id: str,
    stage_name: str,
    script: str,
    job_ip_list: str,
    job_param: str,
    timeout: str,
    next_id: str,
    *,
    ignore_error: bool = False,
    can_retry: bool = True,
) -> list[str]:
    return [
        f"  - id: {node_id}",
        "    type: ServiceActivity",
        "    name: 快速执行脚本",
        f"    stage_name: {stage_name}",
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
        indent_script(script),
        "        job_ip_list:",
        f"          value: \"{job_ip_list}\"",
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
        f"          value: \"{job_param}\"",
        "        job_script_source:",
        "          value: manual",
        "        job_script_timeout:",
        f"          value: '{timeout}'",
        "        job_script_type:",
        "          value: '1'",
        "        job_success_id:",
        "          value: ''",
        "    auto_retry:",
        "      enable: false",
        "      times: 1",
        "      interval: 0",
        f"    ignore_error: {str(ignore_error).lower()}",
        f"    can_retry: {str(can_retry).lower()}",
        "    can_skip: false",
        "    optional: false",
        "    next:",
        f"    - {next_id}",
    ]


COLLECT_PARAM = (
    "'${kafka_node1_ip}' '${kafka_node2_ip}' '${kafka_node3_ip}' "
    "'${kafka_install_prefix}' '${kafka_port}' '${kafka_controller_port}' "
    "'${ts_run_id}'"
)
METRICS_PARAM = COLLECT_PARAM + " '${kafka_verify_topic}'"
LOGS_PARAM = COLLECT_PARAM + " '${kafka_log_dir}' '${ts_log_window_lines}'"
HOST_PARAM = COLLECT_PARAM + " '${kafka_data_dir}'"
CLEAN_PARAM = COLLECT_PARAM + " '${ts_profile}'"
AI_PARAM = COLLECT_PARAM + " '${ts_profile}' '${kafka_ai_endpoint}'"


def constants_block(profile: str = "v1") -> list[str]:
    constants = [
        ("kafka_node1_ip", "Kafka节点1 IP", "10.10.26.144", "^[0-9.]+$"),
        ("kafka_node2_ip", "Kafka节点2 IP", "10.10.26.145", "^[0-9.]+$"),
        ("kafka_node3_ip", "Kafka节点3 IP", "10.10.26.146", "^[0-9.]+$"),
        ("kafka_node_ips", "Kafka三节点IP列表", "10.10.26.144,10.10.26.145,10.10.26.146", "^[0-9.,]+$"),
        ("kafka_port", "Broker服务端口", "9092", "^[0-9]+$"),
        ("kafka_controller_port", "KRaft Controller端口", "9093", "^[0-9]+$"),
        ("kafka_install_prefix", "二进制安装目录", "/opt/kafka/3.8.1", "^/.+"),
        ("kafka_data_dir", "log.dirs数据目录", "/var/lib/kafka/data", "^/.+"),
        ("kafka_log_dir", "Kafka日志目录", "/var/log/kafka", "^/.+"),
        ("kafka_verify_topic", "探针/验收Topic", "deploy-verify", "^[a-zA-Z0-9._-]+$"),
        ("ts_run_id", "排障流水号", "manual", "^[A-Za-z0-9._-]+$"),
        ("ts_log_window_lines", "日志关键字抽取行数", "800", "^[0-9]+$"),
        ("ts_profile", "流程版本", profile, "^(v1|v2|v2-degraded)$"),
        ("kafka_ai_endpoint", "AI诊断HTTP端点(可空)", "", ".*"),
        ("ts_artifact_dir", "采集产物目录", "/tmp/kafka-troubleshoot", "^/.+"),
    ]
    lines: list[str] = []
    for key, name, value, validation in constants:
        lines += [
            f'    "${{{key}}}":',
            f"      name: {name}",
            f"      value: {value}",
            "      type: input",
            f"      validation: {validation}",
        ]
    return lines


def render_v1() -> str:
    p_metrics, p_config, p_logs, p_host, p_net = (
        "kafka-ts_metrics",
        "kafka-ts_config",
        "kafka-ts_logs",
        "kafka-ts_host",
        "kafka-ts_network",
    )
    converge, clean, ai, end = "kafka-ts_converge", "kafka-ts_clean", "kafka-ts_ai", "kafka-ts_end"
    lines = [
        "---",
        "schema_version: v1",
        "meta:",
        "  name: Kafka KRaft三节点排障（五路采集-清洗-AI）",
        "  id: kafka38-kraft-troubleshoot",
        "  description: >",
        "    参考 Redis 排障 Bot：并行采集监控指标、配置、过滤日志、主机资源、网络，",
        "    汇聚清洗后交给 AI 诊断节点。采集节点 ignore_error，保证故障中仍能进入清洗/AI。",
        "    适用拓扑：KRaft 3.8.1 三节点 broker+controller 合一，RF=3，min.isr=2。",
        "spec:",
        "  nodes:",
        "  - id: kafka-ts_start",
        "    type: EmptyStartEvent",
        "    next:",
        "    - kafka-ts_parallel",
        "  - id: kafka-ts_parallel",
        "    type: ParallelGateway",
        "    name: 五路并行采集",
        "    next:",
        f"    - {p_metrics}",
        f"    - {p_config}",
        f"    - {p_logs}",
        f"    - {p_host}",
        f"    - {p_net}",
    ]
    lines += activity_block(
        p_metrics, "采集监控指标", bundle("collect_metrics.sh"),
        "${kafka_node_ips}", METRICS_PARAM, "600", converge, ignore_error=True,
    )
    lines += activity_block(
        p_config, "采集配置信息", bundle("collect_config.sh"),
        "${kafka_node_ips}", COLLECT_PARAM, "600", converge, ignore_error=True,
    )
    lines += activity_block(
        p_logs, "过滤日志", bundle("collect_logs.sh"),
        "${kafka_node_ips}", LOGS_PARAM, "600", converge, ignore_error=True,
    )
    lines += activity_block(
        p_host, "采集主机资源", bundle("collect_host.sh"),
        "${kafka_node_ips}", HOST_PARAM, "600", converge, ignore_error=True,
    )
    lines += activity_block(
        p_net, "采集主机网络", bundle("collect_network.sh"),
        "${kafka_node_ips}", COLLECT_PARAM, "600", converge, ignore_error=True,
    )
    lines += [
        f"  - id: {converge}",
        "    type: ConvergeGateway",
        "    name: 采集汇聚",
        "    next:",
        f"    - {clean}",
    ]
    lines += activity_block(
        clean, "数据清洗", bundle("cleanse_artifacts.sh"),
        "${kafka_node_ips}", CLEAN_PARAM.replace("${ts_profile}", "v1"), "300", ai, ignore_error=True,
    )
    lines += activity_block(
        ai, "AI诊断分析", bundle("ai_diagnose.sh"),
        "${kafka_node1_ip}", AI_PARAM.replace("${ts_profile}", "v1"), "300", end, ignore_error=True,
    )
    lines += [
        f"  - id: {end}",
        "    type: EmptyEndEvent",
        "  constants:",
    ]
    lines += constants_block("v1")
    return "\n".join(lines) + "\n"


def render_v2() -> str:
    pre = "kafka-ts_precheck"
    p_metrics, p_config, p_logs, p_host, p_net = (
        "kafka-ts_metrics",
        "kafka-ts_config",
        "kafka-ts_logs",
        "kafka-ts_host",
        "kafka-ts_network",
    )
    converge = "kafka-ts_converge"
    gw = "kafka-ts_coverage_gw"
    clean, deg, ai, end = "kafka-ts_clean", "kafka-ts_clean_degraded", "kafka-ts_ai", "kafka-ts_end"
    lines = [
        "---",
        "schema_version: v1",
        "meta:",
        "  name: Kafka KRaft三节点排障优化版（覆盖复盘后）",
        "  id: kafka38-kraft-troubleshoot-v2",
        "  description: >",
        "    基于 KAFKA_FAULT_SCENARIOS.md 复盘：在 v1 五路采集之上增加采集预检、",
        "    采集失败降级清洗、ignore_error 贯穿、信号映射到 KF 场景 ID、KRaft quorum/",
        "    URP/Offline/消费组/log.dirs/JVM/时钟/产消探针。清洗后进入 AI 诊断。",
        "spec:",
        "  nodes:",
        "  - id: kafka-ts_start",
        "    type: EmptyStartEvent",
        "    next:",
        f"    - {pre}",
    ]
    lines += activity_block(
        pre, "采集预检", bundle("collect_precheck.sh"),
        "${kafka_node_ips}", COLLECT_PARAM, "180", "kafka-ts_parallel", ignore_error=True,
    )
    lines += [
        "  - id: kafka-ts_parallel",
        "    type: ParallelGateway",
        "    name: 五路并行采集",
        "    next:",
        f"    - {p_metrics}",
        f"    - {p_config}",
        f"    - {p_logs}",
        f"    - {p_host}",
        f"    - {p_net}",
    ]
    lines += activity_block(
        p_metrics, "采集监控指标(含Quorum/URP/消费组/探针)", bundle("collect_metrics.sh"),
        "${kafka_node_ips}", METRICS_PARAM, "900", converge, ignore_error=True,
    )
    lines += activity_block(
        p_config, "采集配置信息(含min.isr/voters/advertised)", bundle("collect_config.sh"),
        "${kafka_node_ips}", COLLECT_PARAM, "600", converge, ignore_error=True,
    )
    lines += activity_block(
        p_logs, "过滤日志(场景关键字映射)", bundle("collect_logs.sh"),
        "${kafka_node_ips}", LOGS_PARAM, "600", converge, ignore_error=True,
    )
    lines += activity_block(
        p_host, "采集主机与JVM(GC/FD/磁盘/时钟)", bundle("collect_host.sh"),
        "${kafka_node_ips}", HOST_PARAM, "600", converge, ignore_error=True,
    )
    lines += activity_block(
        p_net, "采集网络(9092/9093/分区/qdisc/防火墙)", bundle("collect_network.sh"),
        "${kafka_node_ips}", COLLECT_PARAM, "600", converge, ignore_error=True,
    )
    lines += [
        f"  - id: {converge}",
        "    type: ConvergeGateway",
        "    name: 采集汇聚",
        "    next:",
        f"    - {gw}",
        f"  - id: {gw}",
        "    type: ExclusiveGateway",
        "    name: 采集覆盖判定",
        "    conditions:",
        "    - name: 采集降级",
        "      evaluate: \"${coverage_status} in ['empty','degraded']\"",
        f"      next: {deg}",
        "    - name: 正常清洗",
        "      evaluate: default",
        f"      next: {clean}",
        "    next:",
        f"    - {clean}",
        f"    - {deg}",
    ]
    v2_clean = CLEAN_PARAM.replace("${ts_profile}", "v2")
    v2_deg = CLEAN_PARAM.replace("${ts_profile}", "v2-degraded")
    v2_ai = AI_PARAM.replace("${ts_profile}", "v2")
    lines += activity_block(
        clean, "数据清洗与信号映射", bundle("cleanse_artifacts.sh"),
        "${kafka_node_ips}", v2_clean, "300", ai, ignore_error=True,
    )
    lines += activity_block(
        deg, "降级清洗", bundle("cleanse_artifacts.sh"),
        "${kafka_node_ips}", v2_deg, "300", ai, ignore_error=True,
    )
    lines += activity_block(
        ai, "AI诊断分析", bundle("ai_diagnose.sh"),
        "${kafka_node1_ip}", v2_ai, "300", end, ignore_error=True,
    )
    lines += [
        f"  - id: {end}",
        "    type: EmptyEndEvent",
        "  constants:",
    ]
    lines += constants_block("v2")
    return "\n".join(lines) + "\n"


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    DEPLOY_OUT.mkdir(parents=True, exist_ok=True)
    v1 = render_v1()
    v2 = render_v2()
    for folder in (OUT_DIR, DEPLOY_OUT):
        (folder / "kafka38-kraft-troubleshoot.yaml").write_text(v1)
        (folder / "kafka38-kraft-troubleshoot-v2.yaml").write_text(v2)
    print(f"v1 bytes={len(v1)} v2 bytes={len(v2)}")
    print(f"wrote {OUT_DIR}/kafka38-kraft-troubleshoot.yaml")
    print(f"wrote {OUT_DIR}/kafka38-kraft-troubleshoot-v2.yaml")


if __name__ == "__main__":
    main()
