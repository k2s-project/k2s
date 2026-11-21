#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"

output_json=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-json|-o=json|--output=json)
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
    -h|--help)
      echo "Usage: List-Registries.sh [--output-json]"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

registry_dir="/etc/containers/registries.conf.d"
registries=()

if [[ -d "$registry_dir" ]]; then
  shopt -s nullglob
  conf_files=("$registry_dir"/*.conf)
  shopt -u nullglob

  for f in "${conf_files[@]}"; do
    fname="$(basename "$f")"
    # Skip default system files
    if [[ "$fname" == "crio.conf" || "$fname" == "shortnames.conf" || "$fname" == 00-* ]]; then
      continue
    fi

    loc=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*location[[:space:]]*=[[:space:]]*[\"\']?([^\"\'[:space:]]+)[\"\']? ]]; then
        loc="${BASH_REMATCH[1]}"
        break
      fi
    done < "$f"

    if [[ -n "$loc" ]]; then
      registries+=("$loc")
    else
      base_name="${fname%.conf}"
      registries+=("$base_name")
    fi
  done
fi

if [[ "$output_json" == true ]]; then
  if [[ ${#registries[@]} -eq 0 ]]; then
    echo "[]"
  else
    printf '%s\n' "${registries[@]}" | jq -R . | jq -s .
  fi
else
  if [[ ${#registries[@]} -eq 0 ]]; then
    echo " (no custom registries configured)"
  else
    for reg in "${registries[@]}"; do
      echo " - $reg"
    done
  fi
fi
