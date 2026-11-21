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
force=false

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
    -f|--force)
      force=true
      shift
      ;;
    -h|--help)
      echo "Usage: Remove-Image.sh [-i <id>] [-n <name>] [--force]"
      exit 0
      ;;
    *)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

ref=""
if [[ -n "$image_id" ]]; then
  ref="$image_id"
elif [[ -n "$image_name" ]]; then
  ref="$image_name"
else
  k2s_log ERROR "Either image ID (-i) or image name (-n) must be specified"
  exit 1
fi

k2s_log INFO "Removing container image $ref"

# If forced, remove any containers referencing the image first (crictl rmi does not support --force)
if [[ "$force" == true ]] && command -v crictl >/dev/null 2>&1; then
  image_selectors=("$ref")
  if [[ "$ref" != localhost/* ]]; then
    image_selectors+=("localhost/$ref")
  fi
  for selector in "${image_selectors[@]}"; do
    containers=$(crictl ps -a -q --image "$selector" 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
      for cid in $containers; do
        crictl stop "$cid" >/dev/null 2>&1 || true
        crictl rm "$cid" >/dev/null 2>&1 || true
      done
    fi
  done
fi

# Try buildah rmi first (untags specific tag without deleting the underlying image or other tags)
if command -v buildah >/dev/null 2>&1; then
  buildah_args=()
  if [[ "$force" == true ]]; then
    buildah_args+=("--force")
  fi
  if buildah rmi "${buildah_args[@]}" "$ref" >/dev/null 2>&1; then
    exit 0
  fi
  if [[ "$ref" != localhost/* ]]; then
    if buildah rmi "${buildah_args[@]}" "localhost/$ref" >/dev/null 2>&1; then
      exit 0
    fi
  fi
fi

# Try crictl rmi with exact ref
if crictl rmi "$ref" >/dev/null 2>&1; then
  exit 0
fi

# If unqualified, try with localhost/ prefix for CRI-O storage
if [[ "$ref" != localhost/* ]]; then
  if crictl rmi "localhost/$ref" >/dev/null 2>&1; then
    exit 0
  fi
fi

# If all failed, run buildah rmi or crictl rmi directly to surface output and exit code
if command -v buildah >/dev/null 2>&1; then
  if [[ "$ref" != localhost/* ]] && buildah inspect "localhost/$ref" >/dev/null 2>&1; then
    k2s_run buildah rmi "${buildah_args[@]}" "localhost/$ref"
  elif ! k2s_run buildah rmi "${buildah_args[@]}" "$ref"; then
    if [[ "$ref" != localhost/* ]]; then
      k2s_run buildah rmi "${buildah_args[@]}" "localhost/$ref"
    else
      exit 1
    fi
  fi
else
  if [[ "$ref" != localhost/* ]] && crictl inspecti "localhost/$ref" >/dev/null 2>&1; then
    k2s_run crictl rmi "localhost/$ref"
  else
    k2s_run crictl rmi "$ref"
  fi
fi
