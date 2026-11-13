#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Debian 13 (Trixie) variant

# Arguments from PowerShell
TARGET_PATH="$1"
K8S_VERSION="$2"
PROXY="${3:-}"

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

# Setup functions
log_info() {
    echo "[K8sPackages] $1"
}

log_warning() {
    echo "[K8sPackages] WARNING: $1"
}

cleanup_and_create() {
    local path="$1"
    if [ -d "$path" ]; then
        rm -rf "$path"
    fi
    mkdir -p "$path"
}

refresh_apt_cache() {
    local max_retries=2
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        log_info "Refreshing apt package cache (attempt $attempt/$max_retries)..."
        if sudo env DEBIAN_FRONTEND=noninteractive timeout 300s apt-get update \
            -qq --yes --allow-releaseinfo-change \
            -o Acquire::Retries=2 \
            -o Acquire::http::Timeout=30 \
            -o Acquire::https::Timeout=30; then
            log_info "Apt package cache refresh completed"
            return 0
        fi

        log_warning "apt-get update failed (attempt $attempt/$max_retries)"
        if [ $attempt -lt $max_retries ]; then
            log_info "Repairing apt/dpkg state before retry"
            sudo dpkg --configure -a >/dev/null 2>&1 || true
            sudo apt --fix-broken install -y >/dev/null 2>&1 || true
        fi
        attempt=$((attempt + 1))
    done

    log_warning "apt-get update failed after $max_retries attempts"
    return 1
}

# Normalize K8S_VERSION to vX.Y for repo URLs (repos use minor version only)
# e.g. v1.35.0 -> v1.35, v1.35 -> v1.35
K8S_VERSION_REPO=$(echo "$K8S_VERSION" | sed 's/^\(v[0-9]*\.[0-9]*\).*/\1/')
if [ -z "$K8S_VERSION_REPO" ]; then
    K8S_VERSION_REPO="$K8S_VERSION"
fi

# Main execution
log_info "Starting Kubernetes package download"
log_info "Target path: $TARGET_PATH"
log_info "K8s version: $K8S_VERSION (repo version: $K8S_VERSION_REPO)"

# Wait for cloud-init to finish - SSH becomes available before cloud-init completes,
# so without this wait cloud-init still holds the dpkg lock and apt-get update fails instantly.
if command -v cloud-init >/dev/null 2>&1; then
    log_info "Waiting for cloud-init to complete..."
    sudo cloud-init status --wait >/dev/null 2>&1 || true
    log_info "cloud-init done"
fi

# Wait for any residual dpkg/apt locks to be released
log_info "Waiting for apt/dpkg locks..."
local_wait=0
while sudo fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    if [ $local_wait -ge 120 ]; then
        log_warning "Timed out waiting for dpkg locks after 120s - continuing anyway"
        break
    fi
    sleep 5
    local_wait=$((local_wait + 5))
    if [ $((local_wait % 30)) -eq 0 ]; then
        log_info "Still waiting for apt/dpkg locks (${local_wait}s elapsed)..."
    fi
done
log_info "apt/dpkg locks free"

# Setup paths
cleanup_and_create "$TARGET_PATH"

# # APT sandbox config
echo "APT::Sandbox::User \"root\";" | sudo tee /etc/apt/apt.conf.d/10sandbox-for-k2s > /dev/null

# Configure apt proxy if provided - must be set before any apt-get calls
if [ -n "$PROXY" ]; then
    log_info "Configuring apt proxy: $PROXY"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" \
        | sudo tee /etc/apt/apt.conf.d/90k2s-proxy > /dev/null
fi

# Copy ZScaler certificate (if exists)
if [[ "${K2S_DISABLE_ZSCALER_CERT_IMPORT:-false}" != true ]] && [ -f /tmp/ZScalerRootCA.crt ]; then
    log_info "Adding ZScaler certificate"
    sudo mv /tmp/ZScalerRootCA.crt /usr/local/share/ca-certificates/
    sudo update-ca-certificates
fi

