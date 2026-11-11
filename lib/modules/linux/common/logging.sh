#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_LOGGING_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_LOGGING_SH_LOADED=1

: "${K2S_LOG_FILE:=/var/log/k2s.log}"

if [[ ${K2S_LOG_TO_CLI:-false} == true ]]; then
  export K2S_LOG_STREAMED=true
fi

k2s_initialize_logging() {
  if [[ ${K2S_LOG_TO_CLI:-false} == true ]]; then
    return 0
  fi
  local log_directory
  log_directory=$(dirname "$K2S_LOG_FILE")
  mkdir -p "$log_directory"
  touch "$K2S_LOG_FILE"
  chmod 0644 "$K2S_LOG_FILE"
  if [[ ${1:-} == '--stream' ]]; then
    export K2S_LOG_STREAMED=true
    exec > >(tee -a "$K2S_LOG_FILE") 2> >(tee -a "$K2S_LOG_FILE" >&2)
  fi
}

k2s_log() {
  local level="$1"
  shift

  local message="$*"
  if [[ ${K2S_LOG_TO_CLI:-false} != true ]]; then
    message="$(date -Is) [$level] $message"
  fi
  if [[ ${K2S_LOG_STREAMED:-false} != true ]]; then
    printf '%s\n' "$message" >> "$K2S_LOG_FILE"
  fi
  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    printf '%s\n' "$message" >&2
  else
    printf '%s\n' "$message"
  fi
}

k2s_log_command_failure() {
  local exit_code="$1"
  shift
  k2s_log ERROR "Command failed with exit code $exit_code: $*"
}
