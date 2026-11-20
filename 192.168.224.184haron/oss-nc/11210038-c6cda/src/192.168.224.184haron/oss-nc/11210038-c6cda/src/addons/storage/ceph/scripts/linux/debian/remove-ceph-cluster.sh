#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# remove-ceph-cluster.sh  -  Debian (12/13) variant
#
# Tears down a Ceph cluster that was bootstrapped on this node by
# create-ceph-cluster.sh and cleans up the artifacts installed by it
# (cephadm binary, Ceph apt repository/packages, Ceph container images).
#
# Invoked remotely by addons/storage/ceph/scripts/linux/debian/Remove-CephCluster.ps1
# via Invoke-RemoteScript when the storage/ceph addon is disabled and the cluster
# had been provisioned by the addon (clusterMode != 'existing').
#
# Arguments:
#   $1 - Optional Ceph cluster FSID (ceph-config.json 'clusterId'). When omitted,
#        every cluster found under /var/lib/ceph is removed.

FSID="${1:-}"

log_info() {
    echo "[CephRemove] $1"
}

log_error() {
    echo "[CephRemove] ERROR: $1" >&2
}

log_info "Starting Ceph cluster teardown on Debian (fsid='${FSID:-<all>}')"

# Locate a usable cephadm binary (system-installed, downloaded, or leftover in /tmp).
CEPHADM_BIN=''
for candidate in "$(command -v cephadm 2>/dev/null || true)" /usr/sbin/cephadm /usr/bin/cephadm /sbin/cephadm "$(pwd)/cephadm" /tmp/cephadm; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        CEPHADM_BIN="$candidate"
        break
    fi
done
if [ -n "$CEPHADM_BIN" ]; then
    log_info "Using cephadm binary: $CEPHADM_BIN"
else
    log_info "No cephadm binary found; will fall back to manual cleanup"
fi

remove_cluster() {
    local fsid="$1"
    if [ -z "$fsid" ]; then
        return
    fi
    log_info "Removing Ceph cluster fsid $fsid"
    if [ -n "$CEPHADM_BIN" ]; then
        # --zap-osds wipes any OSD block devices; --force skips the confirmation prompt.
        sudo "$CEPHADM_BIN" rm-cluster --force --zap-osds --fsid "$fsid" \
            || log_info "cephadm rm-cluster failed for $fsid (continuing with manual cleanup)"
    fi
}

if [ -n "$FSID" ]; then
    remove_cluster "$FSID"
