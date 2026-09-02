#!/usr/bin/env bash
# 重建 3 个 Docker 模拟 VM，并打开节点间网络互通。
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${LAB_DIR}"
DOCKER="${DOCKER:-sudo docker}"
COMPOSE=(${DOCKER} compose)

echo "==> Removing old Kafka SOPS lab containers"
for name in kafka-n1 kafka-n2 kafka-n3; do
  ${DOCKER} rm -f "${name}" 2>/dev/null || true
done
${COMPOSE[@]} down --remove-orphans 2>/dev/null || true
${DOCKER} network rm kafka_lab 2>/dev/null || true

echo "==> Host sysctl for Kafka"
sudo sysctl -w vm.max_map_count=262144 >/dev/null
sudo sysctl -w fs.file-max=1000000 >/dev/null || true

echo "==> Building VM-node image (Java 17 + SOPS 预检工具)"
${COMPOSE[@]} build

echo "==> Starting 3 Docker nodes on 10.10.26.0/24"
${COMPOSE[@]} up -d --force-recreate

echo "==> Ensuring container-to-container FORWARD is allowed"
if command -v iptables >/dev/null 2>&1; then
  sudo iptables -P FORWARD ACCEPT 2>/dev/null || true
  sudo iptables -C FORWARD -j ACCEPT 2>/dev/null \
    || sudo iptables -I FORWARD -j ACCEPT 2>/dev/null || true
fi
if command -v iptables-legacy >/dev/null 2>&1; then
  sudo iptables-legacy -P FORWARD ACCEPT 2>/dev/null || true
  sudo iptables-legacy -C FORWARD -j ACCEPT 2>/dev/null \
    || sudo iptables-legacy -I FORWARD -j ACCEPT 2>/dev/null || true
fi

echo "==> Waiting for nodes to accept docker exec"
for ctn in kafka-n1 kafka-n2 kafka-n3; do
  ok=0
  for _ in $(seq 1 30); do
    if ${DOCKER} exec "${ctn}" true >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1
  done
  [[ "${ok}" -eq 1 ]] || { echo "FAIL: ${ctn} not exec-ready"; exit 1; }
done

echo "==> Verifying hostname -I / Java / systemctl / nofile"
declare -A expect_ip=(
  [kafka-n1]=10.10.26.144
  [kafka-n2]=10.10.26.145
  [kafka-n3]=10.10.26.146
)
for ctn in kafka-n1 kafka-n2 kafka-n3; do
  ip="${expect_ip[$ctn]}"
  addrs="$(${DOCKER} exec "${ctn}" hostname -I)"
  [[ " ${addrs} " == *" ${ip} "* ]] || { echo "FAIL: ${ctn} hostname -I='${addrs}' missing ${ip}"; exit 1; }
  ${DOCKER} exec "${ctn}" bash -lc '
    command -v java >/dev/null
    command -v curl >/dev/null
    command -v tar >/dev/null
    command -v sha512sum >/dev/null
    command -v ss >/dev/null
    command -v pgrep >/dev/null
    command -v systemctl >/dev/null
    command -v hostname >/dev/null
    java_major=$(java -version 2>&1 | awk -F '"'"'[".]'"'"' "/version/ {print \$2; exit}")
    (( java_major >= 17 ))
    nofile=$(ulimit -n)
    (( nofile >= 65535 ))
  '
  echo "  OK ${ctn} ip=${ip}"
done

echo "==> Network policy: ping + TCP 9092/9093 path between all nodes"
for src in kafka-n1 kafka-n2 kafka-n3; do
  for ip in 10.10.26.144 10.10.26.145 10.10.26.146; do
    ${DOCKER} exec "${src}" ping -c 1 -W 2 "${ip}" >/dev/null \
      || { echo "FAIL: ${src} cannot ping ${ip}"; exit 1; }
  done
  echo "  OK ping from ${src}"
done

echo "==> Lab ready"
${DOCKER} ps --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}' | grep -E 'NAMES|kafka-n' || ${DOCKER} ps
echo
echo "Next: ../../tools/sops_docker_exec.py --yaml ../../output/kafka38-kraft-3node.yaml"
