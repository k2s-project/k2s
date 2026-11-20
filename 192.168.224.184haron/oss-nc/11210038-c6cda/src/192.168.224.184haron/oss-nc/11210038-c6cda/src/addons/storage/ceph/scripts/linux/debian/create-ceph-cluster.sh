#!/bin/bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# create-ceph-cluster.sh  -  Debian 13 variant
#
# Bootstraps a new Ceph cluster on this node using cephadm and creates the
# CephFS filesystem/pool used by the storage/ceph addon CSI installation.
#
# Invoked remotely by addons/storage/ceph/scripts/linux/debian/New-CephCluster.ps1
# via Invoke-RemoteScript when ceph-config.json requests a new cluster
# (clusterMode != 'existing', clusterDistribution = 'debian13').
#
# Arguments:
#   $1 - Optional HTTP/HTTPS proxy URL
#   $2 - Ceph admin url reference from storage addon manifest (from ceph-config.json 'cephAdminUrl')
#   $3 - CephFS filesystem name to create (from ceph-config.json 'cephfsFilesystem')
#   $4 - SSH user for cephadm host management (must be 'root'; K2s always passes 'root' so that
#          external OSD nodes with different usernames are handled uniformly)
#   $5 - Optional osd_crush_chooseleaf_type value
#   $6 - Optional mon daemon count
#   $7 - Optional mgr daemon count
#   $8 - Optional mds daemon count for the CephFS filesystem
#   $9 - Optional total OSD count across all hosts (used to right-size replicated pools)

PROXY="${1:-}"
CEPHADMIN_URL="${2:-}"
CEPH_FS_NAME="${3:-cephfs}"
CEPH_SSH_USER="${4:-root}"
OSD_CRUSH_CHOOSELEAF_TYPE="${5:-}"
MON_COUNT="${6:-}"
MGR_COUNT="${7:-}"
MDS_COUNT="${8:-}"
TOTAL_OSD_COUNT="${9:-}"
CEPH_IMAGE="${10:-}"

log_info() {
    echo "[CephNew] $1"
}

log_error() {
    echo "[CephNew] ERROR: $1" >&2
}

stop_lingering_ceph_containers() {
    # Cleanup leftover Ceph containers that can keep monitor ports bound after failed teardowns.
    if command -v podman >/dev/null 2>&1; then
        lingering_ids="$(sudo podman ps -a --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null | awk '/ceph/ {print $1}')"
        if [ -n "$lingering_ids" ]; then
            log_info "Removing lingering Ceph podman container(s) before bootstrap"
            # shellcheck disable=SC2086
            sudo podman rm -f $lingering_ids >/dev/null 2>&1 || true
        fi
    fi

    if command -v docker >/dev/null 2>&1; then
        lingering_ids="$(sudo docker ps -a --format '{{.ID}} {{.Image}} {{.Names}}' 2>/dev/null | awk '/ceph/ {print $1}')"
        if [ -n "$lingering_ids" ]; then
            log_info "Removing lingering Ceph docker container(s) before bootstrap"
            # shellcheck disable=SC2086
            sudo docker rm -f $lingering_ids >/dev/null 2>&1 || true
        fi
    fi
}

is_ceph_pid() {
    local pid="$1"
    local cmdline=""

    cmdline="$(sudo ps -p "$pid" -o args= 2>/dev/null | tr -d '\r')"
    if [ -z "$cmdline" ]; then
        return 1
    fi

    case "$cmdline" in
        *ceph*|*cephadm*|*radosgw*|*quay.io/ceph*|*/var/lib/ceph*|*/run/ceph*)
            return 0
            ;;
    esac

    return 1
}

format_pid_details() {
    local pids="$1"
    local details=""
    local pid=""
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        details+="$(sudo ps -p "$pid" -o pid=,user=,args= 2>/dev/null | sed -e 's/^ *//')\n"
    done <<< "$pids"
    printf "%b" "$details"
}

