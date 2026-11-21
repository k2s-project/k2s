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
tar_path=""
docker_archive=false

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
    -t|--tar|--output|-o)
      tar_path="$2"
      shift 2
      ;;
    --docker-archive)
      docker_archive=true
      shift
      ;;
    -h|--help)
      echo "Usage: Export-Image.sh [-i <id>] [-n <name>] -t <tar-path> [--docker-archive]"
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

if [[ -z "$tar_path" ]]; then
  k2s_log ERROR "Export target tar path (-t) must be specified"
  exit 1
fi

mkdir -p "$(dirname "$tar_path")"

archive_format="oci-archive"
if [[ "$docker_archive" == true ]]; then
  archive_format="docker-archive"
fi

resolved_id=""
resolved_full_name=""

# 1. Resolve via buildah (matching PowerShell's 'sudo buildah images' resolution)
if command -v buildah >/dev/null 2>&1; then
  if [[ -n "$image_id" ]]; then
    match="$(buildah images --json 2>/dev/null | jq -c --arg id "$image_id" '
      [.[] | select(.id | startswith($id))] |
      (map(select(.names[]? // "" | test("^<none>") | not)) + .)[0] // empty
    ' 2>/dev/null || true)"
    if [[ -n "$match" && "$match" != "null" ]]; then
      resolved_id="$(echo "$match" | jq -r '.id')"
      resolved_full_name="$(echo "$match" | jq -r '(.names[]? // empty) | select(. != "<none>")' | head -n 1 || true)"
    fi
  elif [[ -n "$image_name" ]]; then
    search_name="$image_name"
    match="$(buildah images --json 2>/dev/null | jq -c --arg name "$search_name" '
      [.[] | select(
        .names[]? as $n |
        $n == $name or
        $n == "localhost/" + $name or
        $n == $name + ":latest" or
        $n == "localhost/" + $name + ":latest" or
        ($n | split(":")[0]) == $name
      )][0] // empty
    ' 2>/dev/null || true)"
    if [[ -n "$match" && "$match" != "null" ]]; then
      resolved_id="$(echo "$match" | jq -r '.id')"
      resolved_full_name="$(echo "$match" | jq -r '(.names[]? // empty) | select(. != "<none>")' | head -n 1 || true)"
      if [[ -z "$resolved_full_name" ]]; then
        resolved_full_name="$image_name"
      fi
    fi
  fi
fi

# 2. If not found in buildah, try crictl inspecti
if [[ -z "$resolved_id" ]] && command -v crictl >/dev/null 2>&1; then
  query="${image_id:-$image_name}"
  inspect_json="$(crictl inspecti "$query" 2>/dev/null || true)"
  if [[ -n "$inspect_json" ]]; then
    resolved_id="$(echo "$inspect_json" | jq -r '.status.id // empty')"
    resolved_full_name="$(echo "$inspect_json" | jq -r '.status.repoTags[0] // empty')"
  fi
fi

# Fallback defaults if resolution couldn't find metadata
if [[ -z "$resolved_id" ]]; then
  resolved_id="${image_id:-$image_name}"
fi
if [[ -z "$resolved_full_name" ]]; then
  resolved_full_name="${image_name:-$image_id}"
fi
if [[ "$resolved_full_name" != *":"* && "$resolved_full_name" != *"<none>"* ]]; then
  resolved_full_name="${resolved_full_name}:latest"
fi

k2s_log INFO "Exporting image $resolved_id as $archive_format to $tar_path ($resolved_full_name)"

if command -v buildah >/dev/null 2>&1; then
  # Exact bash command executed by PowerShell over SSH:
  # sudo buildah push ${imageId} ${archiveFormat}:${remoteTarPath}:${imageFullName} 2>&1
  k2s_run buildah push "$resolved_id" "${archive_format}:${tar_path}:${resolved_full_name}"
elif command -v ctr >/dev/null 2>&1; then
  k2s_run ctr -n k8s.io images export "$tar_path" "$resolved_full_name"
elif command -v nerdctl >/dev/null 2>&1; then
  k2s_run nerdctl -n k8s.io save -o "$tar_path" "$resolved_full_name"
else
  k2s_log ERROR "No container tool found to export image. Please install buildah or containerd."
  exit 127
fi
