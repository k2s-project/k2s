# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by the steps of ci-linux-cluster-node-arm64.yml. The control plane and the arm64 worker run on
# two separate GitHub runners. Each guest has a fixed address on the shared subnet 10.10.0.0/24:
#   cp_vm  control plane: Debian 13 amd64 guest with KVM, runs K2s (linux-only install); 4 GB RAM
#   wk_vm  worker:        Debian 13 arm64 guest under QEMU TCG (no KVM); 2 GB RAM; joined with 'k2s node add'
# The runners connect their bridges with a VXLAN device over Tailscale. The jobs set
# VM_OVERLAY_LOCAL (this runner's Tailscale address) and VM_OVERLAY_PEER (the other runner's) before
# calling the helpers.

CP_VM_DIR="${CP_VM_DIR:-$RUNNER_TEMP/vm-cp}"
WK_VM_DIR="${WK_VM_DIR:-$RUNNER_TEMP/vm-worker}"
CP_IP=10.10.0.10
WK_IP=10.10.0.20
# Tailscale carries the VXLAN frames: 1280 bytes minus 50 bytes of VXLAN overhead leaves 1230 for the guests.
OVERLAY_MTU=1230

cp_vm() {
  VM_DIR="$CP_VM_DIR" VM_NAME=k2s-linux-cp VM_CPUS=2 VM_MEMORY_MB=4096 \
    VM_NET_MODE=bridge VM_NET_IP="$CP_IP" VM_TAP=k2s-tap-cp VM_NET_MTU="$OVERLAY_MTU" \
    VM_BRIDGE_GATEWAY=yes \
    bash .github/scripts/linux-cluster-vm.sh "$@"
}

wk_vm() {
  VM_DIR="$WK_VM_DIR" VM_ARCH=arm64 VM_NAME=k2s-arm64-worker VM_CPUS=2 VM_MEMORY_MB=2048 \
    VM_NET_MODE=bridge VM_NET_IP="$WK_IP" VM_TAP=k2s-tap-w VM_NET_MTU="$OVERLAY_MTU" \
    VM_BRIDGE_GATEWAY=no \
    bash .github/scripts/linux-cluster-vm.sh "$@"
}

# Tailscale IPv4 of a peer, found by its hostname. Prints nothing until the peer is online.
tailscale_peer_ip() {
  local hostname="$1"
  tailscale status --json 2>/dev/null \
    | jq -r --arg name "$hostname" '.Peer[]? | select(.HostName == $name) | .TailscaleIPs[]? | select(contains(".") )' \
    | head -n 1
}
