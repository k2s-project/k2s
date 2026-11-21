#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# The one K2s SSH key pair, created on install, deleted on uninstall. Its public key must be authorized on every
# node the user adds.

if [[ -n ${K2S_SSH_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_SSH_SH_LOADED=1

k2s_ssh_home_dir() {
  if [[ -n ${HOME:-} ]]; then
    printf '%s' "$HOME"
  else
    getent passwd "$(id -un)" | cut -d: -f6
  fi
}

k2s_ssh_key_dir() {
  local ssh_dir sub_dir
  ssh_dir=$(jq -er '.configDir.ssh' "$K2S_INSTALL_DIR/cfg/config.json") || { k2s_log ERROR "'configDir.ssh' is not configured in cfg/config.json."; return 1; }
  sub_dir=$(jq -er '.sshKey.subDir' "$K2S_INSTALL_DIR/cfg/config.json") || { k2s_log ERROR "'sshKey.subDir' is not configured in cfg/config.json."; return 1; }
  if [[ $ssh_dir == '~' || $ssh_dir == '~/'* ]]; then
    ssh_dir="$(k2s_ssh_home_dir)${ssh_dir#\~}"
  fi
  printf '%s/%s' "$ssh_dir" "$sub_dir"
}

k2s_ssh_private_key() {
  local key_dir file_name
  key_dir=$(k2s_ssh_key_dir) || return 1
  file_name=$(jq -er '.sshKey.fileName.linux' "$K2S_INSTALL_DIR/cfg/config.json") || { k2s_log ERROR "'sshKey.fileName.linux' is not configured in cfg/config.json."; return 1; }
  printf '%s/%s' "$key_dir" "$file_name"
}

k2s_ssh_require_key() {
  local key
  key=$(k2s_ssh_private_key) || return 1
  [[ -f $key && -f $key.pub ]] || { k2s_log ERROR "The K2s SSH key pair '$key' is missing. It is created by the install; reinstall K2s."; return 1; }
}

# Creates the K2s key pair unless it already exists.
k2s_ssh_ensure_key() {
  local key_dir key
  key_dir=$(k2s_ssh_key_dir) || return 1
  key=$(k2s_ssh_private_key) || return 1
  mkdir -p "$key_dir" || return 1
  chmod 700 "$(dirname "$key_dir")" "$key_dir" || return 1
  if [[ ! -f $key || ! -f $key.pub ]]; then
    k2s_log INFO "Creating the K2s SSH key pair '$key'."
    rm -f "$key" "$key.pub"
    ssh-keygen -q -t ed25519 -N '' -f "$key" -C k2s || return 1
  fi
  chmod 600 "$key"
  chmod 644 "$key.pub"
}

# Deletes the K2s key pair and its dir if nothing else is stored in it.
k2s_ssh_remove_key() {
  local key_dir key
  key_dir=$(k2s_ssh_key_dir) || return 1
  key=$(k2s_ssh_private_key) || return 1
  rm -f "$key" "$key.pub"
  rmdir "$key_dir" 2>/dev/null || true
}
