#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_COMMAND_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_COMMAND_SH_LOADED=1

k2s_run() {
  local command_line
  printf -v command_line '%q ' "$@"
  k2s_log INFO "Running command: ${command_line% }"

  local command_status tee_status
  if [[ ${K2S_LOG_STREAMED:-false} == true ]]; then
    if "$@"; then
      return 0
    else
      command_status=$?
      k2s_log_command_failure "$command_status" "${command_line% }"
      return "$command_status"
    fi
  fi
  local -a pipeline_status
  set -o pipefail
  if "$@" 2>&1 | tee -a "$K2S_LOG_FILE"; then
    return 0
  fi
  pipeline_status=("${PIPESTATUS[@]}")
  command_status=${pipeline_status[0]}
  tee_status=${pipeline_status[1]}
  if [[ $tee_status -ne 0 ]]; then
    printf '%s\n' "K2s log stream failed with exit code $tee_status" >&2
    return "$tee_status"
  fi
  k2s_log_command_failure "$command_status" "${command_line% }"
  return "$command_status"
}
