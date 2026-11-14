#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_files=(
  "lib/scripts/linux/debian/host/Compact.sh"
  "lib/scripts/linux/debian/host/Install.sh"
  "lib/scripts/linux/debian/host/Start.sh"
  "lib/scripts/linux/debian/host/Stop.sh"
  "lib/scripts/linux/debian/host/Status.sh"
  "lib/scripts/linux/debian/host/Uninstall.sh"
  "lib/scripts/linux/debian/linuxonly/Compact.sh"
  "lib/scripts/linux/debian/linuxonly/Install.sh"
  "lib/scripts/linux/debian/linuxonly/Start.sh"
  "lib/scripts/linux/debian/linuxonly/Stop.sh"
  "lib/scripts/linux/debian/linuxonly/Status.sh"
  "lib/scripts/linux/debian/linuxonly/Uninstall.sh"
  "lib/scripts/linux/debian/linuxonly/ProvisionPackages.sh"
  "lib/modules/linux/common/logging.sh"
  "lib/modules/linux/common/command.sh"
  "lib/modules/linux/infra/proxy.sh"
  "lib/modules/linux/networking/dns.sh"
  "lib/modules/linux/node/packages.sh"
  "lib/modules/linux/node/windows-worker.sh"
  "lib/modules/linux/common/paths.sh"
  "lib/modules/linux/common/validation.sh"
  "lib/modules/linux/cluster/lifecycle.sh"
  "cfg/nodeextension/debian13/scripts/download-k8s-packages.sh"
  "cfg/nodeextension/debian13/scripts/install-k8s-packages.sh"
)

for relative_path in "${required_files[@]}"; do
  path="$repo_root/$relative_path"
  if [[ ! -f "$path" ]]; then
    printf 'error: required native Linux path is missing: %s\n' "$relative_path" >&2
    exit 1
  fi
  bash -n "$path"
done

for operation in Compact Install Start Stop Status Uninstall; do
  if ! grep -Fq "../linuxonly/${operation}.sh" "$repo_root/lib/scripts/linux/debian/host/${operation}.sh"; then
    printf 'error: host %s entry point does not delegate to Linux-only lifecycle\n' "$operation" >&2
    exit 1
  fi
done

legacy_paths=(
  "lib/scripts/k2s"
  "lib/scripts/linuxonly"
  "lib/scripts/buildonly"
  "lib/scripts/worker"
  "lib/modules/k2s"
)

for legacy_path in "${legacy_paths[@]}"; do
  if git -C "$repo_root" ls-files --error-unmatch "$legacy_path/*" >/dev/null 2>&1; then
    printf 'error: tracked legacy automation path must not be reintroduced: %s\n' "$legacy_path" >&2
    exit 1
  fi
done

legacy_references=$(git -C "$repo_root" grep -nE 'lib/(scripts/(k2s|linuxonly|buildonly|worker)|modules/k2s)(/|\b)' -- \
  ':!.github/copilot-instructions.md' \
  ':!docs/dev-guide/architecture.md' \
  ':!docs/dev-guide/host-automation-option-3-migration-plan.md' \
  ':!test/native-linux-layout.sh' || true)
if [[ -n "$legacy_references" ]]; then
  printf '%s\n' 'error: active legacy automation references must not be reintroduced:' >&2
  printf '%s\n' "$legacy_references" >&2
  exit 1
fi

printf '%s\n' 'Native Debian 13 lifecycle layout validation passed.'
