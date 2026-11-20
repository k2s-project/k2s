#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: Clean-Images.sh"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

k2s_log INFO "Cleaning non-Kubernetes container images"

failed=0
cleaned_any=false

# Clean non-Kubernetes images from buildah if available
if command -v buildah >/dev/null 2>&1; then
  buildah_json="$(buildah images --json 2>/dev/null || true)"
  if [[ -n "$buildah_json" && "$buildah_json" != "[]" && "$buildah_json" != "null" ]]; then
    buildah_non_k8s_ids=$(echo "$buildah_json" | jq -r '
      def is_k8s_str:
        startswith("registry.k8s.io/") or
        startswith("k8s.gcr.io/") or
        startswith("docker.io/flannel") or
        startswith("docker.io/calico") or
        startswith("quay.io/coreos") or
        startswith("shsk2s.azurecr.io/clusterip-webhook") or
        startswith("shsk2s.azurecr.io/pause");
      def is_k8s:
        ([(.names // [])[]? | select(is_k8s_str)] | length > 0);
      .[]? | select(is_k8s | not) | .id
    ' 2>/dev/null || true)

    if [[ -n "$buildah_non_k8s_ids" ]]; then
      while IFS= read -r image_id; do
        [[ -n "$image_id" ]] || continue
        cleaned_any=true
        k2s_log INFO "Removing non-Kubernetes container image via buildah: $image_id"
        if ! buildah rmi -f "$image_id" >/dev/null 2>&1 && ! buildah rmi "$image_id" >/dev/null 2>&1; then
          k2s_log WARN "Could not remove buildah image $image_id"
          failed=1
        fi
      done <<< "$buildah_non_k8s_ids"
    fi
  fi
fi

# Clean non-Kubernetes images from crictl
if command -v crictl >/dev/null 2>&1; then
  crictl_json="$(crictl images -o json 2>/dev/null || true)"
  if [[ -n "$crictl_json" ]]; then
    crictl_non_k8s_ids=$(echo "$crictl_json" | jq -r '
      def is_k8s_str:
        startswith("registry.k8s.io/") or
        startswith("k8s.gcr.io/") or
        startswith("docker.io/flannel") or
        startswith("docker.io/calico") or
        startswith("quay.io/coreos") or
        startswith("shsk2s.azurecr.io/clusterip-webhook") or
        startswith("shsk2s.azurecr.io/pause");
      def is_k8s:
        ([.repoTags[]? | select(is_k8s_str)] | length > 0) or
        ([.repoDigests[]? | select(is_k8s_str)] | length > 0);
      .images[]? | select(is_k8s | not) | .id
    ' 2>/dev/null || true)

    if [[ -n "$crictl_non_k8s_ids" ]]; then
      while IFS= read -r image_id; do
        [[ -n "$image_id" ]] || continue
        cleaned_any=true
        k2s_log INFO "Removing non-Kubernetes container image via crictl: $image_id"
        if ! crictl rmi "$image_id" >/dev/null 2>&1; then
          k2s_log WARN "Could not remove crictl image $image_id"
          failed=1
        fi
      done <<< "$crictl_non_k8s_ids"
    fi
  fi
fi

if [[ "$cleaned_any" == false ]]; then
  k2s_log INFO "No non-Kubernetes container images to clean"
  exit 0
fi

if [[ $failed -ne 0 ]]; then
  k2s_log WARN "Some container images could not be removed"
fi
