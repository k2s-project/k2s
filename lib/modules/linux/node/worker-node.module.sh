#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Adds a Debian 13 worker node to a K2s cluster that runs on this Linux host. Used by
# lib/scripts/linux/debian/worker/bare-metal/Add.sh. The steps follow the Windows path in
# lib/modules/windows/node/k2s.node.module/linuxnode/setup/worker-node.module.psm1:
#   prerequisites -> copy the node package -> install packages -> import images -> kubeadm join -> Ready
#
# The worker is reached with the K2s SSH key pair (see infra/ssh.sh); its public key must already be
# authorized for the worker user. Host keys are trusted on first use and then pinned in known_hosts.

if [[ -n ${K2S_WORKER_NODE_MODULE_LOADED:-} ]]; then
  return 0
fi
readonly K2S_WORKER_NODE_MODULE_LOADED=1

readonly K2S_NODE_REMOTE_DIR='/tmp/k2s-node'
readonly K2S_NODE_KUBECONFIG='/etc/kubernetes/admin.conf'
readonly K2S_NODE_CRI_SOCKET='unix:///run/crio/crio.sock'

# Set by k2s_node_configure before any remote call.
K2S_NODE_USER=''
K2S_NODE_IP=''
K2S_NODE_KEY=''

k2s_node_configure() {
  K2S_NODE_USER="$1"
  K2S_NODE_IP="$2"
  K2S_NODE_KEY="$3"
}

k2s_node_ssh_options() {
  printf '%s\n' \
    -i "$K2S_NODE_KEY" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=30
}

# Runs a command on the worker. The command is passed as one argument, so it is evaluated remotely.
k2s_node_ssh() {
  local -a opts
  mapfile -t opts < <(k2s_node_ssh_options)
  ssh "${opts[@]}" "$K2S_NODE_USER@$K2S_NODE_IP" "$@"
}

# Trust on first use: the worker's host key is recorded once and must match on every later call.
k2s_node_trust_host() {
  local known_hosts="$HOME/.ssh/known_hosts"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$known_hosts"
  chmod 600 "$known_hosts"
  if ssh-keygen -F "$K2S_NODE_IP" -f "$known_hosts" >/dev/null 2>&1; then
    return 0
  fi
  local host_key
  host_key="$(ssh-keyscan -T 15 "$K2S_NODE_IP" 2>/dev/null || true)"
  if [[ -z $host_key ]]; then
    k2s_log ERROR "Could not read the SSH host key of $K2S_NODE_IP. Is the node reachable on port 22?"
    return 1
  fi
  k2s_log INFO "Recording the SSH host key of $K2S_NODE_IP (trust on first use)."
  printf '%s\n' "$host_key" >> "$known_hosts"
}

k2s_node_check_prerequisites() {
  local arch os_id os_version swap_lines
  k2s_node_ssh true || { k2s_log ERROR "Cannot log in to $K2S_NODE_USER@$K2S_NODE_IP with the K2s SSH key. Authorize its public key on the node first."; return 1; }
  k2s_node_ssh 'sudo -n true' || { k2s_log ERROR "User $K2S_NODE_USER on $K2S_NODE_IP needs passwordless sudo."; return 1; }

  os_id=$(k2s_node_ssh '. /etc/os-release && printf %s "$ID"') || return 1
  os_version=$(k2s_node_ssh '. /etc/os-release && printf %s "$VERSION_ID"') || return 1
  if [[ $os_id != debian || $os_version != 13* ]]; then
    k2s_log ERROR "The node runs $os_id $os_version. Worker nodes must run Debian 13."
    return 1
  fi

  arch=$(k2s_node_ssh 'dpkg --print-architecture') || return 1
  case "$arch" in
    amd64|arm64) ;;
    *) k2s_log ERROR "Unsupported worker architecture '$arch' (supported: amd64, arm64)."; return 1 ;;
  esac

  swap_lines=$(k2s_node_ssh 'wc -l < /proc/swaps') || return 1
  if [[ $swap_lines -gt 1 ]]; then
    k2s_log ERROR "Swap is enabled on the node. Disable it before adding the node."
    return 1
  fi
  k2s_log INFO "Node $K2S_NODE_IP is Debian 13 ($arch), passwordless sudo is available, swap is off."
}

