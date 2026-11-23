#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Stops a worker node added with Add.sh. Counterpart of lib/scripts/windows/worker/linux/bare-metal/Stop.ps1.
# Invoked by 'k2s stop'.
#
# Usage: sudo Stop.sh --name <node> [--wait-for-not-ready] [--install-dir <dir>] [--config-dir <dir>]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../../" && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/infra/ssh.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/node/worker-node.module.sh"

node_name=''
config_dir='/var/lib/k2s'
wait_for_not_ready=false

usage() {
  echo "Usage: sudo $0 --name <node> [--wait-for-not-ready] [--install-dir <dir>] [--config-dir <dir>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) node_name="${2:-}"; shift 2 ;;
    --wait-for-not-ready) wait_for_not_ready=true; shift ;;
    --install-dir) K2S_INSTALL_DIR="${2:-}"; shift 2 ;;
    --config-dir) config_dir="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n $node_name && -n $config_dir ]] || usage
[[ ${EUID} -eq 0 ]] || { k2s_log ERROR 'Stopping a node must be run as root (sudo).'; exit 1; }

node_name="${node_name,,}"
k2s_node_configure_from_config "$config_dir/cluster.json" "$node_name"
k2s_log INFO "[NodeStop] Stopping worker node $node_name ($K2S_NODE_IP)."

k2s_node_stop_services
if [[ $wait_for_not_ready == true ]]; then
  k2s_node_wait_ready "$node_name" False 60 2 2>/dev/null || k2s_log WARN "Node $node_name is still reported Ready; this can take up to ~50 seconds."
fi
