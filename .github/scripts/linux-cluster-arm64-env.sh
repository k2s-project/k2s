# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by the steps of ci-linux-cluster-node-arm64.yml. Both guests run on the same GitHub-hosted runner
# and share its bridge, so they are on one subnet with the runner as gateway:
#   cp_vm  control plane: Debian 13 amd64 guest with KVM, runs K2s (linux-only install); 4 GB RAM
#   wk_vm  worker:        Debian 13 arm64 guest under QEMU TCG (no KVM); 2 GB RAM; joined with 'k2s node add'
# The bridge is created by the first guest that starts, and the runner routes and NATs for both.

CP_VM_DIR="${CP_VM_DIR:-$RUNNER_TEMP/vm-cp}"
WK_VM_DIR="${WK_VM_DIR:-$RUNNER_TEMP/vm-worker}"
CP_IP=10.10.0.10
WK_IP=10.10.0.20

cp_vm() {
  VM_DIR="$CP_VM_DIR" VM_NAME=k2s-linux-cp VM_CPUS=2 VM_MEMORY_MB=4096 \
    VM_NET_MODE=bridge VM_NET_IP="$CP_IP" VM_TAP=k2s-tap-cp \
    bash .github/scripts/linux-cluster-vm.sh "$@"
}

wk_vm() {
  VM_DIR="$WK_VM_DIR" VM_ARCH=arm64 VM_NAME=k2s-arm64-worker VM_CPUS=2 VM_MEMORY_MB=2048 \
    VM_NET_MODE=bridge VM_NET_IP="$WK_IP" VM_TAP=k2s-tap-w \
    bash .github/scripts/linux-cluster-vm.sh "$@"
}
