#!/bin/bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Isolated filesystem and command-mocked tests. Never execute main(), sudo or real package operations.
set -euo pipefail
exec 2>&1
source "$(dirname "${BASH_SOURCE[0]}")/../cfg/nodeextension/debian13/scripts/harden-node.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -r -- "$TEST_DIR"' EXIT
sudo() { fail 'Tests must never execute sudo'; }
sleep() { fail 'Tests must never wait'; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }

printf 'nano\t1.0\tno\toptional\nbuildah\t1.0\tno\toptional\nimportant\t1.0\tno\trequired\nheld-tool\t1.0\tno\toptional\nessential-tool\t1.0\tyes\toptional\n' > "$TEST_DIR/inventory"
printf 'doc-debian\t1.0\tno\toptional\nebtables\t1.0\tno\toptional\nipset\t1.0\tno\toptional\n' >> "$TEST_DIR/inventory"
for package in kubelet cri-o iptables e2fsprogs qemu-guest-agent; do
    printf '%s\t1.0\tno\toptional\n' "$package" >> "$TEST_DIR/inventory"
done
for package in buildah important held-tool essential-tool ebtables ipset kubelet cri-o iptables e2fsprogs qemu-guest-agent; do
    printf 'Remv nano [1.0]\nRemv %s [1.0]\n' "$package" > "$TEST_DIR/plan"
    if validate_removal_plan "$TEST_DIR/plan" "$TEST_DIR/inventory" 'held-tool'; then
        fail "Accepted protected removal $package"; exit 1
    fi
    pass "reject $package before purge"
done
printf 'held-arch:amd64\t1.0\tno\toptional\n' >> "$TEST_DIR/inventory"
printf 'Remv nano [1.0]\nRemv held-arch [1.0]\n' > "$TEST_DIR/plan"
for held_package in held-arch held-arch:amd64; do
    if validate_removal_plan "$TEST_DIR/plan" "$TEST_DIR/inventory" "$held_package"; then
        fail "Accepted held architecture-qualified removal $held_package"; exit 1
    fi
    pass "reject architecture-qualified package with hold $held_package"
done
printf 'Remv nano [1.0]\nRemv doc-debian [1.0]\n' > "$TEST_DIR/plan"
validate_removal_plan "$TEST_DIR/plan" "$TEST_DIR/inventory" ''
[[ " ${REMOVAL_CANDIDATES[*]} " == *' doc-debian '* ]]
pass 'accept approved candidate'
printf 'Inst extra [1.0]\n' > "$TEST_DIR/plan"
if validate_removal_plan "$TEST_DIR/plan" "$TEST_DIR/inventory" ''; then exit 1; fi
pass 'reject install/download during removal'
printf 'Purg unknown [1.0]\n' > "$TEST_DIR/plan"
if validate_removal_plan "$TEST_DIR/plan" "$TEST_DIR/inventory" ''; then exit 1; fi
pass 'reject removal without metadata'
for package in ebtables ipset nftables util-linux-extra nfs-common rpcbind btrfs-progs xfsprogs mdadm multipath-tools hyperv-daemons qemu-guest-agent linux-image-cloud-amd64; do
    package_is_protected "$package" no optional no
    [[ " ${REMOVAL_CANDIDATES[*]} " != *" $package "* ]]
done
pass 'preserve runtime storage and hypervisor tools'

systemctl() {
    case "$*" in
        'show motd-news.timer --property=LoadState --value') printf 'not-found\n' ;;
        show*) printf 'inactive\n' ;;
        *) printf '%s\n' "$*" >> "$TEST_DIR/systemctl" ;;
    esac
}
fuser() { return 1; }
command() {
    if [[ "$*" == '-v cloud-init' ]]; then return 1; fi
    builtin command "$@"
}
prepare_node
[[ "$(head -n 1 "$TEST_DIR/systemctl")" == 'mask apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer' ]]
grep -Fxq 'stop apt-daily.timer apt-daily-upgrade.timer' "$TEST_DIR/systemctl"
[[ "$(tail -n 1 "$TEST_DIR/systemctl")" == 'reset-failed apt-daily.timer apt-daily-upgrade.timer' ]]
pass 'mask first, stop timers only, tolerate missing motd/cloud-init'
fuser() { return 0; }
if wait_for_package_work 0; then exit 1; fi
pass 'busy lock fails at bounded timeout without stopping services'
fuser() { return 1; }
systemctl() { printf 'active\n'; }
if wait_for_package_work 0; then exit 1; fi
pass 'active APT service fails at timeout'
command() { [[ "$*" != '-v fuser' ]] && builtin command "$@"; }
if wait_for_package_work 0; then exit 1; fi
pass 'missing lock inspector fails closed'
unset -f command

