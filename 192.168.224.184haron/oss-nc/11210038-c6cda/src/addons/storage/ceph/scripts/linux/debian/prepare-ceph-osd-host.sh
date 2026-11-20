#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# prepare-ceph-osd-host.sh  -  Debian (12/13) variant
#
# Prepares THIS machine to join an existing cephadm-managed Ceph cluster as an OSD host.
# cephadm manages cluster hosts over SSH as root using the cluster's own key pair
# (/etc/ceph/ceph.pub on the bootstrap/MGR node). K2s always bootstraps with --ssh-user root so
# that external OSD nodes with different K2s usernames are handled uniformly. For cephadm to add
# this host and deploy OSD daemons, the cluster public key must be authorized for root login and
# root key-based SSH must be enabled.
#
# This script automates the manual host-preparation steps:
#   Install a container runtime (podman) and lvm2 - both required by cephadm to deploy an OSD
#   daemon and carve the OSD out of a raw drive (cephadm supports podman as its container engine):
#     - sudo apt install -y ca-certificates curl gnupg lsb-release
#     - sudo apt install -y podman
#     - sudo apt install -y lvm2
#   Authorize the cephadm cluster key for root SSH:
#     1. sudo cat /etc/ceph/ceph.pub        (run on the MGR node to obtain the key -> pass as arg)
#     2. sudo mkdir -p /root/.ssh
#     3. sudo chmod 700 /root/.ssh
#     4. append the key to /root/.ssh/authorized_keys
#     5. sudo chmod 600 /root/.ssh/authorized_keys
#     6. enable PermitRootLogin (prohibit-password) + PubkeyAuthentication in sshd
#     7. sudo systemctl restart ssh
#
# Invoked remotely (Invoke-RemoteScript) or run directly on the OSD host.
#
# Arguments (order-independent):
#   The cephadm cluster public key (contents of /etc/ceph/ceph.pub on the MGR node). An OpenSSH
#     public key contains spaces (type + base64 blob + optional comment); it may be passed either
#     quoted as one argument or as several space-separated arguments - they are reassembled.
#   Optional HTTP/HTTPS proxy URL (e.g. the K2s transparent proxy http://<kubeswitch-ip>:8181).
#     The proxy is recognised by its 'http://' or 'https://' prefix, so it can appear before or
#     after the key without being confused with a key fragment.
#   Optional Ceph container image reference (e.g. quay.io/ceph/ceph:v20). Recognised by containing
#     both '/' and ':' (registry/repo:tag). When provided, the image is pulled locally via the
#     proxy so cephadm can deploy the crash/OSD daemons and run ceph-volume on this host without
#     reaching the public registry (which fails on air-gapped OSD nodes).
#
# Examples:
#   ./prepare-ceph-osd-host.sh ssh-ed25519 AAAA... ceph-<fsid> http://172.19.1.1:8181 quay.io/ceph/ceph:v20
#   ./prepare-ceph-osd-host.sh "ssh-ed25519 AAAA... ceph-<fsid>" http://172.19.1.1:8181 quay.io/ceph/ceph:v20

set -uo pipefail

