#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

usage() {
  printf '%s\n' 'Usage: ProvisionPackages.sh <download|install> <arguments...>' >&2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../" && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"

k2s_initialize_logging
k2s_require_root || { k2s_log ERROR 'Native Debian 13 package provisioning requires root privileges.'; exit 1; }

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

operation="$1"
shift
node_extension_dir="$K2S_INSTALL_DIR/cfg/nodeextension/debian13/scripts"

case "$operation" in
  download)
    [[ $# -ge 2 ]] || { usage; exit 2; }
    target_dir="$1"
    k8s_version="$2"
    proxy="${3:-}"

    k2s_require_file "$node_extension_dir/download-k8s-packages.sh" || exit 1
    k2s_require_file "$node_extension_dir/download-buildah-packages.sh" || exit 1

    k2s_log INFO "Dispatching native Debian 13 package download through node-extension assets."
    bash "$node_extension_dir/download-k8s-packages.sh" "$target_dir" "$k8s_version" "$proxy"

    buildah_dir="$target_dir/buildah"
    offline_buildah_source=""
    for candidate in \
      "$buildah_dir" \
      "$K2S_INSTALL_DIR/bin/linuxnode/packages/debian13/buildah" \
      "$K2S_INSTALL_DIR/packages/debian13/buildah" \
      "$K2S_INSTALL_DIR/packages/buildah"; do
      if [[ -d "$candidate" ]] && compgen -G "$candidate/*.deb" >/dev/null 2>&1; then
        offline_buildah_source="$candidate"
        break
      fi
    done

    if [[ -n "$offline_buildah_source" ]]; then
      k2s_log INFO "Detected offline buildah packages at '$offline_buildah_source'."
      if [[ "$offline_buildah_source" != "$buildah_dir" ]]; then
        mkdir -p "$buildah_dir"
        cp "$offline_buildah_source"/*.deb "$buildah_dir/"
      fi
    else
      k2s_log INFO "Downloading buildah packages to $buildah_dir"
      bash "$node_extension_dir/download-buildah-packages.sh" "$buildah_dir" "$proxy"
    fi
    ;;
  install)
    [[ $# -ge 1 ]] || { usage; exit 2; }
    target_dir="$1"

    k2s_require_file "$node_extension_dir/install-k8s-packages.sh" || exit 1
    k2s_require_file "$node_extension_dir/install-buildah-packages.sh" || exit 1

    k2s_log INFO "Dispatching native Debian 13 package install through node-extension assets."
    bash "$node_extension_dir/install-k8s-packages.sh" "$@"

    buildah_dir="$target_dir/buildah"
    if [[ ! -d "$buildah_dir" ]] || ! compgen -G "$buildah_dir/*.deb" >/dev/null 2>&1; then
      for candidate in \
        "$K2S_INSTALL_DIR/bin/linuxnode/packages/debian13/buildah" \
        "$K2S_INSTALL_DIR/packages/debian13/buildah" \
        "$K2S_INSTALL_DIR/packages/buildah"; do
        if [[ -d "$candidate" ]] && compgen -G "$candidate/*.deb" >/dev/null 2>&1; then
          mkdir -p "$buildah_dir"
          cp "$candidate"/*.deb "$buildah_dir/"
          break
        fi
      done
    fi

    if [[ -d "$buildah_dir" ]] && compgen -G "$buildah_dir/*.deb" >/dev/null 2>&1; then
      k2s_log INFO "Installing buildah packages from $buildah_dir"
      bash "$node_extension_dir/install-buildah-packages.sh" "$buildah_dir"
    elif compgen -G "$target_dir/buildah*.deb" >/dev/null 2>&1; then
      k2s_log INFO "Installing buildah packages from $target_dir"
      bash "$node_extension_dir/install-buildah-packages.sh" "$target_dir"
    else
      k2s_log ERROR "Buildah deb packages not found in $buildah_dir or $target_dir"
      exit 1
    fi
    ;;
  *)
    usage
    exit 2
    ;;
esac
