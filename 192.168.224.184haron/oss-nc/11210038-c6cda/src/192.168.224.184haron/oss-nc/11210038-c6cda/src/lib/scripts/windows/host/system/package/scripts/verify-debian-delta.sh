#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Verify Debian delta package was applied correctly
# This script checks that installed package versions match the expected versions
# from the delta manifest.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MJSON=debian-delta-manifest.json

command -v jq >/dev/null 2>&1 || {
    echo "jq required for verification" >&2
    exit 2
}

ADDED=$(jq -r '.Added[]?' "$MJSON" || true)
UPG=$(jq -r '.Upgraded[]?' "$MJSON" || true)
FAIL=0

# Verify added packages
for entry in $ADDED; do
    P=${entry%%=*}
    V=${entry#*=}
    CV=$(dpkg-query -W -f='${Version}' "$P" 2>/dev/null || echo missing)
    if [[ "$CV" != "$V" ]]; then
        echo "[verify] Added pkg mismatch: $P expected $V got $CV"
        FAIL=1
    fi
done

# Verify upgraded packages (format: name old_version new_version)
while read -r line; do
    [[ -z "$line" ]] && continue
    PKG=$(echo "$line" | awk '{print $1}')
    OV=$(echo "$line" | awk '{print $2}')
    NV=$(echo "$line" | awk '{print $3}')
    CV=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || echo missing)
    if [[ "$CV" != "$NV" ]]; then
        echo "[verify] Upgraded pkg mismatch: $PKG expected $NV got $CV"
        FAIL=1
    fi
done <<< "$UPG"

if [[ $FAIL -eq 0 ]]; then
    echo "[verify] Debian delta verification PASSED"
else
    echo "[verify] Debian delta verification FAILED"
fi

exit $FAIL