systemctl() {
    case "$*" in
        'show motd-news.timer --property=LoadState --value') printf 'not-found\n' ;;
        show*) printf 'inactive\n' ;;
        *) printf '%s\n' "$*" >> "$TEST_DIR/systemctl" ;;
    esac
}
timeout() {
    [[ "$*" == '300 cloud-init status --wait --long' ]] || { fail 'Unexpected cloud-init invocation'; return 1; }
    printf 'cloud-init diagnostic fixture: %s\n' "$cloud_init_result"
    return "$cloud_init_result"
}
cloud-init() { fail 'cloud-init must run through bounded timeout'; }
for cloud_init_result in 0 2; do
    prepare_node > "$TEST_DIR/cloud-init-output"
    if [[ "$cloud_init_result" == 2 ]]; then grep -Fq 'WARNING: cloud-init completed with recoverable errors' "$TEST_DIR/cloud-init-output"; fi
    pass "completed cloud-init status $cloud_init_result allows preparation with diagnostics"
done
for cloud_init_result in 1 124; do
    if prepare_node > "$TEST_DIR/cloud-init-output" 2>&1; then fail "Accepted cloud-init failure $cloud_init_result"; exit 1; fi
    grep -Fq "cloud-init did not complete successfully (exit $cloud_init_result)" "$TEST_DIR/cloud-init-output"
    if grep -Fq 'controlled package operations remain available' "$TEST_DIR/cloud-init-output"; then exit 1; fi
    pass "cloud-init failure $cloud_init_result stops preparation"
done
unset -f timeout cloud-init

ROOT="$TEST_DIR/node root"
DOC="$ROOT/usr/share/doc"
CONFIG="$ROOT/etc/dpkg/dpkg.cfg.d/01_nodoc"
mkdir -p "$DOC/demo/examples" "$DOC/shared" "$ROOT/usr/share/locale/en" "$ROOT/usr/share/common-licenses"
printf 'runtime locale\n' > "$ROOT/usr/share/locale/en/messages.mo"
printf 'common license\n' > "$ROOT/usr/share/common-licenses/GPL"
printf 'package copyright\n' > "$DOC/shared/copyright"
for file in README changelog.gz; do printf 'documentation\n' > "$DOC/demo/$file"; done
for file in copyright LICENSE Licence.txt; do printf 'legal notice\n' > "$DOC/demo/$file"; done
printf 'runtime example\n' > "$DOC/demo/examples/default.conf"
for directory in man groff info lintian linda; do
    mkdir -p "$ROOT/usr/share/$directory"
    printf 'documentation\n' > "$ROOT/usr/share/$directory/payload"
done
MSYS=winsymlinks:sys ln -s shared "$DOC/linked-package"
MSYS=winsymlinks:sys ln -s ../shared/copyright "$DOC/demo/copyright-link"
MSYS=winsymlinks:sys ln -s ../doc/shared/copyright "$ROOT/usr/share/man/linked-notice"
prune_documentation "$ROOT"
[[ ! -e "$DOC/demo/README" && ! -e "$DOC/demo/changelog.gz" ]]
for directory in man groff info lintian linda; do
    [[ -z "$(find "$ROOT/usr/share/$directory" \( -type f -o -type l \) -print)" ]]
done
pass 'real pruning removes documentation files and non-doc symlinks'
for file in copyright LICENSE Licence.txt; do
    [[ "$(cat "$DOC/demo/$file")" == 'legal notice' ]]
