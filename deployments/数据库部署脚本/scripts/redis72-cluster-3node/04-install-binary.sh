#!/usr/bin/env bash
# Redis Cluster 三节点 - 下载官方源码包并编译安装到 PREFIX
set -euo pipefail

REDIS_VERSION="${REDIS_VERSION:-7.2.16}"
REDIS_TARBALL_URL="${REDIS_TARBALL_URL:-https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz}"
REDIS_TARBALL_SHA256="${REDIS_TARBALL_SHA256:-960a8ec15e34ff40e57ff16837b26b33bd81f2da6d24497bb63de532a323a18e}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/redis/${REDIS_VERSION}}"
WORK_DIR="${WORK_DIR:-/tmp/redis-build}"
PARALLEL="${PARALLEL:-$(nproc)}"

log() { echo "[$(date '+%F %T')][二进制安装][$HOSTNAME] $*"; }

if [[ -x "${INSTALL_PREFIX}/bin/redis-server" ]]; then
  log "已安装 ${INSTALL_PREFIX}/bin/redis-server，跳过"
  exit 0
fi

mkdir -p "${WORK_DIR}" "${INSTALL_PREFIX}"
cd "${WORK_DIR}"

TARBALL="redis-${REDIS_VERSION}.tar.gz"
if [[ ! -f "${TARBALL}" ]]; then
  log "下载 ${REDIS_TARBALL_URL}"
  curl -fsSL "${REDIS_TARBALL_URL}" -o "${TARBALL}"
fi

log "校验 SHA256"
echo "${REDIS_TARBALL_SHA256}  ${TARBALL}" | sha256sum -c -

log "解压并编译"
rm -rf "redis-${REDIS_VERSION}"
tar -xzf "${TARBALL}"
cd "redis-${REDIS_VERSION}"
make -j"${PARALLEL}" BUILD_TLS=no
make PREFIX="${INSTALL_PREFIX}" install

log "安装完成: ${INSTALL_PREFIX}/bin/redis-server"
"${INSTALL_PREFIX}/bin/redis-server" --version
