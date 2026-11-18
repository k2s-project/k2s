#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_BUILDAH_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_BUILDAH_SH_LOADED=1

if [[ -z "${K2S_INSTALL_DIR:-}" ]]; then
  buildah_module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export K2S_INSTALL_DIR="$(cd "$buildah_module_dir/../../../.." && pwd)"
fi

source "${K2S_INSTALL_DIR}/lib/modules/linux/common/logging.sh"
source "${K2S_INSTALL_DIR}/lib/modules/linux/common/validation.sh"

: "${K2S_CONTAINER_AUTH_FILE:=/root/.config/containers/auth.json}"

k2s_buildah_login() {
  local registry="${1:-}"
  local user="${2:-}"
  local password="${3:-}"
  local skip_tls_verify="${4:-false}"

  k2s_validate_registry_name "$registry" || { k2s_log ERROR "Invalid registry name '$registry'"; return 1; }

  mkdir -p "$(dirname "$K2S_CONTAINER_AUTH_FILE")"

  local -a tls_flag=()
  if [[ "$skip_tls_verify" == "true" ]]; then
    tls_flag=("--tls-verify=false")
  fi

  if [[ -n "$user" && -n "$password" ]]; then
    k2s_log INFO "Logging into registry '$registry' via buildah"
    local login_output
    if ! login_output=$(printf '%s' "$password" | buildah login --authfile "$K2S_CONTAINER_AUTH_FILE" "${tls_flag[@]}" -u "$user" --password-stdin "$registry" 2>&1); then
      k2s_log ERROR "Buildah login to '$registry' failed: $login_output"
      return 1
    fi
  else
    k2s_log INFO "No credentials provided for '$registry'; skipping buildah login"
  fi
}

k2s_buildah_logout() {
  local registry="${1:-}"
  k2s_validate_registry_name "$registry" || { k2s_log ERROR "Invalid registry name '$registry'"; return 1; }
  k2s_log INFO "Logging out of registry '$registry' via buildah"
  local logout_output
  if ! logout_output=$(buildah logout --authfile "$K2S_CONTAINER_AUTH_FILE" "$registry" 2>&1); then
    k2s_log WARN "Buildah logout from '$registry' failed: $logout_output"
  fi
}
