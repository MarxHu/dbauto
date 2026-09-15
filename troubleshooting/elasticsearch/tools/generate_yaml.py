#!/usr/bin/env python3
"""Generate Elasticsearch 7.x troubleshooting SOPS YAML.

Five-lane collect (ignore_error) → cleanse Markdown → AI last node (fail closed).
Scripts are bundled so nodes do not need the git tree.
Timeouts follow the 5-minute design, not Kafka 600–900s.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / "troubleshooting" / "elasticsearch" / "scripts"
OUT_DIR = ROOT / "troubleshooting" / "elasticsearch"
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
    es_lib = (SCRIPTS / "es_lib.py").read_text()
    src = (SCRIPTS / name).read_text()
    lines = []
    for line in src.splitlines():
        if line.strip() in LIB_SOURCE_SNIPPETS:
            continue
        if line.startswith("SCRIPT_DIR="):
            continue
        lines.append(line)
    body = "\n".join(lines)
    shebang = "#!/usr/bin/env bash"
    rest = "\n".join(body.splitlines()[1:]) if body.startswith("#!") else body
    return (
        f"{shebang}\n"
        "mkdir -p /tmp/es-ts-lib\n"
        "cat > /tmp/es-ts-lib/es_lib.py <<'ES_TS_LIB_PY'\n"
        f"{es_lib}"
        "ES_TS_LIB_PY\n"
        f"{lib_body}\n"
        f"{rest}\n"
    )


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
    "'${es_node1_ip}' '${es_node2_ip}' '${es_node3_ip}' "
    "'${es_http_port}' '${es_transport_port}' '${ts_run_id}' "
    "'${es_user}' '${es_pass}'"
)
LOGS_PARAM = COLLECT_PARAM + " '${es_log_dir}' '${ts_log_window_lines}'"
HOST_PARAM = COLLECT_PARAM + " '${es_data_dir}'"
CLEAN_PARAM = (
    "'${es_node1_ip}' '${es_node2_ip}' '${es_node3_ip}' "
    "'${es_http_port}' '${es_transport_port}' '${ts_run_id}' "
    "'${ts_profile}' '${es_user}' '${es_pass}'"
)
AI_PARAM = (
    "'${es_node1_ip}' '${es_node2_ip}' '${es_node3_ip}' "
    "'${es_http_port}' '${es_transport_port}' '${ts_run_id}' "
    "'${ts_profile}' '${es_ai_endpoint}' '${es_user}' '${es_pass}'"
)


def constants_block() -> list[str]:
    constants = [
        ("es_node1_ip", "ES节点1 IP", "10.10.26.144", "^[0-9.]+$"),
        ("es_node2_ip", "ES节点2 IP", "10.10.26.145", "^[0-9.]+$"),
        ("es_node3_ip", "ES节点3 IP", "10.10.26.146", "^[0-9.]+$"),
        ("es_node_ips", "ES三节点IP列表", "10.10.26.144,10.10.26.145,10.10.26.146", "^[0-9.,]+$"),
        ("es_http_port", "HTTP端口", "9200", "^[0-9]+$"),
        ("es_transport_port", "Transport端口", "9300", "^[0-9]+$"),
        ("es_data_dir", "path.data", "/var/lib/elasticsearch", "^/.+"),
        ("es_log_dir", "日志目录", "/var/log/elasticsearch", "^/.+"),
        ("es_user", "可选basic用户(可空)", "", ".*"),
        ("es_pass", "可选basic密码(可空,勿提交Git)", "", ".*"),
        ("ts_run_id", "排障流水号", "manual", "^[A-Za-z0-9._-]+$"),
        ("ts_log_window_lines", "日志抽取行数", "8000", "^[0-9]+$"),
        ("ts_profile", "流程版本", "v2", "^(v1|v2|v2-degraded)$"),
        ("es_ai_endpoint", "AI诊断HTTP端点(必填,失败则AI节点失败)", "", ".*"),
        ("ts_artifact_dir", "采集产物目录", "/tmp/es-troubleshoot", "^/.+"),
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


def render() -> str:
    pre = "es-ts_precheck"
    p_metrics, p_status, p_config, p_logs, p_host = (
        "es-ts_metrics",
        "es-ts_status",
        "es-ts_config",
        "es-ts_logs",
        "es-ts_hostnet",
    )
    converge = "es-ts_converge"
    gw = "es-ts_coverage_gw"
    clean, deg, ai, end = "es-ts_clean", "es-ts_clean_degraded", "es-ts_ai", "es-ts_end"
    lines = [
        "---",
        "schema_version: v1",
        "meta:",
        "  name: Elasticsearch 7.x三节点排障（五路采集-清洗Markdown-AI）",
        "  id: elasticsearch717-troubleshoot",
        "  description: >",
        "    5分钟排障 Bot：预检 + 并行采集指标/运行状态/配置/日志/主机网络，",
        "    清洗交叉对比后写出 summary.md。AI 为最后节点，异常则该节点失败。",
        "    采集 ignore_error；AI 不 ignore_error。只诊断不变更、不注入。",
        "    无共享盘时请作业平台拼接 ###ES_TS_ARTIFACT，或用 scripts/run_flow.sh 汇聚到清洗节点。",
        "    超时禁止复用 Kafka 600–900s：预检30s 采集120s 清洗60s AI60s。",
        "spec:",
        "  nodes:",
        "  - id: es-ts_start",
        "    type: EmptyStartEvent",
        "    next:",
        f"    - {pre}",
    ]
    lines += activity_block(
        pre, "采集预检", bundle("collect_precheck.sh"),
        "${es_node_ips}", COLLECT_PARAM, "30", "es-ts_parallel", ignore_error=True,
    )
    lines += [
        "  - id: es-ts_parallel",
        "    type: ParallelGateway",
        "    name: 五路并行采集",
        "    next:",
        f"    - {p_metrics}",
        f"    - {p_status}",
        f"    - {p_config}",
        f"    - {p_logs}",
        f"    - {p_host}",
    ]
    lines += activity_block(
        p_metrics, "采集ES指标(本地stats+主节点health)", bundle("collect_metrics.sh"),
        "${es_node_ips}", COLLECT_PARAM, "120", converge, ignore_error=True,
    )
    lines += activity_block(
        p_status, "采集运行状态(本地master+explain抽样)", bundle("collect_status.sh"),
        "${es_node_ips}", COLLECT_PARAM, "120", converge, ignore_error=True,
    )
    lines += activity_block(
        p_config, "采集配置关键项", bundle("collect_config.sh"),
        "${es_node_ips}", COLLECT_PARAM, "120", converge, ignore_error=True,
    )
    lines += activity_block(
        p_logs, "过滤日志(关键字映射)", bundle("collect_logs.sh"),
        "${es_node_ips}", LOGS_PARAM, "120", converge, ignore_error=True,
    )
    lines += activity_block(
        p_host, "采集主机网络(9200/9300分端口)", bundle("collect_hostnet.sh"),
        "${es_node_ips}", HOST_PARAM, "120", converge, ignore_error=True,
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
    lines += activity_block(
        clean, "数据清洗与交叉对比(Markdown)", bundle("cleanse_artifacts.sh"),
        "${es_node1_ip}", CLEAN_PARAM.replace("${ts_profile}", "v2"), "60", ai, ignore_error=True,
    )
    lines += activity_block(
        deg, "降级清洗(Markdown)", bundle("cleanse_artifacts.sh"),
        "${es_node1_ip}", CLEAN_PARAM.replace("${ts_profile}", "v2-degraded"), "60", ai, ignore_error=True,
    )
    lines += activity_block(
        ai, "AI诊断分析(失败则本节点失败)", bundle("ai_diagnose.sh"),
        "${es_node1_ip}", AI_PARAM.replace("${ts_profile}", "v2"), "60", end,
        ignore_error=False,
    )
    lines += [
        f"  - id: {end}",
        "    type: EmptyEndEvent",
        "  constants:",
    ]
    lines += constants_block()
    return "\n".join(lines) + "\n"


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    DEPLOY_OUT.mkdir(parents=True, exist_ok=True)
    yaml_text = render()
    for folder in (OUT_DIR, DEPLOY_OUT):
        (folder / "elasticsearch717-troubleshoot.yaml").write_text(yaml_text)
    print(f"bytes={len(yaml_text)}")
    print(f"wrote {OUT_DIR}/elasticsearch717-troubleshoot.yaml")
    print(f"wrote {DEPLOY_OUT}/elasticsearch717-troubleshoot.yaml")


if __name__ == "__main__":
    main()
