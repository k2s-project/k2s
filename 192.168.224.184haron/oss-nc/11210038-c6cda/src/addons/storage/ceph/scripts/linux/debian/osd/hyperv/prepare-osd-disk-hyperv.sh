#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# prepare-osd-disk-hyperv.sh  -  Debian (12/13) variant
#
# Prepares a RAW, unformatted, unpartitioned VIRTUAL disk on a Hyper-V OSD host so that
# cephadm / ceph-volume can consume the whole device for a Bluestore OSD.
#
# The virtual disk itself (a .vhdx) is created and hot-attached to the VM from the Windows host by
# New-CephOsdDisk.ps1 BEFORE this script runs. This guest-side script then makes sure the newly
# attached virtual disk is truly raw (no partition table / filesystem) and reports it back.
#
# Arguments:
#   $1 - Target virtual block device to prepare, e.g. /dev/sdb (OPTIONAL).
#        If omitted, the script auto-detects the single freshly-attached, empty Hyper-V virtual
#        disk (vendor 'Msft Virtual Disk') that is not the OS disk and not in use.
#
# WARNING: All data on the target virtual device is destroyed.

set -uo pipefail

DEVICE="${1:-}"

log_info() {
    echo "[CephOsdDisk] $1"
}

log_error() {
    echo "[CephOsdDisk] ERROR: $1" >&2
}

log_info "Preparing a raw virtual OSD disk on this Hyper-V host"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Returns 0 if the given whole disk is safe & empty (no OS disk, no mounts, no holders, no fs/parts).
is_candidate_empty_disk() {
    local dev="$1"
    local base
    base="$(basename "$dev")"

    # Skip the OS/root disk.
    if [ -n "$ROOT_DISK" ] && [ "$ROOT_DISK" = "$dev" ]; then
        return 1
    fi
    # Skip anything currently mounted.
    if [ -n "$(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' || true)" ]; then
        return 1
    fi
    # Skip disks claimed by LVM/mdraid/device-mapper.
    if [ -n "$(ls "/sys/block/$base/holders" 2>/dev/null || true)" ]; then
        return 1
    fi
    # Skip disks that carry an active swap device (OS swap).
    if [ -n "$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep -E "^${dev}([0-9]+|p[0-9]+)?$" || true)" ]; then
        return 1
    fi
    # Must currently have no child partitions and no filesystem signature.
    if [ -n "$(lsblk -nr -o NAME "$dev" 2>/dev/null | grep -v "^$base$" || true)" ]; then
        return 1
    fi
    if [ -n "$(sudo blkid -o value -s TYPE "$dev" 2>/dev/null || true)" ]; then
        return 1
    fi
    return 0
}

# Determine the OS/root disk so it is never selected or wiped.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null)"
ROOT_DISK=""
if [ -n "$ROOT_SRC" ]; then
    ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -n1 | tr -d '[:space:]')"
fi

# ---------------------------------------------------------------------------
# Resolve the target virtual disk.
# ---------------------------------------------------------------------------

if [ -n "$DEVICE" ]; then
    if [ ! -b "$DEVICE" ]; then
        log_error "'$DEVICE' is not a block device."
        exit 1
    fi
    DEV_TYPE="$(lsblk -dn -o TYPE "$DEVICE" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [ "$DEV_TYPE" != "disk" ]; then
        log_error "'$DEVICE' is of type '$DEV_TYPE'; a whole virtual disk (TYPE=disk) is required, not a partition."
        exit 1
    fi
    if [ -n "$ROOT_DISK" ] && [ "$ROOT_DISK" = "$DEVICE" ]; then
        log_error "'$DEVICE' is the OS/root disk. Refusing to wipe it."
        exit 1
    fi
