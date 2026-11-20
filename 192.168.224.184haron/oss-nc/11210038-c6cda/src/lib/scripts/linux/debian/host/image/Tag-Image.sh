#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"

source_id=""
source_name=""
target_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--id|--image-id)
      source_id="$2"
      shift 2
      ;;
    -n|--name|--image-name)
      source_name="$2"
      shift 2
      ;;
    -t|--target|--target-image-name)
      target_name="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: Tag-Image.sh [-i <id>] [-n <name>] -t <target-image-name>"
      exit 0
      ;;
    *)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

source_ref=""
if [[ -n "$source_id" ]]; then
  source_ref="$source_id"
elif [[ -n "$source_name" ]]; then
  source_ref="$source_name"
else
  k2s_log ERROR "Either source image ID (-i) or source image name (-n) must be specified"
  exit 1
fi

if [[ -z "$target_name" ]]; then
  k2s_log ERROR "Target image name (-t) must be specified"
  exit 1
fi

k2s_log INFO "Tagging container image $source_ref as $target_name"
if command -v buildah >/dev/null 2>&1; then
  if [[ "$source_ref" != localhost/* ]] && ! buildah inspect "$source_ref" >/dev/null 2>&1 && buildah inspect "localhost/$source_ref" >/dev/null 2>&1; then
    source_ref="localhost/$source_ref"
  fi
  if ! k2s_run buildah tag "$source_ref" "$target_name"; then
    if [[ "$source_ref" != localhost/* ]]; then
      k2s_run buildah tag "localhost/$source_ref" "$target_name"
    else
      exit 1
    fi
  fi
elif command -v ctr >/dev/null 2>&1; then
  k2s_run ctr -n k8s.io images tag "$source_ref" "$target_name"
else
  k2s_log ERROR "No container tool found to tag image. Please install buildah (apt-get install -y buildah)."
  exit 127
fi