kill_processes_on_port() {
    local port="$1"
    local pids=""

    if command -v ss >/dev/null 2>&1; then
        pids="$(sudo ss -ltnp "sport = :$port" 2>/dev/null | awk -F'pid=' 'NR>1 {split($2,a,",|"); if (a[1] ~ /^[0-9]+$/) print a[1]}' | sort -u)"
    fi

    if [ -z "$pids" ] && command -v lsof >/dev/null 2>&1; then
        pids="$(sudo lsof -ti TCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u)"
    fi

    if [ -z "$pids" ]; then
        return 0
    fi

    log_info "Port $port is still in use by PID(s): $(echo "$pids" | tr '\n' ' ' | xargs)"

    local ceph_pids=""
    local non_ceph_pids=""
    local pid=""

    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if is_ceph_pid "$pid"; then
            ceph_pids+="$pid\n"
        else
            non_ceph_pids+="$pid\n"
        fi
    done <<< "$pids"

    if [ -n "$ceph_pids" ]; then
        # shellcheck disable=SC2086
        sudo kill $(echo -e "$ceph_pids" | tr '\n' ' ') >/dev/null 2>&1 || true
        sleep 2
    fi

    local still_listening=""
    if command -v ss >/dev/null 2>&1; then
        still_listening="$(sudo ss -ltnp "sport = :$port" 2>/dev/null | awk -F'pid=' 'NR>1 {split($2,a,",|"); if (a[1] ~ /^[0-9]+$/) print a[1]}' | sort -u)"
    fi

    if [ -n "$still_listening" ]; then
        local still_ceph_pids=""
        local still_non_ceph_pids=""
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            if is_ceph_pid "$pid"; then
                still_ceph_pids+="$pid\n"
            else
                still_non_ceph_pids+="$pid\n"
            fi
        done <<< "$still_listening"

        if [ -n "$still_ceph_pids" ]; then
            log_info "Force-killing lingering Ceph PID(s) still listening on port $port"
            # shellcheck disable=SC2086
            sudo kill -9 $(echo -e "$still_ceph_pids" | tr '\n' ' ') >/dev/null 2>&1 || true
        fi

        if [ -n "$still_non_ceph_pids" ]; then
            log_error "Port $port is used by non-Ceph process(es). Refusing to terminate them."
            format_pid_details "$still_non_ceph_pids" | while IFS= read -r detail; do
                [ -n "$detail" ] || continue
                log_error "  $detail"
            done
            return 1
        fi
    fi

    if [ -n "$non_ceph_pids" ]; then
        # Re-check after Ceph-specific cleanup. If non-Ceph owners remain on the port, fail safely.
        local non_ceph_still_listening=""
        if command -v ss >/dev/null 2>&1; then
            non_ceph_still_listening="$(sudo ss -ltnp "sport = :$port" 2>/dev/null | awk -F'pid=' 'NR>1 {split($2,a,",|"); if (a[1] ~ /^[0-9]+$/) print a[1]}' | sort -u)"
        fi
        if [ -n "$non_ceph_still_listening" ]; then
            local confirmed_non_ceph=""
            while IFS= read -r pid; do
                [ -n "$pid" ] || continue
                if ! is_ceph_pid "$pid"; then
                    confirmed_non_ceph+="$pid\n"
                fi
            done <<< "$non_ceph_still_listening"
            if [ -n "$confirmed_non_ceph" ]; then
                log_error "Port $port remains occupied by non-Ceph process(es)."
                format_pid_details "$confirmed_non_ceph" | while IFS= read -r detail; do
                    [ -n "$detail" ] || continue
                    log_error "  $detail"
                done
                return 1
            fi
        fi
    fi

    return 0
}

ensure_ceph_ports_free() {
    # Ceph monitor ports must be free before bootstrap.
    stop_lingering_ceph_containers
    kill_processes_on_port 3300 || return 1
    kill_processes_on_port 6789 || return 1

    if command -v ss >/dev/null 2>&1; then
        local port_3300_in_use
        local port_6789_in_use
        port_3300_in_use="$(sudo ss -ltn "sport = :3300" 2>/dev/null | awk 'NR>1 {print $4}')"
        port_6789_in_use="$(sudo ss -ltn "sport = :6789" 2>/dev/null | awk 'NR>1 {print $4}')"
        if [ -n "$port_3300_in_use" ] || [ -n "$port_6789_in_use" ]; then
            log_error "Ceph monitor ports are still occupied after cleanup (3300='${port_3300_in_use:-free}', 6789='${port_6789_in_use:-free}')."
            return 1
        fi
    fi

    return 0
}

