#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail
export LC_ALL=C

# Dedicated nodes do not need documentation viewers, editors or mail/discovery daemons.
# Storage, mount and network administration tools are deliberately NOT candidates.
REMOVAL_CANDIDATES=(man-db manpages manpages-dev groff groff-base doc-debian info install-info
    nano vim-tiny ed exim4 exim4-base exim4-config exim4-daemon-light exim4-daemon-heavy avahi-daemon)
APT_UNITS=(apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer)
AUDIT_DIR=/var/lib/k2s/hardening

log() { printf '[Hardening] %s\n' "$*"; }
fail() { log "ERROR: $*" >&2; return 1; }

package_is_protected() {
    local package="${1%%:*}" essential="$2" priority="$3" held="$4"
    [[ "$essential" == yes || "$priority" == required || "$held" == yes ]] && return 0
    case "$package" in
        kube*|cri-o*|cri-tools|containerd*|runc|crun|buildah|podman*|conmon*|netavark*|aardvark-dns*|containernetworking*|containers-*|libnvidia*|nvidia-*|linux-*|hyperv-daemons|qemu-guest-agent|systemd*|udev|dbus*|openssh*|sudo|apt|dpkg|bash|coreutils|util-linux*|mount|psmisc|procps|kmod|cron|cloud-init|cloud-guest-utils|lsb-release|ca-certificates|curl|wget|gpg*|gnupg*|openssl|iproute2|net-tools|iptables|ebtables|ipset|nftables|iputils-*|conntrack|socat|ethtool|ifupdown*|isc-dhcp*|systemd-networkd|systemd-resolved|dnsmasq*|dnsutils|bind9-*|resolvconf|network-manager*|wpasupplicant|ppp*|e2fsprogs|btrfs-progs|xfsprogs|mdadm|multipath-tools|lvm2|thin-provisioning-tools|cryptsetup*|nfs-common|rpcbind|cifs-utils|smbclient|samba*|open-iscsi|parted|fdisk|gdisk|dosfstools|fuse*|jq|tar|gzip|unzip|rsync|git|python3*) return 0 ;;
    esac
    return 1
}

wait_for_package_work() {
    local max_wait="${1:-300}" deadline=$((SECONDS + ${1:-300})) state busy
    command -v fuser >/dev/null || { fail 'fuser is required to inspect package locks'; return 1; }
    while :; do
        busy=false
        for unit in apt-daily.service apt-daily-upgrade.service cloud-final.service; do
            state="$(systemctl show "$unit" --property=ActiveState --value)"
            case "$state" in activating|deactivating) busy=true ;; esac
            if [[ "$unit" != cloud-final.service && "$state" == active ]]; then busy=true; fi
        done
        if fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
            busy=true
        fi
        [[ "$busy" == false ]] && return 0
        if (( SECONDS >= deadline )); then
            fail "Timeout waiting for APT/cloud-init package work after ${max_wait}s; locks and processes left untouched"
            return 1
        fi
        log 'Waiting for existing package work to finish'
        sleep 5
    done
}

prepare_node() {
    # Masking a service does not terminate a running package transaction.
    systemctl mask "${APT_UNITS[@]}"
    systemctl stop apt-daily.timer apt-daily-upgrade.timer
    if [[ "$(systemctl show motd-news.timer --property=LoadState --value)" != not-found ]]; then
        systemctl disable --now motd-news.timer
    fi
    if command -v cloud-init >/dev/null; then
        log 'Waiting for cloud-init (maximum 300s)'
        local cloud_init_status=0
        timeout 300 cloud-init status --wait --long || cloud_init_status=$?
        case "$cloud_init_status" in
            0) ;;
            2) log 'WARNING: cloud-init completed with recoverable errors; review the diagnostics above' ;;
            *) fail "cloud-init did not complete successfully (exit $cloud_init_status)"; return 1 ;;
        esac
    fi
    wait_for_package_work
    systemctl reset-failed apt-daily.timer apt-daily-upgrade.timer
    log 'Automatic APT triggers disabled; controlled package operations remain available'
}

validate_removal_plan() {
    local simulation="$1" inventory="$2" held_packages="$3" action package rest record essential priority held
    while read -r action package rest; do
        case "$action" in
            Inst|Conf) fail "Removal would install/configure $package; refusing offline cleanup"; return 1 ;;
            Remv|Purg)
                record="$(awk -F '\t' -v package="$package" '$1 == package || $1 == package ":amd64" { print; exit }' "$inventory")"
                [[ -n "$record" ]] || { fail "No installed-package metadata for planned removal $package"; return 1; }
                IFS=$'\t' read -r package rest essential priority <<< "$record"
                held=no
                if grep -Fxq "$package" <<< "$held_packages" || grep -Fxq "${package%%:*}" <<< "$held_packages"; then held=yes; fi
                if package_is_protected "$package" "$essential" "$priority" "$held"; then
                    fail "Removal would purge protected package $package"
                    return 1
                fi ;;
        esac
    done < "$simulation"
}

