#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lib/common.sh"

ACTION=""; DURATION=""; NODE=""
TOPIC="${TOPIC:-${FAULT_TOPIC}}"
RECORD_BYTES="${RECORD_BYTES:-2000000}"
MIN_ISR="${MIN_ISR:-3}"
CONN_N="${CONN_N:-200}"
HOT_RATE="${HOT_RATE:-200}"
LAG_MESSAGES="${LAG_MESSAGES:-5000}"

usage() {
  usage_header
  cat <<EOF

Actions (Kafka process / traffic / metadata):
  process-stop       systemctl stop kafka (KF015)
  process-freeze     SIGSTOP kafka JVM (KF016)
  heap-oom           shrink heap + fill (KF017) — best-effort
  gc-storm           stress-ng vm inside cgroup to induce GC (KF018)
  fd-exhaust         open many files toward nofile (KF011)
  quorum-loss        stop 2/3 brokers (KF026)
  isr-shrink         stop one broker, expect URP (KF039/KF036)
  min-isr-breach     set topic min.isr high (KF044/KF053)
  bad-min-isr        min.insync.replicas >= RF (KF101)
  hot-partition      hammer partition 0 (KF047)
  unknown-topic      produce to missing topic (KF050)
  oversized-record   produce huge payload (KF055)
  consumer-lag       produce without consume (KF062)
  rebalance-storm    join/leave group loop (KF061)
  offset-oor         produce then delete records / short retention (KF063)
  produce-quota      set produce quota very low (KF060)
  max-connections    many TCP connects to 9092 (KF097)
  leader-skew        prefer one broker if possible (KF041)
  metadata-corrupt   truncate meta log (KF027) --confirm YES
  log-corrupt        truncate a log segment (KF087) --confirm YES
  txn-abort          empty transactional produce abort (KF058)

Examples:
  $0 --action process-stop --node 10.10.26.144:9092 --duration 300
  $0 --action min-isr-breach --duration 300
EOF
}

recover_process() {
  bind_target_from_node "${NODE}"
  run_on_target "systemctl start ${KAFKA_SERVICE} 2>/dev/null || true"
  restore_container_restart_policy
}

recover_freeze() {
  bind_target_from_node "${NODE}"
  run_on_target "pkill -CONT -f 'kafka.Kafka' 2>/dev/null || true"
}

recover_gc() { run_on_target "pkill -f 'stress-ng --vm' 2>/dev/null || true"; }
recover_fd() { run_on_target "pkill -f kafka_fd_bomb 2>/dev/null || true; rm -f /tmp/kafka_fd_bomb.sh"; }

STOPPED_HOSTS=()
recover_quorum() {
  local h
  for h in "${STOPPED_HOSTS[@]:-}"; do
    [[ -z "$h" ]] && continue
    TARGET_HOST="$h"; TARGET_CONTAINER=""
    run_on_target "systemctl start ${KAFKA_SERVICE} 2>/dev/null || true" || true
    restore_container_restart_policy || true
  done
}

TOPIC_CFG_SAVED=""
recover_topic_cfg() {
  if [[ -n "${TOPIC_CFG_SAVED}" ]]; then
    kafka_sh kafka-configs.sh --bootstrap-server "${BOOTSTRAP}" --entity-type topics --entity-name "${TOPIC}" \
      --alter --add-config "${TOPIC_CFG_SAVED}" >/dev/null 2>&1 || \
    kafka_sh kafka-configs.sh --bootstrap-server "${BOOTSTRAP}" --entity-type topics --entity-name "${TOPIC}" \
      --alter --delete-config min.insync.replicas >/dev/null 2>&1 || true
  fi
}

HOT_PID=""; recover_hot() { [[ -n "${HOT_PID}" ]] && kill "${HOT_PID}" 2>/dev/null || true; }
REB_PID=""; recover_rebalance() { [[ -n "${REB_PID}" ]] && kill "${REB_PID}" 2>/dev/null || true; }
CONN_PID=""; recover_conn() { [[ -n "${CONN_PID}" ]] && kill "${CONN_PID}" 2>/dev/null || true; run_on_target "pkill -f kafka_conn_bomb 2>/dev/null || true"; }