ensure_root_ssh_ready_for_cephadm() {
    # cephadm bootstrap registers the bootstrap node itself through the orchestrator using SSH.
    # Ensure root pubkey login is enabled before bootstrap so localhost host-add succeeds.
    local ssh_dropin="/etc/ssh/sshd_config.d/60-k2s-ceph-bootstrap.conf"

    sudo mkdir -p /root/.ssh
    sudo chmod 700 /root/.ssh
    sudo touch /root/.ssh/authorized_keys
    sudo chmod 600 /root/.ssh/authorized_keys

    sudo mkdir -p /etc/ssh/sshd_config.d
    sudo tee "$ssh_dropin" > /dev/null <<'EOF'
# Managed by K2s storage/ceph addon (create-ceph-cluster.sh).
# Required so cephadm can SSH as root to the bootstrap host during orchestrator host registration.
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF

    if sudo systemctl restart ssh 2>/dev/null; then
        log_info "Restarted 'ssh' service after applying root SSH settings"
    elif sudo systemctl restart sshd 2>/dev/null; then
        log_info "Restarted 'sshd' service after applying root SSH settings"
    else
        log_error "Failed to restart SSH service after applying root SSH settings"
        return 1
    fi

    return 0
}

log_info "Starting new Ceph cluster bootstrap on Debian"

cleanup_proxy_config() {
    if [ -n "$PROXY" ]; then
        sudo rm -f /etc/apt/apt.conf.d/95k2s-proxy
    fi
}

trap cleanup_proxy_config EXIT

# APT sandbox config
echo 'APT::Sandbox::User "root";' | sudo tee /etc/apt/apt.conf.d/10sandbox-for-k2s > /dev/null

# Configure apt proxy if provided (ensures apt-get uses the same proxy path)
if [ -n "$PROXY" ]; then
    log_info "Configuring apt proxy: $PROXY"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$PROXY" "$PROXY" | sudo tee /etc/apt/apt.conf.d/95k2s-proxy > /dev/null
fi

OFFLINE_PKG_DIR="$HOME/.storage"
# Also check addon-specific storage folder (.storage-ceph) as fallback
OFFLINE_PKG_DIR_ALT="$HOME/.storage-ceph"

# Collect .deb packages from both locations (primary first, then fallback)
offline_debs=""
if [ -d "$OFFLINE_PKG_DIR" ]; then
    offline_debs="$(find "$OFFLINE_PKG_DIR" -type f -name '*.deb' 2>/dev/null)"
fi

# Append packages from alternate location if primary is empty or to supplement
if [ -d "$OFFLINE_PKG_DIR_ALT" ]; then
    alt_debs="$(find "$OFFLINE_PKG_DIR_ALT" -type f -name '*.deb' 2>/dev/null)"
    if [ -n "$alt_debs" ]; then
        if [ -n "$offline_debs" ]; then
            offline_debs="$offline_debs"$'\n'"$alt_debs"
        else
            offline_debs="$alt_debs"
            log_info "Using addon-specific offline packages from $OFFLINE_PKG_DIR_ALT (primary $OFFLINE_PKG_DIR not found)"
        fi
    fi
fi

if [ -n "$offline_debs" ]; then
    log_info "Installing offline debian packages"
    # shellcheck disable=SC2086
    sudo dpkg -i $offline_debs 2>/dev/null || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y --no-download 2>/dev/null || true
fi

if ! command -v podman >/dev/null 2>&1; then
    log_info "podman not found, installing it via apt-get"
    sudo apt-get update
    if ! sudo apt-get install -y podman; then
        log_error "Failed to install podman (required by cephadm)"
        exit 1
    fi
fi
log_info "Using container engine: $(command -v podman)"


if sudo podman image exists "$CEPH_IMAGE" 2>/dev/null; then
    log_info "Ceph image '$CEPH_IMAGE' already present locally (e.g. loaded during offline artifact import); skipping pull"
elif [ -n "$PROXY" ]; then
    log_info "Pulling Ceph image via proxy for quay.io access: $CEPH_IMAGE"
    if ! sudo env HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" podman pull "$CEPH_IMAGE"; then
        log_error "Failed to pull Ceph image '$CEPH_IMAGE' with proxy"
        exit 1
    fi
else
    log_info "Pulling Ceph image without proxy: $CEPH_IMAGE"
    if ! sudo podman pull "$CEPH_IMAGE"; then
        log_error "Failed to pull Ceph image '$CEPH_IMAGE'"
        exit 1
    fi
fi

CEPH_VERSION_STRING="$(sudo podman run --rm --entrypoint ceph "$CEPH_IMAGE" --version 2>/dev/null)"
CEPH_VERSION="$(echo "$CEPH_VERSION_STRING" | sed -E 's/^ceph version ([0-9.]+) .*/\1/')"
CEPH_RELEASE="$(echo "$CEPH_VERSION_STRING" | sed -E 's/^.*\) ([[:alpha:]]+) \(stable\).*/\1/')"

