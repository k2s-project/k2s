#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_FILESYSTEM_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_FILESYSTEM_SH_LOADED=1

k2s_ensure_directory() {
  local directory_path="$1"
  local mode="${2:-0755}"

  if [[ ! -d "$directory_path" ]]; then
    mkdir -p "$directory_path"
    k2s_log INFO "Created managed directory: $directory_path"
  fi
  chmod "$mode" "$directory_path"
}

k2s_write_managed_file() {
  local file_path="$1"
  local mode="$2"
  local content="$3"

  k2s_ensure_directory "$(dirname "$file_path")"
  printf '%s\n' "$content" > "$file_path"
  chmod "$mode" "$file_path"
  k2s_log INFO "Wrote managed file: $file_path"
}
