#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# remove-ceph-cluster-smb.sh  -  Debian 13 variant
#
# Tears down the Ceph 'mgr/smb' configuration created by create-ceph-cluster-smb.sh on an
# already-running Ceph cluster: it removes the mgr/smb cluster (and its shares) and drops the
# cephadm placement label so the managed Samba daemons are undeployed. The underlying CephFS
# volume and the rest of the Ceph cluster are left intact.
#
# Invoked remotely by addons/storage/ceph/scripts/linux/debian/Remove-CephSmbCluster.ps1 via
# Invoke-RemoteScript when the ceph addon is disabled.
#
# Arguments:
#   $1 - SMB cluster id to remove (from ceph-config.json 'smb.clusterId')
#   $2 - Optional cephadm host placement label to drop (default 'smb')
#   $3 - Optional CephFS volume name (needed to remove the shared subvolume)
#   $4 - Optional shared CephFS subvolume to remove (from ceph-config.json 'smb.subvolume')
#   $5 - Optional subvolume group name (default 'csi')

SMB_CLUSTER_ID="${1:-k2ssmb}"
PLACEMENT_LABEL="${2:-smb}"
CEPH_FS_NAME="${3:-}"
SMB_SUBVOLUME="${4:-}"
SMB_SUBVOLUME_GROUP="${5:-}"

log_info() {
    echo "[CephSMB] $1"
}

log_error() {
    echo "[CephSMB] ERROR: $1" >&2
}

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
    log_info "cephadm not found; assuming no Ceph cluster is present. Nothing to remove."
    exit 0
fi

ceph_cmd() {
    sudo "$CEPHADM_BIN" shell -- ceph "$@"
}

# If the command interface or smb module is unavailable, there is nothing to clean up.
if ! timeout 30 ceph_cmd -s >/dev/null 2>&1; then
    log_info "Ceph command interface is not reachable; nothing to remove."
    exit 0
fi
if ! ceph_cmd smb cluster ls >/dev/null 2>&1; then
    log_info "The 'ceph smb' interface is unavailable (module not enabled); nothing to remove."
    exit 0
fi

if ceph_cmd smb cluster ls 2>/dev/null | grep -q "\"cluster_id\":[[:space:]]*\"${SMB_CLUSTER_ID}\""; then
    log_info "Removing mgr/smb cluster '$SMB_CLUSTER_ID' (and its shares)"
    if ! ceph_cmd smb cluster rm "$SMB_CLUSTER_ID" --recursive; then
        log_error "Failed to remove mgr/smb cluster '$SMB_CLUSTER_ID'"
        exit 1
    fi
else
    log_info "mgr/smb cluster '$SMB_CLUSTER_ID' not found; nothing to remove."
fi

# Remove the placement label only from the bootstrap host that ran the SMB service. We intentionally
# do not remove labels from every Ceph host, because the service itself is bound to the cluster host.
CURRENT_HOST="$(hostname -s 2>/dev/null || hostname)"
if [ -n "$CURRENT_HOST" ] && [ -n "$PLACEMENT_LABEL" ]; then
    ceph_cmd orch host label rm "$CURRENT_HOST" "$PLACEMENT_LABEL" >/dev/null 2>&1 || true
fi

# Remove the shared CephFS subvolume that backed the SMB share (best-effort; this deletes the
# cross-OS shared data). Only attempted when both the volume and subvolume names were provided.
if [ -n "$CEPH_FS_NAME" ] && [ -n "$SMB_SUBVOLUME" ]; then
    SUBVOL_RM_ARGS=(fs subvolume rm "$CEPH_FS_NAME" "$SMB_SUBVOLUME")
    if [ -n "$SMB_SUBVOLUME_GROUP" ]; then
        SUBVOL_RM_ARGS+=("$SMB_SUBVOLUME_GROUP")
    fi
    log_info "Removing shared CephFS subvolume '$SMB_SUBVOLUME' from volume '$CEPH_FS_NAME'"
    ceph_cmd "${SUBVOL_RM_ARGS[@]}" >/dev/null 2>&1 || log_info "Failed to remove subvolume '$SMB_SUBVOLUME' (may not exist; continuing)"
fi

log_info "Ceph mgr/smb teardown completed for cluster '$SMB_CLUSTER_ID'."
exit 0
