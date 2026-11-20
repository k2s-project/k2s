#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_PATHS_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_PATHS_SH_LOADED=1

k2s_require_install_dir() {
  if [[ -z ${K2S_INSTALL_DIR:-} ]]; then
    printf '%s\n' 'K2S_INSTALL_DIR must identify the installed K2s directory.' >&2
    return 1
  fi
  if [[ ! -d "$K2S_INSTALL_DIR" ]]; then
    printf 'K2S_INSTALL_DIR does not exist: %s\n' "$K2S_INSTALL_DIR" >&2
    return 1
  fi
}

k2s_install_path() {
  local relative_path="$1"
  k2s_require_install_dir || return 1
  printf '%s/%s\n' "${K2S_INSTALL_DIR%/}" "${relative_path#/}"
}

k2s_runtime_path() {
  local relative_path="$1"
  printf '/var/lib/k2s/%s\n' "${relative_path#/}"
}
