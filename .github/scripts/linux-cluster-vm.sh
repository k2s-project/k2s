#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Debian 13 (trixie) guests for the Linux-host CI workflows. K2s' native Linux host path
# refuses any host that is not Debian 13 (lib/modules/linux/cluster/lifecycle.sh), and
# GitHub-hosted runners do not offer a Debian host image, so the runner boots a Debian guest.
#
# Defaults (VM_NET_MODE=user): the amd64 guest of ci-linux-cluster.yml, KVM, user-mode NAT,
# SSH forwarded to 127.0.0.1.
#
# VM_NET_MODE=bridge: the guest is one NIC on a bridge, with a static address on one subnet.
# ci-linux-cluster-node-arm64.yml uses it on two GitHub runners that form one L2 segment:
#   control-plane runner  bridge with the gateway 10.10.0.1 (VM_BRIDGE_GATEWAY=yes): routes and NATs
#   worker runner         bridge without an address (VM_BRIDGE_GATEWAY=no)
#   both runners          VXLAN device (VM_OVERLAY_PEER=<other runner's address>) joins the bridges
#                         over the private network that Tailscale provides on the runners
# So the worker sits in the control plane's subnet, and K2s sees one default route and one address
# per node, which the API server advertisement and the pod network rely on.
#
# Subcommands:
#   prepare     install QEMU tools, fetch the Debian cloud image, create overlay + cloud-init seed
#   start       create the bridge, overlay and tap devices if needed, boot the guest in the background
#   wait-ssh    block until the guest accepts SSH
#   exec        read a bash script from stdin and run it in the guest (as $VM_USER, sudo available)
#   push        copy a local file/dir to the guest:  push <local> <remote>
#   pull        copy a guest file/dir to a local dir: pull <remote> <local-dir>
#   stop        power the guest off (the runner is discarded afterwards anyway)

set -euo pipefail

VM_ARCH="${VM_ARCH:-amd64}"
VM_DIR="${VM_DIR:-${RUNNER_TEMP:-/tmp}/k2s-vm}"
VM_NAME="${VM_NAME:-k2s-linux-ci}"
VM_USER="${VM_USER:-debian}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_CPUS="${VM_CPUS:-3}"
VM_MEMORY_MB="${VM_MEMORY_MB:-10240}"
VM_DISK_SIZE="${VM_DISK_SIZE:-40G}"
VM_NET_MODE="${VM_NET_MODE:-user}"
VM_NET_IP="${VM_NET_IP:-}"
VM_NET_GATEWAY="${VM_NET_GATEWAY:-10.10.0.1}"
VM_NET_MTU="${VM_NET_MTU:-1500}"
VM_BRIDGE="${VM_BRIDGE:-k2s-br0}"
VM_BRIDGE_ADDR="${VM_BRIDGE_ADDR:-10.10.0.1/24}"
VM_BRIDGE_SUBNET="${VM_BRIDGE_SUBNET:-10.10.0.0/24}"
VM_BRIDGE_GATEWAY="${VM_BRIDGE_GATEWAY:-yes}"
VM_TAP="${VM_TAP:-}"
VM_OVERLAY_DEV="${VM_OVERLAY_DEV:-k2s-vx0}"
VM_OVERLAY_ID="${VM_OVERLAY_ID:-42}"
VM_OVERLAY_LOCAL="${VM_OVERLAY_LOCAL:-}"
VM_OVERLAY_PEER="${VM_OVERLAY_PEER:-}"

case "$VM_ARCH" in
  amd64|arm64) ;;
  *)
    echo "::error::Unsupported VM_ARCH '$VM_ARCH' (amd64 or arm64)" >&2
    exit 1
    ;;
esac
BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-${VM_ARCH}.qcow2}"

case "$VM_NET_MODE" in
  user) ssh_host=127.0.0.1; ssh_port="$VM_SSH_PORT" ;;
  bridge)
    [[ -n "$VM_NET_IP" && -n "$VM_TAP" ]] || { echo "::error::VM_NET_MODE=bridge needs VM_NET_IP and VM_TAP" >&2; exit 1; }
    ssh_host="$VM_NET_IP"; ssh_port=22 ;;
  *)
    echo "::error::Unsupported VM_NET_MODE '$VM_NET_MODE' (user or bridge)" >&2
    exit 1
    ;;
