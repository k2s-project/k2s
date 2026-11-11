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
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/node/windows-worker.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/networking/dns.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/cluster/lifecycle.sh"

k2s_dispatch_lifecycle compact "$@"
