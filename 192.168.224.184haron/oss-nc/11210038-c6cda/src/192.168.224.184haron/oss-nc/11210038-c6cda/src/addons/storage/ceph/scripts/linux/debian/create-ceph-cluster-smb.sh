#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# create-ceph-cluster-smb.sh  -  Debian 13 variant
#
# Configures Ceph's built-in SMB support (the 'mgr/smb' module,
# https://docs.ceph.com/en/latest/mgr/smb/) on an ALREADY-RUNNING Ceph cluster so that an
# existing CephFS volume is exported over SMB. cephadm deploys managed Samba containers on the
# hosts carrying the placement label; the storage/ceph addon then provisions PVCs from the
# resulting SMB share via the SMB CSI driver so Windows (and Linux) pods can consume CephFS.
#
# This script does NOT bootstrap a cluster - it assumes create-ceph-cluster.sh already ran and
# the CephFS volume named in the arguments exists. It is invoked remotely by
# addons/storage/ceph/scripts/linux/debian/New-CephSmbCluster.ps1 via Invoke-RemoteScript when
# the ceph addon is enabled with the -w / setupWindowsNode flag.
#
# Arguments:
#   $1 - Optional Ceph image reference (from storage addon additionalImages); when set it is
#          pinned as the container_image so the Samba daemons deploy offline/air-gapped
#   $2 - CephFS volume name to export (from ceph-config.json 'cephfsFilesystem')
#   $3 - SMB cluster id (mgr/smb cluster identifier, from ceph-config.json 'smb.clusterId')
#   $4 - SMB share id (mgr/smb share identifier, from ceph-config.json 'smb.shareId')
#   $5 - SMB share name presented to clients (from ceph-config.json 'smb.shareName')
#   $6 - SMB user name (standalone user for 'user' auth mode)
#   $7 - SMB password for the user
#   $8 - Optional CephFS path to export as the share root (default '/')
#   $9 - Optional cephadm host placement label for the Samba daemons (default 'smb')
#   $10 - Optional CephFS subvolume name to create and export (from ceph-config.json 'smb.subvolume').
#           When set, a dedicated CephFS subvolume is created and exported as the SMB share so the
#           same underlying storage is shared cross-OS; the SMB CSI StorageClass then places each PVC
#           in an isolated '<namespace>/<name>' sub-directory inside it.
#   $11 - Optional subvolume size in bytes (from ceph-config.json 'smb.subvolumeSizeInGb' * GiB)
#   $12 - Optional subvolume group name (default 'csi')

CEPH_IMAGE_INPUT="${1:-}"
CEPH_FS_NAME="${2:-cephfs}"
SMB_CLUSTER_ID="${3:-k2ssmb}"
SMB_SHARE_ID="${4:-cephfs}"
SMB_SHARE_NAME="${5:-$SMB_SHARE_ID}"
SMB_USER="${6:-}"
SMB_PASS="${7:-}"
SMB_PATH="${8:-/}"
PLACEMENT_LABEL="${9:-smb}"
SMB_SUBVOLUME="${10:-}"
SMB_SUBVOLUME_SIZE_BYTES="${11:-}"
SMB_SUBVOLUME_GROUP="${12:-csi}"
if [ -z "$SMB_SUBVOLUME_GROUP" ]; then
    SMB_SUBVOLUME_GROUP="csi"
fi


log_info() {
    echo "[CephSMB] $1"
}

log_error() {
    echo "[CephSMB] ERROR: $1" >&2
}

if [ -z "$SMB_USER" ] || [ -z "$SMB_PASS" ]; then
    log_error "SMB user and password arguments are required"
    exit 1
fi

case "$SMB_PASS" in
    *%*)
        log_error "SMB password must not contain the '%' character (it is the user/pass delimiter for mgr/smb)"
        exit 1
        ;;
esac

# Locate the cephadm binary the same way create-ceph-cluster.sh does; a non-root SSH session on
# Debian does not always have /usr/sbin on PATH.
CEPHADM_BIN="${CEPHADM_BIN:-}"
if [ -z "$CEPHADM_BIN" ]; then
    CEPHADM_BIN="$(command -v cephadm 2>/dev/null || true)"