elif [ -d /var/lib/ceph ]; then
    # No fsid provided - discover and remove every cluster present on the host.
    for dir in /var/lib/ceph/*/; do
        [ -d "$dir" ] || continue
        candidate_fsid="$(basename "$dir")"
        if [[ "$candidate_fsid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            remove_cluster "$candidate_fsid"
        fi
    done
fi

# Stop any Ceph systemd units that may still be running.
log_info "Stopping remaining Ceph systemd units"
sudo systemctl stop 'ceph-*.target' 2>/dev/null || true
sudo systemctl stop 'ceph-*.service' 2>/dev/null || true
sudo systemctl stop ceph.target 2>/dev/null || true

# Remove leftover configuration, data and runtime directories.
log_info "Removing Ceph configuration and data directories"
sudo rm -rf /etc/ceph /var/lib/ceph /var/log/ceph /run/ceph

# Remove the downloaded cephadm binaries.
sudo rm -f /tmp/cephadm "$(pwd)/cephadm"

# Remove the Ceph apt repository and host-side packages installed by 'cephadm add-repo/install'.
log_info "Removing Ceph apt repository and host packages"
sudo rm -f /etc/apt/sources.list.d/ceph.list
sudo rm -f /etc/apt/trusted.gpg.d/ceph.asc /etc/apt/trusted.gpg.d/ceph.gpg

# Force-purge the cephadm package. Its post-removal (postrm) script runs
# 'deluser --remove-home ceph', which requires the 'perl' package. On a minimal Debian
# node 'perl' is usually absent, so a plain 'apt-get remove' fails and leaves dpkg in a
# half-configured state. To keep this offline and robust we neutralize cephadm's maintainer
# scripts first, then force-purge, then let dpkg reconcile any half-removed state.
purge_pkg() {
    local pkg="$1"
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        return
    fi
    log_info "Purging package '$pkg'"
    # Blank out the pre/post-removal maintainer scripts so they cannot fail the purge.
    for script in prerm postrm; do
        local scriptPath="/var/lib/dpkg/info/${pkg}.${script}"
        if [ -f "$scriptPath" ]; then
            printf '#!/bin/sh\nexit 0\n' | sudo tee "$scriptPath" >/dev/null
            sudo chmod +x "$scriptPath"
        fi
    done
    sudo dpkg --purge --force-all "$pkg" 2>/dev/null || log_info "dpkg purge of '$pkg' reported errors (continuing)"
}

purge_pkg cephadm
purge_pkg ceph-common

# Reconcile any package left half-configured by an earlier failed removal.
sudo dpkg --configure -a 2>/dev/null || true
sudo apt-get --fix-broken install -y 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

# Remove Ceph-related container images left on the node. This covers the Ceph daemon
# image pulled by the bootstrap (quay.io/ceph/ceph, quay.io/ceph/ceph-grafana), the Ceph
# CSI images cached for the driver pods (quay.io/cephcsi/*) and the upstream CSI sidecar
# images the ceph-csi driver pulls onto this node's containerd
# (registry.k8s.io/sig-storage/* e.g. csi-node-driver-registrar, csi-provisioner,
# csi-attacher, csi-resizer, csi-snapshotter, livenessprobe).
#
# On a K2s Linux node several container engines can hold these images and may share or use
# separate stores (buildah is the primary tool and shares containers/storage with podman;
# containerd is accessed via nerdctl/crictl). The bootstrap uses podman, but 'buildah images'
# also lists them, so remove from every engine that is present. The container engines
# themselves are left installed as they are general-purpose tools used elsewhere.
CEPH_IMAGE_PATTERN='^(quay\.io/(ceph/|cephcsi/)|registry\.k8s\.io/sig-storage/)'

remove_ceph_images_with_engine() {
    local tool="$1"
    local nameField="$2"   # image-name format field for this engine
    command -v "$tool" >/dev/null 2>&1 || return 0

    local imgs
    imgs="$(sudo "$tool" images --format "{{.${nameField}}}:{{.Tag}}" 2>/dev/null | grep -E "$CEPH_IMAGE_PATTERN" | sort -u)"
    if [ -z "$imgs" ]; then
        return 0
    fi

    log_info "Removing Ceph container images via $tool"
    echo "$imgs" | while IFS= read -r img; do
        [ -n "$img" ] || continue
        log_info "  removing image '$img' ($tool)"
        sudo "$tool" rmi -f "$img" 2>/dev/null || true
    done
}

# podman and nerdctl expose the repository via '.Repository'; buildah uses '.Name'.
remove_ceph_images_with_engine podman Repository
remove_ceph_images_with_engine buildah Name
remove_ceph_images_with_engine nerdctl Repository

# containerd via crictl (columns: IMAGE  TAG  IMAGE-ID  SIZE). crictl has no Go-template
# formatting, so parse the tabular output. Guarded so it is a no-op when crictl is unconfigured.
if command -v crictl >/dev/null 2>&1; then
    ceph_crictl_imgs="$(sudo crictl images 2>/dev/null | awk 'NR>1 && $1 ~ /^(quay\.io\/(ceph\/|cephcsi\/)|registry\.k8s\.io\/sig-storage\/)/ {print $1":"$2}' | sort -u)"
    if [ -n "$ceph_crictl_imgs" ]; then
        log_info "Removing Ceph container images via crictl"
        echo "$ceph_crictl_imgs" | while IFS= read -r img; do
            [ -n "$img" ] || continue
            log_info "  removing image '$img' (crictl)"
            sudo crictl rmi "$img" >/dev/null 2>&1 || true
        done
    fi
fi

log_info "Ceph cluster teardown completed on Debian"
