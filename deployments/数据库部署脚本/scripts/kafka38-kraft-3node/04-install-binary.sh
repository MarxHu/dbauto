#!/usr/bin/env bash
# Kafka KRaft 三节点 - 下载解压安装
set -euo pipefail

KAFKA_VERSION="${KAFKA_VERSION:-3.8.1}"
SCALA_VERSION="${SCALA_VERSION:-2.13}"
TARBALL_URL="${TARBALL_URL:-https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz}"
TARBALL_SHA512="${TARBALL_SHA512:-}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/kafka/${KAFKA_VERSION}}"
WORK_DIR="${WORK_DIR:-/tmp/kafka-install}"

log() { echo "[$(date '+%F %T')][下载解压安装][$HOSTNAME] $*"; }
error() { echo "[ERROR][下载解压安装][$HOSTNAME] $*" >&2; exit 1; }

if [[ -x "${INSTALL_PREFIX}/bin/kafka-server-start.sh" ]]; then
  log "已安装 ${INSTALL_PREFIX}/bin/kafka-server-start.sh，跳过"
  exit 0
fi

mkdir -p "${WORK_DIR}" "${INSTALL_PREFIX}"
cd "${WORK_DIR}"
tarball="kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
if [[ ! -f "${tarball}" ]]; then
  log "下载 ${TARBALL_URL}"
  curl -fsSL "${TARBALL_URL}" -o "${tarball}"
fi
[[ -n "${TARBALL_SHA512}" ]] || error "未配置 tar.gz SHA512"
tarball_sha512="$(echo "${TARBALL_SHA512}" | tr '[:upper:]' '[:lower:]')"
echo "${tarball_sha512}  ${tarball}" | sha512sum -c -

rm -rf "kafka_${SCALA_VERSION}-${KAFKA_VERSION}"
tar -xzf "${tarball}"
src_dir="kafka_${SCALA_VERSION}-${KAFKA_VERSION}"
[[ -d "${src_dir}" ]] || error "解压后目录不存在: ${src_dir}"

rm -rf "${INSTALL_PREFIX}"
mkdir -p "$(dirname "${INSTALL_PREFIX}")"
mv "${src_dir}" "${INSTALL_PREFIX}"

[[ -x "${INSTALL_PREFIX}/bin/kafka-server-start.sh" ]] || error "install 后缺少 kafka-server-start.sh"
[[ -x "${INSTALL_PREFIX}/bin/kafka-storage.sh" ]] || error "install 后缺少 kafka-storage.sh"
"${INSTALL_PREFIX}/bin/kafka-broker-api-versions.sh" --version >/dev/null 2>&1 \
  || log "WARN: kafka-broker-api-versions 版本探测失败，继续"
log "二进制安装完成: ${INSTALL_PREFIX}"