fi
if [ -z "$CEPHADM_BIN" ]; then
    for candidate in /usr/sbin/cephadm /usr/bin/cephadm /sbin/cephadm; do
        if [ -x "$candidate" ]; then
            CEPHADM_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$CEPHADM_BIN" ]; then
    log_error "cephadm was not found (searched PATH, /usr/sbin, /usr/bin, /sbin). Is the Ceph cluster installed on this host?"
    exit 1
fi
log_info "Using cephadm binary: $CEPHADM_BIN"

# Thin wrapper: run a ceph CLI command inside a cephadm shell on this cluster host.
ceph_cmd() {
    sudo "$CEPHADM_BIN" shell -- ceph "$@"
}

# Ensure the Ceph command interface is reachable before doing anything.
# NOTE: 'timeout' is an external binary and cannot invoke shell functions, so the readiness
# check must use the full command inline (matching the pattern in create-ceph-cluster.sh).
for attempt in $(seq 1 18); do
    if timeout 30 sudo "$CEPHADM_BIN" shell -- ceph -s >/dev/null 2>&1; then
        break
    fi
    if [ "$attempt" -eq 18 ]; then
        log_error "Ceph did not become ready for shell commands."
        exit 1
    fi
    log_info "Ceph command interface not ready yet (attempt $attempt/18). Retrying in 10s..."
    sleep 10
done

# Verify the CephFS volume to export actually exists.
if ! ceph_cmd fs ls --format json 2>/dev/null | grep -q "\"name\":[[:space:]]*\"${CEPH_FS_NAME}\""; then
    log_error "CephFS volume '$CEPH_FS_NAME' was not found on this cluster. Enable the ceph addon first so the CephFS filesystem exists."
    exit 1
fi
log_info "Found CephFS volume '$CEPH_FS_NAME'"

# Offline/air-gapped: pin the container image used by cephadm-deployed daemons (including Samba) to
# the tag already loaded locally so the Samba service can start without registry access.
if [ -n "$CEPH_IMAGE_INPUT" ]; then
    if ceph_cmd config set global container_image "$CEPH_IMAGE_INPUT" >/dev/null 2>&1; then
        log_info "Pinned global container_image to '$CEPH_IMAGE_INPUT' for offline Samba deployment"
    else
        log_info "Failed to pin container_image to '$CEPH_IMAGE_INPUT' (continuing)"
    fi
fi

# Enable the mgr/smb module that provides the 'ceph smb ...' command family.
log_info "Enabling the Ceph 'smb' mgr module"
if ! ceph_cmd mgr module enable smb; then
    log_error "Failed to enable the Ceph 'smb' mgr module"
    exit 1
fi

# Give cephadm a moment to register the new module command interface.
for attempt in $(seq 1 12); do
    if ceph_cmd smb cluster ls >/dev/null 2>&1; then
        break
    fi
    if [ "$attempt" -eq 12 ]; then
        log_error "The 'ceph smb' command interface did not become available after enabling the module."
        exit 1
    fi
    log_info "'ceph smb' command interface not ready yet (attempt $attempt/12). Retrying in 5s..."
    sleep 5
done

# Only the Ceph bootstrap host should own the Samba service. The SMB CSI StorageClass connects to
# the cluster-host IP (for example 172.19.1.100), so deploying Ceph mgr/smb daemons onto every OSD
# host is not only unnecessary, it can cause CEPHADM_FAILED_DAEMON when one of those hosts does not
# have the needed network/runtime setup for the share. Use a label-based placement and keep that
# label only on the bootstrap host so the service is pinned to the master node.
CURRENT_HOST="$(hostname -s 2>/dev/null || hostname)"
SMB_PLACEMENT_SPEC="label:${PLACEMENT_LABEL}"
if [ -n "$CURRENT_HOST" ]; then
    log_info "Ensuring the current Ceph host '$CURRENT_HOST' carries the SMB placement label '$PLACEMENT_LABEL'"
    ceph_cmd orch host label add "$CURRENT_HOST" "$PLACEMENT_LABEL" >/dev/null 2>&1 || log_info "Failed to add label '$PLACEMENT_LABEL' to '$CURRENT_HOST' (may already be present; continuing)"
fi