if [ -z "$CEPH_VERSION" ] || [ "$CEPH_VERSION" = "$CEPH_VERSION_STRING" ]; then
    log_error "Could not determine Ceph version from image '$CEPH_IMAGE' (got: '$CEPH_VERSION_STRING')"
    exit 1
fi
if [ -z "$CEPH_RELEASE" ] || [ "$CEPH_RELEASE" = "$CEPH_VERSION_STRING" ]; then
    log_error "Could not determine Ceph release codename from image '$CEPH_IMAGE' (got: '$CEPH_VERSION_STRING')"
    exit 1
fi
log_info "Detected Ceph version '$CEPH_VERSION' (release codename '$CEPH_RELEASE') from image"

is_valid_cephadm() {
    head -n1 "$1" 2>/dev/null | grep -qE '^#!.*python'
}

download_cephadm() {
    local url="$1"
    rm -f cephadm
    curl -x "$PROXY" --fail --silent --show-error --remote-name --location "$url" || return 1
    if ! is_valid_cephadm cephadm; then
        log_error "Downloaded file from '$url' is not the cephadm script (likely an HTTP error page)."
        rm -f cephadm
        return 1
    fi
    return 0
}

# Obtain the cephadm bootstrap binary. Prefer the binary staged offline into
# ~/.storage/cephadm during 'k2s addons import' so air-gapped installs never depend on
# download.ceph.com. Also check ~/.storage-ceph as fallback. Only fall back to downloading
# when no valid offline copy is present.
OFFLINE_CEPHADM="$HOME/.storage/cephadm"
OFFLINE_CEPHADM_ALT="$HOME/.storage-ceph/cephadm"
if [ -f "$OFFLINE_CEPHADM" ] && is_valid_cephadm "$OFFLINE_CEPHADM"; then
    log_info "Using offline cephadm bootstrap binary staged at $OFFLINE_CEPHADM"
    cp "$OFFLINE_CEPHADM" ./cephadm
elif [ -f "$OFFLINE_CEPHADM_ALT" ] && is_valid_cephadm "$OFFLINE_CEPHADM_ALT"; then
    log_info "Using offline cephadm bootstrap binary from addon-specific storage at $OFFLINE_CEPHADM_ALT"
    cp "$OFFLINE_CEPHADM_ALT" ./cephadm
elif download_cephadm "$CEPHADMIN_URL"; then
    log_info "Downloaded cephadm bootstrap binary for version '$CEPH_VERSION'"
# elif download_cephadm "https://download.ceph.com/rpm-$CEPH_RELEASE/el9/noarch/cephadm"; then
#     log_info "Downloaded cephadm bootstrap binary for release '$CEPH_RELEASE'"
else
    log_error "Failed to obtain a valid cephadm bootstrap binary (offline copy at $OFFLINE_CEPHADM missing/invalid and download from download.ceph.com failed for version '$CEPH_VERSION' and release '$CEPH_RELEASE')."
    exit 1
fi

# Make the cephadm binary executable
sudo chmod +x cephadm

# Install cephadm onto PATH so bare 'cephadm' invocations resolve later in this script and
# in New-CephCluster.ps1 ('sudo cephadm shell ...'), even when the online 'cephadm install'
# step below cannot reach the Ceph package repositories (offline / air-gapped).
sudo install -m 0755 ./cephadm /usr/local/bin/cephadm

if ! dpkg -s gnupg >/dev/null 2>&1; then
    sudo apt-get install -y gnupg
fi
sudo rm -f /etc/apt/trusted.gpg.d/ceph.asc

