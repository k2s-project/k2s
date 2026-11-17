#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Debian 13 (trixie) amd64 guest for ci-linux-cluster.yml. K2s' native Linux host path
# refuses any host that is not Debian 13 (lib/modules/linux/cluster/lifecycle.sh), and
# GitHub-hosted runners do not offer a Debian host image, so the runner boots a KVM guest.
#
# Subcommands:
#   prepare     install QEMU tools, fetch the Debian cloud image, create overlay + cloud-init seed
#   start       boot the guest in the background (SSH forwarded to 127.0.0.1:$VM_SSH_PORT)
#   wait-ssh    block until the guest accepts SSH
#   exec        read a bash script from stdin and run it in the guest (as $VM_USER, sudo available)
#   push        copy a local file/dir to the guest:  push <local> <remote>
#   pull        copy a guest file/dir to a local dir: pull <remote> <local-dir>
#   stop        power the guest off (the runner is discarded afterwards anyway)

set -euo pipefail

VM_DIR="${VM_DIR:-${RUNNER_TEMP:-/tmp}/k2s-vm}"
VM_USER="${VM_USER:-debian}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_CPUS="${VM_CPUS:-3}"
VM_MEMORY_MB="${VM_MEMORY_MB:-10240}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"

die() {
  echo "::error::$*" >&2
  exit 1
}

ssh_opts=(
  -i "$VM_DIR/id_ed25519"
  -p "$VM_SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=30
)

ssh_vm() {
  ssh "${ssh_opts[@]}" "$VM_USER@127.0.0.1" "$@"
}

prepare() {
  [[ -e /dev/kvm ]] || die "/dev/kvm is missing: the runner cannot start KVM guests."
  [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not readable and writable by $(id -un)."

  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    qemu-system-x86 qemu-utils cloud-image-utils openssh-client

  mkdir -p "$VM_DIR"
  if [[ ! -s "$VM_DIR/base.qcow2" ]]; then
    curl -fsSL --retry 3 --retry-delay 10 -o "$VM_DIR/base.qcow2" "$BASE_IMAGE_URL"
  fi

  ssh-keygen -q -t ed25519 -N '' -f "$VM_DIR/id_ed25519"
  local pubkey
  pubkey="$(cat "$VM_DIR/id_ed25519.pub")"

  # Packages required by the native Linux host preflight (lifecycle.sh: k2s_require_host)
  # that the stock cloud image may not ship. K2s installs everything else itself.
  cat > "$VM_DIR/user-data" <<EOF
#cloud-config
ssh_authorized_keys:
  - $pubkey
package_update: true
packages:
  - jq
  - openssh-client
  - iproute2
  - util-linux
  - e2fsprogs
  - curl
  - ca-certificates
EOF
  printf 'instance-id: k2s-linux-ci\nlocal-hostname: k2s-linux-ci\n' > "$VM_DIR/meta-data"
  cloud-localds "$VM_DIR/seed.img" "$VM_DIR/user-data" "$VM_DIR/meta-data"

  qemu-img create -f qcow2 -F qcow2 -b "$VM_DIR/base.qcow2" "$VM_DIR/overlay.qcow2" "$VM_DISK_SIZE"
}

start() {
  [[ -f "$VM_DIR/overlay.qcow2" ]] || die "Run 'prepare' before 'start'."
  qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "$VM_CPUS" \
    -m "$VM_MEMORY_MB" \
    -drive "file=$VM_DIR/overlay.qcow2,if=virtio,format=qcow2" \
    -drive "file=$VM_DIR/seed.img,if=virtio,format=raw" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$VM_SSH_PORT-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "file:$VM_DIR/console.log" \
    -daemonize \
    -pidfile "$VM_DIR/qemu.pid"
}

wait_ssh() {
  local attempt
  for attempt in $(seq 1 60); do
    if ssh_vm true 2>/dev/null; then
      echo "Guest is accepting SSH (attempt $attempt)."
      return 0
    fi
    sleep 10
  done
  echo "--- guest console (tail) ---" >&2
  tail -n 80 "$VM_DIR/console.log" >&2 || true
  die "Guest did not accept SSH within 10 minutes."
}

exec_vm() {
  # The script is passed as one argument so that stdin is not consumed by remote commands.
  local script
  script="$(cat)"
  ssh_vm "bash -c $(printf '%q' "set -euo pipefail"$'\n'"$script")"
}

scp_opts=(
  -i "$VM_DIR/id_ed25519"
  -P "$VM_SSH_PORT"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

push() {
  scp -r "${scp_opts[@]}" "$1" "$VM_USER@127.0.0.1:$2"
}

pull() {
  scp -r "${scp_opts[@]}" "$VM_USER@127.0.0.1:$1" "$2"
}

stop() {
  if [[ -f "$VM_DIR/qemu.pid" ]]; then
    kill "$(cat "$VM_DIR/qemu.pid")" 2>/dev/null || true
  fi
}

case "${1:-}" in
  prepare) prepare ;;
  start) start ;;
  wait-ssh) wait_ssh ;;
  exec) exec_vm ;;
  push) shift; push "$@" ;;
  pull) shift; pull "$@" ;;
  stop) stop ;;
  *) die "Usage: $0 {prepare|start|wait-ssh|exec|push|pull|stop}" ;;
esac
