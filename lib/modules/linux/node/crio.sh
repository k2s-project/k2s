#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

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

: "${K2S_CONTAINERS_REGISTRIES_DIR:=/etc/containers/registries.conf.d}"

# Formats and writes the TOML registry configuration drop-in file
k2s_crio_add_registry() {
  local registry="${1:-}"
  local insecure="${2:-false}"

  k2s_validate_registry_name "$registry" || { k2s_log ERROR "Invalid registry name '$registry'"; return 1; }

  if [[ "$insecure" != "true" ]]; then
    insecure="false"
  fi

  # Escape %, : and / to produce a unique, filesystem-safe drop-in filename without collisions (e.g. host:5000 vs host5000)
  local file_name="${registry//%/%25}"
  file_name="${file_name//:/%3A}"
  file_name="${file_name//\//%2F}"
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
  local registry="${1:-}"
  k2s_validate_registry_name "$registry" || { k2s_log ERROR "Invalid registry name '$registry'"; return 1; }

  local file_name="${registry//%/%25}"
  file_name="${file_name//:/%3A}"
  file_name="${file_name//\//%2F}"
  local config_file="${K2S_CONTAINERS_REGISTRIES_DIR}/${file_name}.conf"

  local target_file=""
  if [[ -f "$config_file" ]]; then
    target_file="$config_file"
  elif [[ -f "${K2S_CONTAINERS_REGISTRIES_DIR}/${registry//:/}.conf" ]]; then
    target_file="${K2S_CONTAINERS_REGISTRIES_DIR}/${registry//:/}.conf"
  elif [[ -d "$K2S_CONTAINERS_REGISTRIES_DIR" ]]; then
    for f in "$K2S_CONTAINERS_REGISTRIES_DIR"/*.conf; do
      [[ -f "$f" ]] || continue
      if grep -qE "^[[:space:]]*location[[:space:]]*=[[:space:]]*[\"\']?${registry//./\\.}[\"\']?[[:space:]]*$" "$f" 2>/dev/null; then
        target_file="$f"
        break
      fi
    done
  fi

  if [[ -n "$target_file" && -f "$target_file" ]]; then
    k2s_log INFO "Removing registry drop-in $target_file"
    rm -f "$target_file"
  else
    k2s_log WARN "Registry configuration for '$registry' not found; skipping removal"
  fi
}

# Reloads systemd and restarts the CRI-O daemon
k2s_crio_reload() {
  k2s_log INFO "Reloading systemd and restarting crio service"
  systemctl daemon-reload || return 1
  systemctl restart crio || return 1
}

# Lists the configured mirrors as "<registry> <mirror>" lines.
k2s_crio_mirror_registries() {
  jq -r '.smallsetup.mirrorRegistries // [] | .[] | "\(.registry) \(.mirror)"' "$K2S_INSTALL_DIR/cfg/config.json"
}

# Same drop-in as AddRegistryMirrors writes for the control-plane VM on a Windows host.
k2s_crio_mirror_dropin() {
  printf '[[registry]]\nlocation="%s"\ninsecure=true\n\n[[registry.mirror]]\nlocation="%s"\ninsecure=true\n' "$1" "$2"
}

k2s_crio_configure_mirror_registries() {
  local mirrors registry mirror
  mirrors=$(k2s_crio_mirror_registries) || return 1
  [[ -n $mirrors ]] || return 0
  mkdir -p "$K2S_CONTAINERS_REGISTRIES_DIR" || return 1
  while read -r registry mirror; do
    k2s_log INFO "Configuring CRI-O registry mirror '$mirror' for '$registry'."
    k2s_crio_mirror_dropin "$registry" "$mirror" > "$K2S_CONTAINERS_REGISTRIES_DIR/${registry//:/}.conf" || return 1
    chmod 644 "$K2S_CONTAINERS_REGISTRIES_DIR/${registry//:/}.conf"
  done <<< "$mirrors"
  systemctl try-restart crio
}

k2s_crio_remove_mirror_registries() {
  local registry
  while read -r registry _; do
    [[ -n $registry ]] && rm -f "$K2S_CONTAINERS_REGISTRIES_DIR/${registry//:/}.conf"
  done < <(k2s_crio_mirror_registries)
  return 0
}