# The package architecture must match the node. The kubeadm package carries it in its control file.
k2s_node_check_package_architecture() {
  local kubeadm_deb="$1" package_arch node_arch
  package_arch=$(dpkg-deb -f "$kubeadm_deb" Architecture) || return 1
  node_arch=$(k2s_node_ssh 'dpkg --print-architecture') || return 1
  if [[ $package_arch != "$node_arch" ]]; then
    k2s_log ERROR "The node package is for $package_arch but the node is $node_arch."
    return 1
  fi
}

# Copies the packages, the images, and the node-extension scripts to the worker staging directory.
# Directories are streamed through tar, which keeps permissions and avoids one scp per file.
k2s_node_copy_artifacts() {
  local package_dir="$1" scripts_dir="$2"
  k2s_log INFO "Copying the node package to $K2S_NODE_IP."
  k2s_node_ssh "rm -rf $K2S_NODE_REMOTE_DIR && mkdir -p $K2S_NODE_REMOTE_DIR/packages $K2S_NODE_REMOTE_DIR/images $K2S_NODE_REMOTE_DIR/scripts" || return 1
  tar -C "$package_dir" -cf - packages images | k2s_node_ssh "tar -C $K2S_NODE_REMOTE_DIR -xf -" || return 1
  tar -C "$scripts_dir" -cf - . | k2s_node_ssh "tar -C $K2S_NODE_REMOTE_DIR/scripts -xf -" || return 1
}

# Installs buildah first (the image import needs it), then the Kubernetes packages. The scripts are the
# node-extension scripts of cfg/nodeextension/debian13: they only install packages the node does not have.
k2s_node_install_packages() {
  local registry_token="$1"
  k2s_log INFO "Installing buildah packages on $K2S_NODE_IP."
  k2s_node_ssh "sudo bash $K2S_NODE_REMOTE_DIR/scripts/install-buildah-packages.sh $K2S_NODE_REMOTE_DIR/packages/debian13/buildah" || return 1
  k2s_log INFO "Installing Kubernetes packages on $K2S_NODE_IP."
  k2s_node_ssh "sudo bash $K2S_NODE_REMOTE_DIR/scripts/install-k8s-packages.sh $K2S_NODE_REMOTE_DIR/packages/debian13/kubernetes '' '$registry_token' false" || return 1
}

# Imports every image archive into the container storage that CRI-O uses.
k2s_node_import_images() {
  local archive count=0
  while IFS= read -r archive; do
    k2s_log INFO "Importing image $(basename "$archive")."
    k2s_node_ssh "sudo buildah pull oci-archive:$archive" </dev/null >/dev/null || { k2s_log ERROR "Could not import $(basename "$archive") on $K2S_NODE_IP."; return 1; }
    count=$((count + 1))
  done < <(k2s_node_ssh "ls $K2S_NODE_REMOTE_DIR/images/*.tar")
  [[ $count -gt 0 ]] || { k2s_log ERROR "No image archives were found in the node package."; return 1; }
  k2s_log INFO "Imported $count images on $K2S_NODE_IP."
}

# Joins the worker with a fresh token from the control plane. The control plane is this host.
k2s_node_join() {
  local join_command
  join_command=$(KUBECONFIG="$K2S_NODE_KUBECONFIG" kubeadm token create --print-join-command) || { k2s_log ERROR "Could not create a join token."; return 1; }
  join_command="$join_command --cri-socket $K2S_NODE_CRI_SOCKET"
  k2s_log INFO "Joining $K2S_NODE_IP to the cluster."
  k2s_node_ssh "sudo $join_command" || { k2s_log ERROR "kubeadm join failed on $K2S_NODE_IP."; return 1; }
}

# Waits until the node reports Ready. The node name is the hostname the kubelet registered with.
k2s_node_wait_ready() {
  local node_name="$1" attempt ready
  for attempt in $(seq 1 60); do
    ready=$(KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl get node "$node_name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ $ready == True ]]; then
      k2s_log INFO "Node $node_name is Ready."
      return 0
    fi
    sleep 15
  done
  k2s_log ERROR "Node $node_name did not become Ready within 15 minutes."
  return 1
}

k2s_node_remove_staging() {
  k2s_node_ssh "sudo rm -rf $K2S_NODE_REMOTE_DIR" || true
}

k2s_node_hostname() {
  k2s_node_ssh 'hostname' | tr -d '[:space:]'
}