else
    log_info "No device specified - auto-detecting the freshly-attached Hyper-V virtual disk..."
    CANDIDATES=()
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        dev="/dev/$name"
        # Prefer Hyper-V virtual disks (vendor 'Msft', model 'Virtual Disk').
        vendor="$(lsblk -dn -o VENDOR "$dev" 2>/dev/null | sed 's/[[:space:]]\+$//')"
        model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+$//')"
        if echo "$vendor $model" | grep -qi 'virtual disk'; then
            if is_candidate_empty_disk "$dev"; then
                CANDIDATES+=("$dev")
            fi
        fi
    done < <(lsblk -dn -o NAME -e 7,11 2>/dev/null)

    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        log_error "Could not find an empty Hyper-V virtual disk to use as an OSD."
        log_error "Ensure a new blank .vhdx was attached to this VM (New-CephOsdDisk.ps1 does this), or pass the device explicitly."
        exit 1
    fi
    if [ "${#CANDIDATES[@]}" -gt 1 ]; then
        log_error "Found multiple empty virtual disks (${CANDIDATES[*]}). Pass the intended device explicitly to avoid ambiguity."
        exit 1
    fi
    DEVICE="${CANDIDATES[0]}"
    log_info "Auto-detected virtual OSD disk: $DEVICE"
fi

DEV_BASENAME="$(basename "$DEVICE")"

# Final safety checks on the resolved device.
if [ -n "$(lsblk -nr -o MOUNTPOINT "$DEVICE" 2>/dev/null | grep -v '^$' || true)" ]; then
    log_error "'$DEVICE' (or a partition of it) is currently mounted. Refusing to wipe it."
    exit 1
fi
if [ -n "$(ls "/sys/block/$DEV_BASENAME/holders" 2>/dev/null || true)" ]; then
    log_error "'$DEVICE' is in use by another subsystem (LVM/mdraid/device-mapper holders)."
    exit 1
fi
if [ -n "$(awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | grep -E "^${DEVICE}([0-9]+|p[0-9]+)?$" || true)" ]; then
    log_error "'$DEVICE' (or a partition of it) is an active swap device (part of the OS). Refusing to wipe it."
    exit 1
fi

log_info "Selected virtual disk '$DEVICE' (size: $(lsblk -dn -o SIZE "$DEVICE" 2>/dev/null | tr -d '[:space:]'))"

# ---------------------------------------------------------------------------
# Wipe the device to a raw, unformatted, unpartitioned state.
# ---------------------------------------------------------------------------

log_info "Wiping filesystem / partition-table signatures from '$DEVICE'..."
sudo wipefs -a "$DEVICE" >/dev/null 2>&1 || true

if command -v sgdisk >/dev/null 2>&1; then
    sudo sgdisk --zap-all "$DEVICE" >/dev/null 2>&1 || true
else
    DEV_SECTORS="$(blockdev --getsz "$DEVICE" 2>/dev/null || echo 0)"
    sudo dd if=/dev/zero of="$DEVICE" bs=1M count=16 conv=fsync >/dev/null 2>&1 || true
    if [ "$DEV_SECTORS" -gt 0 ] 2>/dev/null; then
        SEEK_SECTORS=$(( DEV_SECTORS - 32768 ))
        if [ "$SEEK_SECTORS" -gt 0 ]; then
            sudo dd if=/dev/zero of="$DEVICE" bs=512 seek="$SEEK_SECTORS" count=32768 conv=fsync >/dev/null 2>&1 || true
        fi
    fi
fi

sudo blkdiscard -f "$DEVICE" >/dev/null 2>&1 || true
sudo partprobe "$DEVICE" >/dev/null 2>&1 || true
sudo udevadm settle >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Verify the device is now raw (no filesystem, no partitions).
# ---------------------------------------------------------------------------

REMAINING_FS="$(sudo blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)"
REMAINING_PARTS="$(lsblk -nr -o NAME "$DEVICE" 2>/dev/null | grep -v "^$DEV_BASENAME$" || true)"
if [ -n "$REMAINING_FS" ] || [ -n "$REMAINING_PARTS" ]; then
    log_error "'$DEVICE' still reports a filesystem/partitions after wiping (fs='$REMAINING_FS', parts='$(echo "$REMAINING_PARTS" | tr '\n' ' ')')."
    exit 1
fi

log_info "Virtual disk '$DEVICE' is now raw, unformatted and unpartitioned - ready to be consumed as a Ceph OSD."
echo "K2S_CEPH_OSD_DISK=${DEVICE}"
echo "K2S_CEPH_OSD_DISK_READY=1"
exit 0
