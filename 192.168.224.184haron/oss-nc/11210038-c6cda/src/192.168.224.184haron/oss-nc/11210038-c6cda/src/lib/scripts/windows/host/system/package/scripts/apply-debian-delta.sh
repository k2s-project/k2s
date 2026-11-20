#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Apply Debian delta package updates
# This script is copied into the delta package and executed on the Kubemaster VM
# to apply package changes (add/remove/upgrade) and run kubeadm upgrade.

set -euo pipefail

echo "[debian-delta] Apply start"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ADDED_FILE=packages.added
REMOVED_FILE=packages.removed
UPGRADED_FILE=packages.upgraded
PKG_DIR=packages
INSTALL_SPECS=()

# Remove packages that were removed between versions
if [[ -f "$REMOVED_FILE" ]]; then
    echo "[debian-delta] Purging removed packages"
    xargs -r dpkg --purge < "$REMOVED_FILE" || true
fi

# Collect added packages
if [[ -f "$ADDED_FILE" ]]; then
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        INSTALL_SPECS+=("$l")
    done < "$ADDED_FILE"
fi

# Collect upgraded packages (format: name old_version new_version)
if [[ -f "$UPGRADED_FILE" ]]; then
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        PKG=$(echo "$l" | awk '{print $1}')
        NEWV=$(echo "$l" | awk '{print $3}')
        INSTALL_SPECS+=("${PKG}=${NEWV}")
    done < "$UPGRADED_FILE"
fi