prune_documentation() {
    local root="${1:-}" directory doc_directory
    doc_directory="$root/usr/share/doc"
    # Keep package directories, legal notices and examples which may be used at runtime.
    mkdir -p "$root/etc/dpkg/dpkg.cfg.d"
    cat > "$root/etc/dpkg/dpkg.cfg.d/01_nodoc" <<'CONFIG'
# Managed by K2s Debian 13 node hardening.
path-exclude=/usr/share/doc/*
path-exclude=/usr/share/man/*
path-exclude=/usr/share/groff/*
path-exclude=/usr/share/info/*
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/linda/*
path-include=/usr/share/doc/*/
path-include=/usr/share/doc/*/*[Cc][Oo][Pp][Yy][Rr][Ii][Gg][Hh][Tt]*
path-include=/usr/share/doc/*/*[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*
path-include=/usr/share/doc/*/*[Ll][Ii][Cc][Ee][Nn][Cc][Ee]*
path-include=/usr/share/doc/*/examples/*
CONFIG
    for directory in "$doc_directory" "$root/usr/share/man" "$root/usr/share/groff" "$root/usr/share/info" "$root/usr/share/lintian" "$root/usr/share/linda"; do
        [[ -d "$directory" && ! -L "$directory" ]] || continue
        find -P "$directory" \( -type f -o -type l \) \
            ! -path "$doc_directory/*" -delete
        if [[ "$directory" == "$doc_directory" ]]; then
            # Preserve symlinks: Debian packages share legal notices through doc-directory links.
            find -P "$directory" -type f \
                ! -iname '*copyright*' ! -iname '*license*' ! -iname '*licence*' \
                ! -path "$doc_directory/*/examples/*" -delete
        fi
    done
}

cleanup_node() {
    wait_for_package_work
    mkdir -p "$AUDIT_DIR"
    local inventory="$AUDIT_DIR/packages-before.tsv" simulation="$AUDIT_DIR/removal-plan.log"
    local post_inventory="$AUDIT_DIR/packages-after.tsv"
    local package version essential priority held_packages
    local candidates=() purge_options=(--yes --no-download --purge --autoremove remove)
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Essential}\t${Priority}\t${db:Status-Status}\n' \
        | awk -F '\t' '$5 == "installed" { print $1 "\t" $2 "\t" ($3 == "yes" ? "yes" : "no") "\t" $4 }' > "$inventory"
    held_packages="$(apt-mark showhold)"
    for package in "${REMOVAL_CANDIDATES[@]}"; do
        if awk -F '\t' -v package="$package" '$1 == package || $1 == package ":amd64" { found=1 } END { exit !found }' "$inventory"; then
            candidates+=("$package")
        fi
    done
    if (( ${#candidates[@]} )); then
        log "Simulating purge/autoremove: ${candidates[*]}"
        apt-get --simulate "${purge_options[@]}" "${candidates[@]}" | tee "$simulation" || return 1
        validate_removal_plan "$simulation" "$inventory" "$held_packages" || return 1
        # Keep the versioned reinstall list BEFORE executing; partial failures remain auditable.
        awk '($1 == "Remv" || $1 == "Purg") { print $2 }' "$simulation" | sort -u > "$AUDIT_DIR/planned-removals.txt"
        while IFS=$'\t' read -r package version essential priority; do
            if grep -Fxq "$package" "$AUDIT_DIR/planned-removals.txt" || grep -Fxq "${package%%:*}" "$AUDIT_DIR/planned-removals.txt"; then
                printf '%s\t%s\n' "$package" "$version" >> "$AUDIT_DIR/reinstall.tsv"
            fi
        done < "$inventory"
        sort -u "$AUDIT_DIR/reinstall.tsv" -o "$AUDIT_DIR/reinstall.tsv"
        DEBIAN_FRONTEND=noninteractive apt-get "${purge_options[@]}" "${candidates[@]}" || return 1
        if ! dpkg-query -W -f='${binary:Package}\t${Version}\t${Essential}\t${Priority}\t${db:Status-Status}\n' \
            | awk -F '\t' '$5 == "installed" { print $1 "\t" $2 "\t" ($3 == "yes" ? "yes" : "no") "\t" $4 }' > "$post_inventory"; then
            fail 'Unable to verify installed packages after purge'
            return 1
        fi
        for package in "${candidates[@]}"; do
            if awk -F '\t' -v package="$package" '$1 == package || $1 == package ":amd64" { found=1 } END { exit !found }' "$post_inventory"; then
                fail "Candidate still installed after cleanup: $package"
                return 1
            fi
        done
        awk -F '\t' 'FILENAME == ARGV[1] { installed[$1] = 1; next }
            !($1 in installed) { print $1 "\t" $2 }' "$post_inventory" "$inventory" >> "$AUDIT_DIR/removed.tsv" || return 1
        if [[ -f "$AUDIT_DIR/removed.tsv" ]]; then sort -u "$AUDIT_DIR/removed.tsv" -o "$AUDIT_DIR/removed.tsv"; fi
    else
        log 'No installed removal candidates; skipping purge/autoremove'
    fi
    prune_documentation
    # Only APT's disposable archives; /home/.../apt-offline-k2s remains untouched.
    apt-get clean
    log "Cleanup complete; audit/reinstall records: $AUDIT_DIR"
}

main() {
    local stage="${1:?Expected prepare or cleanup}"
    case "$stage" in prepare|cleanup) ;; *) fail "Unknown hardening stage: $stage"; return 1 ;; esac
    if (( EUID != 0 )); then exec sudo -- bash "$0" "$stage"; fi
    # This script must never harden a different distribution or the Windows host.
    . /etc/os-release
    [[ "$ID" == debian && "$VERSION_ID" == 13 ]] || { fail 'Debian 13 is required'; return 1; }
    case "$stage" in prepare) prepare_node ;; cleanup) cleanup_node ;; esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
