<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: MIT
-->

# Extending a K2s Cluster

This guide explains how to extend a K2s cluster by adding additional nodes. At the moment, the documented and supported workflow covers Linux worker nodes on physical hosts or existing virtual machines. Support for Windows worker nodes will follow.

## Prerequisites

Complete the following preparation on the K2s host and on the Debian 13 target before running `k2s node add`.

### K2s host

- K2s is installed and the cluster is running and healthy.
- Run the command from an elevated PowerShell or command prompt on the K2s Windows host.
- The K2s SSH key pair exists. The public key is `%USERPROFILE%\.ssh\k2s\id_rsa.pub`.

### Debian 13 target

- Install Debian 13 (Trixie) on a physical machine or an existing VM. The target must not already be a member of a Kubernetes cluster.
- Configure a stable IPv4 address, either statically or with a DHCP reservation. K2s stores the address supplied to `k2s node add` for later node operations.
- Set a hostname containing only lowercase letters. K2s uses the remote hostname as the Kubernetes node name; if `--name` is supplied, it must match that hostname.
- Install and enable an SSH server, and make TCP port 22 reachable from the K2s host.
- Use a user that can run commands with `sudo`. The K2s provisioning process uses `sudo` to install packages, configure services, and add routes.
- Install `lsb-release`, which K2s uses to identify the Debian release:

```console
sudo apt-get update
sudo apt-get install --yes openssh-server sudo lsb-release ca-certificates
sudo systemctl enable --now ssh
```

- Ensure the user has a home directory and that SSH key authentication can read `~/.ssh/authorized_keys`:

```console
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

- Disable swap permanently before adding the node. Kubelet cannot run while swap is enabled. If the Debian installer created a swap partition, disable it, remove its `/etc/fstab` entry, and mask its systemd swap unit:

```bash
swapUnits=$(systemctl list-units --type=swap --all --plain --no-legend | awk '{print $1}')
sudo swapoff -a
sudo sed -i.bak '/[[:space:]]swap[[:space:]]/d' /etc/fstab

for unit in $swapUnits; do
    sudo systemctl mask "$unit"
done
```

Reboot the target and verify that swap remains disabled before running `k2s node add`:

```bash
sudo reboot
```

After reconnecting:

```bash
sudo swapon --show
```

The command must produce no output.

Do not install kubelet, Kubernetes, CRI-O, containerd, or CNI components manually. `k2s node add` installs and configures the required worker-node components.

### Network requirements

- **Bare-metal target**: the target IP must be in a physical network subnet (LAN/Wi-Fi/Ethernet) reachable by the Windows host. It must not be an address from the K2s internal KubeSwitch network.
- **Existing Hyper-V VM**: attach the VM to KubeSwitch, keep it running, and assign it an IP in the KubeSwitch CIDR, for example `172.19.1.x`. The Windows host's KubeSwitch network profile must be `Private`.
- Verify reachability from the K2s host before continuing:

```powershell
Test-NetConnection -ComputerName <node-ip> -Port 22
```

The command must report `TcpTestSucceeded : True`.

---

## Known Limitations

- Adding a Linux worker node is currently supported for *Debian 12* and *Debian 13*.
- The supported target can be either a physical host or a virtual machine, as long as SSH access and the OS requirements are met.
- The node IP address supplied to `k2s node add` must stay stable. Use a static IP address or a DHCP reservation.

---

## Online vs. Offline Node Add

`k2s node add` supports two installation modes for Linux worker nodes on either physical hosts or virtual machines:

- **Online mode**: the target node downloads or receives the required packages during provisioning.
- **Offline mode**: a prebuilt node package ZIP is supplied with `--node-package`, and *K2s* installs the node from the package contents instead of downloading artifacts from the internet.

Use offline mode when the new node has no internet connectivity, is behind a restricted proxy, or when you want reproducible node onboarding.

---

## Steps to Add a Supported Node

Before running `k2s node add`, make sure your target matches one of the supported types:

- **Bare-metal host**: reachable over SSH and IP belongs to a physical host subnet.
- **Existing Hyper-V VM**: reachable over SSH, connected to KubeSwitch, and currently running.

### 1. Install and verify the K2s SSH key

When K2s is installed, an SSH public key is available under the directory `%USERPROFILE%\.ssh\k2s\id_rsa.pub`.
This key must be copied to the Linux physical host or VM to establish communication and initiate the installation.

Copy the public key to the target. For example, from the K2s host:

```powershell
scp -o StrictHostKeyChecking=no "$env:USERPROFILE\.ssh\k2s\id_rsa.pub" <usernameOfNode>@<IpAddressOfNode>:/tmp/temp_k2s.pub
```

!!! hint "scp"
    The target user's password may be requested for this initial copy. The password is not needed by K2s after the public key is installed.

On the Debian 13 target, append the key and verify it:

```bash
cat /tmp/temp_k2s.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
grep -F "$(cat /tmp/temp_k2s.pub)" ~/.ssh/authorized_keys
```

From the K2s host, verify key-based, non-interactive access before starting provisioning:

```powershell
ssh -o BatchMode=yes -o StrictHostKeyChecking=no <usernameOfNode>@<IpAddressOfNode> "hostname; lsb_release -is; lsb_release -rs; sudo -n true"
```

The command should print the hostname, `Debian`, `13`, and complete without asking for a password. If `sudo -n true` fails, configure sudo for the selected user before continuing.

### 2. Add the new node with K2s CLI

Linux workers join through SSH. Node addition does not require a local Windows `kubeadm` process ID.

```cmd
k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection>
```

If the node should be installed **offline**, first create a node package and then pass it to `k2s node add`:

```console
k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection> --node-package <PathToNodePackageZip>
```

### 3. Check new node status

```cmd
k2s status -o wide
```

## Offline Installation of a Linux Worker Node

The offline workflow has two phases:

1. Build a node package on a machine that has access to the required artifacts.
2. Use that package while running `k2s node add` against the target machine.

### 1. Create the node package

Generate an OS-specific node package. This step requires an installed and running *K2s* cluster on the machine where you run the command. The local cluster proxy `http://172.19.1.1:8181` is used by default, so `--proxy` can be omitted; pass `-p` only to override it.

