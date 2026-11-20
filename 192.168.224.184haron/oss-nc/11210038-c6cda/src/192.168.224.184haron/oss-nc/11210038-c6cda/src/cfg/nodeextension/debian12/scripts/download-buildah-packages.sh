#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# download-buildah-packages.sh
#
# Downloads buildah and its dependencies as .deb packages from the Debian APT
# repository for offline installation.
#
# Arguments:
#   $1 - Target path on the remote machine to store downloaded .deb packages
#        (e.g. /home/sk/apt-offline-k2s/buildah)
#   $2 - Optional HTTP/HTTPS proxy URL

BUILDAH_DEB_PACKAGES_PATH="${1:?Argument missing: BuildahDebPackagesPath}"
PROXY="${2:-}"

if [[ -n "${K2S_APT_CONFIG:-}" || "${K2S_PACKAGE_DOWNLOAD_ONLY:-}" == true ]]; then
    sudo() {
        if [[ "${K2S_PACKAGE_DOWNLOAD_ONLY:-}" == true ]]; then
            case "${1:-}" in
                dpkg) return 0 ;;
                apt)
                    if [[ "${2:-}" == "--fix-broken" ]]; then
                        return 0
                    fi
                    ;;
            esac
        fi
        if [[ -n "${K2S_APT_CONFIG:-}" ]]; then
            command sudo env APT_CONFIG="$K2S_APT_CONFIG" "$@"
        else
            command sudo "$@"
        fi
    }
fi

log_info() {
    echo "[BuildahPkg] $1"
}

log_info "Starting download of buildah packages"
log_info "Target path: $BUILDAH_DEB_PACKAGES_PATH"

cleanup_proxy_config() {
    if [ -n "$PROXY" ]; then
        sudo rm -f /etc/apt/apt.conf.d/95k2s-proxy
    fi
}

trap cleanup_proxy_config EXIT

# ---------------------------------------------------------------------------
# Prepare target directory
# ---------------------------------------------------------------------------
if [ -d "$BUILDAH_DEB_PACKAGES_PATH" ]; then
    rm -rf "$BUILDAH_DEB_PACKAGES_PATH"
fi
mkdir -p "$BUILDAH_DEB_PACKAGES_PATH"

# APT sandbox config
echo 'APT::Sandbox::User "root";' | sudo tee /etc/apt/apt.conf.d/10sandbox-for-k2s > /dev/null

# Configure apt proxy if provided (ensures apt-get download uses the same proxy path)
if [ -n "$PROXY" ]; then
    log_info "Configuring apt proxy: $PROXY"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" | sudo tee /etc/apt/apt.conf.d/95k2s-proxy > /dev/null
fi

cd "$BUILDAH_DEB_PACKAGES_PATH"

download_packages() {
    local package_name="$1"
    local deb_pattern="${package_name%%=*}*.deb"

    log_info "Downloading: $package_name"

    cd "$BUILDAH_DEB_PACKAGES_PATH" && sudo apt-get download "$package_name" 2>/dev/null || true

    if ls "$BUILDAH_DEB_PACKAGES_PATH"/${deb_pattern} >/dev/null 2>&1; then
        cd "$BUILDAH_DEB_PACKAGES_PATH" && \
        sudo DEBIAN_FRONTEND=noninteractive \
            apt-get --reinstall install -y \
            -o DPkg::Options::="--force-confnew" \
            --no-install-recommends --no-install-suggests \
            --simulate ./${deb_pattern} 2>/dev/null \
            | grep 'Inst ' \
            | cut -d ' ' -f 2 \
            | sort -u \
            | xargs -r sh -c 'if [ -n "${K2S_APT_CONFIG:-}" ]; then sudo env APT_CONFIG="$K2S_APT_CONFIG" apt-get download "$@"; else sudo apt-get download "$@"; fi' sh 2>/dev/null || true
    fi
}

log_info "=== Downloading buildah and dependencies ==="

download_packages 'buildah'

# Explicitly download the recommended package crun (with retry + repair)
log_info "Downloading recommended package: crun"
for attempt in 1 2; do
    if (cd "$BUILDAH_DEB_PACKAGES_PATH" && sudo apt-get download crun 2>/dev/null); then
        break
    fi

    log_info "crun download attempt $attempt failed; running repair"
    sudo dpkg --configure -a >/dev/null 2>&1 || true
    sudo apt --fix-broken install -y >/dev/null 2>&1 || true

    if [ "$attempt" -eq 2 ]; then
        log_info "WARNING: failed to download crun after 2 attempts"
    fi
done

# crun's dependencies (e.g. libyajl2) may be pre-installed on the control plane
# and therefore missed by the simulate-reinstall approach above.
# Discover them dynamically via a fresh repo simulation and download what is missing.
log_info "Downloading missing dependencies of crun"
cd "$BUILDAH_DEB_PACKAGES_PATH" && \
sudo DEBIAN_FRONTEND=noninteractive \
    apt-get --simulate install \
    --no-install-recommends --no-install-suggests \
    crun 2>/dev/null \
    | grep '^Inst ' \
    | cut -d ' ' -f 2 \
    | sort -u \
    | xargs -r sh -c 'if [ -n "${K2S_APT_CONFIG:-}" ]; then sudo env APT_CONFIG="$K2S_APT_CONFIG" apt-get download "$@"; else sudo apt-get download "$@"; fi' sh 2>/dev/null || true

log_info "Downloaded packages:"
ls -1 "$BUILDAH_DEB_PACKAGES_PATH"

log_info "Finished downloading buildah packages successfully"
