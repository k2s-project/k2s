#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/node/crio.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/node/buildah.sh"

registry=""
username=""
password=""
skip_verify=false
plain_http=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry|-r)
      registry="$2"
      shift 2
      ;;
    --username|-u)
      username="$2"
      shift 2
      ;;
    --password|-p)
      password="$2"
      shift 2
      ;;
    --skip-verify)
      skip_verify=true
      shift
      ;;
    --plain-http)
      plain_http=true
      shift
      ;;
    -h|--help)
      echo "Usage: Add-Registry.sh --registry <name> [--username <user>] [--password <pass>] [--skip-verify] [--plain-http]"
      exit 0
      ;;
    *)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$registry" ]]; then
  k2s_log ERROR "Registry name (--registry) must be specified"
  exit 1
fi

insecure=false
if [[ "$skip_verify" == true || "$plain_http" == true ]]; then
  insecure=true
fi

k2s_crio_add_registry "$registry" "$insecure"

if [[ -n "$username" && -n "$password" ]]; then
  k2s_buildah_login "$registry" "$username" "$password" "$insecure"
fi

k2s_crio_reload
