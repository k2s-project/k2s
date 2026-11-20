#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../" && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/paths.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"

k2s_initialize_logging
k2s_require_install_dir || { k2s_log ERROR 'Native K2s installation directory is invalid.'; exit 1; }
k2s_log INFO 'Dispatching native Debian 13 status through the K2s CLI.'
exec "$K2S_INSTALL_DIR/k2s" status "$@"