QUOTA_SAVED=""
recover_quota() {
  kafka_sh kafka-configs.sh --bootstrap-server "${BOOTSTRAP}" --entity-type clients --entity-default \
    --alter --delete-config producer_byte_rate >/dev/null 2>&1 || true
}

stop_kafka_on_current() {
  save_container_restart_policy
  run_on_target "systemctl stop ${KAFKA_SERVICE} 2>/dev/null || pkill -f 'kafka.Kafka' || true"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --target-host) TARGET_HOST="$2"; shift 2 ;;
    --target-container) TARGET_CONTAINER="$2"; shift 2 ;;
    --topic) TOPIC="$2"; shift 2 ;;
    --confirm) CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_action
resolve_node
acquire_inject_lock

case "${ACTION}" in
  process-stop)
    parse_duration; bind_target_from_node "${NODE}"
    inject_begin KF015 recover_process
    stop_kafka_on_current
    post_check_broker_down "${NODE}" || inject_fail "broker still up"
    inject_pass "stopped kafka on $(target_label)"
    run_timed_fault "${DURATION}" recover_process
    ;;
  process-freeze)
    parse_duration; bind_target_from_node "${NODE}"
    inject_begin KF016 recover_freeze
    run_on_target "pkill -STOP -f 'kafka.Kafka'"
    sleep 2
    # port may still listen; API should hang/fail
    if broker_api_ok "${NODE}"; then
      log "WARN API still answered after SIGSTOP (slow fail?)"
    fi
    inject_pass "SIGSTOP kafka on $(target_label)"
    run_timed_fault "${DURATION}" recover_freeze
    ;;
  gc-storm)
    parse_duration; bind_target_from_node "${NODE}"
    inject_begin KF018 recover_gc
    run_on_target "nohup stress-ng --vm 2 --vm-bytes 70% --timeout ${DURATION}s >/tmp/kafka_gc.log 2>&1 &"
    inject_pass "vm stress for GC on $(target_label)"
    run_timed_fault "${DURATION}" recover_gc
    ;;
  heap-oom)
    parse_duration; bind_target_from_node "${NODE}"
    inject_begin KF017 recover_gc
    run_on_target "nohup stress-ng --vm 4 --vm-bytes 95% --timeout ${DURATION}s >/tmp/kafka_oom.log 2>&1 &"
    inject_pass "aggressive vm stress (heap/host OOM path) on $(target_label)"
    run_timed_fault "${DURATION}" recover_gc
    ;;
  fd-exhaust)
    parse_duration; bind_target_from_node "${NODE}"
    inject_begin KF011 recover_fd
    run_on_target 'cat > /tmp/kafka_fd_bomb.sh << "EOS"
#!/bin/bash
ulimit -n 1024
files=()
for i in $(seq 1 20000); do
  exec {fd}>/tmp/kafka_fd_$i 2>/dev/null || break
  files+=($fd)
