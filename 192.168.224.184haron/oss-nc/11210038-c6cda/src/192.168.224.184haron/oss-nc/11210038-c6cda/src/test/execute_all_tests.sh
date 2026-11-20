#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Native Linux acceptance-test runner. The Windows runner remains
# execute_all_tests.ps1; this script runs the portable Go/Ginkgo e2e suites.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: execute_all_tests.sh [options]

Options:
  -v                         Enable verbose Ginkgo output.
  --throw-on-failure         Kept for CI-service compatibility.
  --proxy URL                Proxy for tests that require internet access.
  --test-result-path PATH    Directory for Ginkgo reports.
  --tags TAGS                Comma-separated Ginkgo labels to include.
  --exclude-tags TAGS        Comma-separated Ginkgo labels to exclude.
  --offline-mode             Skip tests requiring internet access.
  --keep-resources-in-case-of-error
                             Kept for CI-service compatibility.
EOF
}

verbose=false
proxy=""
test_result_path="${TMPDIR:-/tmp}/k2s-test-results"
tags=""
exclude_tags=""
offline_mode=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v)
      verbose=true
      shift
      ;;
    --throw-on-failure|--keep-resources-in-case-of-error)
      shift
      ;;
    --proxy|--test-result-path|--tags|--exclude-tags)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a value" >&2
        exit 2
      fi
      case "$1" in
        --proxy) proxy="$2" ;;
        --test-result-path) test_result_path="$2" ;;
        --tags) tags="$2" ;;
        --exclude-tags) exclude_tags="$2" ;;
      esac
      shift 2
      ;;
    --offline-mode)
      offline_mode=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unsupported argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# The CI service is started by systemd, whose default PATH often omits the Go
# installation used to build K2s. Keep the runner self-contained as well.
export PATH="/usr/local/go/bin:$PATH"

if [[ ! -x "$repo_root/k2s" ]]; then
  echo "error: native K2s CLI is missing: $repo_root/k2s" >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl is not available on PATH" >&2
  exit 1
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: Go is not available on PATH; install Go under /usr/local/go or configure the CI service PATH" >&2
  exit 1
fi

if [[ -z "${KUBECONFIG:-}" ]]; then
  # super-admin.conf is intentionally used for CI acceptance tests. It is
  # created by kubeadm for privileged local administration and avoids relying
  # on a potentially restricted admin.conf RBAC binding.
  for kubeconfig in /etc/kubernetes/super-admin.conf /etc/kubernetes/admin.conf; do
    if [[ -r "$kubeconfig" ]]; then
      export KUBECONFIG="$kubeconfig"
      break
    fi
  done
fi
if [[ -z "${KUBECONFIG:-}" || ! -r "$KUBECONFIG" ]]; then
  echo "error: no readable kubeadm admin kubeconfig found" >&2
  exit 1
fi
internal_no_proxy="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,.svc,.cluster.local"
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}$internal_no_proxy"
export no_proxy="${no_proxy:+$no_proxy,}$internal_no_proxy"
if [[ -n "$proxy" ]]; then
  export SYSTEM_TEST_PROXY="$proxy"
fi
if [[ "$offline_mode" == true ]]; then
  export SYSTEM_OFFLINE_MODE=true
fi

mkdir -p "$test_result_path"

# Validate the platform-first native Linux layout before acceptance tests use a
# cluster. This check is read-only and catches missing script/module paths.
bash "$repo_root/test/native-linux-layout.sh"

label_terms=()
if [[ -n "$tags" ]]; then
  IFS=',' read -ra include_tags <<< "$tags"
  for tag in "${include_tags[@]}"; do
    tag="${tag//[[:space:]]/}"
    [[ -n "$tag" ]] && label_terms+=("$tag")
  done
fi
if [[ ${#label_terms[@]} -gt 0 ]]; then
  label_filter="${label_terms[0]}"
  for tag in "${label_terms[@]:1}"; do
    label_filter+=" || $tag"
  done
else
  label_filter="acceptance"
fi
if [[ "$offline_mode" == true ]]; then
  label_filter="($label_filter) && !internet-required"
fi
if [[ -n "$exclude_tags" ]]; then
  IFS=',' read -ra excluded <<< "$exclude_tags"
  for tag in "${excluded[@]}"; do
    tag="${tag//[[:space:]]/}"
    [[ -n "$tag" ]] && label_filter+=" && !$tag"
  done
fi

# Start with the portable core suite for the native Linux-only test. The
# suite is labelled sanity and skips Windows workloads when LinuxOnly is set.
suites=(./test/e2e/cluster/core)

ginkgo_args=(--label-filter "$label_filter" --output-dir "$test_result_path" --json-report "linux-acceptance-report.json")
if [[ "$verbose" == true ]]; then
  ginkgo_args+=(-v)
fi

ginkgo_args+=("${suites[@]}")

echo "Running native Linux acceptance tests"
echo "KUBECONFIG=$KUBECONFIG"
echo "Label filter: $label_filter"
echo "Result directory: $test_result_path"
go run github.com/onsi/ginkgo/v2/ginkgo "${ginkgo_args[@]}"
