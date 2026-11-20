#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Verify node delta package was applied correctly.
# This script validates Debian package versions from delta-manifest.json and
# checks that removed packages are no longer installed.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MJSON=delta-manifest.json

if [[ ! -f "$MJSON" ]]; then
    echo "[verify-node][error] Manifest not found: $MJSON" >&2
    exit 2
fi

command -v jq >/dev/null 2>&1 || {
    echo "[verify-node][error] jq required for verification" >&2
    exit 2
}

FAIL=0

url_decode() {
    local s="$1"
    printf '%b' "${s//%/\\x}"
}

normalize_version() {
    # Replace ALL spaces with + and strip leading/trailing whitespace
    local ver="$1"
    ver="${ver//[[:space:]]/+}"
    echo "${ver}"
}

verify_pkg_from_deb_name() {
    local entry="$1"
    local leaf namever pkg rest ver cur

    leaf="$(basename "$entry")"
    namever="${leaf%.deb}"

    # Expected Debian package filename format: <name>_<version>_<arch>.deb
    if [[ "$namever" != *_*_* ]]; then
        echo "[verify-node][warn] Unable to parse package/version from '$entry'"
        return 0
    fi

    pkg="${namever%%_*}"
    rest="${namever#*_}"
    ver="${rest%_*}"
    # Decode URL-encoded characters and normalize all spaces to +
    ver="$(url_decode "$ver")"
    ver="$(normalize_version "$ver")"

    # Also normalize the currently installed version for comparison
    cur="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo missing)"
    cur="$(normalize_version "$cur")"

    if [[ "$cur" != "$ver" ]]; then
        echo "[verify-node][error] Package mismatch: $pkg expected $ver got $cur"
        FAIL=1
    fi
}

is_pkg_installed() {
    local pkg="$1"
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"
}

echo "[verify-node] Verifying added and changed packages"
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    verify_pkg_from_deb_name "$entry"
done < <(jq -r '(.DebianPackageDiff.Added[]?, .DebianPackageDiff.Changed[]?)' "$MJSON")

echo "[verify-node] Verifying removed packages"
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    leaf="$(basename "$entry")"
    namever="${leaf%.deb}"
    pkg="${namever%%_*}"
    if [[ -n "$pkg" ]] && is_pkg_installed "$pkg"; then
        echo "[verify-node][error] Removed package still installed: $pkg"
        FAIL=1
    fi
done < <(jq -r '.DebianPackageDiff.Removed[]?' "$MJSON")

if [[ $FAIL -eq 0 ]]; then
    echo "[verify-node] Node delta verification PASSED"
else
    echo "[verify-node] Node delta verification FAILED"
fi

exit $FAIL