done
[[ -L "$DOC/linked-package" && -L "$DOC/demo/copyright-link" ]]
[[ "$(cat "$DOC/linked-package/copyright")" == 'package copyright' ]]
[[ "$(cat "$DOC/demo/copyright-link")" == 'package copyright' ]]
[[ "$(cat "$DOC/demo/examples/default.conf")" == 'runtime example' ]]
[[ "$(cat "$ROOT/usr/share/locale/en/messages.mo")" == 'runtime locale' ]]
[[ "$(cat "$ROOT/usr/share/common-licenses/GPL")" == 'common license' ]]
pass 'real pruning preserves legal notices, doc symlinks, examples, locales and common licenses'
for directory in doc man groff info lintian linda; do
    grep -Fxq "path-exclude=/usr/share/$directory/*" "$CONFIG"
done
for pattern in '*/' '*/*[Cc][Oo][Pp][Yy][Rr][Ii][Gg][Hh][Tt]*' '*/*[Ll][Ii][Cc][Ee][Nn][Ss][Ee]*' '*/*[Ll][Ii][Cc][Ee][Nn][Cc][Ee]*' '*/examples/*'; do
    grep -Fxq "path-include=/usr/share/doc/$pattern" "$CONFIG"
done
[[ "$(grep -c '^path-exclude=' "$CONFIG")" == 6 ]]
pass 'dpkg config excludes all six documentation trees with legal and runtime exceptions'
cp "$CONFIG" "$TEST_DIR/01_nodoc.before"
prune_documentation "$ROOT"
cmp "$CONFIG" "$TEST_DIR/01_nodoc.before"
[[ "$(cat "$DOC/demo/copyright")" == 'legal notice' && -L "$DOC/linked-package" ]]
pass 'real documentation cleanup is repeatable without changing config or retained content'

