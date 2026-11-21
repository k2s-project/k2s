#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# verify-ceph-cluster.sh  -  Debian (12/13) variant
#
# Pre-flight connectivity/identity check for an EXISTING Ceph cluster. Invoked remotely by
# addons/storage/ceph/scripts/linux/debian/Test-CephCluster.ps1 during
# 'k2s addons enable storage ceph' when clusterMode = 'existing'.
#
# Emits the live cluster identity (fsid, CephFS filesystems, pools) as K2S_CEPH_* markers so the
# caller can confirm the node is reachable over SSH and that the ceph-config.json details match
# the actual cluster. Exits non-zero when the cluster cannot be queried.

set -uo pipefail

log_info() { echo "[verify-ceph-cluster] $*"; }

# Resolve a working 'ceph' invocation. On a cephadm host ceph-common is normally installed;
# fall back to 'cephadm shell -- ceph' when the CLI is not directly on PATH.
if command -v ceph >/dev/null 2>&1; then
    CEPH="sudo ceph"
elif command -v cephadm >/dev/null 2>&1; then
    CEPH="sudo cephadm shell -- ceph"
else
    log_info "ERROR: neither 'ceph' nor 'cephadm' found on node; cannot query cluster"
    exit 1
fi

# 'ceph fsid' is the cheapest call that still requires a healthy MON connection and a valid
# admin keyring, so it doubles as the reachability probe.
FSID="$(${CEPH} fsid 2>/dev/null | tr -d '[:space:]')"
if [ -z "${FSID}" ]; then
    log_info "ERROR: unable to query cluster ('ceph fsid' returned nothing); cluster unreachable or admin keyring missing"
    exit 1
fi
echo "K2S_CEPH_FSID=${FSID}"

# CephFS filesystem names: 'ceph fs ls' prints lines like
#   name: cephfs, metadata pool: cephfs.cephfs.meta, data pools: [cephfs.cephfs.data ]
FS_LIST="$(${CEPH} fs ls 2>/dev/null | sed -nE 's/^name:[[:space:]]*([^,]+),.*/\1/p' | tr '\n' ' ')"
echo "K2S_CEPH_FS_LIST=${FS_LIST}"

# Pool names, one per line.
POOL_LIST="$(${CEPH} osd pool ls 2>/dev/null | tr '\n' ' ')"
echo "K2S_CEPH_POOL_LIST=${POOL_LIST}"

echo "K2S_CEPH_VERIFY_OK=1"
exit 0
