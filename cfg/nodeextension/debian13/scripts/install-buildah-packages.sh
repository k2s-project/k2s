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

# Links packages with an absent or incompatible installed version into a new directory and prints
# that directory. Buildah/runtime packages use the bundled version exactly; other packages are
# retained when their installed version is at least as new as the bundled dependency version.
stage_missing_debs() {
    local source_dir="$1" target_dir deb package package_version installed_status installed_version
    target_dir="$(mktemp -d)"
    for deb in "$source_dir"/*.deb; do
        [ -e "$deb" ] || continue
        package="$(dpkg-deb -f "$deb" Package)"
        package_version="$(dpkg-deb -f "$deb" Version)"
        installed_status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
        if [[ "$installed_status" == 'install ok installed' ]]; then
            installed_version="$(dpkg-query -W -f='${Version}' "$package")"
            case "$package" in
                buildah|crun|netavark|aardvark-dns|nftables)
                    [[ "$installed_version" == "$package_version" ]] && continue
                    ;;
                *)
                    dpkg --compare-versions "$installed_version" ge "$package_version" && continue
                    ;;
            esac
        fi
        ln -s "$deb" "$target_dir/"
    done
    echo "$target_dir"
}

BUILDAH_MISSING_DEBS_PATH="$(stage_missing_debs "$BUILDAH_DEB_PACKAGES_PATH")"
echo "[BuildahInstall] Packages not yet installed on this node: $(ls "$BUILDAH_MISSING_DEBS_PATH" | wc -l)"

# Multi-pass dpkg: alphabetical glob order can place a package before its deps
# are configured. Three passes let each iteration configure more packages.
# --no-remove prevents apt --fix-broken from evicting buildah.
for pass in 1 2 3; do
    echo "[BuildahInstall] dpkg install pass $pass"
    sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew -i "$BUILDAH_MISSING_DEBS_PATH"/*.deb 2>&1 || true
done

sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y --no-remove 2>&1 || true

# Verify buildah is actually usable - this is the definitive success check.
if ! sudo buildah --version > /dev/null 2>&1; then
    echo "[BuildahInstall] ERROR: buildah is not functional after installation"
    exit 1
fi

# netavark requires nft from nftables at runtime for networking during image builds.
if ! sudo dpkg-query -W -f='${Status}' nftables 2>/dev/null | grep -q "install ok installed"; then
    echo "[BuildahInstall] ERROR: nftables is not fully installed"
    exit 1
fi

if ! sudo nft --version > /dev/null 2>&1; then
    echo "[BuildahInstall] ERROR: nft binary is not available"
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
