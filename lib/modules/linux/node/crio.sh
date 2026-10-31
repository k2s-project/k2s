#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ -n ${K2S_CRIO_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_CRIO_SH_LOADED=1

if [[ -z "${K2S_INSTALL_DIR:-}" ]]; then
  crio_module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export K2S_INSTALL_DIR="$(cd "$crio_module_dir/../../../.." && pwd)"
fi

source "${K2S_INSTALL_DIR}/lib/modules/linux/common/logging.sh"
source "${K2S_INSTALL_DIR}/lib/modules/linux/common/validation.sh"

readonly K2S_CONTAINERS_REGISTRIES_DIR="/etc/containers/registries.conf.d"

# Formats and writes the TOML registry configuration drop-in file
k2s_crio_add_registry() {
  local registry="$1"
  local insecure="${2:-false}"

  [[ -n "$registry" ]] || { k2s_log ERROR "Registry name cannot be empty"; return 1; }

  local file_name
  file_name="${registry//:/}"
  local config_file="${K2S_CONTAINERS_REGISTRIES_DIR}/${file_name}.conf"

  k2s_log INFO "Configuring registry drop-in at $config_file (insecure=$insecure)"
  mkdir -p "$K2S_CONTAINERS_REGISTRIES_DIR" || return 1

  cat <<EOF > "$config_file"
[[registry]]
location = "${registry}"
insecure = ${insecure}
EOF
  chmod 644 "$config_file"
}

# Removes the TOML registry configuration drop-in file
k2s_crio_remove_registry() {
  local registry="$1"
  [[ -n "$registry" ]] || { k2s_log ERROR "Registry name cannot be empty"; return 1; }

  local file_name
  file_name="${registry//:/}"
  local config_file="${K2S_CONTAINERS_REGISTRIES_DIR}/${file_name}.conf"

  if [[ -f "$config_file" ]]; then
    k2s_log INFO "Removing registry drop-in $config_file"
    rm -f "$config_file"
  else
    k2s_log WARN "Registry configuration file $config_file not found; skipping removal"
  fi
}

# Reloads systemd and restarts the CRI-O daemon
k2s_crio_reload() {
  k2s_log INFO "Reloading systemd and restarting crio service"
  systemctl daemon-reload || return 1
  systemctl restart crio || return 1
}
