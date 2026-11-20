#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Apply node delta package updates
# This script is copied into a node delta package and executed on the Linux worker node
# to apply package changes (add/remove/upgrade), import bundled images, and refresh kubelet runtime state.

set -euo pipefail

echo "[node-delta] Apply start"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PKG_ROOT=packages
REMOVED_FILE=packages.removed
IMAGES_REMOVED_FILE=images.removed
IMAGES_DIR=images
OS_DIR="${1:-}"

remove_image_best_effort() {
    local image_ref="$1"
    [[ -z "$image_ref" ]] && return 0

    if command -v crictl >/dev/null 2>&1; then
        crictl rmi "$image_ref" >/dev/null 2>&1 || true
    fi
    if command -v ctr >/dev/null 2>&1; then
        ctr -n k8s.io images rm "$image_ref" >/dev/null 2>&1 || true
    fi
    if command -v podman >/dev/null 2>&1; then
        podman rmi "$image_ref" >/dev/null 2>&1 || true
    fi
    if command -v buildah >/dev/null 2>&1; then
        buildah rmi "$image_ref" >/dev/null 2>&1 || true
    fi
}

if [[ ! -d "$PKG_ROOT" ]]; then
    echo "[node-delta][warn] Packages directory not found: $PKG_ROOT"
else
    if [[ -z "$OS_DIR" ]]; then
        OS_DIR="$(find "$PKG_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n1 | xargs -r basename)"
    fi

    if [[ -z "$OS_DIR" || ! -d "$PKG_ROOT/$OS_DIR" ]]; then
        echo "[node-delta][warn] Could not determine OS directory under $PKG_ROOT"
    else
        shopt -s globstar nullglob
        DEBS=("$PKG_ROOT/$OS_DIR"/**/*.deb)
        if [[ ${#DEBS[@]} -gt 0 ]]; then
            echo "[node-delta] Installing local .deb files (${#DEBS[@]}) from $PKG_ROOT/$OS_DIR"
            dpkg -i "${DEBS[@]}" || true
            if command -v apt-get >/dev/null 2>&1; then
                apt-get -y --no-install-recommends install -f || true
            fi
        else
            echo "[node-delta] No local .deb files present under $PKG_ROOT/$OS_DIR"
        fi
    fi
fi

# Purge removed packages (supports package names and .deb filenames)
if [[ -f "$REMOVED_FILE" ]]; then
    echo "[node-delta] Purging removed packages"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        entry="$(basename "$line")"
        if [[ "$entry" == *.deb ]]; then
            pkg="${entry%%_*}"
        else
            pkg="$entry"
        fi
        [[ -z "$pkg" ]] && continue
        dpkg --purge "$pkg" || true
    done < "$REMOVED_FILE"
fi

# Remove container images listed in images.removed (best effort)
if [[ -f "$IMAGES_REMOVED_FILE" ]]; then
    echo "[node-delta] Removing images listed in $IMAGES_REMOVED_FILE"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        entry="$(basename "$line")"
        name="${entry%.tar}"
        # Convert archive naming to image reference (matches package generation fallback):
        # '__' -> ':' then '_' -> '/'
        image_ref="${name//__/:}"
        image_ref="${image_ref//_//}"
        remove_image_best_effort "$image_ref"
    done < "$IMAGES_REMOVED_FILE"
fi

# Import bundled OCI archives if available
if [[ -d "$IMAGES_DIR" ]]; then
    shopt -s nullglob
    TARFILES=("$IMAGES_DIR"/*.tar)
    if [[ ${#TARFILES[@]} -gt 0 ]]; then
        echo "[node-delta] Loading ${#TARFILES[@]} container images"
        for tarfile in "${TARFILES[@]}"; do
            echo "[node-delta] Importing image: $(basename "$tarfile")"
            if ! buildah pull oci-archive:"$tarfile" 2>&1; then
                echo "[node-delta][warn] Failed to import image: $(basename "$tarfile")"
            fi
        done
    else
        echo "[node-delta] No image archives present"
    fi
fi

# Reload systemd state if unit files changed as part of package updates
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

echo "[node-delta] Apply complete"
