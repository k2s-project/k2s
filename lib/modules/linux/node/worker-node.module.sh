#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0
#
# Adds a Debian 13 worker node to a K2s cluster that runs on this Linux host. Used by
# lib/scripts/linux/debian/worker/bare-metal/Add.sh; follows Add-LinuxWorkerNode in
# lib/modules/windows/node/k2s.node.module/linuxnode/setup/worker-node.module.psm1.
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
# Must match the nodeScriptExit* constants in internal/provider/node_linux.go.
readonly K2S_NODE_EXIT_NOT_SUPPORTED=3
readonly K2S_NODE_EXIT_ALREADY_EXISTS=4
readonly K2S_NODE_EXIT_NOT_FOUND=5

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
    return "$K2S_NODE_EXIT_NOT_SUPPORTED"
  fi

  arch=$(k2s_node_ssh 'dpkg --print-architecture') || return 1
  case "$arch" in
    amd64|arm64) ;;
    *) k2s_log ERROR "Unsupported worker architecture '$arch' (supported: amd64, arm64)."; return "$K2S_NODE_EXIT_NOT_SUPPORTED" ;;
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

k2s_node_check_not_in_cluster() {
  local node_name="$1" cluster_config="$2" nodes
  nodes=$(KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl get nodes -o jsonpath='{.items[*].metadata.name}') \
    || { k2s_log ERROR 'Could not list the cluster nodes.'; return 1; }
  if [[ " $nodes " == *" $node_name "* ]]; then
    k2s_log ERROR "Node $node_name is already part of the cluster."
    return "$K2S_NODE_EXIT_ALREADY_EXISTS"
  fi
  if [[ -f $cluster_config ]] && jq -e --arg name "$node_name" '.nodes // [] | any(.Name == $name)' "$cluster_config" >/dev/null; then
    k2s_log ERROR "Node $node_name is already configured in $cluster_config. Run 'k2s node remove --name $node_name' first."
    return "$K2S_NODE_EXIT_ALREADY_EXISTS"
  fi
}

# Same entry as Add-NodeConfig on a Windows host (schema: internal/core/clusterconfig).
k2s_node_config_add() {
  local cluster_config="$1" node_name="$2" temp_file
  temp_file=$(mktemp "$cluster_config.XXXXXX") || return 1
  if ! { if [[ -f $cluster_config ]]; then cat "$cluster_config"; else printf '{}'; fi; } \
    | jq --arg name "$node_name" --arg ip "$K2S_NODE_IP" --arg user "$K2S_NODE_USER" \
      '.nodes = ((.nodes // []) + [{Name: $name, IpAddress: $ip, Username: $user, NodeType: "HOST", Role: "worker", OS: "linux", Proxy: "", PodCIDR: ""}])' \
      > "$temp_file"; then
    rm -f "$temp_file"
    k2s_log ERROR "Could not add node $node_name to $cluster_config."
    return 1
  fi
  chmod 644 "$temp_file" && mv "$temp_file" "$cluster_config" || { rm -f "$temp_file"; return 1; }
  k2s_log INFO "Node $node_name added to $cluster_config."
}

# Prints "<ip> <user>" of the node's entry; nothing if there is none.
k2s_node_config_get() {
  local cluster_config="$1" node_name="$2"
  [[ -f $cluster_config ]] || return 0
  jq -r --arg name "$node_name" \
    '[(.nodes // [])[] | select((.Name // "" | ascii_downcase) == $name)] | last // empty | "\(.IpAddress // "") \(.Username // "")"' \
    "$cluster_config" || { k2s_log ERROR "Could not read $cluster_config."; return 1; }
}

k2s_node_config_remove() {
  local cluster_config="$1" node_name="$2" temp_file
  temp_file=$(mktemp "$cluster_config.XXXXXX") || return 1
  if ! jq --arg name "$node_name" '.nodes = [(.nodes // [])[] | select((.Name // "" | ascii_downcase) != $name)]' \
    "$cluster_config" > "$temp_file"; then
    rm -f "$temp_file"
    k2s_log ERROR "Could not remove node $node_name from $cluster_config."
    return 1
  fi
  chmod 644 "$temp_file" && mv "$temp_file" "$cluster_config" || { rm -f "$temp_file"; return 1; }
  k2s_log INFO "Node $node_name removed from $cluster_config."
}