done
sleep 3600
EOS
chmod +x /tmp/kafka_fd_bomb.sh
nohup bash /tmp/kafka_fd_bomb.sh >/tmp/kafka_fd_bomb.log 2>&1 &'
    inject_pass "fd bomb started on $(target_label)"
    run_timed_fault "${DURATION}" recover_fd
    ;;
  isr-shrink)
    parse_duration; bind_target_from_node "${NODE}"
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF039 recover_process
    stop_kafka_on_current
    post_check_urp || inject_fail "no URP after broker stop"
    inject_pass "URP after stopping $(target_label)"
    run_timed_fault "${DURATION}" recover_process
    ;;
  quorum-loss)
    parse_duration
    inject_begin KF026 recover_quorum
    local_i=0
    for node in ${KAFKA_NODES}; do
      local_i=$((local_i + 1))
      (( local_i <= 2 )) || break
      host="${node%%:*}"
      STOPPED_HOSTS+=("${host}")
      TARGET_HOST="${host}"; TARGET_CONTAINER=""
      save_container_restart_policy
      run_on_target "systemctl stop ${KAFKA_SERVICE} 2>/dev/null || pkill -f 'kafka.Kafka' || true"
    done
    sleep 5
    if broker_api_ok "$(first_node)" && "${KAFKA_HOME}/bin/kafka-metadata-quorum.sh" --bootstrap-server "${BOOTSTRAP}" describe --status >/dev/null 2>&1; then
      log "WARN quorum still answering (may be remaining node)"
    fi
    inject_pass "stopped 2/3 brokers"
    run_timed_fault "${DURATION}" recover_quorum
    ;;
  min-isr-breach)
    parse_duration
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF044 recover_topic_cfg
    TOPIC_CFG_SAVED="min.insync.replicas=1"
    kafka_sh kafka-configs.sh --bootstrap-server "${BOOTSTRAP}" --entity-type topics --entity-name "${TOPIC}" \
      --alter --add-config min.insync.replicas="${MIN_ISR}"
    bind_target_from_node "${NODE}"
    stop_kafka_on_current
    inject_pass "min.isr=${MIN_ISR} and broker stopped"
    run_timed_fault "${DURATION}" recover_process
    recover_topic_cfg
    ;;
  bad-min-isr)
    parse_duration
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF101 recover_topic_cfg
    TOPIC_CFG_SAVED="min.insync.replicas=1"
    kafka_sh kafka-configs.sh --bootstrap-server "${BOOTSTRAP}" --entity-type topics --entity-name "${TOPIC}" \
      --alter --add-config min.insync.replicas=3
    inject_pass "min.insync.replicas=3 on RF=3 topic ${TOPIC}"
    run_timed_fault "${DURATION}" recover_topic_cfg
    ;;
  hot-partition)
    parse_duration
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF047 recover_hot
    (
      end=$((SECONDS + DURATION))
      while (( SECONDS < end )); do
        printf 'hot-%s\n' "$$"
        sleep 0.01
      done
    ) | timeout "${DURATION}" "${KAFKA_HOME}/bin/kafka-console-producer.sh" \
          --bootstrap-server "${BOOTSTRAP}" --topic "${TOPIC}" >/dev/null 2>&1 &
    HOT_PID=$!
    inject_pass "hot produce to ${TOPIC}"
    run_timed_fault "${DURATION}" recover_hot
    ;;
  unknown-topic)
    parse_duration
    inject_begin KF050 true
    if printf 'x\n' | timeout 10 "${KAFKA_HOME}/bin/kafka-console-producer.sh" \
         --bootstrap-server "${BOOTSTRAP}" --topic "no-such-topic-${RANDOM}" >/dev/null 2>&1; then
      inject_fail "produce to missing topic unexpectedly succeeded (auto.create?)"
    fi
    inject_pass "unknown topic produce failed as expected"
    sleep "${DURATION}"
    ;;
  oversized-record)
    parse_duration
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF055 true
    python3 - "${RECORD_BYTES}" "${KAFKA_HOME}" "${BOOTSTRAP}" "${TOPIC}" <<'PY' || true
import os, sys, subprocess
n=int(sys.argv[1]); home, bs, topic = sys.argv[2:5]
payload=("A"*min(n, 5_000_000)+"\n").encode()
p=subprocess.run([f"{home}/bin/kafka-console-producer.sh","--bootstrap-server",bs,"--topic",topic],
                 input=payload, timeout=20)
sys.exit(p.returncode)
PY
    inject_pass "oversized produce attempted bytes=${RECORD_BYTES}"
    sleep "${DURATION}"
    ;;
  consumer-lag)
    parse_duration
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF062 true
    python3 - "${LAG_MESSAGES}" "${KAFKA_HOME}" "${BOOTSTRAP}" "${TOPIC}" <<'PY' || true
import sys, subprocess
n=int(sys.argv[1]); home,bs,topic=sys.argv[2:5]
data=("lag\n"*n).encode()
subprocess.run([f"{home}/bin/kafka-console-producer.sh","--bootstrap-server",bs,"--topic",topic],
               input=data, timeout=60)