CEPHADM_PROXY_ENV=()
if [ -n "$PROXY" ]; then
    CEPHADM_PROXY_ENV=(http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY")
fi

# DEBIAN_CODENAME="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-trixie}")"
# CEPH_REPO_RELEASE_URL="https://download.ceph.com/debian-${CEPH_RELEASE}/dists/${DEBIAN_CODENAME}/Release"

# # Host-side add-repo/install is optional. Bootstrap and all runtime ceph commands use the
# # downloaded/staged cephadm binary plus the container image, so skip this path when the
# # release/codename repo is unavailable (common for newly released Debian versions).
# repo_probe_ok=0
# if [ -n "$PROXY" ]; then
#     if curl -x "$PROXY" --fail --silent --show-error --location --output /dev/null "$CEPH_REPO_RELEASE_URL"; then
#         repo_probe_ok=1
#     fi
# else
#     if curl --fail --silent --show-error --location --output /dev/null "$CEPH_REPO_RELEASE_URL"; then
#         repo_probe_ok=1
#     fi
# fi

# if [ "$repo_probe_ok" -eq 1 ]; then
#     log_info "Ceph Debian repo is reachable for release '$CEPH_RELEASE' on codename '$DEBIAN_CODENAME'; running cephadm add-repo/install"
    # sudo env "${CEPHADM_PROXY_ENV[@]}" ./cephadm add-repo --release "$CEPH_RELEASE" || \
    #     log_info "add-repo failed (continuing; host-side ceph CLI may be unavailable)"

sudo env "${CEPHADM_PROXY_ENV[@]}" ./cephadm install || \
        log_info "cephadm install failed (continuing; using available cephadm binary for bootstrap)"
# else
#     log_info "Ceph Debian repo not available at '$CEPH_REPO_RELEASE_URL'; skipping cephadm add-repo/install and continuing with staged cephadm binary."
# fi


CEPHADM_BIN=''
if [ -x "$(pwd)/cephadm" ]; then
    CEPHADM_BIN="$(pwd)/cephadm"
fi
if [ -z "$CEPHADM_BIN" ]; then
    CEPHADM_BIN="$(command -v cephadm 2>/dev/null || true)"
fi
if [ -z "$CEPHADM_BIN" ]; then
    # /usr/sbin is not always in PATH for non-root SSH sessions on Debian
    for candidate in /usr/sbin/cephadm /usr/bin/cephadm /sbin/cephadm; do
        if [ -x "$candidate" ]; then
            CEPHADM_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$CEPHADM_BIN" ]; then
    log_error "cephadm was not found after installation (searched offline storage, PATH, and /usr/sbin, /usr/bin, /sbin)"
    exit 1
fi
log_info "Using cephadm binary: $CEPHADM_BIN"

# Determine the monitor IP address for the bootstrap process (first non-loopback IP)
MON_IP="$(hostname -I | awk '{print $1}')"
if [ -z "$MON_IP" ]; then
    log_error "Failed to resolve monitor IP from hostname -I"
    exit 1
fi

log_info "Bootstrapping Ceph cluster with image '$CEPH_IMAGE' and MON_IP '$MON_IP'"
log_info "Using cephadm SSH user '$CEPH_SSH_USER' for host management"
if [ -n "$OSD_CRUSH_CHOOSELEAF_TYPE" ]; then
    log_info "Requested osd_crush_chooseleaf_type=$OSD_CRUSH_CHOOSELEAF_TYPE"
fi
if [ -n "$MON_COUNT" ] || [ -n "$MGR_COUNT" ] || [ -n "$MDS_COUNT" ]; then
    log_info "Requested daemon placement counts: mon='${MON_COUNT:-<ceph-default>}', mgr='${MGR_COUNT:-<ceph-default>}', mds='${MDS_COUNT:-<ceph-default>}'"
fi

# Fresh-install behavior: if cluster state already exists on this node (including leftovers from
# an interrupted previous run), remove it automatically so we always bootstrap a clean, new cluster.
EXISTING_FSIDS="$(sudo ls /var/lib/ceph 2>/dev/null | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || true)"

if [ -n "$EXISTING_FSIDS" ]; then
    log_info "WARNING: Existing Ceph cluster state detected on this node."
    log_info "WARNING: Existing Ceph cluster(s) will be removed automatically before new bootstrap."
    log_info "WARNING: ALL DATA in those cluster(s) will be lost."

    while IFS= read -r existing_fsid; do
        [ -n "$existing_fsid" ] || continue
        log_info "Removing existing Ceph cluster fsid '$existing_fsid'"

        if ! timeout 300 sudo "$CEPHADM_BIN" rm-cluster --force --zap-osds --fsid "$existing_fsid"; then
            log_info "rm-cluster failed for '$existing_fsid' (continuing with manual cleanup of Ceph directories/services)"
        fi
    done <<< "$EXISTING_FSIDS"

    # Ensure no stale Ceph runtime/config state survives the auto-cleanup.
    sudo systemctl stop 'ceph-*.target' 2>/dev/null || true
    sudo systemctl stop 'ceph-*.service' 2>/dev/null || true
    sudo systemctl stop ceph.target 2>/dev/null || true
    sudo rm -rf /etc/ceph /var/lib/ceph /var/log/ceph /run/ceph

    log_info "Finished cleanup of existing Ceph cluster state"
fi

log_info "Ensuring Ceph monitor ports are free before bootstrap"
if ! ensure_ceph_ports_free; then
    exit 1
fi

if [ "$CEPH_SSH_USER" = "root" ]; then
    log_info "Preparing bootstrap host SSH configuration for cephadm root login"
    if ! ensure_root_ssh_ready_for_cephadm; then
        exit 1
    fi
fi


if ! sudo "$CEPHADM_BIN" --image "$CEPH_IMAGE" bootstrap --mon-ip "$MON_IP" --ssh-user "$CEPH_SSH_USER" --skip-pull --allow-mismatched-release --skip-monitoring-stack; then
    log_error "cephadm bootstrap failed"
    exit 1
fi
log_info "Ceph cluster bootstrap completed on Debian"


log_info "A new (empty) volume drive will be consumed to create the Ceph OSD."
log_info "Attach a raw/unused disk to an OSD host, then let cephadm provision the OSD on it."
CEPH_PUB_KEY="$(sudo cat /etc/ceph/ceph.pub 2>/dev/null)"
if [ -n "$CEPH_PUB_KEY" ]; then
    log_info "cephadm cluster public key (authorize on additional OSD hosts via prepare-ceph-osd-host.sh):"
    echo "$CEPH_PUB_KEY" | sed 's/^/[CephNew]   /'
    echo "K2S_CEPH_PUB_KEY=${CEPH_PUB_KEY}"
fi


log_info "Creating CephFS filesystem '$CEPH_FS_NAME' and collecting connection details"

for attempt in $(seq 1 18); do
    if timeout 30 sudo "$CEPHADM_BIN" shell -- ceph -s >/dev/null 2>&1; then
        break
    fi

    if [ "$attempt" -eq 18 ]; then
        log_error "Ceph did not become ready for shell commands after bootstrap."
        exit 1
    fi

    log_info "Ceph command interface not ready yet (attempt $attempt/18). Retrying in 10s..."
    sleep 10
done

# Offline/air-gapped: stop the cephadm mgr module from resolving the container image to a
# registry digest (its default, use_repo_digest=true). Digest resolution requires reaching the
# image registry (e.g. quay.io); when it is unreachable, orchestrator-deployed daemons such as
# the MDS never start (MDS_ALL_DOWN / MDS_UP_LESS_THAN_MAX) because podman tries to pull a
# digest-pinned reference that is not loaded locally. Pinning to the tag of the image already
# loaded during offline import lets MDS/OSD/MGR (re)deploy without any network access.
if ! sudo "$CEPHADM_BIN" shell -- ceph config set mgr mgr/cephadm/use_repo_digest false; then
    log_info "Failed to set mgr/cephadm/use_repo_digest=false (continuing; MDS deploy may require network)"
fi
if ! sudo "$CEPHADM_BIN" shell -- ceph config set global container_image "$CEPH_IMAGE"; then
    log_info "Failed to pin global container_image to '$CEPH_IMAGE' (continuing)"
fi

if [ -n "$OSD_CRUSH_CHOOSELEAF_TYPE" ]; then
    if ! sudo "$CEPHADM_BIN" shell -- ceph config set osd osd_crush_chooseleaf_type "$OSD_CRUSH_CHOOSELEAF_TYPE"; then
        log_error "Failed to set osd_crush_chooseleaf_type to '$OSD_CRUSH_CHOOSELEAF_TYPE'"
        exit 1
    fi
    log_info "Configured osd_crush_chooseleaf_type=$OSD_CRUSH_CHOOSELEAF_TYPE"
fi

# Derive the replicated pool size from the requested number of OSDs so pools are never left
# permanently undersized/degraded (HEALTH_WARN). min_size is ALWAYS 1 so a single surviving
# replica keeps the pool available; size follows the OSD count and is capped at 3 (Ceph's
# conventional replication maximum). Applied BEFORE creating the CephFS volume so its
# auto-created pools inherit the healthy layout.
POOL_SIZE=3
if printf '%s' "${TOTAL_OSD_COUNT:-}" | grep -Eq '^[0-9]+$' && [ "${TOTAL_OSD_COUNT}" -ge 1 ] && [ "${TOTAL_OSD_COUNT}" -lt 3 ]; then
    POOL_SIZE="${TOTAL_OSD_COUNT}"
fi
log_info "Setting global osd_pool_default_size=$POOL_SIZE / osd_pool_default_min_size=1 (requested OSD count=${TOTAL_OSD_COUNT:-unknown})"
# When size=1 is needed, first unlock single-replica pools (Ceph rejects size=1 without this).
if [ "$POOL_SIZE" = "1" ]; then
    sudo "$CEPHADM_BIN" shell -- ceph config set global mon_allow_pool_size_one true || log_info "Failed to set global mon_allow_pool_size_one=true (continuing)"
    sudo "$CEPHADM_BIN" shell -- ceph config set mon mon_allow_pool_size_one true || log_info "Failed to set mon mon_allow_pool_size_one=true (continuing)"
    # Single OSD/host cannot satisfy replication; suppress persistent POOL_NO_REDUNDANCY warnings.
    sudo "$CEPHADM_BIN" shell -- ceph config set global mon_warn_on_pool_no_redundancy false || log_info "Failed to set mon_warn_on_pool_no_redundancy=false (continuing)"
    sudo "$CEPHADM_BIN" shell -- ceph health mute POOL_NO_REDUNDANCY 1w --sticky || log_info "Failed to mute POOL_NO_REDUNDANCY health warning (continuing)"
else
    # Keep warning enabled whenever replication >1 can be achieved.
    sudo "$CEPHADM_BIN" shell -- ceph config set global mon_warn_on_pool_no_redundancy true || log_info "Failed to set mon_warn_on_pool_no_redundancy=true (continuing)"
    sudo "$CEPHADM_BIN" shell -- ceph health unmute POOL_NO_REDUNDANCY || log_info "Failed to unmute POOL_NO_REDUNDANCY health warning (continuing)"
fi
sudo "$CEPHADM_BIN" shell -- ceph config set global osd_pool_default_size "$POOL_SIZE" || log_info "Failed to set osd_pool_default_size=$POOL_SIZE (continuing)"
sudo "$CEPHADM_BIN" shell -- ceph config set global osd_pool_default_min_size 1 || log_info "Failed to set osd_pool_default_min_size=1 (continuing)"

if [ -n "$MON_COUNT" ]; then
    if ! sudo "$CEPHADM_BIN" shell -- ceph orch apply mon --placement="count:${MON_COUNT}"; then
        log_error "Failed to apply mon placement count '$MON_COUNT'"
        exit 1
    fi
    log_info "Configured mon placement count=$MON_COUNT"
fi

if [ -n "$MGR_COUNT" ]; then
    if ! sudo "$CEPHADM_BIN" shell -- ceph orch apply mgr --placement="count:${MGR_COUNT}"; then
        log_error "Failed to apply mgr placement count '$MGR_COUNT'"
        exit 1
    fi
    log_info "Configured mgr placement count=$MGR_COUNT"
fi

if ! CLUSTER_DETAILS="$(timeout 900 sudo "$CEPHADM_BIN" shell --env K2S_FS_NAME="$CEPH_FS_NAME" --env K2S_MDS_COUNT="$MDS_COUNT" -- bash -c '
    # Create the CephFS volume (idempotent). This also deploys an MDS and
    # creates the "cephfs.<name>.meta" / "cephfs.<name>.data" pools.
    ceph fs volume create "$K2S_FS_NAME" >/dev/null 2>&1 || true

    if [ -n "$K2S_MDS_COUNT" ]; then
        ceph orch apply mds "$K2S_FS_NAME" --placement="count:${K2S_MDS_COUNT}" >/dev/null
    fi

    FSID="$(ceph fsid 2>/dev/null)"
    ADMIN_KEY="$(ceph auth get-key client.admin 2>/dev/null)"

    # Monitor endpoints: extract the v1 (msgr1) "IP:6789" addresses used by the CSI driver.
    MON_ENDPOINTS="$(ceph mon dump 2>/dev/null | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}:6789" | sort -u | paste -sd, -)"

    # Data pool for the filesystem. Prefer querying it; fall back to the
    # deterministic name that "ceph fs volume create" uses.
    DATA_POOL="$(ceph fs ls 2>/dev/null | sed -n "s/.*name: ${K2S_FS_NAME},.*data pools: \[\([^ ]*\).*/\1/p")"
    if [ -z "$DATA_POOL" ]; then
        DATA_POOL="cephfs.${K2S_FS_NAME}.data"
    fi

    echo "K2S_CEPH_FSID=${FSID}"
    echo "K2S_CEPH_MON_ENDPOINTS=${MON_ENDPOINTS}"
    echo "K2S_CEPH_ADMIN_KEY=${ADMIN_KEY}"
    echo "K2S_CEPH_FS_NAME=${K2S_FS_NAME}"
    echo "K2S_CEPH_DATA_POOL=${DATA_POOL}"
    # ceph-csi expects the user id WITHOUT the "client." prefix (it prepends it internally).
    echo "K2S_CEPH_USER=admin"
')"; then
    log_error "Timed out while creating CephFS/collecting cluster details via cephadm shell."
    log_error "If this follows a previous failed run, clean up the stale cluster first and retry enable."
    exit 1
fi

echo "$CLUSTER_DETAILS" | grep -E '^K2S_CEPH_' | while IFS= read -r line; do
    case "$line" in
        K2S_CEPH_ADMIN_KEY=*) log_info "Collected K2S_CEPH_ADMIN_KEY=<hidden>" ;;
        *) log_info "Collected $line" ;;
    esac
