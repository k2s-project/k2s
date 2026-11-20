#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/node/crio.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/node/buildah.sh"

registry=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry|-r)
      registry="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: Remove-Registry.sh --registry <name>"
      exit 0
      ;;
    -*)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
    *)
      if [[ -z "$registry" ]]; then
        registry="$1"
        shift
      else
        k2s_log ERROR "Unexpected argument: $1"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$registry" ]]; then
  k2s_log ERROR "Registry name (--registry) must be specified"
  exit 1
fi

k2s_crio_remove_registry "$registry"
k2s_buildah_logout "$registry"
k2s_crio_reload