# Recreate the SMB cluster idempotently: remove any pre-existing cluster with the same id (this also
# removes its shares) so a re-enable always yields a clean, correctly-configured cluster.
if ceph_cmd smb cluster ls 2>/dev/null | grep -q "\"cluster_id\":[[:space:]]*\"${SMB_CLUSTER_ID}\""; then
    log_info "Existing mgr/smb cluster '$SMB_CLUSTER_ID' detected; removing it before recreation"
    ceph_cmd smb cluster rm "$SMB_CLUSTER_ID" --recursive >/dev/null 2>&1 || log_info "Failed to remove existing smb cluster '$SMB_CLUSTER_ID' (continuing)"
fi

log_info "Creating mgr/smb cluster '$SMB_CLUSTER_ID' (user auth, placement '$SMB_PLACEMENT_SPEC')"
if ! ceph_cmd smb cluster create "$SMB_CLUSTER_ID" user \
        --define-user-pass="${SMB_USER}%${SMB_PASS}" \
        --placement="$SMB_PLACEMENT_SPEC"; then
    log_error "Failed to create mgr/smb cluster '$SMB_CLUSTER_ID'"
    exit 1
fi

# The smb module initializes an internal libcephfs/RADOS client on the first 'share create'
# that requires CephFS access. This client is not ready immediately after module enable +
# cluster create and returns 'rados_initialize failed with error code: -22' (EINVAL) if called
# too soon. Wait for the mgr/smb module's RADOS client to settle; the share create retry loop
# will catch any remaining issues.
log_info "Waiting for smb module RADOS client to settle before share creation..."
sleep 5

# Cross-OS shared storage: create a dedicated CephFS subvolume and export THAT as the SMB share.
# Both operating systems then address the same physical storage - Linux pods via the CephFS CSI
# driver and Windows pods via the SMB CSI driver - and the SMB CSI StorageClass places every PVC in
# an isolated '<namespace>/<name>' sub-directory inside the shared subvolume so the paths align.
# '--extra-config' forces 0777 create/directory modes so files created by one OS remain fully
# accessible from the other.
SMB_SHARE_ARGS=(smb share create "$SMB_CLUSTER_ID" "$SMB_SHARE_ID" "$CEPH_FS_NAME")
if [ -n "$SMB_SUBVOLUME" ]; then
    if ! ceph_cmd fs subvolumegroup ls "$CEPH_FS_NAME" --format json 2>/dev/null | grep -q "\"name\":[[:space:]]*\"${SMB_SUBVOLUME_GROUP}\""; then
        log_info "CephFS subvolume group '$SMB_SUBVOLUME_GROUP' does not exist on volume '$CEPH_FS_NAME'; creating it now"
        if ! ceph_cmd fs subvolumegroup create "$CEPH_FS_NAME" "$SMB_SUBVOLUME_GROUP" >/dev/null 2>&1; then
            log_error "Failed to create CephFS subvolume group '$SMB_SUBVOLUME_GROUP' on volume '$CEPH_FS_NAME'"
            exit 1
        fi
    else
        log_info "CephFS subvolume group '$SMB_SUBVOLUME_GROUP' already exists on volume '$CEPH_FS_NAME'"
    fi

    SUBVOL_CREATE_ARGS=(fs subvolume create "$CEPH_FS_NAME" "$SMB_SUBVOLUME")
    if [ -n "$SMB_SUBVOLUME_SIZE_BYTES" ] && [ "$SMB_SUBVOLUME_SIZE_BYTES" -gt 0 ] 2>/dev/null; then
        SUBVOL_CREATE_ARGS+=("--size=$SMB_SUBVOLUME_SIZE_BYTES")
    fi
    # Force 0777 so both OSes can read/write files the other created.
    SUBVOL_CREATE_ARGS+=("--mode=0777")
    if [ -n "$SMB_SUBVOLUME_GROUP" ]; then
        SUBVOL_CREATE_ARGS+=("--group_name=$SMB_SUBVOLUME_GROUP")
    fi
    log_info "Creating shared CephFS subvolume '$SMB_SUBVOLUME' on volume '$CEPH_FS_NAME' in group '$SMB_SUBVOLUME_GROUP'"
    if ! ceph_cmd "${SUBVOL_CREATE_ARGS[@]}"; then
        log_error "Failed to create CephFS subvolume '$SMB_SUBVOLUME' in group '$SMB_SUBVOLUME_GROUP'"
        exit 1
    fi

    # Resolve the subvolume's absolute CephFS path explicitly. Using --subvolume in
    # 'ceph smb share create' triggers an internal RADOS/libcephfs path lookup inside the
    # mgr/smb module that fails with 'rados_initialize failed with error code: -22' (EINVAL)
    # when the module was just enabled and its internal RADOS client is not yet fully settled.
    # Passing the resolved path as a positional argument avoids that lookup entirely.
    GETPATH_ARGS=(fs subvolume getpath "$CEPH_FS_NAME" "$SMB_SUBVOLUME")
    if [ -n "$SMB_SUBVOLUME_GROUP" ]; then
        GETPATH_ARGS+=("--group_name=$SMB_SUBVOLUME_GROUP")
    fi
    SUBVOL_PATH="$(ceph_cmd "${GETPATH_ARGS[@]}" 2>/dev/null | tr -d '\n')"
    if [ -z "$SUBVOL_PATH" ]; then
        log_error "Failed to resolve path for subvolume '$SMB_SUBVOLUME' on volume '$CEPH_FS_NAME'"
        exit 1
    fi
    log_info "Resolved subvolume path: $SUBVOL_PATH"

    # Positional arguments: <cluster_id> <share_id> <cephfs_volume> <path> [<share_name>]
    # NOTE: the resolved absolute CephFS path is passed as <path> without the optional <subvolume>
    # positional arg. When <subvolume> is present the module validates <path> relative to the
    # subvolume root, which conflicts with the absolute internal path returned by getpath.
    SMB_SHARE_ARGS+=("$SUBVOL_PATH" "$SMB_SHARE_NAME")
    log_info "Creating SMB share '$SMB_SHARE_ID' (name '$SMB_SHARE_NAME') exporting subvolume '$SMB_SUBVOLUME' (path '$SUBVOL_PATH') of CephFS volume '$CEPH_FS_NAME'"