# Configures the remote calls for the node's entry; fails with K2S_NODE_EXIT_NOT_FOUND if there is none.
k2s_node_configure_from_config() {
  local cluster_config="$1" node_name="$2" entry ip user key
  entry=$(k2s_node_config_get "$cluster_config" "$node_name") || return 1
  read -r ip user <<< "$entry"
  if [[ -z ${ip:-} || -z ${user:-} ]]; then
    k2s_log ERROR "Node $node_name was not added with 'k2s node add': it has no entry with IP address and user in $cluster_config."
    return "$K2S_NODE_EXIT_NOT_FOUND"
  fi
  k2s_ssh_require_key || return 1
  key=$(k2s_ssh_private_key) || return 1
  k2s_node_configure "$user" "$ip" "$key"
}

k2s_node_flannel_backend() {
  KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl -n kube-flannel get configmap kube-flannel-cfg -o jsonpath='{.data.net-conf\.json}' \
    | jq -er '.Backend.Type // empty' || { k2s_log ERROR 'Could not read the Flannel backend from kube-flannel-cfg.'; return 1; }
}

# Prints this host's address in the node's subnet.
k2s_node_host_ip() {
  local route host_ip
  route=$(ip -4 route get "$K2S_NODE_IP") || { k2s_log ERROR "No route from this host to $K2S_NODE_IP."; return 1; }
  if [[ $route == *" via "* ]]; then
    k2s_log ERROR "Node $K2S_NODE_IP is not in a subnet directly connected to this host. Flannel host-gw requires host and node in the same layer-2 network."
    return 1
  fi
  host_ip=$(awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' <<< "$route")
  [[ -n $host_ip ]] || { k2s_log ERROR "Could not determine this host's address towards $K2S_NODE_IP."; return 1; }
  printf '%s\n' "$host_ip"
}

# Copies the packages, the images, and the node-extension scripts to the worker staging directory.
# Directories are streamed through tar, which keeps permissions and avoids one scp per file.
k2s_node_copy_artifacts() {
  local package_dir="$1" scripts_dir="$2"
  k2s_log INFO "Copying the node-extension scripts${package_dir:+ and the node package} to $K2S_NODE_IP."
  k2s_node_ssh "rm -rf $K2S_NODE_REMOTE_DIR && mkdir -p $K2S_NODE_REMOTE_DIR/packages/debian13/kubernetes $K2S_NODE_REMOTE_DIR/packages/debian13/buildah $K2S_NODE_REMOTE_DIR/images $K2S_NODE_REMOTE_DIR/scripts" || return 1
  if [[ -n $package_dir ]]; then
    tar -C "$package_dir" -cf - packages images | k2s_node_ssh "tar -C $K2S_NODE_REMOTE_DIR -xf -" || return 1
  fi
  tar -C "$scripts_dir" -cf - . | k2s_node_ssh "tar -C $K2S_NODE_REMOTE_DIR/scripts -xf -" || return 1
}

# Online: the node downloads the packages for its own architecture, like the Windows cross-architecture path.
k2s_node_download_packages() {
  local k8s_version="$1" proxy="$2" packages_dir="$K2S_NODE_REMOTE_DIR/packages/debian13"
  k2s_log INFO "Downloading Kubernetes $k8s_version and buildah packages on $K2S_NODE_IP."
  k2s_node_ssh "sudo bash $K2S_NODE_REMOTE_DIR/scripts/download-k8s-packages.sh $packages_dir/kubernetes $(printf '%q %q' "$k8s_version" "$proxy") && sudo bash $K2S_NODE_REMOTE_DIR/scripts/download-buildah-packages.sh $packages_dir/buildah $(printf '%q' "$proxy")" 2>&1 \
    | k2s_node_mask_proxy "$proxy" | k2s_log_output \
    || { k2s_log ERROR "Downloading the packages failed on $K2S_NODE_IP."; return 1; }
}

# Masks the credentials of a proxy URL in the output passed through.
k2s_node_mask_proxy() {
  local proxy="$1" masked line
  if [[ $proxy != *@* ]]; then
    cat
    return
  fi
  masked="${proxy%%://*}://***@${proxy##*@}"
  while IFS= read -r line || [[ -n $line ]]; do
    printf '%s\n' "${line//"$proxy"/"$masked"}"
  done
}

# Installs buildah first (the image import needs it), then the Kubernetes packages. The scripts are the
# node-extension scripts of cfg/nodeextension/debian13: they only install packages the node does not have.
k2s_node_install_packages() {
  local registry_token="$1" proxy="$2"
  k2s_log INFO "Installing buildah packages on $K2S_NODE_IP."
  k2s_node_ssh "sudo bash $K2S_NODE_REMOTE_DIR/scripts/install-buildah-packages.sh $K2S_NODE_REMOTE_DIR/packages/debian13/buildah" 2>&1 | k2s_log_output \
    || { k2s_log ERROR "Installing the buildah packages failed on $K2S_NODE_IP."; return 1; }
  k2s_log INFO "Installing Kubernetes packages on $K2S_NODE_IP."
  k2s_node_ssh "sudo bash $K2S_NODE_REMOTE_DIR/scripts/install-k8s-packages.sh $K2S_NODE_REMOTE_DIR/packages/debian13/kubernetes $(printf '%q' "$proxy") '$registry_token' false" 2>&1 \
    | k2s_node_mask_proxy "$proxy" | k2s_log_output \
    || { k2s_log ERROR "Installing the Kubernetes packages failed on $K2S_NODE_IP."; return 1; }
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

k2s_node_harden() {
  local stage="$1"
  k2s_log INFO "Running the Debian 13 node hardening ($stage) on $K2S_NODE_IP."
  k2s_node_ssh "sudo bash $K2S_NODE_REMOTE_DIR/scripts/harden-node.sh $stage" 2>&1 | k2s_log_output \
    || { k2s_log ERROR "Node hardening ($stage) failed on $K2S_NODE_IP."; return 1; }
}

# Same drop-ins as Add-LinuxWorkerNodeRegistryMirrors on a Windows host.
k2s_node_configure_registry_mirrors() {
  local mirrors registry mirror
  mirrors=$(k2s_crio_mirror_registries) || return 1
  [[ -n $mirrors ]] || return 0
  k2s_log INFO "Configuring CRI-O registry mirrors on $K2S_NODE_IP."
  k2s_node_ssh 'sudo mkdir -p /etc/containers/registries.conf.d' || return 1
  while read -r registry mirror; do
    k2s_crio_mirror_dropin "$registry" "$mirror" \
      | k2s_node_ssh "sudo tee $(printf %q "/etc/containers/registries.conf.d/${registry//:/}.conf") >/dev/null" || return 1
  done <<< "$mirrors"
  k2s_node_ssh 'sudo systemctl restart crio' || { k2s_log ERROR "Could not restart CRI-O on $K2S_NODE_IP."; return 1; }
}

# Same k2s-routes.service as Add-PersistentLinuxWorkerNodeRoutes on a Windows host.
k2s_node_add_routes() {
  local host_ip="$1" switch_cidr pod_cidr
  switch_cidr=$(jq -er '.smallsetup.masterNetworkCIDR' "$K2S_INSTALL_DIR/cfg/config.json") || return 1
  pod_cidr=$(jq -er '.smallsetup.podNetworkCIDR' "$K2S_INSTALL_DIR/cfg/config.json") || return 1
  k2s_log INFO "Routing $switch_cidr and $pod_cidr on $K2S_NODE_IP via $host_ip."
  k2s_node_ssh 'sudo tee /etc/systemd/system/k2s-routes.service >/dev/null' <<EOF || return 1
[Unit]
Description=K2s Kubernetes Routes
After=network-online.target systemd-networkd.service
Wants=network-online.target
PartOf=systemd-networkd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do ping -c 1 -W 2 $host_ip >/dev/null 2>&1 && break; sleep 2; done; ip route replace $switch_cidr via $host_ip; ip route replace $pod_cidr via $host_ip'

[Install]
WantedBy=multi-user.target
EOF
  k2s_node_ssh 'sudo systemctl daemon-reload && sudo systemctl enable k2s-routes.service && sudo systemctl restart k2s-routes.service' \
    || { k2s_log ERROR "Could not enable k2s-routes.service on $K2S_NODE_IP."; return 1; }
}

# Joins the worker with a fresh token from the control plane. The control plane is this host.
k2s_node_join() {
  local join_command command api_server_endpoint token ca_cert_hash quoted_endpoint quoted_token quoted_hash quoted_node_ip join_config
  join_command=$(KUBECONFIG="$K2S_NODE_KUBECONFIG" kubeadm token create --print-join-command) || { k2s_log ERROR "Could not create a join token."; return 1; }
  read -r command _ api_server_endpoint _ token _ ca_cert_hash <<< "$join_command"
  if [[ "$command" != kubeadm || -z "$api_server_endpoint" || -z "$token" || -z "$ca_cert_hash" ]]; then
    k2s_log ERROR "Could not parse the kubeadm join command."
    return 1
  fi
  quoted_endpoint="$(jq -Rn --arg value "$api_server_endpoint" '$value')" || return 1
  quoted_token="$(jq -Rn --arg value "$token" '$value')" || return 1
  quoted_hash="$(jq -Rn --arg value "$ca_cert_hash" '$value')" || return 1
  quoted_node_ip="$(jq -Rn --arg value "$K2S_NODE_IP" '$value')" || return 1
  join_config="$(cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: $quoted_endpoint
    token: $quoted_token
    caCertHashes:
      - $quoted_hash
nodeRegistration:
  criSocket: $K2S_NODE_CRI_SOCKET
  kubeletExtraArgs:
    - name: node-ip
      value: $quoted_node_ip
    - name: config-dir
      value: /etc/kubernetes/kubelet.conf.d
EOF
)" || return 1
  k2s_log INFO "Joining $K2S_NODE_IP to the cluster."
  # The kubelet drop-in directory must exist before the join (the Windows path creates it the same way).
  # The config file is created by root: a file made by the SSH user in /tmp cannot be written by sudo tee.
  k2s_node_ssh "sudo mkdir -p /etc/kubernetes/kubelet.conf.d && config=\$(sudo mktemp) && sudo tee \"\$config\" >/dev/null && sudo kubeadm join --config=\"\$config\"; result=\$?; sudo rm -f \"\$config\"; exit \"\$result\"" <<< "$join_config" 2>&1 | k2s_log_output \
    || { k2s_log ERROR "kubeadm join failed on $K2S_NODE_IP."; return 1; }
}

# kubeadm join can return before the kubelet has registered the Node object (slow nodes, e.g. arm64 under TCG).
k2s_node_wait_registered() {
  local node_name="$1" timeout="${2:-300}" interval="${3:-2}" waited=0
  while (( waited < timeout )); do
    if [[ -n $(KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl get node "$node_name" --ignore-not-found -o name 2>/dev/null || true) ]]; then
      return 0
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  k2s_log ERROR "Node $node_name was not registered in the cluster within $timeout seconds after the join."
  return 1
}

# Same label as Join-LinuxNode on a Windows host; kubectl shows it as role.
k2s_node_label_worker() {
  local node_name="$1"
  KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl label node "$node_name" kubernetes.io/role=worker --overwrite 2>&1 | k2s_log_output \
    || { k2s_log ERROR "Could not label node $node_name as worker."; return 1; }
}

# Waits until the node's Ready condition is the wanted status (True or not True); polls every interval seconds.
k2s_node_wait_ready() {
  local node_name="$1" want="${2:-True}" timeout="${3:-900}" interval="${4:-15}" waited=0 ready label=Ready
  [[ $want == True ]] || label=NotReady
  while (( waited < timeout )); do
    ready=$(KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl get node "$node_name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [[ $want == True && $ready == True ]] || [[ $want != True && -n $ready && $ready != True ]]; then
      k2s_log INFO "Node $node_name is $label."
      return 0
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  k2s_log ERROR "Node $node_name did not become $label within $timeout seconds."
  return 1
}

k2s_node_wait_reachable() {
  local attempt
  for attempt in $(seq 1 12); do
    k2s_node_ssh true 2>/dev/null && return 0
    if [[ $attempt == 1 ]]; then
      k2s_log INFO "Waiting for the SSH connection to $K2S_NODE_IP."
    fi
    sleep 5
  done
  k2s_log ERROR "Cannot connect to $K2S_NODE_USER@$K2S_NODE_IP over SSH."
  return 1
}

# Like Start-LinuxWorkerNodeServices on a Windows host; the routes service exists on host-gw clusters only.
k2s_node_start_services() {
  k2s_log INFO "Starting CRI-O and kubelet on $K2S_NODE_IP."
  k2s_node_ssh 'if systemctl cat k2s-routes.service >/dev/null 2>&1; then sudo systemctl restart k2s-routes.service; fi && sudo systemctl start crio kubelet' 2>&1 | k2s_log_output \
    || { k2s_log ERROR "Could not start CRI-O and kubelet on $K2S_NODE_IP."; return 1; }
}

k2s_node_stop_services() {
  k2s_log INFO "Stopping kubelet and CRI-O on $K2S_NODE_IP."
  k2s_node_ssh 'sudo systemctl stop kubelet && sudo systemctl stop crio' 2>&1 | k2s_log_output \
    || { k2s_log ERROR "Could not stop kubelet and CRI-O on $K2S_NODE_IP."; return 1; }
}

k2s_node_remove_staging() {
  k2s_node_ssh "sudo rm -rf $K2S_NODE_REMOTE_DIR" || true
}

k2s_node_hostname() {
  k2s_node_ssh 'hostname' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

k2s_node_collect_diagnostics() {
  local node_name="$1"
  k2s_log INFO "Collecting diagnostics of $node_name ($K2S_NODE_IP) into $K2S_LOG_FILE."
  k2s_node_ssh 'sudo journalctl -u kubelet -u crio --no-pager -n 200' 2>&1 | k2s_log_output || true
  KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl describe node "$node_name" 2>&1 | k2s_log_output || true
}

k2s_node_remove_from_cluster() {
  local node_name="$1"
  if ! KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl get node "$node_name" >/dev/null 2>&1; then
    k2s_log INFO "Node $node_name is not part of the cluster."
    return 0
  fi
  k2s_log INFO "Draining node $node_name."
  KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data --force --grace-period=0 --timeout=60s 2>&1 | k2s_log_output \
    || k2s_log WARN "Draining node $node_name did not complete; deleting it anyway."
  KUBECONFIG="$K2S_NODE_KUBECONFIG" kubectl delete node "$node_name" --ignore-not-found 2>&1 | k2s_log_output \
    || { k2s_log ERROR "Could not delete node $node_name from the cluster."; return 1; }
}

# Best effort, like Remove-LinuxNode and Remove-KubernetesArtifacts on a Windows host.
k2s_node_reset() {
  local switch_cidr pod_cidr
  switch_cidr=$(jq -er '.smallsetup.masterNetworkCIDR' "$K2S_INSTALL_DIR/cfg/config.json") || return 1
  pod_cidr=$(jq -er '.smallsetup.podNetworkCIDR' "$K2S_INSTALL_DIR/cfg/config.json") || return 1
  k2s_log INFO "Removing Kubernetes from $K2S_NODE_IP."
  k2s_node_ssh "sudo bash -s -- $(printf '%q %q' "$switch_cidr" "$pod_cidr")" <<'SCRIPT' 2>&1 | k2s_log_output
switch_cidr=$1
pod_cidr=$2
if systemctl cat k2s-routes.service >/dev/null 2>&1; then
  systemctl disable --now k2s-routes.service
fi
rm -f /etc/systemd/system/k2s-routes.service
kubeadm reset --force
systemctl disable --now kubelet crio
for cidr in "$switch_cidr" "$pod_cidr"; do
  ip -4 route show root "$cidr" | grep -v 'proto kernel' | while read -r route; do ip route delete $route; done
done
for link in cni0 flannel.1; do
  if ip link show "$link" >/dev/null 2>&1; then
    ip link delete "$link"
  fi
done
for package in kubeadm kubectl kubelet cri-tools cri-o buildah; do
  DEBIAN_FRONTEND=noninteractive dpkg -P "$package"
done
for file in /etc/containers/registries.conf.d/*.conf; do
  grep -q '^[[:space:]]*\[\[registry\.mirror\]\]' "$file" 2>/dev/null && rm -f "$file"
done
rm -rf /etc/kubernetes /etc/cni /etc/crio /var/lib/crio/* /etc/crictl.yaml /etc/systemd/system/crio.service.d \
  /root/.config/containers /etc/containers/registries.conf /etc/containers/containers.conf.d/20-k2s-proxy.conf \
  /etc/sysctl.d/k8s.conf /etc/modules-load.d/k8s.conf /etc/cron.d/sharedmount /usr/local/sbin/k2s-crio-precheck \
  /etc/apt/apt.conf.d/90k2s-install-proxy /etc/apt/apt.conf.d/95k2s-proxy /tmp/k2s-node \
  /etc/apt/apt.conf.d/90k2s-proxy /etc/apt/apt.conf.d/10sandbox-for-k2s \
  /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/cri-o.list \
  /usr/share/keyrings/kubernetes-apt-keyring.gpg /usr/share/keyrings/cri-o-apt-keyring.gpg
sysctl --system >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y
systemctl daemon-reload
SCRIPT
}

k2s_node_forget_host() {
  ssh-keygen -R "$K2S_NODE_IP" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1 || true
}
