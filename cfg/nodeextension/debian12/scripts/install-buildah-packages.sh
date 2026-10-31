#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"

echo "[BuildahInstall] Installing buildah packages from '$BUILDAH_DEB_PACKAGES_PATH'"

# ---------------------------------------------------------------------------
# Wait for dpkg lock (unattended-upgrades may hold it)
# ---------------------------------------------------------------------------
wait_for_dpkg_lock() {
    local max_wait=300  # 5 minutes
    local waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ $waited -ge $max_wait ]; then
            echo "[BuildahInstall] ERROR: Timeout waiting for dpkg lock after ${max_wait}s" >&2
            exit 1
        fi
        echo "[BuildahInstall] Waiting for dpkg lock (held by another process)..."
        sleep 5
        waited=$((waited + 5))
    done
    if [ $waited -gt 0 ]; then
        echo "[BuildahInstall] dpkg lock released after ${waited}s"
    fi
}

wait_for_dpkg_lock

# dpkg installs packages in the order the shell glob expands (alphabetical).
# A package like libgpgme11 may appear before its own deps (gnupg, libassuan0),
# leaving it unconfigured after pass 1. Running dpkg -i multiple times lets
# each pass configure packages whose deps are now satisfied by the previous pass.
# --no-remove prevents apt --fix-broken from evicting buildah when the fresh
# node has not yet configured all of buildah's transitively-needed packages.
for pass in 1 2 3; do
    echo "[BuildahInstall] dpkg install pass $pass"
    sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew -i "$BUILDAH_DEB_PACKAGES_PATH"/*.deb 2>&1 || true
done

# Repair any remaining dependency issues but do NOT remove packages.
sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y --no-remove 2>&1 || true

# Verify buildah is actually usable - this is the definitive success check.
if ! sudo buildah --version > /dev/null 2>&1; then
    echo "[BuildahInstall] ERROR: buildah is not functional after installation"
    exit 1
fi

# Add unqualified-search-registries only if not already present (prevents duplicate entries on retry)
sudo mkdir -p /etc/containers
if ! grep -q '^[[:space:]]*unqualified-search-registries[[:space:]]*=' /etc/containers/registries.conf 2>/dev/null; then
    echo 'unqualified-search-registries = ["docker.io", "quay.io"]' | sudo tee -a /etc/containers/registries.conf
else
    echo "[BuildahInstall] unqualified-search-registries already configured in /etc/containers/registries.conf, skipping"
fi

echo "[BuildahInstall] Finished installing buildah"