done
echo "$CLUSTER_DETAILS" | grep -E '^K2S_CEPH_'

COLLECTED_FSID="$(echo "$CLUSTER_DETAILS" | sed -n 's/^K2S_CEPH_FSID=//p')"
COLLECTED_KEY="$(echo "$CLUSTER_DETAILS" | sed -n 's/^K2S_CEPH_ADMIN_KEY=//p')"
COLLECTED_MONS="$(echo "$CLUSTER_DETAILS" | sed -n 's/^K2S_CEPH_MON_ENDPOINTS=//p')"
if [ -z "$COLLECTED_FSID" ] || [ -z "$COLLECTED_KEY" ] || [ -z "$COLLECTED_MONS" ]; then
    log_error "Failed to read back the Ceph connection details from the cluster (fsid/key/mon endpoints missing)."
    log_error "The Ceph cluster may not be healthy yet. Check 'sudo cephadm shell -- ceph -s' on the node."
    exit 1
fi

# If OSD-level CRUSH placement was requested, create a named rule and explicitly apply it to
# the CephFS pools. 'ceph config set osd osd_crush_chooseleaf_type' only affects future
# auto-generated rules; pools created by 'ceph fs volume create' inherit the existing
# 'replicated_rule' (chooseleaf type host) and must be updated explicitly.
if [ "${OSD_CRUSH_CHOOSELEAF_TYPE:-}" = "0" ]; then
    log_info "Creating OSD-level CRUSH rule 'k2s-osd-rule' for single-host placement..."
    if ! sudo "$CEPHADM_BIN" shell -- ceph osd crush rule create-replicated k2s-osd-rule default osd; then
        log_error "Failed to create OSD-level CRUSH rule 'k2s-osd-rule'"
        exit 1
    fi
    if ! sudo "$CEPHADM_BIN" shell -- ceph osd pool set "cephfs.${CEPH_FS_NAME}.meta" crush_rule k2s-osd-rule; then
        log_error "Failed to apply k2s-osd-rule to pool 'cephfs.${CEPH_FS_NAME}.meta'"
        exit 1
    fi
    if ! sudo "$CEPHADM_BIN" shell -- ceph osd pool set "cephfs.${CEPH_FS_NAME}.data" crush_rule k2s-osd-rule; then
        log_error "Failed to apply k2s-osd-rule to pool 'cephfs.${CEPH_FS_NAME}.data'"
        exit 1
    fi