# Separate the (possibly space-containing) public key from the optional proxy URL and the optional
# Ceph container image reference. Classification rules (order-independent):
#   - an http(s):// token is the proxy URL
#   - a token containing both '/' and ':' (e.g. quay.io/ceph/ceph:v20) is the Ceph image reference
#   - everything else is treated as part of the OpenSSH public key (which may span several tokens)
CEPH_PUB_KEY=""
PROXY=""
CEPH_IMAGE=""
for arg in "$@"; do
    case "$arg" in
        http://*|https://*)
            PROXY="$arg"
            ;;
        */*:*)
            CEPH_IMAGE="$arg"
            ;;
        *)
            if [ -z "$CEPH_PUB_KEY" ]; then
                CEPH_PUB_KEY="$arg"
            else
                CEPH_PUB_KEY="$CEPH_PUB_KEY $arg"
            fi
            ;;
    esac
done

log_info() {
    echo "[CephOsd] $1"
}

log_error() {
    echo "[CephOsd] ERROR: $1" >&2
}

log_info "Preparing this machine as a Ceph OSD host on Debian"

if [ -z "$CEPH_PUB_KEY" ]; then
    log_error "Missing required cephadm public key argument (contents of /etc/ceph/ceph.pub from the MGR node)."
    exit 1
fi

# Basic sanity check: cephadm keys are OpenSSH public keys (ssh-rsa / ssh-ed25519 / ecdsa-...).
case "$CEPH_PUB_KEY" in
    ssh-*|ecdsa-*) : ;;
    *)
        log_error "The provided key does not look like an OpenSSH public key (expected it to start with 'ssh-' or 'ecdsa-')."
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Install container runtime (podman) and lvm2 required by cephadm to deploy the
# OSD daemon and provision the OSD on a raw drive.
# ---------------------------------------------------------------------------

# Configure apt to use the K2s proxy when provided (air-gapped nodes reach the internet only
# through it). Removed again on exit so it does not linger in the node's apt configuration.
cleanup_proxy_config() {
    if [ -n "$PROXY" ]; then
        sudo rm -f /etc/apt/apt.conf.d/95k2s-proxy
    fi
}
trap cleanup_proxy_config EXIT

if [ -n "$PROXY" ]; then
    log_info "Configuring apt proxy: $PROXY"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" | sudo tee /etc/apt/apt.conf.d/95k2s-proxy > /dev/null
fi

# Wait for any other apt/dpkg run to release the lock instead of failing (the manual workaround
# for the lock error was to restart the VM; here we simply wait for it to clear).
wait_for_apt_lock() {
    local waited=0
    while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if [ "$waited" -ge 300 ]; then
            log_error "Timed out waiting for the apt/dpkg lock to be released (another package operation is running)."
            return 1
        fi
        log_info "apt/dpkg is locked by another process; waiting..."
        sleep 5
        waited=$((waited + 5))
    done
    return 0
}

if [ -z "$PROXY" ]; then
    log_info "No proxy argument was provided; packages are fetched directly."
    log_info "On an air-gapped node this may fail - re-run passing the K2s proxy URL, e.g. http://<kubeswitch-ip>:8181"
fi

wait_for_apt_lock || exit 1
if ! sudo apt-get update; then
    log_error "'apt-get update' failed. If it reported a lock error, ensure no other apt process is running."
    exit 1
fi

# Install prerequisite packages, skipping any that are already present (e.g. installed via dpkg
# during offline artifact import). Only the missing ones are handed to apt-get.
PREREQ_PKGS="ca-certificates curl gnupg lsb-release"
MISSING_PREREQ=""
for pkg in $PREREQ_PKGS; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PREREQ="$MISSING_PREREQ $pkg"
done
if [ -n "$MISSING_PREREQ" ]; then
    wait_for_apt_lock || exit 1
    # shellcheck disable=SC2086
    if ! sudo apt-get install -y $MISSING_PREREQ; then
        log_error "Failed to install prerequisite packages ($MISSING_PREREQ)."
        exit 1
    fi
else
    log_info "Prerequisite packages (ca-certificates, curl, gnupg, lsb-release) already installed; skipping"
fi

# Install podman (the container engine cephadm uses to deploy the OSD daemon). Skip when it is
# already present (e.g. installed via dpkg during offline artifact import). podman ships in the
# Debian base repositories, so no external apt repository / GPG key setup is required.
if command -v podman >/dev/null 2>&1; then
    log_info "podman already installed; skipping podman install"
else
    wait_for_apt_lock || exit 1
    if ! sudo apt-get install -y podman; then
        log_error "Failed to install podman (required by cephadm)."
        exit 1
    fi
fi
log_info "Installed container runtime: $(command -v podman)"

# lvm2 provides the LVM tooling cephadm uses to create the OSD's logical volume on the drive.
# Skip when already present (e.g. installed via dpkg during offline artifact import).
if dpkg -s lvm2 >/dev/null 2>&1; then
    log_info "lvm2 already installed; skipping"
else
    wait_for_apt_lock || exit 1
    if ! sudo apt-get install -y lvm2; then
        log_error "Failed to install lvm2 (required by cephadm to create the OSD on a raw drive)."
        exit 1
    fi
    log_info "Installed lvm2"
fi

# ---------------------------------------------------------------------------
# Ensure the Ceph container image is present locally so cephadm can deploy the crash/OSD daemons
# and run ceph-volume WITHOUT reaching out to the public registry (quay.io). On an air-gapped OSD
# node cephadm's own 'podman pull quay.io/ceph/ceph:<tag>' fails with a DNS/timeout error and the
# OSD/crash daemon placement never completes. Pull the exact image the cluster uses via the K2s
# proxy here, mirroring what create-ceph-cluster.sh does on the bootstrap node.
# ---------------------------------------------------------------------------
if [ -n "$CEPH_IMAGE" ]; then
    if sudo podman image exists "$CEPH_IMAGE" 2>/dev/null; then
        log_info "Ceph image '$CEPH_IMAGE' already present locally; skipping pull"
    elif [ -n "$PROXY" ]; then
        log_info "Pulling Ceph image via proxy so cephadm does not need registry access: $CEPH_IMAGE"
        if ! sudo env HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" http_proxy="$PROXY" https_proxy="$PROXY" podman pull "$CEPH_IMAGE"; then
            log_error "Failed to pull Ceph image '$CEPH_IMAGE' via proxy '$PROXY'. cephadm will not be able to deploy OSD/crash daemons on this host."
            exit 1
        fi
        log_info "Pulled Ceph image '$CEPH_IMAGE'"
    else
        log_info "Pulling Ceph image without proxy: $CEPH_IMAGE"
        if ! sudo podman pull "$CEPH_IMAGE"; then
            log_error "Failed to pull Ceph image '$CEPH_IMAGE'. cephadm will not be able to deploy OSD/crash daemons on this host."
            exit 1
        fi
        log_info "Pulled Ceph image '$CEPH_IMAGE'"
    fi
else
    log_info "No Ceph image reference was provided; assuming the image is already present locally for cephadm."
fi

# 1) Ensure root's .ssh directory exists with correct permissions.
sudo mkdir -p /root/.ssh
sudo chmod 700 /root/.ssh

# 2) Authorize the cephadm public key for root (idempotent - avoid duplicate lines).
AUTH_KEYS="/root/.ssh/authorized_keys"
sudo touch "$AUTH_KEYS"
if sudo grep -qF "$CEPH_PUB_KEY" "$AUTH_KEYS"; then
    log_info "cephadm public key already present in $AUTH_KEYS"
else
    echo "$CEPH_PUB_KEY" | sudo tee -a "$AUTH_KEYS" > /dev/null
    log_info "Added cephadm public key to $AUTH_KEYS"
fi
sudo chmod 600 "$AUTH_KEYS"

# 3) Enable root key-based SSH login for cephadm. Use a dedicated drop-in so the main
#    sshd_config is left untouched (and to override any conflicting default).
SSHD_DROPIN="/etc/ssh/sshd_config.d/60-ceph-osd.conf"
sudo mkdir -p /etc/ssh/sshd_config.d
sudo tee "$SSHD_DROPIN" > /dev/null <<'EOF'
# Managed by K2s storage/ceph addon (prepare-ceph-osd-host.sh).
# Allows the cephadm cluster to manage this OSD host as root over SSH using its key pair.
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF
log_info "Wrote sshd drop-in '$SSHD_DROPIN' (PermitRootLogin prohibit-password, PubkeyAuthentication yes)"

# 4) Show the effective settings for visibility.
log_info "Effective SSH root-login / pubkey settings:"
sudo grep -E '^(PermitRootLogin|PubkeyAuthentication)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sed 's/^/[CephOsd]   /' || true

# 5) Restart the SSH service so the new settings take effect. The unit is 'ssh' on Debian,
#    'sshd' on some distributions - try both.
if sudo systemctl restart ssh 2>/dev/null; then
    log_info "Restarted 'ssh' service"
elif sudo systemctl restart sshd 2>/dev/null; then
    log_info "Restarted 'sshd' service"
else
    log_error "Failed to restart the SSH service; restart it manually so cephadm can connect as root."
    exit 1
fi

log_info "This machine is ready to be added to the Ceph cluster as an OSD host."
log_info "A new volume drive on this machine will be consumed to create the OSD."
echo "K2S_CEPH_OSD_HOST_READY=1"
exit 0
