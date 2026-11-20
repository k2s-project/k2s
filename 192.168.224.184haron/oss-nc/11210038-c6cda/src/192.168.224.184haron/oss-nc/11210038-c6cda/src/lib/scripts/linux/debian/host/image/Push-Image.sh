#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"

image_id=""
image_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--id|--image-id)
      image_id="$2"
      shift 2
      ;;
    -n|--name|--image-name)
      image_name="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: Push-Image.sh [-i <id>] [-n <image-name>]"
      exit 0
      ;;
    -*)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
    *)
      if [[ -z "$image_name" && -z "$image_id" ]]; then
        image_name="$1"
        shift
      else
        k2s_log ERROR "Unexpected argument: $1"
        exit 1
      fi
      ;;
  esac
done

ref=""
if [[ -n "$image_name" ]]; then
  ref="$image_name"
elif [[ -n "$image_id" ]]; then
  ref="$image_id"
else
  k2s_log ERROR "Either image name (-n) or image ID (-i) must be specified"
  exit 1
fi

k2s_log INFO "Pushing container image $ref"
if command -v buildah >/dev/null 2>&1; then
  if [[ "$ref" != localhost/* ]] && ! buildah inspect "$ref" >/dev/null 2>&1 && buildah inspect "localhost/$ref" >/dev/null 2>&1; then
    ref="localhost/$ref"
  fi
  k2s_run buildah push "$ref"
elif command -v nerdctl >/dev/null 2>&1; then
  k2s_run nerdctl push "$ref"
else
  k2s_log ERROR "No container tool found to push image. Please install buildah (apt-get install -y buildah)."
  exit 127
fi