fi

# Explicitly enforce the derived sizing on the CephFS and .mgr pools. Pools created by
# 'ceph fs volume create' before the global default took effect, and the .mgr pool created at
# bootstrap, would otherwise keep size=3 and hold the cluster in HEALTH_WARN when fewer OSDs exist.
log_info "Enforcing size=$POOL_SIZE/min_size=1 on CephFS and .mgr pools (requested OSD count=${TOTAL_OSD_COUNT:-unknown})"
for pool in "cephfs.${CEPH_FS_NAME}.meta" "cephfs.${CEPH_FS_NAME}.data" ".mgr"; do
    if [ "$POOL_SIZE" = "1" ]; then
        sudo "$CEPHADM_BIN" shell -- ceph osd pool set "$pool" size "$POOL_SIZE" --yes-i-really-mean-it || log_info "Failed to set size=$POOL_SIZE on pool '$pool' (continuing)"
    else
        sudo "$CEPHADM_BIN" shell -- ceph osd pool set "$pool" size "$POOL_SIZE" || log_info "Failed to set size=$POOL_SIZE on pool '$pool' (continuing)"
    fi
    sudo "$CEPHADM_BIN" shell -- ceph osd pool set "$pool" min_size 1 || log_info "Failed to set min_size=1 on pool '$pool' (continuing)"
done

log_info "Finished collecting Ceph cluster connection details"