# Simulate cleanup using only temporary audit files and mocked package/filesystem commands.
wait_for_package_work() { :; }
prune_documentation() { printf 'prune\n' >> "$TEST_DIR/actions"; }
AUDIT_DIR="$TEST_DIR/audit"
dpkg-query() {
    if [[ "$*" == *'binary:Package'* ]]; then
        if [[ ! -f "$TEST_DIR/removed" ]]; then printf 'nano\t1.0\t\toptional\tinstalled\n'; fi
        printf 'buildah\t1.0\t\toptional\tinstalled\n'
    else
        if [[ "${*: -1}" == buildah ]]; then printf 'installed'; else printf 'not-installed'; fi
    fi
}
apt-mark() { :; }
apt-get() {
    printf '%s\n' "$*" >> "$TEST_DIR/actions"
    case "$1" in
        --simulate) printf 'Remv nano [1.0]\n' ;;
        --yes) touch "$TEST_DIR/removed" ;;
        clean) : ;;
        *) fail 'Unexpected APT operation'; return 1 ;;
    esac
}
cleanup_node
[[ "$(cat "$AUDIT_DIR/reinstall.tsv")" == $'nano\t1.0' ]]
grep -Fxq -- '--simulate --yes --no-download --purge --autoremove remove nano' "$TEST_DIR/actions"
grep -Fxq -- '--yes --no-download --purge --autoremove remove nano' "$TEST_DIR/actions"
pass 'exact offline removal simulation/execution and versioned audit'
cleanup_node
[[ "$(grep -c '^--yes' "$TEST_DIR/actions")" == 1 ]]
[[ "$(cat "$AUDIT_DIR/reinstall.tsv")" == $'nano\t1.0' ]]
pass 'repeat cleanup does not purge again or discard reinstall list'
[[ "$(cat "$AUDIT_DIR/removed.tsv")" == $'nano\t1.0' ]]
pass 'actual removed list excludes retained packages'
# Reintroduce candidate but inject a protected transitive removal in the simulation.
rm -- "$TEST_DIR/removed"
apt-get() {
    printf '%s\n' "$*" >> "$TEST_DIR/actions"
    if [[ "$1" == --simulate ]]; then printf 'Remv nano [1.0]\nRemv buildah [1.0]\n'; else fail 'Unsafe purge must never run'; return 1; fi
}
if cleanup_node; then fail 'Unsafe transaction accepted'; exit 1; fi
[[ "$(grep -c '^--yes' "$TEST_DIR/actions")" == 1 ]]
pass 'protected transitive removal prevents any purge or subsequent cleanup'
for failure in inventory holds simulate purge postquery postcheck prune clean; do
    set +e
    (
        trap - EXIT
        set -e
        AUDIT_DIR="$TEST_DIR/failure-$failure"
        dpkg-query() {
            if [[ "$*" == *'binary:Package'* ]]; then
                [[ "$failure" != inventory ]] || { fail 'Injected inventory failure'; return 51; }
                if [[ -e "$AUDIT_DIR/purged" && "$failure" == postquery ]]; then
                    printf 'buildah\t1.0\t\toptional\tinstalled\n'
                    fail 'Injected post-purge query failure'
                    return 42
                fi
                if [[ ! -e "$AUDIT_DIR/purged" || "$failure" == postcheck ]]; then
                    printf 'nano\t1.0\t\toptional\tinstalled\n'
                fi
                printf 'buildah\t1.0\t\toptional\tinstalled\n'
            elif [[ "$failure" == postquery ]]; then
                fail 'Injected post-purge query failure'
                return 42
            elif [[ "${*: -1}" == buildah || "$failure" == postcheck ]]; then
                printf 'installed'
            else
                printf 'not-installed'
            fi
        }
        apt-mark() { [[ "$failure" != holds ]] || { fail 'Injected hold-query failure'; return 52; }; }
        apt-get() {
            printf '%s\n' "$1" >> "$AUDIT_DIR/actions"
            case "$1" in
                --simulate)
                    [[ "$failure" != simulate ]] || { fail 'Injected simulation failure'; return 53; }
                    printf 'Remv nano [1.0]\n' ;;
                --yes)
                    [[ "$failure" != purge ]] || { fail 'Injected purge failure'; return 54; }
                    touch "$AUDIT_DIR/purged" ;;
                clean)
                    [[ "$failure" != clean ]] || { fail 'Injected cache-clean failure'; return 55; } ;;
                *) fail 'Unexpected APT operation'; return 1 ;;
            esac
        }
        prune_documentation() {
            touch "$AUDIT_DIR/pruned"
            [[ "$failure" != prune ]] || { fail 'Injected documentation-pruning failure'; return 56; }
        }
        cleanup_node
    ) > "$TEST_DIR/failure-$failure.log" 2>&1
    failure_status=$?
    set -e
    [[ "$failure_status" != 0 ]] || { fail "Cleanup reported success after $failure failure"; exit 1; }
    case "$failure" in
        inventory|holds|simulate)
            if [[ -f "$TEST_DIR/failure-$failure/actions" ]] && grep -Fxq -- --yes "$TEST_DIR/failure-$failure/actions"; then exit 1; fi
            [[ ! -e "$TEST_DIR/failure-$failure/pruned" ]] ;;
        purge|postcheck)
            [[ -s "$TEST_DIR/failure-$failure/reinstall.tsv" && ! -e "$TEST_DIR/failure-$failure/pruned" ]] ;;
        postquery)
            [[ -s "$TEST_DIR/failure-$failure/reinstall.tsv" && ! -e "$TEST_DIR/failure-$failure/pruned" ]]
            [[ ! -e "$TEST_DIR/failure-$failure/removed.tsv" ]]
            grep -Fq 'Injected post-purge query failure' "$TEST_DIR/failure-$failure.log"
            if grep -Fxq clean "$TEST_DIR/failure-$failure/actions" ||
                grep -Fq 'Cleanup complete' "$TEST_DIR/failure-$failure.log"; then exit 1; fi ;;
        prune)
            if grep -Fxq clean "$TEST_DIR/failure-$failure/actions"; then exit 1; fi ;;
    esac
    pass "$failure failure stops cleanup without success-shaped continuation"
done
printf 'Passed=%s Failed=0 (isolated filesystem and command mocks; no guest validation)\n' "$passed"
