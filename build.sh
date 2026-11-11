#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Native Linux build for the K2s Go executables -- no PowerShell required.
#
# Mirrors the Linux build performed by smallsetup/common/BuildGoExe.ps1
# (GOOS=linux, GOARCH=amd64, GOFIPS140=certified, matching ldflags and
# gcflags, and the same version metadata injected into internal/version).
#
# Usage:
#   ./build.sh                 build all Linux executables
#   ./build.sh --proxy URL     route Go module downloads through a proxy
#   ./build.sh -h | --help     show usage

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [--proxy URL]

Builds the Linux-targeted K2s Go executables natively (no PowerShell):
    k2s                 -> k2s
  cloudinitisobuilder -> bin/
  httpproxy           -> bin/
    dnsproxy            -> bin/
  yaml2json           -> bin/

The Linux CLI is named k2s; the Windows CLI artifact is k2s.exe.
Helper executables are placed in bin/.

Options:
  --proxy URL   Set HTTP_PROXY/HTTPS_PROXY for Go module downloads.
  -h, --help    Show this help.
EOF
}

PROXY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy)
            if [[ $# -lt 2 ]]; then
                echo "error: --proxy requires a URL argument" >&2
                exit 2
            fi
            PROXY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Repository root = directory containing this script.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

if ! command -v go >/dev/null 2>&1; then
    echo "error: 'go' not found on PATH. Install Go (see go.mod for the required version)." >&2
    exit 1
fi


unset GOEXPERIMENT # ensure stale boringcrypto value doesn't linger
export GOFIPS140=certified # GOFIPS140=certified for FIPS compliance (matches BuildGoExe.ps1).
export GOOS=linux
export GOARCH=amd64

if [[ -n "$PROXY" ]]; then
    echo "Using proxy: $PROXY"
    export HTTP_PROXY="$PROXY"
    export HTTPS_PROXY="$PROXY"
fi

# VERSION
VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
echo "VERSION: $VERSION"

# BUILD DATE
BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "BUILD_DATE: $BUILD_DATE"

# GIT COMMIT, TREE STATE, AND TAG
# Falls back to "unknown" (instead of aborting the build under `set -e`)
# when the script runs outside a git working tree, e.g. from files copied
# without .git.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    GIT_COMMIT="$(git rev-parse HEAD)"

    GIT_TAG=""
    GIT_TREE_STATE="clean"

    if [[ -n "$(git status --porcelain)" ]]; then
        GIT_TREE_STATE="dirty"
    else
        GIT_TAG="$(git describe --exact-match --tags HEAD 2>/dev/null || true)"
    fi
else
    echo "No git repository found."

    GIT_COMMIT="unknown"
    GIT_TAG=""
    GIT_TREE_STATE="unknown"
fi
echo "GIT_COMMIT: $GIT_COMMIT"
echo "GIT_TREE_STATE: $GIT_TREE_STATE"

VERSION_PKG="github.com/k2s-project/k2s/internal/version"
LDFLAGS="-s -w \
-X ${VERSION_PKG}.version=${VERSION} \
-X ${VERSION_PKG}.buildDate=${BUILD_DATE} \
-X ${VERSION_PKG}.gitCommit=${GIT_COMMIT} \
-X ${VERSION_PKG}.gitTag=${GIT_TAG} \
-X ${VERSION_PKG}.gitTreeState=${GIT_TREE_STATE}"

BIN_DIR="$REPO_ROOT/bin"
mkdir -p "$BIN_DIR"

# Linux-targeted executables: command package -> output file.
# Mirrors BuildGoExe.ps1's mapping minus the Windows-only apps.
#   app|output_path
BUILD_TARGETS=(
    "k2s|$REPO_ROOT/k2s"
    "cloudinitisobuilder|$BIN_DIR/cloudinitisobuilder"
    "httpproxy|$BIN_DIR/httpproxy"
    "yaml2json|$BIN_DIR/yaml2json"
)

# Build each command from the repository-root Go module.

for target in "${BUILD_TARGETS[@]}"; do
    app="${target%%|*}"
    out_path="${target#*|}"
    echo "Building GO executable: $app -> $out_path ..."
    go build \
        -ldflags "$LDFLAGS" \
        -trimpath \
        -o "$out_path" \
        "./cmd/${app}"
    echo "Built: \"$out_path\""
done

DNSPROXY_VERSION="0.83.1"
DNSPROXY_SHA256="e3b82e72b8175a2278d56ba0230476014823d3d15c1bf48aad803051df4dce34"
if [[ ! "$DNSPROXY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$DNSPROXY_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
    echo "error: invalid pinned dnsproxy version or SHA-256" >&2
    exit 1
fi
DNSPROXY_ARCHIVE="dnsproxy-linux-amd64-v${DNSPROXY_VERSION}.tar.gz"
DNSPROXY_URL="https://github.com/AdguardTeam/dnsproxy/releases/download/v${DNSPROXY_VERSION}/${DNSPROXY_ARCHIVE}"
DNSPROXY_OUTPUT="$BIN_DIR/dnsproxy"
echo "Downloading pinned dnsproxy v${DNSPROXY_VERSION} -> $DNSPROXY_OUTPUT ..."
curl --fail --location --retry 3 --output "$BIN_DIR/$DNSPROXY_ARCHIVE" "$DNSPROXY_URL"
printf '%s  %s\n' "$DNSPROXY_SHA256" "$BIN_DIR/$DNSPROXY_ARCHIVE" | sha256sum --check --status
tar --extract --gzip --file "$BIN_DIR/$DNSPROXY_ARCHIVE" --directory "$BIN_DIR" --strip-components=2 "./linux-amd64/dnsproxy"
rm -f "$BIN_DIR/$DNSPROXY_ARCHIVE"
chmod +x "$DNSPROXY_OUTPUT"

echo '---------------------------------------------------------------'
echo ' Build finished.'
echo '---------------------------------------------------------------'
