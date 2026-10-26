#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

if [[ -n ${K2S_WINDOWS_WORKER_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_WINDOWS_WORKER_SH_LOADED=1

readonly K2S_WINDOWS_WORKER_NAME='k2s-win-worker'
readonly K2S_WINDOWS_WORKER_NETWORK='k2s-switch'
readonly K2S_WINDOWS_WORKER_BRIDGE='kubeswitch'
readonly K2S_WINDOWS_WORKER_MAC='52:54:00:25:57:01'
k2s_windows_worker_state_file() { printf '%s/windows-worker.json' "$K2S_CONFIG_DIR"; }
k2s_windows_worker_vm_dir() { printf '%s' '/var/lib/libvirt/images/k2s'; }
k2s_windows_worker_gateway() { k2s_cfg '.smallsetup.kubeSwitch'; }
# Pod subnet of the Windows worker; corresponds to the -PodSubnetworkNumber '1'
# passed to Add-WindowsWorkerNodeOnWindowsHost in k2s_windows_worker_join_cluster.
k2s_windows_worker_pod_subnet() { k2s_cfg '.smallsetup.podNetworkWorkerCIDR'; }
k2s_windows_worker_network_cidr() { k2s_cfg '.smallsetup.masterNetworkCIDR'; }
k2s_windows_worker_ip() {
  local gateway
  gateway=$(k2s_windows_worker_gateway) || return 1
  printf '%s.101\n' "${gateway%.*}"
}

k2s_windows_worker_install_host_dependencies() {
  local package
  local packages='qemu-system-x86 qemu-utils util-linux libvirt-daemon-system libvirt-daemon-driver-qemu libvirt-daemon-config-network libvirt-clients dnsmasq-base ovmf openssh-client sshpass'
  k2s_log INFO 'Installing KVM Windows worker host dependencies.'
  k2s_wait_for_dpkg_lock || return 1
  k2s_run env DEBIAN_FRONTEND=noninteractive apt-get update || return 1
  k2s_run env DEBIAN_FRONTEND=noninteractive apt-get install -y $packages || return 1
  k2s_run systemd-sysusers || return 1
  for package in $packages; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -Fq 'install ok installed'; then
      k2s_log ERROR "KVM Windows worker dependency was not installed: $package"
      return 1
    fi
  done
  k2s_windows_worker_start_libvirt
}

k2s_windows_worker_start_libvirt() {
  if systemctl cat libvirtd.service >/dev/null 2>&1; then
    k2s_run systemctl enable --now libvirtd || return 1
  elif systemctl cat virtqemud.socket >/dev/null 2>&1; then
    k2s_run systemctl enable --now virtqemud.socket || return 1
    if systemctl cat virtnetworkd.socket >/dev/null 2>&1; then
      k2s_run systemctl enable --now virtnetworkd.socket || return 1
    elif systemctl cat virtnetworkd.service >/dev/null 2>&1; then
      k2s_run systemctl enable --now virtnetworkd || return 1
    else
      k2s_log ERROR 'Modular libvirt is installed but virtnetworkd is unavailable.'
      return 1
    fi
  elif systemctl cat virtqemud.service >/dev/null 2>&1; then
    k2s_run systemctl enable --now virtqemud || return 1
    if systemctl cat virtnetworkd.service >/dev/null 2>&1; then
      k2s_run systemctl enable --now virtnetworkd || return 1
    elif systemctl cat virtnetworkd.socket >/dev/null 2>&1; then
      k2s_run systemctl enable --now virtnetworkd.socket || return 1
    else
      k2s_log ERROR 'Modular libvirt is installed but virtnetworkd is unavailable.'
      return 1
    fi
  else
    k2s_log ERROR 'Neither libvirtd.service, virtqemud.socket, nor virtqemud.service is available after libvirt installation.'
    return 1
  fi
  if ! virsh -c qemu:///system uri >/dev/null 2>&1; then
    k2s_log ERROR 'libvirt is installed but qemu:///system is unavailable. Check libvirtd or virtqemud logs.'
    return 1
  fi
}

k2s_windows_worker_memory_mb() {
  [[ "$K2S_WORKER_MEMORY" =~ ^([2-9]|[1-9][0-9]+)(GB|G)$ ]] || { k2s_log ERROR "Invalid --worker-memory value: $K2S_WORKER_MEMORY"; return 2; }
  printf '%s\n' "$(( ${BASH_REMATCH[1]} * 1024 ))"
}

k2s_windows_worker_disk_gb() {
  [[ "$K2S_WORKER_DISK_SIZE" =~ ^([2-9][0-9]|[1-9][0-9]{2,})(GB|G)$ ]] || { k2s_log ERROR "Invalid --worker-disk value: $K2S_WORKER_DISK_SIZE"; return 2; }
  printf '%s\n' "${BASH_REMATCH[1]}"
}

k2s_windows_worker_preflight() {
  local command memory_mb available_mb total_mb disk_gb available_gb vm_dir
  [[ -r /dev/kvm && -c /dev/kvm ]] || { k2s_log ERROR 'KVM is unavailable. Enable nested virtualization and expose /dev/kvm to the Debian host.'; return 3; }
  for command in virsh qemu-img sfdisk ssh scp ssh-keyscan ssh-keygen sshpass tar; do k2s_require_command "$command" || return 4; done
  getent passwd libvirt-qemu >/dev/null || { k2s_log ERROR 'The libvirt-qemu service account is missing. Reinstall libvirt-daemon-system.'; return 3; }
  getent passwd dnsmasq >/dev/null || { k2s_log ERROR 'The dnsmasq service account is missing. Install dnsmasq-base.'; return 3; }
  k2s_windows_worker_start_libvirt || return 3
  [[ "$K2S_WORKER_CPU_COUNT" =~ ^[1-9][0-9]*$ ]] || { k2s_log ERROR "Invalid --worker-cpus value: $K2S_WORKER_CPU_COUNT"; return 2; }
  memory_mb=$(k2s_windows_worker_memory_mb) || return $?
  disk_gb=$(k2s_windows_worker_disk_gb) || return $?
  available_mb=$(awk '/MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
  total_mb=$(awk '/MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  (( memory_mb * 4 <= total_mb * 3 )) || { k2s_log ERROR 'Windows worker memory must not exceed 75% of host memory.'; return 3; }
  (( available_mb >= memory_mb + 2048 )) || { k2s_log ERROR 'Windows worker would leave less than 2GB of host memory available.'; return 3; }
  vm_dir=$(k2s_windows_worker_vm_dir)
  install -d -m 0711 "$vm_dir" || return 1
  available_gb=$(df -BG --output=avail "$vm_dir" | tail -1 | tr -dc '0-9')
  (( available_gb - disk_gb >= 20 )) || { k2s_log ERROR 'Windows worker would leave less than 20GB of host disk space available.'; return 3; }
}

k2s_windows_worker_network_create() {
  local gateway network_cidr worker_ip prefix network_xml result existing_xml pod_subnet
  gateway=$(k2s_windows_worker_gateway) || return 1
  network_cidr=$(k2s_windows_worker_network_cidr) || return 1
  worker_ip=$(k2s_windows_worker_ip) || return 1
  pod_subnet=$(k2s_windows_worker_pod_subnet) || return 1
  prefix=${network_cidr#*/}
  [[ "$prefix" == '24' ]] || { k2s_log ERROR "Managed KubeSwitch requires a /24 masterNetworkCIDR, found: $network_cidr"; return 2; }
  if virsh net-info "$K2S_WINDOWS_WORKER_NETWORK" >/dev/null 2>&1; then
    existing_xml=$(virsh net-dumpxml "$K2S_WINDOWS_WORKER_NETWORK") || return 1
    # A network defined before DNS was disabled still runs a dnsmasq holding
    # port 53 on the gateway, which the K2s DNS proxy needs. Redefine it.
    if ! printf '%s' "$existing_xml" | grep -Fq "bridge name='$K2S_WINDOWS_WORKER_BRIDGE'" || ! printf '%s' "$existing_xml" | grep -Fq "address='$gateway'" || ! printf '%s' "$existing_xml" | grep -Fq "<dns enable='no'/>"; then
      k2s_log INFO 'Replacing a prior K2s-managed libvirt network definition with the configured KubeSwitch network.'
      virsh net-destroy "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
      virsh net-undefine "$K2S_WINDOWS_WORKER_NETWORK" || return 1
    else
      virsh net-start "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
      virsh net-autostart "$K2S_WINDOWS_WORKER_NETWORK" || return 1
      ip route replace "$pod_subnet" via "$worker_ip"
      return 0
    fi
  fi
  network_xml=$(mktemp)
  cat > "$network_xml" <<EOF
<network><name>$K2S_WINDOWS_WORKER_NETWORK</name><forward mode='nat'/><bridge name='$K2S_WINDOWS_WORKER_BRIDGE' stp='on' delay='0'/><dns enable='no'/><ip address='$gateway' netmask='255.255.255.0'><dhcp><range start='${gateway%.*}.100' end='${gateway%.*}.199'/><host mac='$K2S_WINDOWS_WORKER_MAC' name='$K2S_WINDOWS_WORKER_NAME' ip='$worker_ip'/></dhcp></ip></network>
EOF
  virsh net-define "$network_xml" && virsh net-start "$K2S_WINDOWS_WORKER_NETWORK" && virsh net-autostart "$K2S_WINDOWS_WORKER_NETWORK"
  result=$?; rm -f "$network_xml"
  (( result == 0 )) || return "$result"
  ip route replace "$pod_subnet" via "$worker_ip"
}

k2s_windows_worker_prepare_image() {
  local vm_dir disk disk_gb
  vm_dir=$(k2s_windows_worker_vm_dir)
  disk="$vm_dir/$K2S_WINDOWS_WORKER_NAME.qcow2"
  disk_gb=$(k2s_windows_worker_disk_gb) || return $?
  install -d -m 0711 "$vm_dir" || return 1
  [[ ! -e "$disk" ]] || { printf '%s\n' "$disk"; return 0; }
  local cache="$vm_dir/WindowsWorker-Base.qcow2"
  [[ -f "$cache" ]] || k2s_windows_worker_import_qcow2 "$cache" >&2 || return $?
  k2s_windows_worker_create_overlay "$cache" "$disk" "$disk_gb" >&2 || return $?
  printf '%s\n' "$disk"
}

# A QCOW2 overlay cannot be smaller than the image it is backed by, so
# --worker-disk is an "at least" request: it grows the worker disk beyond the
# prepared base image, and is capped at the base image size when it is smaller.
k2s_windows_worker_create_overlay() {
  local cache="$1" disk="$2" disk_gb="$3" backing_bytes backing_gb
  backing_bytes=$(qemu-img info --output=json "$cache" | jq -r '.["virtual-size"]') || return 1
  backing_gb=$(( (backing_bytes + 1073741823) / 1073741824 ))
  if (( disk_gb <= backing_gb )); then
    (( disk_gb == backing_gb )) || k2s_log WARN "--worker-disk ${disk_gb}GB is smaller than the prepared base image (${backing_gb}GB); using ${backing_gb}GB."
    qemu-img create -f qcow2 -F qcow2 -b "$cache" "$disk" >&2
  else
    k2s_log INFO "Growing the Windows worker disk from the ${backing_gb}GB base image to ${disk_gb}GB." >&2
    qemu-img create -f qcow2 -F qcow2 -b "$cache" "$disk" "${disk_gb}G" >&2
  fi
}

k2s_windows_worker_import_qcow2() {
  local cache="$1" source_format temporary_cache
  [[ -f "$K2S_WINDOWS_QCOW2_PATH" ]] || { k2s_log ERROR 'A cached Windows worker base image or --windows-qcow2-path is required.'; return 2; }
  source_format=$(qemu-img info --output=json "$K2S_WINDOWS_QCOW2_PATH" | jq -r '.format') || return 1
  [[ "$source_format" == 'qcow2' ]] || { k2s_log ERROR "Windows worker image must use QCOW2 format, found: $source_format"; return 2; }
  temporary_cache="$cache.tmp"
  rm -f "$temporary_cache"
  k2s_log INFO "Importing prepared Windows worker QCOW2 image: $K2S_WINDOWS_QCOW2_PATH"
  qemu-img convert -f qcow2 -O qcow2 -o compat=1.1 "$K2S_WINDOWS_QCOW2_PATH" "$temporary_cache" || return 1
  qemu-img check "$temporary_cache" || { rm -f "$temporary_cache"; return 1; }
  chmod 0644 "$temporary_cache" || { rm -f "$temporary_cache"; return 1; }
  mv "$temporary_cache" "$cache"
}

k2s_windows_worker_detect_boot_mode() {
  local disk="$1" partition_table boot_sector
  boot_sector=$(mktemp) || return 1
  # A GPT header resides at LBA 1, while the MBR is at LBA 0. Copying 2 MiB
  # gives sfdisk both headers without attaching an NBD device to this nested VM.
  qemu-img dd -f qcow2 "if=$disk" "of=$boot_sector" bs=1M count=2 >/dev/null 2>&1 || { rm -f "$boot_sector"; return 1; }
  partition_table=$(sfdisk --json "$boot_sector" 2>/dev/null | jq -r '.partitiontable.label // empty')
  rm -f "$boot_sector"
  case "$partition_table" in
    dos)
      k2s_log INFO 'Detected MBR partition table; booting the Windows worker with BIOS.' >&2
      printf '%s\n' bios
      ;;
    gpt)
      k2s_log INFO 'Detected GPT partition table; booting the Windows worker with UEFI.' >&2
      printf '%s\n' uefi
      ;;
    *)
      k2s_log ERROR "Cannot detect a supported Windows worker partition table (found: ${partition_table:-none})."
      return 2
      ;;
  esac
}

k2s_windows_worker_ssh_dir() { printf '%s/ssh' "$K2S_CONFIG_DIR"; }
k2s_windows_worker_private_key() { printf '%s/windows-worker' "$(k2s_windows_worker_ssh_dir)"; }
k2s_windows_worker_known_hosts() { printf '%s/windows-worker.known_hosts' "$(k2s_windows_worker_ssh_dir)"; }

k2s_windows_worker_create_ssh_key() {
  local key_dir key
  key_dir=$(k2s_windows_worker_ssh_dir); key=$(k2s_windows_worker_private_key)
  mkdir -p "$key_dir"; chmod 700 "$key_dir"
  [[ -f "$key" && -f "$key.pub" ]] || ssh-keygen -q -t ed25519 -N '' -f "$key" -C k2s-windows-worker
  chmod 600 "$key"; chmod 644 "$key.pub"
}

# ServerAlive* bounds how long a session hangs after the worker's networking drops out
# from under it, which happens whenever HNS rebinds the NIC. Without it ssh waits for
# the TCP timeout, roughly 20 minutes.
k2s_windows_worker_ssh() {
  ssh -i "$(k2s_windows_worker_private_key)" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "remote@$(k2s_windows_worker_ip)" "$@"
}

k2s_windows_worker_password() { printf '%s' "${K2S_WINDOWS_WORKER_PASSWORD:-admin}"; }

k2s_windows_worker_password_ssh() {
  SSHPASS=$(k2s_windows_worker_password) sshpass -e ssh -o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" -o ConnectTimeout=10 "remote@$(k2s_windows_worker_ip)" "$@"
}

k2s_windows_worker_password_scp() {
  SSHPASS=$(k2s_windows_worker_password) sshpass -e scp -o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" "$(k2s_windows_worker_private_key).pub" "remote@$(k2s_windows_worker_ip):windows-worker.pub"
}

# sshd reads administrators_authorized_keys on every authentication, so the key takes
# effect without restarting the service. Restarting it would tear down the very session
# running this command and can leave port 22 unreachable while the guest is still busy
# with its first boot.
k2s_windows_worker_bootstrap_ssh_key() {
  k2s_windows_worker_password_scp || return $?
  k2s_windows_worker_password_ssh 'powershell.exe -NoProfile -Command "New-Item -ItemType Directory -Path C:\ProgramData\ssh -Force | Out-Null; Copy-Item -Path C:\Users\remote\windows-worker.pub -Destination C:\ProgramData\ssh\administrators_authorized_keys -Force; icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant \"Administrators:F\" /grant \"SYSTEM:F\" | Out-Null; Remove-Item C:\Users\remote\windows-worker.pub -Force"'
}

k2s_windows_worker_wait_for_ssh() {
  local known_hosts worker_ip deadline attempt=0
  k2s_windows_worker_create_ssh_key || return 1
  known_hosts=$(k2s_windows_worker_known_hosts)
  worker_ip=$(k2s_windows_worker_ip) || return 1
  install -d -m 0700 "$(k2s_windows_worker_ssh_dir)" || return 1
  : > "$known_hosts"; chmod 600 "$known_hosts"
  k2s_log INFO "Waiting for the Windows worker to answer SSH on $worker_ip."
  deadline=$((SECONDS + 900))
  while ! ssh-keyscan -T 10 -H "$worker_ip" >> "$known_hosts" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      k2s_windows_worker_log_ssh_diagnostics "$worker_ip"
      k2s_log ERROR 'Timed out waiting for Windows worker SSH host key.'
      return 1
    fi
    sleep 10
  done
  k2s_log INFO 'Windows worker SSH host key retrieved; installing the generated key.'
  # The guest is still settling during its first boot, so the bootstrap itself can fail
  # transiently. Retry it instead of only polling for its result.
  deadline=$((SECONDS + 900))
  until k2s_windows_worker_ssh 'exit 0' 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      k2s_log ERROR 'Windows worker SSH key authentication never succeeded. Last attempt:'
      k2s_windows_worker_ssh 'exit 0' || true
      k2s_windows_worker_log_ssh_diagnostics "$worker_ip"
      k2s_log ERROR "Timed out waiting for Windows worker SSH key authentication after $attempt attempts."
      return 1
    fi
    attempt=$((attempt + 1))
    k2s_log INFO "Installing the Windows worker SSH key through temporary password authentication (attempt $attempt)."
    k2s_windows_worker_bootstrap_ssh_key || k2s_log WARN 'SSH key installation attempt failed; the guest is probably still booting.'
    sleep 10
  done
  k2s_log INFO "Windows worker SSH key authentication established after $attempt attempt(s)."
}

k2s_windows_worker_log_ssh_diagnostics() {
  local worker_ip="$1"
  k2s_log ERROR "Windows worker SSH diagnostics for $worker_ip"
  virsh domstate "$K2S_WINDOWS_WORKER_NAME" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  virsh dominfo "$K2S_WINDOWS_WORKER_NAME" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  virsh domifaddr "$K2S_WINDOWS_WORKER_NAME" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  virsh net-dhcp-leases "$K2S_WINDOWS_WORKER_NETWORK" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  ip -4 neigh show "$worker_ip" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  virsh vncdisplay "$K2S_WINDOWS_WORKER_NAME" 2>&1 | tee -a "$K2S_LOG_FILE" || true
  if virsh screenshot "$K2S_WINDOWS_WORKER_NAME" "$K2S_CONFIG_DIR/${K2S_WINDOWS_WORKER_NAME}-console.png" >/dev/null 2>&1; then
    k2s_log ERROR "Windows worker console screenshot: $K2S_CONFIG_DIR/${K2S_WINDOWS_WORKER_NAME}-console.png"
  fi
  tail -n 100 "/var/log/libvirt/qemu/${K2S_WINDOWS_WORKER_NAME}.log" 2>&1 | tee -a "$K2S_LOG_FILE" || true
}

k2s_windows_worker_copy_runtime() {
  local archive result
  local runtime_paths=(VERSION cfg lib smallsetup bin)
  [[ -d "$K2S_INSTALL_DIR/LocalHooks" ]] && runtime_paths+=(LocalHooks)
  archive=$(mktemp --suffix=.tar) || return 1
  k2s_log INFO 'Copying K2s runtime files to the Windows worker.'
  tar -C "$K2S_INSTALL_DIR" \
    --exclude='bin/*.iso' \
    --exclude='bin/*.qcow2' \
    --exclude='bin/*.vhdx' \
    -cf "$archive" "${runtime_paths[@]}" || { rm -f "$archive"; return 1; }
  k2s_windows_worker_ssh 'powershell.exe -NoProfile -Command "New-Item -ItemType Directory -Path C:\ProgramData\K2s -Force | Out-Null"' || { rm -f "$archive"; return 1; }
  scp -i "$(k2s_windows_worker_private_key)" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" "$archive" "remote@$(k2s_windows_worker_ip):C:/ProgramData/K2s/k2s-runtime.tar"
  result=$?
  rm -f "$archive"
  (( result == 0 )) || return "$result"
  k2s_windows_worker_ssh 'powershell.exe -NoProfile -Command "New-Item -ItemType Directory -Path C:\k2s -Force | Out-Null; tar.exe -xf C:\ProgramData\K2s\k2s-runtime.tar -C C:\k2s; Remove-Item C:\ProgramData\K2s\k2s-runtime.tar -Force"'
}

# kubectl on the worker is invoked without --kubeconfig during the join. On a Windows
# host the control-plane install fetches the config from the control plane (see
# Copy-KubeConfigFromControlPlaneNode); there is no Windows control plane here, so the
# host pushes it to the location the Windows node modules expect.
k2s_windows_worker_copy_kubeconfig() {
  local kubeconfig result
  k2s_log INFO 'Copying the cluster kubeconfig to the Windows worker.'
  kubeconfig=$(mktemp) || return 1
  cp /etc/kubernetes/admin.conf "$kubeconfig" || { rm -f "$kubeconfig"; return 1; }
  scp -i "$(k2s_windows_worker_private_key)" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" "$kubeconfig" "remote@$(k2s_windows_worker_ip):C:/k2s/config"
  result=$?
  rm -f "$kubeconfig"
  return "$result"
}

# The Kubernetes node registers under the worker's Windows computer name, which comes
# from the prepared QCOW2 image and is unrelated to the libvirt domain name.
k2s_windows_worker_node_name() {
  k2s_windows_worker_ssh 'powershell.exe -NoProfile -Command "$env:COMPUTERNAME.ToLower()"' | tr -d '[:space:]'
}

# The generated scripts run over SSH, so only what PowerShell writes to stderr reaches
# the host log; everything Write-Log produces stays on the worker. Pull that log back
# on failure, otherwise a worker-side error surfaces here as a bare exception.
k2s_windows_worker_collect_logs() {
  local log_dir log
  log_dir=$(k2s_cfg '.configDir.logs') || return 0
  log_dir=${log_dir//\\//}
  log=$(mktemp) || return 0
  k2s_log ERROR "Retrieving the Windows worker K2s log from $log_dir/k2s.log"
  if scp -i "$(k2s_windows_worker_private_key)" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" "remote@$(k2s_windows_worker_ip):$log_dir/k2s.log" "$log" >/dev/null 2>&1; then
    printf '===== Windows worker K2s log (last 300 lines) =====\n'
    tail -n 300 "$log" | tr -d '\r'
    printf '===== end of Windows worker K2s log =====\n'
  else
    k2s_log ERROR 'Could not retrieve the Windows worker K2s log.'
  fi
  rm -f "$log"
}

# Cluster-side view of why the worker is not ready. The worker-side view comes from
# k2s_windows_worker_collect_logs.
k2s_windows_worker_diagnose_node() {
  local node_name
  node_name=$(k2s_windows_worker_node_name)
  printf '===== Windows worker node diagnostics =====\n'
  k2s_kubectl get nodes -o wide || true
  [[ -z "$node_name" ]] || k2s_kubectl describe "node/$node_name" || true
  k2s_kubectl -n kube-flannel get pods -o wide || true
  k2s_windows_worker_ssh 'powershell.exe -NoProfile -Command "Get-Service containerd,kubelet,kubeproxy,flanneld,httpproxy -ErrorAction SilentlyContinue | Format-Table Name,Status,StartType -AutoSize | Out-String"' || true
  printf '===== end of Windows worker node diagnostics =====\n'
}

k2s_windows_worker_join_result_file() { printf '%s' 'C:\ProgramData\K2s\JoinWorker.result'; }

k2s_windows_worker_join_cluster() {
  local join_command join_script escaped_join gateway worker_ip result_file
  join_command=$(kubeadm token create --ttl 30m --print-join-command) || return 1
  escaped_join=${join_command//\'/\'\'}
  gateway=$(k2s_windows_worker_gateway) || return 1
  worker_ip=$(k2s_windows_worker_ip) || return 1
  result_file=$(k2s_windows_worker_join_result_file)
  join_script=$(mktemp)
  cat > "$join_script" <<EOF
Import-Module 'C:\\k2s\\lib\\modules\\windows\\infra\\k2s.infra.module\\k2s.infra.module.psm1' -Force
Import-Module 'C:\\k2s\\lib\\modules\\windows\\node\\k2s.node.module\\k2s.node.module.psm1' -Force
Import-Module 'C:\\k2s\\lib\\modules\\windows\\cluster\\k2s.cluster.module\\k2s.cluster.module.psm1' -Force

# -ShowLogs mirrors every Write-Log to the console. The script runs over SSH, so this
# is what makes the worker's progress visible in the host log as it happens, instead
# of only in the worker's own log file.
Initialize-Logging -ShowLogs

# Mirror lib/scripts/windows/worker/windows-host/Install.ps1: the Windows node
# modules are written and tested against 'Continue'. Forcing 'Stop' here turns
# their benign non-terminating errors into fatal ones.
\$ErrorActionPreference = 'Continue'

# Whatever inside Add-WindowsWorkerNodeOnWindowsHost rebinds the worker's NIC (loopback
# adapter install, VFP rules, HNS) can drop this SSH session the same way starting the
# node does. Record the outcome so the host can pick it up after reconnecting instead of
# depending on the SSH exit status.
try {

\$installationPath = Get-KubePath
Set-Location \$installationPath

# Mirror lib/scripts/control-plane/Install.ps1: on a Windows host the control-plane
# install seeds these before any worker setup runs. There is no Windows control plane
# here, so the worker has to do it for itself.
Set-ConfigProductVersion -Value (Get-ProductVersion)
Set-ConfigInstallFolder -Value \$installationPath
try {
    Set-ConfigLogRoot -Value (Get-ConfiguredLogDirectory)
    Update-LogFilePathFromConfig -Force
}
catch {
    Write-Log "Could not persist resolved log root: \$_"
}

# This worker is a dedicated VM, so the l2 bridge is built on its own Ethernet NIC
# instead of the loopback adapter the Windows-host setup creates to avoid taking
# over the user's NIC. Resolve the adapter by IP; Windows may name it 'Ethernet 2'.
\$ipConfig = Get-NetIPAddress -AddressFamily IPv4 -IPAddress '$worker_ip' -ErrorAction Stop
\$adapter = Get-NetAdapter -InterfaceIndex \$ipConfig.InterfaceIndex -ErrorAction Stop
Write-Log "Building the l2 bridge on network adapter '\$(\$adapter.Name)'"
Set-ConfigL2BridgeAdapterName -Value \$adapter.Name

# Puts \$installationPath\bin\kube on PATH. The kubeadm join preflight shells out to
# 'kubelet --version' and fails fatally with ERROR KubeletVersion when it is missing;
# that check is not covered by the --ignore-preflight-errors the join already passes.
# On a Windows host this is done by the control-plane setup, which does not run here.
Set-EnvVars

# Populates C:\k2s\bin\windowsnode, which Initialize-WinNode consumes but never fills.
Invoke-DeployWinArtifacts -KubernetesVersion (Get-DefaultK8sVersion) -Proxy 'http://$gateway:8181'

# The host put the kubeconfig at \$installationPath\config. Publish it the way
# Add-K8sContext would, which cannot run yet because it needs kubectl.exe and that is
# only deployed later by Add-WindowsWorkerNodeOnWindowsHost.
Set-InstalledClusterName -Value '$K2S_CLUSTER_NAME'
# Wait-ForNodesReady watches for this node to go Ready so it can stop the kubeadm join,
# which otherwise blocks on a TLS bootstrap that never completes. Unset, it falls back
# to 'kubemaster' and never matches the native Debian host.
Set-ConfigControlPlaneNodeHostname '$K2S_CONTROL_PLANE_HOSTNAME'
\$kubeConfigDir = Get-ConfiguredKubeConfigDir
if (!(Test-Path \$kubeConfigDir)) {
    New-Item -ItemType Directory -Path \$kubeConfigDir -Force | Out-Null
}
Copy-Item "\$installationPath\config" -Destination "\$kubeConfigDir\config" -Force
\$env:KUBECONFIG = "\$installationPath\config"
[Environment]::SetEnvironmentVariable('KUBECONFIG', "\$installationPath\config", [System.EnvironmentVariableTarget]::Machine)

# Add-WindowsWorkerNodeOnWindowsHost requires this path (it reads kubeletOverrides.windowsWorker
# from it). The native Linux control-plane install does not stage an effective-install-config.json
# anywhere the worker could fetch it, so provide an empty one: Get-K2sKubeletOverrideContent treats
# a config with no 'kubeletOverrides' key as "no overrides" rather than an error. Per-worker kubelet
# overrides are therefore not yet supported for a managed KVM Windows worker.
\$effectiveInstallConfigPath = 'C:\ProgramData\K2s\effective-install-config.json'
if (!(Test-Path \$effectiveInstallConfigPath)) {
    '{}' | Set-Content -Path \$effectiveInstallConfigPath -Encoding ascii
}

\$workerNodeParams = @{
    Proxy                      = 'http://$gateway:8181'
    PodSubnetworkNumber        = '1'
    JoinCommand                = '$escaped_join'
    EffectiveInstallConfigPath = \$effectiveInstallConfigPath
}
Add-WindowsWorkerNodeOnWindowsHost @workerNodeParams

# Mirror lib/scripts/windows/worker/windows-host/Install.ps1.
Write-Log 'Adding mirror registries'
foreach (\$registry in (Get-MirrorRegistries)) {
    Set-Registry -Name \$registry.registry -Https -SkipVerify -Mirror \$registry.mirror -Server \$registry.server
}
    'OK' | Set-Content -Path '$result_file' -Encoding ascii
}
catch {
    "FAILED: \$_" | Set-Content -Path '$result_file' -Encoding ascii
    throw
}
EOF
  scp -i "$(k2s_windows_worker_private_key)" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" "$join_script" "remote@$(k2s_windows_worker_ip):C:/ProgramData/K2s/JoinWorker.ps1"
  local result=$?; rm -f "$join_script"; (( result == 0 )) || return "$result"
  # Best-effort: the worker's disk is a fresh qcow2 overlay on every install, so a stale
  # marker from a previous run cannot actually exist here. Do not abort the join over a
  # transient hiccup in this throwaway cleanup call.
  k2s_windows_worker_ssh "powershell.exe -NoProfile -Command \"Remove-Item -Path '$result_file' -Force -ErrorAction SilentlyContinue\"" || true
  # The SSH session may die mid-run if the worker's NIC gets rebound; that is expected.
  k2s_windows_worker_ssh 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\K2s\JoinWorker.ps1' || true
  k2s_windows_worker_wait_for_join_result
}

# Polls for the marker JoinWorker.ps1 writes, reconnecting as needed while the worker's
# networking settles after a NIC rebind. Mirrors k2s_windows_worker_wait_for_start_result.
k2s_windows_worker_wait_for_join_result() {
  local result_file outcome deadline=$((SECONDS + 900))
  result_file=$(k2s_windows_worker_join_result_file)
  while :; do
    outcome=$(k2s_windows_worker_ssh "powershell.exe -NoProfile -Command \"if (Test-Path '$result_file') { Get-Content -Path '$result_file' -Raw }\"" 2>/dev/null | tr -d '\r\n')
    case "$outcome" in
      OK)
        k2s_log INFO 'Windows worker joined the cluster.'
        return 0
        ;;
      FAILED*)
        k2s_log ERROR "Joining the Windows worker reported: $outcome"
        return 1
        ;;
    esac
    if (( SECONDS >= deadline )); then
      k2s_log ERROR 'Timed out waiting for the Windows worker to report the result of its join.'
      return 1
    fi
    sleep 15
  done
}

# Mirrors lib/scripts/windows/worker/windows-host/Start.ps1. Installing the worker
# only registers the services; this is what creates the cbr0 l2 bridge and starts
# containerd, flanneld, kubelet and kubeproxy, so the node can become Ready.
k2s_windows_worker_start_result_file() { printf '%s' 'C:\ProgramData\K2s\StartWorker.result'; }

k2s_windows_worker_start_node() {
  local start_script gateway result_file
  gateway=$(k2s_windows_worker_gateway) || return 1
  result_file=$(k2s_windows_worker_start_result_file)
  start_script=$(mktemp)
  cat > "$start_script" <<EOF
Import-Module 'C:\\k2s\\lib\\modules\\windows\\infra\\k2s.infra.module\\k2s.infra.module.psm1' -Force
Import-Module 'C:\\k2s\\lib\\modules\\windows\\node\\k2s.node.module\\k2s.node.module.psm1' -Force
Import-Module 'C:\\k2s\\lib\\modules\\windows\\cluster\\k2s.cluster.module\\k2s.cluster.module.psm1' -Force

# -ShowLogs mirrors every Write-Log to the console. The script runs over SSH, so this
# is what makes the worker's progress visible in the host log as it happens, instead
# of only in the worker's own log file.
Initialize-Logging -ShowLogs

# Mirror lib/scripts/windows/worker/windows-host/Install.ps1: the Windows node
# modules are written and tested against 'Continue'. Forcing 'Stop' here turns
# their benign non-terminating errors into fatal ones.
\$ErrorActionPreference = 'Continue'
\$ProgressPreference = 'SilentlyContinue'

Set-Location (Get-KubePath)

# sshd caches its environment block, so a new SSH session does not pick up the PATH the
# join wrote to the registry. Re-apply it; Update-SystemPath de-duplicates.
Set-EnvVars

\$workerNodeStartParams = @{
    PodSubnetworkNumber = '1'
    DnsServers          = '$gateway'
    SkipHeaderDisplay   = \$true
}

# Creating the cbr0 l2 bridge rebinds the worker's only NIC and drops the SSH session
# running this script, while the script itself keeps going. Record the outcome so the
# host can pick it up after reconnecting instead of depending on the SSH exit status.
try {
    Start-WindowsWorkerNodeOnWindowsHost @workerNodeStartParams
    'OK' | Set-Content -Path '$result_file' -Encoding ascii
}
catch {
    "FAILED: \$_" | Set-Content -Path '$result_file' -Encoding ascii
    throw
}
EOF
  scp -i "$(k2s_windows_worker_private_key)" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(k2s_windows_worker_known_hosts)" "$start_script" "remote@$(k2s_windows_worker_ip):C:/ProgramData/K2s/StartWorker.ps1"
  local result=$?; rm -f "$start_script"; (( result == 0 )) || return "$result"
  # Best-effort: the worker's disk is a fresh qcow2 overlay on every install, so a stale
  # marker from a previous run cannot actually exist here. Do not abort the start over a
  # transient hiccup in this throwaway cleanup call.
  k2s_windows_worker_ssh "powershell.exe -NoProfile -Command \"Remove-Item -Path '$result_file' -Force -ErrorAction SilentlyContinue\"" || true
  # The SSH session is expected to die mid-run, so its exit status says nothing.
  k2s_windows_worker_ssh 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\K2s\StartWorker.ps1' || true
  k2s_windows_worker_wait_for_start_result
}

# Polls for the marker StartWorker.ps1 writes, reconnecting as needed while the worker's
# networking settles after the l2 bridge is created.
k2s_windows_worker_wait_for_start_result() {
  local result_file outcome deadline=$((SECONDS + 900))
  result_file=$(k2s_windows_worker_start_result_file)
  while :; do
    outcome=$(k2s_windows_worker_ssh "powershell.exe -NoProfile -Command \"if (Test-Path '$result_file') { Get-Content -Path '$result_file' -Raw }\"" 2>/dev/null | tr -d '\r\n')
    case "$outcome" in
      OK)
        k2s_log INFO 'Kubernetes services started on the Windows worker.'
        return 0
        ;;
      FAILED*)
        k2s_log ERROR "Starting Kubernetes services on the Windows worker reported: $outcome"
        return 1
        ;;
    esac
    if (( SECONDS >= deadline )); then
      k2s_log ERROR 'Timed out waiting for the Windows worker to report the result of its start.'
      return 1
    fi
    sleep 15
  done
}

k2s_windows_worker_wait_for_node() {
  local node_name deadline
  node_name=$(k2s_windows_worker_node_name) || return 1
  [[ -n "$node_name" ]] || { k2s_log ERROR 'Could not determine the Windows worker computer name.'; return 1; }
  k2s_log INFO "Waiting for the Windows worker to register as Kubernetes node '$node_name'."
  deadline=$((SECONDS + 1200))
  while ! k2s_kubectl get node "$node_name" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || { k2s_log ERROR "Timed out waiting for the Windows worker Kubernetes node '$node_name'."; return 1; }
    sleep 10
  done
  k2s_kubectl wait --for=condition=Ready "node/$node_name" --timeout=10m
}

k2s_windows_worker_define() {
  local disk="$1" memory_mb domain_xml boot_mode firmware variables nvram firmware_xml
  memory_mb=$(k2s_windows_worker_memory_mb) || return $?
  boot_mode=$(k2s_windows_worker_detect_boot_mode "$disk") || return $?
  firmware_xml=''
  if [[ "$boot_mode" == uefi ]]; then
    firmware=/usr/share/OVMF/OVMF_CODE_4M.fd
    variables=/usr/share/OVMF/OVMF_VARS_4M.fd
    [[ -r "$firmware" && -r "$variables" ]] || { k2s_log ERROR 'UEFI boot requires standard OVMF firmware and variables from the ovmf package.'; return 1; }
    nvram="/var/lib/libvirt/qemu/nvram/${K2S_WINDOWS_WORKER_NAME}_VARS.fd"
    firmware_xml="<loader readonly='yes' secure='no' type='pflash'>$firmware</loader><nvram template='$variables'>$nvram</nvram>"
  fi
  domain_xml=$(mktemp)
  cat > "$domain_xml" <<EOF
<domain type='kvm'><name>$K2S_WINDOWS_WORKER_NAME</name><memory unit='MiB'>$memory_mb</memory><currentMemory unit='MiB'>$memory_mb</currentMemory><vcpu placement='static'>$K2S_WORKER_CPU_COUNT</vcpu><os><type arch='x86_64' machine='q35'>hvm</type>$firmware_xml<boot dev='hd'/></os><features><acpi/><apic/><hyperv mode='custom'><relaxed state='on'/><vapic state='on'/><spinlocks state='on' retries='8191'/><vpindex state='on'/><runtime state='on'/><synic state='on'/><stimer state='on'/></hyperv></features><cpu mode='host-passthrough' check='none'/><clock offset='localtime'><timer name='hypervclock' present='yes'/><timer name='hpet' present='no'/></clock><devices><disk type='file' device='disk'><driver name='qemu' type='qcow2' discard='unmap'/><source file='$disk'/><target dev='sda' bus='sata'/></disk><interface type='network'><mac address='$K2S_WINDOWS_WORKER_MAC'/><source network='$K2S_WINDOWS_WORKER_NETWORK'/><model type='e1000'/></interface><serial type='pty'/><console type='pty'/><graphics type='vnc' autoport='yes' listen='127.0.0.1'><listen type='address' address='127.0.0.1'/></graphics><video><model type='vga' vram='16384' heads='1' primary='yes'/></video><rng model='virtio'><backend model='random'>/dev/urandom</backend></rng><memballoon model='virtio'/></devices></domain>
EOF
  virsh define "$domain_xml"; local result=$?; rm -f "$domain_xml"; return "$result"
}

k2s_windows_worker_write_state() {
  local disk="$1" state gateway worker_ip
  state=$(k2s_windows_worker_state_file)
  gateway=$(k2s_windows_worker_gateway) || return 1
  worker_ip=$(k2s_windows_worker_ip) || return 1
  jq -n --arg name "$K2S_WINDOWS_WORKER_NAME" --arg network "$K2S_WINDOWS_WORKER_NETWORK" --arg ip "$worker_ip" --arg mac "$K2S_WINDOWS_WORKER_MAC" --arg disk "$disk" --arg proxy "http://$gateway:8181" '{name:$name,network:$network,ip:$ip,mac:$mac,disk:$disk,proxy:$proxy}' > "$state"
  chmod 600 "$state"
}

k2s_windows_worker_provision() {
  k2s_log INFO 'Preflighting managed KVM Windows worker.'
  k2s_windows_worker_preflight || return $?
  k2s_log INFO "Creating libvirt network '$K2S_WINDOWS_WORKER_NETWORK' on bridge '$K2S_WINDOWS_WORKER_BRIDGE'."
  k2s_windows_worker_network_create || return 1
  local disk
  disk=$(k2s_windows_worker_prepare_image) || return $?
  k2s_windows_worker_create_ssh_key || return 1
  k2s_log INFO "Defining libvirt domain '$K2S_WINDOWS_WORKER_NAME' with ${K2S_WORKER_CPU_COUNT} vCPUs."
  k2s_windows_worker_define "$disk" || return 1
  k2s_windows_worker_write_state "$disk" || return 1
  k2s_log INFO "Starting the Windows worker and waiting for SSH on $(k2s_windows_worker_ip)."
  virsh start "$K2S_WINDOWS_WORKER_NAME" || return 1
  k2s_windows_worker_wait_for_ssh || return $?
  k2s_windows_worker_copy_runtime || return $?
  k2s_windows_worker_copy_kubeconfig || return $?
  k2s_log INFO 'Joining the Windows worker to the cluster. Output below comes from the worker.'
  k2s_windows_worker_join_cluster || { k2s_log ERROR 'Joining the Windows worker failed.'; k2s_windows_worker_collect_logs; return 1; }
  k2s_log INFO 'Starting Kubernetes services on the Windows worker. Output below comes from the worker.'
  k2s_windows_worker_start_node || { k2s_log ERROR 'Starting the Windows worker node failed.'; k2s_windows_worker_collect_logs; return 1; }
  k2s_windows_worker_wait_for_node || { k2s_log ERROR 'The Windows worker did not become a ready Kubernetes node.'; k2s_windows_worker_diagnose_node; k2s_windows_worker_collect_logs; return 1; }
  k2s_log INFO 'Managed Windows worker is reachable through SSH and joined to the Kubernetes cluster.'
}

k2s_windows_worker_start() {
  virsh net-start "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
  virsh start "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null || true
  k2s_windows_worker_wait_for_ssh || return $?
  k2s_windows_worker_start_node
}
k2s_windows_worker_stop() {
  local deadline=$((SECONDS + 120)) state
  virsh domstate "$K2S_WINDOWS_WORKER_NAME" >/dev/null 2>&1 || return 0
  virsh shutdown "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null || true
  while :; do
    state=$(virsh domstate "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null || true)
    [[ "$state" == 'shut off' ]] && return 0
    if (( SECONDS >= deadline )); then
      k2s_log WARN 'Windows worker did not shut down within 120 seconds; forcing termination.'
      virsh destroy "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null || return 1
      return 0
    fi
    sleep 2
  done
}
k2s_windows_worker_remove() {
  local vm_dir
  vm_dir=$(k2s_windows_worker_vm_dir)
  ip route del "$(k2s_windows_worker_pod_subnet)" 2>/dev/null || true
  virsh destroy "$K2S_WINDOWS_WORKER_NAME" 2>/dev/null || true
  virsh undefine "$K2S_WINDOWS_WORKER_NAME" --remove-all-storage --nvram 2>/dev/null || true
  rm -f "$vm_dir/$K2S_WINDOWS_WORKER_NAME.qcow2" "/var/lib/libvirt/qemu/nvram/${K2S_WINDOWS_WORKER_NAME}_VARS.fd"
  virsh net-destroy "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
  virsh net-undefine "$K2S_WINDOWS_WORKER_NETWORK" 2>/dev/null || true
  rm -f "$(k2s_windows_worker_state_file)"
}
