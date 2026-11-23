#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Removes a worker node added with Add.sh from the K2s cluster that runs on this Linux host.
# Counterpart of lib/scripts/windows/worker/linux/bare-metal/Remove.ps1. Invoked by 'k2s node remove'.
#
# Usage: sudo Remove.sh --name <node> [--install-dir <dir>] [--config-dir <dir>]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../../" && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/infra/ssh.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/node/worker-node.module.sh"

node_name=''
config_dir='/var/lib/k2s'

usage() {
  echo "Usage: sudo $0 --name <node> [--install-dir <dir>] [--config-dir <dir>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) node_name="${2:-}"; shift 2 ;;
    --install-dir) K2S_INSTALL_DIR="${2:-}"; shift 2 ;;
    --config-dir) config_dir="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n $node_name && -n $config_dir ]] || usage
[[ ${EUID} -eq 0 ]] || { k2s_log ERROR 'Removing a node must be run as root (sudo).'; exit 1; }
for tool in ssh ssh-keygen jq kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { k2s_log ERROR "Required command is not available: $tool"; exit 1; }
done

node_name="${node_name,,}"
cluster_config="$config_dir/cluster.json"
k2s_node_configure_from_config "$cluster_config" "$node_name"
k2s_log INFO "[NodeRemove] Removing worker node $node_name ($K2S_NODE_USER@$K2S_NODE_IP)."

reachable=false
if k2s_node_ssh true 2>/dev/null; then
  reachable=true
  actual_name="$(k2s_node_hostname)"
  if [[ $actual_name != "$node_name" ]]; then
    k2s_log ERROR "The node with IP address $K2S_NODE_IP is $actual_name, not $node_name."
    exit 1
  fi
else
  k2s_log WARN "Cannot reach $K2S_NODE_USER@$K2S_NODE_IP. Removing $node_name from the cluster and the configuration only."
fi

k2s_node_remove_from_cluster "$node_name"
if [[ $reachable == true ]]; then
  k2s_node_reset || k2s_log WARN "Removing Kubernetes from $K2S_NODE_IP did not complete; see $K2S_LOG_FILE."
fi
k2s_node_config_remove "$cluster_config" "$node_name"
k2s_node_forget_host

k2s_log INFO "[NodeRemove] Worker node $node_name ($K2S_NODE_IP) removed from the cluster."