else
    SMB_SHARE_ARGS+=("$SMB_PATH" "$SMB_SHARE_NAME")
    log_info "Creating SMB share '$SMB_SHARE_ID' (name '$SMB_SHARE_NAME') exporting CephFS volume '$CEPH_FS_NAME' path '$SMB_PATH'"
fi

SMB_SHARE_CREATE_OK=0
for attempt in $(seq 1 6); do
    if ceph_cmd "${SMB_SHARE_ARGS[@]}"; then
        SMB_SHARE_CREATE_OK=1
        break
    fi
    if [ "$attempt" -lt 6 ]; then
        log_info "SMB share create attempt $attempt/6 failed (smb module RADOS client may not be ready), retrying in 20s..."
        sleep 20
    fi
done
if [ "$SMB_SHARE_CREATE_OK" -eq 0 ]; then
    log_error "Failed to create SMB share '$SMB_SHARE_ID' on cluster '$SMB_CLUSTER_ID'"
    exit 1
fi

# Wait for cephadm to deploy the Samba service so the share is actually reachable when the CSI
# driver tries to mount it.
log_info "Waiting for the cephadm-managed Samba service to be deployed"
SMB_SERVICE_READY=0
for attempt in $(seq 1 30); do
    if ceph_cmd orch ls --service_type smb 2>/dev/null | grep -q "smb.${SMB_CLUSTER_ID}"; then
        running="$(ceph_cmd orch ls --service_type smb --format json 2>/dev/null | grep -o '"running":[[:space:]]*[0-9]*' | grep -o '[0-9]*' | head -n1)"
        if [ -n "$running" ] && [ "$running" -ge 1 ]; then
            SMB_SERVICE_READY=1
            break
        fi
    fi
    sleep 10
done
if [ "$SMB_SERVICE_READY" -eq 1 ]; then
    log_info "Samba service for cluster '$SMB_CLUSTER_ID' is running"
else
    log_info "WARNING: Samba service for cluster '$SMB_CLUSTER_ID' was not confirmed running yet; it may still be starting"
fi

log_info "Ceph mgr/smb configuration completed. CephFS volume '$CEPH_FS_NAME' is exported as SMB share '$SMB_SHARE_NAME'."
echo "K2S_CEPH_SMB_SHARE=${SMB_SHARE_NAME}"
echo "K2S_CEPH_SMB_CLUSTER=${SMB_CLUSTER_ID}"
echo "K2S_CEPH_SMB_SUBVOLUME=${SMB_SUBVOLUME}"
exit 0