Example using `k2s.exe` directly from a local directory:

```console
.\k2s.exe system package --node-package --os debian12 --target-dir "D:\Linuxpackagetest" --name "debian12.zip"
```

You can also generate the package on an existing *K2s* host:

```console
k2s system package --node-package --os debian12 --target-dir "C:\out" --name "debian12-node.zip"
```

For Debian 13 nodes, create a Debian 13 package instead:

```console
k2s system package --node-package --os debian13 --target-dir "C:\out" --name "debian13-node.zip"
```

!!! note
    The node package contains Linux worker node artifacts such as `.deb` packages and container images needed during `k2s node add`.

!!! note
    The `--os` value must match the target node's distribution. Use the package built for the node you are adding.

!!! note
    The same workflow applies whether the target Linux node is a physical host or an existing VM.

### GPU Support for Offline Nodes

To add a GPU-capable worker node offline, create the node package with the `--include-gpu` flag:

```console
k2s system package --node-package --os debian13 --include-gpu --target-dir C:\output --name debian13-gpu.zip
```

Then add the node as usual:

```console
k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection> --node-package C:\output\debian13-gpu.zip
```

K2s automatically detects the NVIDIA GPU and configures GPU support using the bundled packages. If the target has no NVIDIA GPU, it joins as a regular worker.

!!! warning "Prerequisites"
    NVIDIA kernel drivers must be pre-installed on the target node. Verify with `nvidia-smi` before running `k2s node add`.

See [GPU Node addon](../user-guide/gpu-node.md#external-gpu-worker-nodes) for complete GPU worker documentation.

### 2. Prepare SSH access to the target node

Follow the SSH key setup described above:

- Copy `%USERPROFILE%\.ssh\k2s\id_rsa.pub` to the target node.
- Add it to the authorized SSH keys on the target node.

This step is required in both online and offline mode because `k2s node add` still connects to the node over SSH.

### 3. Add the node using the offline package

Run `k2s node add` and point it to the node package ZIP:

```console
k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection> --node-package C:\temp\debian13-node.zip
```

### 4. Verify the node joined successfully

```console
k2s status -o wide
```

You can also use `k2s node connect` or `k2s node exec` to confirm SSH connectivity to the node after provisioning.

## When the Node IP Changes

`k2s node add` stores the node IP address for later management operations. If the node gets a different LAN IP after a reboot or network change, SSH-based operations can fail.

Recommended handling:

1. Configure a static IP address or DHCP reservation for the node.
2. If the IP already changed, remove and re-add the node with the new IP:

```console
k2s node remove --name <NodeName>
k2s node add --ip-addr <NewIpAddress> --username <UserNameForRemoteConnection> --name <NodeName>
```

If you use offline installation, include `--node-package <PathToNodePackageZip>` again during the re-add operation.
