#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"

include_k8s=false
output_json=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-k8s-images|-A)
      include_k8s=true
      shift
      ;;
    --output-json)
      output_json=true
      shift
      ;;
    -o|--output)
      if [[ "${2:-}" == "json" ]]; then
        output_json=true
        shift 2
      else
        shift 2
      fi
      ;;
    -o=json|--output=json)
      output_json=true
      shift
      ;;
    -h|--help)
      echo "Usage: Get-Images.sh [--include-k8s-images] [--output-json]"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

raw_json="$(crictl images -o json 2>/dev/null || echo '{"images":[]}')"

# Process raw crictl JSON
processed_json=$(echo "$raw_json" | jq --argjson incK8s "$include_k8s" '
  def is_k8s($repo):
    ($repo | startswith("registry.k8s.io/")) or
    ($repo | startswith("k8s.gcr.io/")) or
    ($repo | startswith("docker.io/flannel")) or
    ($repo | startswith("docker.io/calico")) or
    ($repo | startswith("quay.io/coreos")) or
    ($repo | startswith("shsk2s.azurecr.io/clusterip-webhook")) or
    ($repo | startswith("shsk2s.azurecr.io/pause"));

  def parse_tag($t):
    if ($t == null or $t == "" or $t == "<none>:<none>") then
      {repo: "<none>", tag: "<none>"}
    else
      ($t | split(":")) as $parts |
      {repo: ($parts[0:-1] | join(":")), tag: $parts[-1]}
    end;

  [ (.images // [])[] |
    . as $img |
    (($img.repoTags // []) | if length == 0 then ["<none>:<none>"] else . end)[] |
    parse_tag(.) as $parsed |
    {
      imageId: ($img.id | sub("^sha256:"; "") | .[:12]),
      repository: $parsed.repo,
      tag: $parsed.tag,
      node: (env.HOSTNAME // "linux"),
      size: ($img.size // "0")
    } | select($incK8s or (is_k8s(.repository) | not))
  ]
')

if [[ "$output_json" == true ]]; then
  echo "$processed_json"
else
  count=$(echo "$processed_json" | jq 'length')
  if [[ "$count" -eq 0 ]]; then
    echo "No container images found"
  else
    printf "%-14s %-40s %-15s %-10s %-10s\n" "IMAGE ID" "REPOSITORY" "TAG" "NODE" "SIZE"
    echo "$processed_json" | jq -r '.[] | [ .imageId, .repository, .tag, .node, .size ] | @tsv' | while IFS=$'\t' read -r id repo tag node size; do
      printf "%-14s %-40s %-15s %-10s %-10s\n" "$id" "$repo" "$tag" "$node" "$size"
    done
  fi
fi
