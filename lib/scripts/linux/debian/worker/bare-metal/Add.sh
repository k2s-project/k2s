#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Adds a Debian 13 worker node (amd64 or arm64) to the K2s cluster that runs on this Linux host.
# Counterpart of lib/scripts/windows/worker/linux/bare-metal/Add.ps1. Invoked by 'k2s node add'.
#
# Usage: sudo Add.sh --ip-address <ip> --user <name> --node-package <zip> [--install-dir <dir>]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../../" && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/paths.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/infra/ssh.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/node/worker-node.module.sh"

ip_address=''
user_name=''
node_package=''

usage() {
  echo "Usage: sudo $0 --ip-address <ip> --user <name> --node-package <zip> [--install-dir <dir>]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip-address) ip_address="${2:-}"; shift 2 ;;
    --user) user_name="${2:-}"; shift 2 ;;
    --node-package) node_package="${2:-}"; shift 2 ;;
    --install-dir) K2S_INSTALL_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n $ip_address && -n $user_name && -n $node_package ]] || usage
[[ ${EUID} -eq 0 ]] || { k2s_log ERROR 'Adding a node must be run as root (sudo).'; exit 1; }
[[ -f $node_package ]] || { k2s_log ERROR "Node package not found: $node_package"; exit 1; }
for tool in unzip ssh ssh-keygen ssh-keyscan tar kubectl kubeadm dpkg-deb; do
  command -v "$tool" >/dev/null 2>&1 || { k2s_log ERROR "Required command is not available: $tool"; exit 1; }
done

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

k2s_log INFO "[NodeAdd] Adding worker node $user_name@$ip_address from $(basename "$node_package")."

k2s_ssh_require_key || exit 1
k2s_node_configure "$user_name" "$ip_address" "$(k2s_ssh_private_key)"
k2s_node_trust_host

unzip -q "$node_package" -d "$work_dir/package"
package_dir="$work_dir/package"
[[ -d $package_dir/packages/debian13 && -d $package_dir/images ]] \
  || { k2s_log ERROR 'The node package has no packages/debian13 or images folder.'; exit 1; }
kubeadm_deb="$(find "$package_dir/packages/debian13/kubernetes" -maxdepth 1 -name 'kubeadm_*.deb' | head -n 1)"
[[ -n $kubeadm_deb ]] || { k2s_log ERROR 'The node package has no kubeadm package.'; exit 1; }

registry_token_file="$K2S_INSTALL_DIR/bin/registry.dat"
[[ -f $registry_token_file ]] || { k2s_log ERROR "Registry credentials are missing: $registry_token_file"; exit 1; }
registry_token="$(sed '1s/^\xEF\xBB\xBF//' "$registry_token_file" | tr -d '\r\n[:space:]')"

k2s_node_check_prerequisites
k2s_node_check_package_architecture "$kubeadm_deb"
node_name="$(k2s_node_hostname)"
k2s_log INFO "[NodeAdd] Node name: $node_name"

k2s_node_copy_artifacts "$package_dir" "$K2S_INSTALL_DIR/cfg/nodeextension/debian13/scripts"
k2s_node_install_packages "$registry_token"
k2s_node_import_images
k2s_node_join
k2s_node_wait_ready "$node_name"
k2s_node_remove_staging

k2s_log INFO "[NodeAdd] Worker node $node_name ($ip_address) added to the cluster."