# Install local .deb files if present
if [[ -d "$PKG_DIR" ]]; then
    shopt -s nullglob
    DEBS=($PKG_DIR/*.deb)
    if [[ ${#DEBS[@]} -gt 0 ]]; then
        echo "[debian-delta] Installing local .deb files (${#DEBS[@]})"
        dpkg -i "${DEBS[@]}" || true
        # Attempt to fix missing dependencies without network if possible
        if command -v apt-get >/dev/null 2>&1; then
            apt-get -y --no-install-recommends install -f || true
        fi
    else
        echo "[debian-delta] No local .deb files present"
    fi
fi

# Verify installed versions match expectations
if [[ ${#INSTALL_SPECS[@]} -gt 0 ]]; then
    echo "[debian-delta] Ensuring target versions for ${#INSTALL_SPECS[@]} packages"
    # Attempt version enforcement using dpkg (requires local .debs); fallback echo warnings
    for spec in "${INSTALL_SPECS[@]}"; do
        P=${spec%%=*}
        V=${spec#*=}
        CUR=$(dpkg-query -W -f='${Version}' "$P" 2>/dev/null || echo missing)
        if [[ "$CUR" != "$V" ]]; then
            echo "[debian-delta][warn] Version mismatch for $P expected $V got $CUR"
        fi
    done
else
    echo "[debian-delta] No packages specified for install/upgrade"
fi

# Hard guard: if the package declares an expected Kubernetes version, the installed kubelet MUST match
# it after the .deb install. Otherwise the package is incomplete (the Kubernetes .deb files were not
# downloaded during package creation) and the kubeadm upgrade below would silently re-apply the OLD
# version, leaving the Linux control plane unchanged. Fail loudly instead.
EXPECTED_K8S_FILE=expected-k8s-version
if [[ -f "$EXPECTED_K8S_FILE" ]]; then
    EXPECTED_K8S="$(tr -d '[:space:]' < "$EXPECTED_K8S_FILE")"
    ACTUAL_K8S="$(kubelet --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '')"
    if [[ -n "$EXPECTED_K8S" && "$ACTUAL_K8S" != "$EXPECTED_K8S" ]]; then
        echo "[debian-delta][error] Kubernetes version mismatch after package install: expected v${EXPECTED_K8S}, got v${ACTUAL_K8S:-none}." >&2
        echo "[debian-delta][error] The delta package is incomplete - the Kubernetes .deb files were not bundled (likely a failed download during package creation). Rebuild the delta package and re-apply." >&2
        exit 1
    fi
    echo "[debian-delta] Verified installed Kubernetes version v${ACTUAL_K8S} matches expected v${EXPECTED_K8S}"
fi

# Run kubeadm upgrade to migrate cluster configuration (manifests, kubelet flags, etc.)
echo "[debian-delta] Running kubeadm upgrade to migrate cluster configuration"
KUBE_VERSION=$(kubelet --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")

if [[ -n "$KUBE_VERSION" ]]; then
    echo "[debian-delta] Detected Kubernetes version: v${KUBE_VERSION}"

    # Load container images for air-gapped kubeadm upgrade
    # kubeadm upgrade apply requires control plane images (kube-apiserver, kube-controller-manager, etc.)
    # These images are pre-bundled in the delta package and copied to the VM
    IMAGES_DIR="$SCRIPT_DIR/images"
    if [[ -d "$IMAGES_DIR" ]]; then
        shopt -s nullglob
        TARFILES=("$IMAGES_DIR"/*.tar)
        if [[ ${#TARFILES[@]} -gt 0 ]]; then
            echo "[debian-delta] Loading ${#TARFILES[@]} container images for offline upgrade"
            for tarfile in "${TARFILES[@]}"; do
                echo "[debian-delta] Importing image: $(basename "$tarfile")"
                # Use buildah to import OCI archive (matches K2s Linux image format)
                if ! buildah pull oci-archive:"$tarfile" 2>&1; then
                    echo "[debian-delta][warn] Failed to import image: $(basename "$tarfile")"
                fi
            done
            echo "[debian-delta] Container images loaded successfully"
        fi
    fi

    # Reload systemd to pick up any changes to kubelet.service
    systemctl daemon-reload

    KUBEADM_PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "v${KUBE_VERSION}" | grep '/pause:' | tail -n 1 || true)"
    if [[ -n "$KUBEADM_PAUSE_IMAGE" ]]; then
        echo "[debian-delta] Configuring CRI-O pause image from kubeadm: $KUBEADM_PAUSE_IMAGE"
        mkdir -p /etc/crio/crio.conf.d
        {
            echo '[crio.image]'
            echo "pause_image = \"$KUBEADM_PAUSE_IMAGE\""
        } > /etc/crio/crio.conf.d/20-k2s-kubeadm-pause.conf
        if ! systemctl restart crio; then
            echo "[debian-delta][warn] Failed to restart CRI-O after pause image configuration; continuing"
        fi
    else
        echo "[debian-delta][warn] Could not resolve pause image from kubeadm; keeping CRI-O package default"
    fi

    # Verify kubeadm-required images are available before upgrade (informational)
    # This helps diagnose air-gapped environment issues and keeps pause version checks aligned with kubeadm.
    echo "[debian-delta] Verifying required kubeadm images..."
    MISSING_IMAGES=0
    REQUIRED_IMAGES=""
    if ! KUBEADM_IMAGES_OUTPUT="$(kubeadm config images list --kubernetes-version "v${KUBE_VERSION}" 2>&1)"; then
        echo "[debian-delta][warn] Could not retrieve kubeadm image list for Kubernetes v${KUBE_VERSION}"
        MISSING_IMAGES=$((MISSING_IMAGES + 1))
    else
        REQUIRED_IMAGES="$(printf '%s\n' "$KUBEADM_IMAGES_OUTPUT" | grep -E '^[^[:space:]]+/[^[:space:]]+:[^[:space:]]+$' || true)"
        if [[ -z "$REQUIRED_IMAGES" ]]; then
            echo "[debian-delta][warn] Kubeadm image list for Kubernetes v${KUBE_VERSION} is empty"
            MISSING_IMAGES=$((MISSING_IMAGES + 1))
        fi
    fi
    while IFS= read -r required_image; do
        [[ -z "$required_image" ]] && continue
        image_repo="${required_image%:*}"
        image_tag="${required_image##*:}"
        if ! crictl images 2>/dev/null | awk -v repo="$image_repo" -v tag="$image_tag" '$1 == repo && $2 == tag { found = 1 } END { exit found ? 0 : 1 }'; then
            echo "[debian-delta][warn] Kubeadm image may be missing: $required_image"
            MISSING_IMAGES=$((MISSING_IMAGES + 1))
        fi
    done <<< "$REQUIRED_IMAGES"
    if [[ $MISSING_IMAGES -eq 0 ]]; then
        echo "[debian-delta] All required kubeadm images verified"
    else
        echo "[debian-delta][warn] $MISSING_IMAGES kubeadm image(s) may be missing - kubeadm will attempt to proceed"
    fi

    # Run kubeadm upgrade apply with appropriate flags
    # --yes: auto-approve the upgrade
    # --certificate-renewal=false: preserve existing certificates
    # --etcd-upgrade=false: do not upgrade etcd (already handled by package)
    # --ignore-preflight-errors: skip CoreDNS plugin migration warnings and image pull attempts (air-gapped)
    if kubeadm upgrade apply "v${KUBE_VERSION}" --yes --certificate-renewal=false --etcd-upgrade=false --ignore-preflight-errors=CoreDNSUnsupportedPlugins,ImagePull 2>&1; then
        echo "[debian-delta] kubeadm upgrade completed successfully"

        # Cleanup imported image archives to free disk space
        if [[ -d "$IMAGES_DIR" ]]; then
            echo "[debian-delta] Cleaning up imported image archives"
            rm -rf "$IMAGES_DIR"
        fi
    else
        echo "[debian-delta][error] kubeadm upgrade failed; the control plane was not upgraded" >&2

        # Cleanup imported image archives even on failure
        if [[ -d "$IMAGES_DIR" ]]; then
            echo "[debian-delta] Cleaning up imported image archives"
            rm -rf "$IMAGES_DIR"
        fi

        # Fallback: Clean deprecated kubelet flags manually
        KUBEADM_FLAGS_FILE="/var/lib/kubelet/kubeadm-flags.env"
        if [[ -f "$KUBEADM_FLAGS_FILE" ]]; then
            echo "[debian-delta] Cleaning deprecated kubelet flags from $KUBEADM_FLAGS_FILE"
            # Remove --pod-infra-container-image (deprecated in 1.27, removed in 1.34)
            sed -i 's/--pod-infra-container-image=[^ "]*//g' "$KUBEADM_FLAGS_FILE"
            # Clean up whitespace
            sed -i 's/  */ /g' "$KUBEADM_FLAGS_FILE"
            sed -i 's/" /"/g' "$KUBEADM_FLAGS_FILE"
            echo "[debian-delta] Kubelet flags after cleanup: $(cat $KUBEADM_FLAGS_FILE)"
        fi
        exit 1
    fi
else
    echo "[debian-delta][warn] Could not detect Kubernetes version, skipping kubeadm upgrade"
fi

echo "[debian-delta] Apply complete"