esac

die() {
  echo "::error::$*" >&2
  exit 1
}

ssh_opts=(
  -i "$VM_DIR/id_ed25519"
  -p "$ssh_port"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=30
)

ssh_vm() {
  ssh "${ssh_opts[@]}" "$VM_USER@$ssh_host" "$@"
}

# The MAC is derived from the address, so the cloud-init network-config can match the NIC.
net_mac() {
  printf '52:54:00:10:00:%02x' "${VM_NET_IP##*.}"
}

prepare() {
  if [[ "$VM_ARCH" == amd64 ]]; then
    [[ -e /dev/kvm ]] || die "/dev/kvm is missing: the runner cannot start KVM guests."
    [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not readable and writable by $(id -un)."
    qemu_packages=(qemu-system-x86)
  else
    # No KVM for the arm64 guest: the guest runs under TCG (emulation) by design.
    qemu_packages=(qemu-system-arm qemu-efi-aarch64)
  fi

  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    "${qemu_packages[@]}" qemu-utils cloud-image-utils openssh-client iproute2

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
  - git
  - unzip
EOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$VM_NAME" "$VM_NAME" > "$VM_DIR/meta-data"

  local seed_args=("$VM_DIR/seed.img" "$VM_DIR/user-data" "$VM_DIR/meta-data")
  if [[ "$VM_NET_MODE" == bridge ]]; then
    cat > "$VM_DIR/network-config" <<EOF
version: 2
ethernets:
  lan:
    match:
      macaddress: "$(net_mac)"
    set-name: eth0
    mtu: ${VM_NET_MTU}
    addresses:
      - ${VM_NET_IP}/24
    routes:
      - to: default
        via: ${VM_NET_GATEWAY}
    nameservers:
      addresses:
        - 1.1.1.1
        - 8.8.8.8
EOF
    seed_args+=("$VM_DIR/network-config")
  fi
  cloud-localds "${seed_args[@]}"

  qemu-img create -f qcow2 -F qcow2 -b "$VM_DIR/base.qcow2" "$VM_DIR/overlay.qcow2" "$VM_DISK_SIZE"

  if [[ "$VM_ARCH" == arm64 ]]; then
    # UEFI variables must be writable per guest; the code image is shared read-only.
    cp /usr/share/AAVMF/AAVMF_VARS.fd "$VM_DIR/AAVMF_VARS.fd"
  fi
}

# Bridge, overlay and NAT for the bridge-mode guests. Idempotent, so every guest's start can call it.
network_up() {
  if ! ip link show "$VM_BRIDGE" >/dev/null 2>&1; then
    sudo ip link add "$VM_BRIDGE" type bridge
  fi
  sudo ip link set "$VM_BRIDGE" mtu "$VM_NET_MTU" up

  if [[ "$VM_BRIDGE_GATEWAY" == yes ]]; then
    if ! ip -o -4 addr show dev "$VM_BRIDGE" | grep -qF "inet $VM_BRIDGE_ADDR"; then
      sudo ip addr add "$VM_BRIDGE_ADDR" dev "$VM_BRIDGE"
    fi
    sudo sysctl -q -w net.ipv4.ip_forward=1
    sudo iptables -t nat -C POSTROUTING -s "$VM_BRIDGE_SUBNET" ! -d "$VM_BRIDGE_SUBNET" -j MASQUERADE 2>/dev/null \
      || sudo iptables -t nat -A POSTROUTING -s "$VM_BRIDGE_SUBNET" ! -d "$VM_BRIDGE_SUBNET" -j MASQUERADE
    # The runner's FORWARD policy may drop traffic it does not know about, so accept the bridge explicitly.
    sudo iptables -C FORWARD -i "$VM_BRIDGE" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -i "$VM_BRIDGE" -j ACCEPT
    sudo iptables -C FORWARD -o "$VM_BRIDGE" -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -o "$VM_BRIDGE" -j ACCEPT
  fi

  if [[ -n "$VM_OVERLAY_PEER" ]]; then
    [[ -n "$VM_OVERLAY_LOCAL" ]] || die "VM_OVERLAY_PEER needs VM_OVERLAY_LOCAL (this runner's address)."
    if ! ip link show "$VM_OVERLAY_DEV" >/dev/null 2>&1; then
      sudo ip link add "$VM_OVERLAY_DEV" type vxlan id "$VM_OVERLAY_ID" dstport 4789 \
        local "$VM_OVERLAY_LOCAL" nolearning
      # Unknown and broadcast frames go to the peer runner, which is all a two-runner segment needs.
      sudo bridge fdb append 00:00:00:00:00:00 dev "$VM_OVERLAY_DEV" dst "$VM_OVERLAY_PEER"
    fi
    sudo ip link set "$VM_OVERLAY_DEV" mtu "$VM_NET_MTU" master "$VM_BRIDGE" up
  fi

  if ! ip link show "$VM_TAP" >/dev/null 2>&1; then
    sudo ip tuntap add dev "$VM_TAP" mode tap user "$(id -un)"
  fi
  sudo ip link set "$VM_TAP" mtu "$VM_NET_MTU" master "$VM_BRIDGE" up
}

start() {
  [[ -f "$VM_DIR/overlay.qcow2" ]] || die "Run 'prepare' before 'start'."

  local net_args
  if [[ "$VM_NET_MODE" == bridge ]]; then
    network_up
    net_args=(
      -netdev "tap,id=net0,ifname=$VM_TAP,script=no,downscript=no"
      -device "virtio-net-pci,netdev=net0,mac=$(net_mac)"
    )
  else
    net_args=(
      -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$VM_SSH_PORT-:22"
      -device "virtio-net-pci,netdev=net0"
    )
  fi

  if [[ "$VM_ARCH" == amd64 ]]; then
    qemu-system-x86_64 \
      -machine q35,accel=kvm \
      -cpu host \
      -smp "$VM_CPUS" \
      -m "$VM_MEMORY_MB" \
      -drive "file=$VM_DIR/overlay.qcow2,if=virtio,format=qcow2" \
      -drive "file=$VM_DIR/seed.img,if=virtio,format=raw" \
      "${net_args[@]}" \
      -display none \
      -serial "file:$VM_DIR/console.log" \
      -daemonize \
      -pidfile "$VM_DIR/qemu.pid"
  else
    qemu-system-aarch64 \
      -machine virt,accel=tcg,gic-version=3 \
      -cpu cortex-a72 \
      -smp "$VM_CPUS" \
      -m "$VM_MEMORY_MB" \
      -drive "if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd" \
      -drive "if=pflash,format=raw,file=$VM_DIR/AAVMF_VARS.fd" \
      -drive "file=$VM_DIR/overlay.qcow2,if=virtio,format=qcow2" \
      -drive "file=$VM_DIR/seed.img,if=virtio,format=raw" \
      "${net_args[@]}" \
      -display none \
      -serial "file:$VM_DIR/console.log" \
      -daemonize \
      -pidfile "$VM_DIR/qemu.pid"
  fi
}

wait_ssh() {
  local attempt
  # TCG boots several times slower than KVM, so the arm64 guest gets a longer window.
  local attempts=60
  if [[ "$VM_ARCH" == arm64 ]]; then attempts=180; fi
  for attempt in $(seq 1 "$attempts"); do
    if ssh_vm true 2>/dev/null; then
      echo "Guest $VM_NAME is accepting SSH (attempt $attempt)."
      return 0
    fi
    sleep 10
  done
  echo "--- guest console (tail) ---" >&2
  tail -n 80 "$VM_DIR/console.log" >&2 || true
  die "Guest $VM_NAME did not accept SSH within $((attempts * 10 / 60)) minutes."
}

exec_vm() {
  # The script is passed as one argument so that stdin is not consumed by remote commands.
  local script
  script="$(cat)"
  ssh_vm "bash -c $(printf '%q' "set -euo pipefail"$'\n'"$script")"
}

scp_opts=(
  -i "$VM_DIR/id_ed25519"
  -P "$ssh_port"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

push() {
  scp -r "${scp_opts[@]}" "$1" "$VM_USER@$ssh_host:$2"
}

pull() {
  scp -r "${scp_opts[@]}" "$VM_USER@$ssh_host:$1" "$2"
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
