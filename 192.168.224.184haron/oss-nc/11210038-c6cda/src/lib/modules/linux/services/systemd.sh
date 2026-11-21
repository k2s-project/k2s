#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_SYSTEMD_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_SYSTEMD_SH_LOADED=1

k2s_start_service() {
  local service_name="$1"
  if systemctl is-active --quiet "$service_name"; then
    k2s_log INFO "Service is already running: $service_name"
    return 0
  fi
  k2s_run systemctl start "$service_name"
}

k2s_stop_service() {
  local service_name="$1"
  if ! systemctl is-active --quiet "$service_name"; then
    k2s_log INFO "Service is already stopped: $service_name"
    return 0
  fi
  k2s_run systemctl stop "$service_name"
}

k2s_enable_service() {
  local service_name="$1"
  if systemctl is-enabled --quiet "$service_name"; then
    return 0
  fi
  k2s_run systemctl enable "$service_name"
}
