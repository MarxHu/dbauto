#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/lib/common.sh 2>/dev/null || true
exec "${ROOT_DIR}/scripts/${1:?missing scenario script}" "${@:2}"