download_packages() {
    local package_name="$1"
    local pkg_base="${package_name%%=*}"
    local pkg_version=""
    local max_retries=2
    local attempt=1
    local downloaded_main_package=0

    log_info "Downloading: $package_name"

    # Step 1: Download the main .deb (matches original PowerShell Command 1)
    while [ $attempt -le $max_retries ]; do
        local download_error_file
        download_error_file=$(mktemp)

        if cd "$TARGET_PATH" && sudo apt-get download "$package_name" 2>"$download_error_file"; then
            downloaded_main_package=1
            rm -f "$download_error_file"
            log_info "Downloaded main package: $package_name"
            break
        fi

        local download_error
        download_error=$(tr '\n' ' ' < "$download_error_file" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //;s/ $//')
        rm -f "$download_error_file"

        log_warning "Download failed for '$package_name' (attempt $attempt/$max_retries)"
        if [ -n "$download_error" ]; then
            log_warning "apt-get download error: $download_error"
        fi

        if [ $attempt -lt $max_retries ]; then
            log_info "Running repair before retry: dpkg --configure -a && apt --fix-broken install && apt-get update"
            sudo dpkg --configure -a >/dev/null 2>&1 || true
            sudo apt --fix-broken install -y >/dev/null 2>&1 || true
            sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes --allow-releaseinfo-change >/dev/null 2>&1 || true
        fi

        attempt=$((attempt + 1))
    done

    if [[ "$package_name" == *"="* ]]; then
        pkg_version="${package_name#*=}"
    fi

    local deb_pattern="${pkg_base}*.deb"
    if [ -n "$pkg_version" ]; then
        deb_pattern="${pkg_base}_${pkg_version}_*.deb"
    fi

    if ls "$TARGET_PATH"/${deb_pattern} >/dev/null 2>&1; then
        log_info "Resolving and downloading dependencies for: $package_name"
        cd "$TARGET_PATH" && sudo DEBIAN_FRONTEND=noninteractive \
            apt-get --reinstall install -y \
            --no-install-recommends --no-install-suggests \
            --simulate ./${deb_pattern} 2>/dev/null \
            | grep 'Inst ' \
            | cut -d ' ' -f 2 \
            | sort -u \
            | grep -v "^${pkg_base}$" \
            | xargs -r sh -c 'if [ -n "${K2S_APT_CONFIG:-}" ]; then sudo env APT_CONFIG="$K2S_APT_CONFIG" apt-get download "$@"; else sudo apt-get download "$@"; fi' sh 2>/dev/null || true

        log_info "Completed package set: $package_name"

        return 0
    fi

    if [ "$downloaded_main_package" -eq 1 ]; then
        return 0
    fi

    log_warning "Package was not downloaded: $package_name"
    return 1
}

resolve_kubernetes_package_version() {
    local package_name="$1"
    local upstream_version="${K8S_VERSION#v}"

    RESOLVED_K8S_PACKAGE_VERSION=$(apt-cache madison "$package_name" \
        | awk -v version="$upstream_version" '$3 ~ "^" version "-" { print $3 }' \
        | sort -V \
        | tail -n 1)

    if [ -z "$RESOLVED_K8S_PACKAGE_VERSION" ]; then
        log_warning "No apt package version found for $package_name matching Kubernetes $upstream_version"
        log_warning "Available versions for $package_name:"
        apt-cache madison "$package_name" || true
        return 1
    fi

    log_info "Resolved $package_name package version: $RESOLVED_K8S_PACKAGE_VERSION"
    return 0
}

download_required_kubernetes_package() {
    local package_name="$1"

    if ! resolve_kubernetes_package_version "$package_name"; then
        exit 1
    fi

    if ! download_packages "$package_name=$RESOLVED_K8S_PACKAGE_VERSION"; then
        log_warning "Required Kubernetes package was not downloaded: $package_name=$RESOLVED_K8S_PACKAGE_VERSION"
        exit 1
    fi

    if ! ls "$TARGET_PATH"/${package_name}_${RESOLVED_K8S_PACKAGE_VERSION}_*.deb >/dev/null 2>&1; then
        log_warning "Required Kubernetes package file is missing after download: $package_name=$RESOLVED_K8S_PACKAGE_VERSION"
        exit 1
    fi
}

log_info "=== Downloading Base Tools ==="
log_info "Refreshing apt package cache before base tools download"
if ! refresh_apt_cache; then
    log_warning "Initial apt package cache refresh failed"
    exit 1
fi

if ! download_packages 'gpg' || ! ls "$TARGET_PATH"/gpg*.deb >/dev/null 2>&1; then
    log_warning "gpg download failed; cannot continue"
    exit 1
fi
# apt-transport-https was removed from Debian 13 (Trixie): HTTPS support is
# built into apt natively and the package no longer exists in the archive.
download_packages 'ca-certificates'

set_kubernetes_apt_repository() {
    local K8S_VERSION="$1"
    local PROXY="${2:-}"
    local MAX_RETRIES=2

    log_info "Setting up repositories for K8s version: $K8S_VERSION"

    # Remove stale .list files from previous runs to avoid stale URL conflicts
    sudo rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/cri-o.list

    log_info "Step 1: Update package list (required before installing anything)"
    log_info "Updating apt package list before repository configuration"
    sudo env DEBIAN_FRONTEND=noninteractive timeout 300s apt-get update \
        -qq --yes --allow-releaseinfo-change \
        -o Acquire::Retries=2 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 2>&1 | grep -v "^Reading" | grep -v "^Building" || true
    
    log_info "Step 2: Install required tools (gpg and curl)"
    # Install GPG with retry and repair logic
    if ! install_with_retry "gpg" "$MAX_RETRIES"; then
        log_warning "gpg installation failed"
        exit 1
    fi
    
    # Install curl with retry and repair logic
    if ! install_with_retry "curl" "$MAX_RETRIES"; then
        log_warning "curl installation failed"
        exit 1
    fi
    
    log_info "Step 3: Download and configure Kubernetes and CRI-O repositories"

    # Setup proxy flag if provided
    PROXY_FLAG=""
    if [ -n "$PROXY" ]; then
        PROXY_FLAG="--proxy $PROXY"
    fi

    KUBERNETES_APT_KEYRING='/usr/share/keyrings/kubernetes-apt-keyring.gpg'
    
    # Clean up old keyring file
    sudo rm -f "$KUBERNETES_APT_KEYRING"
    
    # Download and convert the Kubernetes GPG key. Do not install from an
    # unauthenticated repository if the key cannot be verified.
    log_info "Downloading and converting Kubernetes GPG key"
    if sudo curl -fsSL $PROXY_FLAG "https://pkgs.k8s.io/core:/stable:/$K8S_VERSION_REPO/deb/Release.key" | sudo gpg --dearmor -o "$KUBERNETES_APT_KEYRING" 2>/dev/null; then
        echo "deb [signed-by=$KUBERNETES_APT_KEYRING] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION_REPO/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
        log_info "✓ Kubernetes repository configured successfully"
    else
        log_warning "Kubernetes key download or conversion failed"
        exit 1
    fi

    # ===== CRI-O REPOSITORY SETUP =====
    log_info "Setting up CRI-O repository via curl + GPG key"

    CRIO_KEY_FILE='/tmp/crio.key'
    CRIO_APT_KEYRING='/usr/share/keyrings/cri-o-apt-keyring.gpg'
    
    # Clean up old keyring file
    sudo rm -f "$CRIO_APT_KEYRING"
    
    # Download and convert the CRI-O GPG key. Do not fall back to a trusted
    # repository because this script provisions the host runtime.
    log_info "Downloading and converting CRI-O GPG key from OpenSUSE"
    if sudo curl -fsSL $PROXY_FLAG "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$K8S_VERSION_REPO/deb/Release.key" | sudo gpg --dearmor -o "$CRIO_APT_KEYRING" 2>/dev/null; then
        echo "deb [signed-by=$CRIO_APT_KEYRING] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$K8S_VERSION_REPO/deb/ /" | sudo tee /etc/apt/sources.list.d/cri-o.list > /dev/null
        log_info "✓ CRI-O repository configured successfully"
    else
        log_warning "CRI-O key download or conversion failed"
        exit 1
    fi

    # ===== UPDATE APT PACKAGE LIST =====
    log_info "Step 4: Final update of package list with new repositories"
    log_info "Refreshing apt package list with Kubernetes and CRI-O repositories"
    if ! sudo env DEBIAN_FRONTEND=noninteractive timeout 300s apt-get update \
        -qq --yes --allow-releaseinfo-change \
        -o Acquire::Retries=2 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30; then
        log_warning "Final apt package cache refresh failed"
        exit 1
    fi

}

install_with_retry() {
    local package="$1"
    local retries="$2"
    local attempt=1

    if [[ "${K2S_PACKAGE_DOWNLOAD_ONLY:-}" == true ]]; then
        if command -v "$package" >/dev/null 2>&1; then
            log_info "$package is available; skipping host installation for package download"
            return 0
        fi
        log_warning "$package is required as a host tool but is not installed"
        return 1
    fi
    
    while [ $attempt -le $retries ]; do
        log_info "Installing $package (attempt $attempt/$retries)"
        
        # Try to install - check exit status directly
        if sudo env DEBIAN_FRONTEND=noninteractive timeout 300s apt-get install \
            -qq --yes "$package" \
            -o Acquire::Retries=2 \
            -o Acquire::http::Timeout=30 \
            -o Acquire::https::Timeout=30 \
            -o DPkg::Lock::Timeout=60 >/dev/null 2>&1; then
            log_info "✓ $package ready (installed or already present)"
            return 0
        fi
        
        # Installation failed
        log_warning "$package installation failed (attempt $attempt/$retries)"
        
        if [ $attempt -lt $retries ]; then
            log_info "Attempting repair: dpkg --configure -a && apt --fix-broken install"
            sudo dpkg --configure -a 2>/dev/null || true
            sudo apt --fix-broken install -y 2>/dev/null || true
            attempt=$((attempt + 1))
        else
            log_warning "$package installation failed after $retries retries - continuing with soft failure"
            return 1
        fi
    done
}

set_kubernetes_apt_repository "$K8S_VERSION_REPO" "$PROXY"

log_info "=== Downloading CRI-O ==="
download_packages 'cri-o'

log_info "=== Downloading cri-tools (crictl) ==="
download_packages 'cri-tools'

log_info "=== Downloading Kubernetes Tools ==="
SHORT_K8S_VERSION="${K8S_VERSION#v}"
log_info "Target Kubernetes upstream version: $SHORT_K8S_VERSION"

download_required_kubernetes_package "kubectl"
download_required_kubernetes_package "kubelet"
download_required_kubernetes_package "kubeadm"

# Cleanup extra versions (keep only the requested upstream version)
log_info "Cleaning up extra package versions"
NODE_ARCH="$(dpkg --print-architecture)"
cd "$TARGET_PATH" && sudo find . -maxdepth 1 -type f \
    \( -name 'kubeadm_*.deb' -o -name 'kubectl_*.deb' -o -name 'kubelet_*.deb' \) \
    ! -name "*_${SHORT_K8S_VERSION}-*_${NODE_ARCH}.deb" \
    -exec sudo rm -f {} + || true

if ! ls "$TARGET_PATH"/cri-tools*.deb >/dev/null 2>&1; then
    log_warning "Required cri-tools package was not downloaded"
    exit 1
fi

log_info "Download verification:"
log_info "Total packages: $(ls "$TARGET_PATH"/*.deb 2>/dev/null | wc -l)"
ls -lh "$TARGET_PATH"/*.deb 2>/dev/null || true

# Remove temporary apt proxy config
if [ -n "$PROXY" ]; then
    sudo rm -f /etc/apt/apt.conf.d/90k2s-proxy
fi

   
