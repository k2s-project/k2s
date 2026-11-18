#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_LOGGING_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_LOGGING_SH_LOADED=1

: "${K2S_LOG_FILE:=/var/log/k2s.log}"

# Log lines always go to K2S_LOG_FILE. Warnings and errors are also printed to stderr,
# other messages to stdout only if K2S_SHOW_LOGS=true.
K2S_LOG_CAPTURED=false
K2S_LOG_STDOUT_FD=1
K2S_LOG_STDERR_FD=2

k2s_show_logs() {
  [[ ${K2S_SHOW_LOGS:-false} == true ]]
}

# --capture appends all stdout/stderr of the shell to the log file; the original
# streams stay available as fd 3 and 4.
k2s_initialize_logging() {
  local log_directory
  log_directory=$(dirname "$K2S_LOG_FILE")
  mkdir -p "$log_directory"
  touch "$K2S_LOG_FILE"
  chmod 0644 "$K2S_LOG_FILE"
  if [[ ${1:-} == '--capture' ]]; then
    K2S_LOG_CAPTURED=true
    exec 3>&1 4>&2
    K2S_LOG_STDOUT_FD=3
    K2S_LOG_STDERR_FD=4
    if k2s_show_logs; then
      exec > >(tee -a "$K2S_LOG_FILE")
    else
      exec >> "$K2S_LOG_FILE"
    fi
    exec 2> >(tee -a "$K2S_LOG_FILE" >&4)
  fi
}

k2s_log() {
  local level="$1"
  shift

  printf '%s [%s] %s\n' "$(date -Is)" "$level" "$*" >> "$K2S_LOG_FILE"
  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    printf '%s\n' "$*" >&"$K2S_LOG_STDERR_FD"
  elif k2s_show_logs; then
    printf '%s\n' "$*" >&"$K2S_LOG_STDOUT_FD"
  fi
}

# Marks a failed install pre-requisite with the [PREREQ-FAILED] marker.
k2s_log_prereq_failure() {
  k2s_log ERROR "[PREREQ-FAILED] $*"
}

# Appends stdin to the log file and passes it on to stdout if K2S_SHOW_LOGS=true.
k2s_log_output() {
  if [[ $K2S_LOG_CAPTURED == true ]]; then
    cat
  elif k2s_show_logs; then
    tee -a "$K2S_LOG_FILE"
  else
    cat >> "$K2S_LOG_FILE"
  fi
}

k2s_log_command_failure() {
  local exit_code="$1"
  shift
  k2s_log ERROR "Command failed with exit code $exit_code: $*"
}