PY
    inject_pass "produced ${LAG_MESSAGES} messages to ${TOPIC} (no consumer)"
    sleep "${DURATION}"
    ;;
  rebalance-storm)
    parse_duration
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF061 recover_rebalance
    (
      end=$((SECONDS + DURATION))
      g="storm-$$"
      while (( SECONDS < end )); do
        timeout 8 "${KAFKA_HOME}/bin/kafka-console-consumer.sh" --bootstrap-server "${BOOTSTRAP}" \
          --topic "${TOPIC}" --group "${g}" --timeout-ms 2000 >/dev/null 2>&1 || true
        sleep 1
      done
    ) &
    REB_PID=$!
    inject_pass "rebalance storm group storm-$$"
    run_timed_fault "${DURATION}" recover_rebalance
    ;;
  offset-oor)
    parse_duration
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF063 recover_topic_cfg
    printf 'oor-1\noor-2\n' | timeout 15 "${KAFKA_HOME}/bin/kafka-console-producer.sh" \
      --bootstrap-server "${BOOTSTRAP}" --topic "${TOPIC}" >/dev/null || true
    kafka_sh kafka-configs.sh --bootstrap-server "${BOOTSTRAP}" --entity-type topics --entity-name "${TOPIC}" \
      --alter --add-config retention.ms=1000
    TOPIC_CFG_SAVED="retention.ms=604800000"
    inject_pass "short retention on ${TOPIC}"
    run_timed_fault "${DURATION}" recover_topic_cfg
    ;;
  produce-quota)
    parse_duration
    inject_begin KF060 recover_quota
    kafka_sh kafka-configs.sh --bootstrap-server "${BOOTSTRAP}" --entity-type clients --entity-default \
      --alter --add-config producer_byte_rate=1024 || inject_fail "cannot set produce quota"
    inject_pass "producer_byte_rate=1024"
    run_timed_fault "${DURATION}" recover_quota
    ;;
  max-connections)
    parse_duration; bind_target_from_node "${NODE}"
    inject_begin KF097 recover_conn
    host="$(node_host "${NODE}")"
    (
      end=$((SECONDS + DURATION))
      while (( SECONDS < end )); do
        timeout 1 bash -c "echo >/dev/tcp/${host}/${KAFKA_PORT}" 2>/dev/null || true
      done
    ) &
    CONN_PID=$!
    inject_pass "connection pulse to ${host}:${KAFKA_PORT}"
    run_timed_fault "${DURATION}" recover_conn
    ;;
  leader-skew)
    parse_duration
    ensure_topic "${TOPIC}" 3 3
    inject_begin KF041 true
    kafka_sh kafka-leader-election.sh --bootstrap-server "${BOOTSTRAP}" --election-type preferred --all-topic-partitions >/dev/null 2>&1 || true
    inject_pass "preferred leader election triggered"
    sleep "${DURATION}"
    ;;
  metadata-corrupt)
    [[ "${CONFIRM:-}" == "YES" ]] || die "metadata-corrupt requires --confirm YES"
    bind_target_from_node "${NODE}"
    inject_begin KF027 true
    run_on_target "systemctl stop ${KAFKA_SERVICE} || true; find ${KAFKA_DATA_DIR} -name '__cluster_metadata-0' -type d | head -1 | xargs -I{} sh -c 'dd if=/dev/zero of={}/00000000000000000000.log bs=4k count=1 conv=notrunc 2>/dev/null || true'"
    inject_pass "truncated cluster metadata log on $(target_label) — manual recover"
    ;;
  log-corrupt)
    [[ "${CONFIRM:-}" == "YES" ]] || die "log-corrupt requires --confirm YES"
    bind_target_from_node "${NODE}"
    inject_begin KF087 true
    run_on_target "find ${KAFKA_DATA_DIR} -name '*.log' ! -path '*cluster_metadata*' | head -1 | xargs -I{} dd if=/dev/urandom of={} bs=4k count=1 conv=notrunc"
    inject_pass "corrupted a log segment on $(target_label)"
    ;;
  txn-abort)
    parse_duration
    inject_begin KF058 true
    inject_pass "txn-abort is a client-side scenario; marker only (use transactional producer in lab extra)"
    sleep "${DURATION}"
    ;;
  *)
    die "unknown action: ${ACTION}"
    ;;
esac
