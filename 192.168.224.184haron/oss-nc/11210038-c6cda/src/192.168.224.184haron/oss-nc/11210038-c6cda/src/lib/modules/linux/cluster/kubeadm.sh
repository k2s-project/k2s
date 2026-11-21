#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_KUBEADM_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_KUBEADM_SH_LOADED=1

k2s_kubeadm_reset() {
  k2s_run kubeadm reset -f
}

k2s_wait_for_node_ready() {
  local node_name="$1"
  local timeout_seconds="${2:-120}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if kubectl get node "$node_name" --no-headers 2>/dev/null | grep -q ' Ready '; then
      k2s_log INFO "Kubernetes node is ready: $node_name"
      return 0
    fi
    sleep 3
  done

  k2s_log ERROR "Timed out waiting for Kubernetes node to become ready: $node_name"
  return 1
}
