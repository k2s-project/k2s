<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Extending a K2s Cluster

This guide explains how to extend a K2s cluster by adding additional nodes. At the moment, the documented and supported workflow covers Linux worker nodes on physical hosts or existing virtual machines. Support for Windows worker nodes will follow.

## Prerequisites

Complete the following preparation on the K2s host and on the Debian 13 target before running `k2s node add`.

### K2s host

- K2s is installed and the cluster is running and healthy.

=== "Windows host"

    - Run the command from an elevated PowerShell or command prompt on the K2s Windows host.
    - The K2s SSH key pair exists. The public key is `%USERPROFILE%\.ssh\k2s\id_rsa.pub`.

=== "Linux host (experimental)"

    - Run `k2s` with `sudo` on the Debian 13 host.
    - The K2s SSH key pair is created by `k2s install`. The public key is `/root/.ssh/k2s/id_ed25519.pub`. The location and file names are configured in the `sshKey` section and `configDir.ssh` of `cfg/config.json`, see the [configuration reference](configuration-reference.md#ssh-key).
    - `k2s node add` records the SSH host key of the node in `/root/.ssh/known_hosts` on first contact (trust on first use).

### Debian 13 target

- Install Debian 13 (Trixie) on a physical machine or an existing VM. The target must not already be a member of a Kubernetes cluster.
- Configure a stable IPv4 address, either statically or with a DHCP reservation. K2s stores the address supplied to `k2s node add` for later node operations.
- Set a hostname containing only lowercase letters. K2s uses the remote hostname as the Kubernetes node name.
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

### Changes made to a Debian 13 target

`k2s node add` hardens Debian 13 targets for their dedicated worker role. These changes remain in place, also after `k2s node remove`:

- The `apt-daily` and `apt-daily-upgrade` services and timers are masked, so the machine no longer installs updates automatically. `motd-news.timer` is disabled when present.
- Installed documentation and editor packages, for example `man-db`, `manpages`, `groff-base`, `nano` and `vim-tiny`, are purged together with dependencies that are no longer needed.
- Documentation under `/usr/share/doc`, `/usr/share/man` and related directories is removed, and `/etc/dpkg/dpkg.cfg.d/01_nodoc` prevents later package installations from adding it again. Copyright and license files are kept.

Removed package names and versions are recorded in `/var/lib/k2s/hardening/reinstall.tsv`. Use a machine dedicated to the worker role and keep it patched through your controlled update process. If the machine is later used for other purposes, restore automatic updates and documentation installation manually, and reinstall required packages:

```bash
sudo systemctl unmask apt-daily.service apt-daily.timer apt-daily-upgrade.service apt-daily-upgrade.timer
sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
sudo rm /etc/dpkg/dpkg.cfg.d/01_nodoc
```

For details, see [Debian 13 Node Hardening](../security/security-features.md#debian-13-node-hardening).

### Network requirements

=== "Windows host"

    - **Bare-metal target**: the target IP must be in a physical network subnet (LAN/Wi-Fi/Ethernet) reachable by the Windows host. It must not be an address from the K2s internal KubeSwitch network.
    - **Existing Hyper-V VM**: attach the VM to KubeSwitch, keep it running, and assign it an IP in the KubeSwitch CIDR, for example `172.19.1.x`. The Windows host's KubeSwitch network profile must be `Private`.
    - Verify reachability from the K2s host before continuing:

        ```powershell
        Test-NetConnection -ComputerName <node-ip> -Port 22
        ```

        The command must report `TcpTestSucceeded : True`.

=== "Linux host (experimental)"

    - The target is a physical machine or a VM outside of K2s, for example in the host's LAN. The node IP must not be in one of the K2s networks (`masterNetworkCIDR`, `podNetworkCIDR`, `servicesCIDR` in `cfg/config.json`).
    - The node reaches the API server on the host's primary IP address (TCP 6443), and the host reaches the node on TCP 22 (SSH) and TCP 10250 (kubelet).
    - With `k2s install --linux-only`, Flannel uses VXLAN: UDP 8472 must be open in both directions between host and node. The node may be in another subnet if it is routed.
    - With the default install (managed Windows worker), Flannel uses `host-gw`: the node must be in a subnet directly connected to the host (same layer-2 network). `k2s node add` checks this before it changes the node, and installs the `k2s-routes` service on the node, which routes the K2s switch and pod networks via the host.
    - Verify reachability from the K2s host before continuing (`nc` is in the Debian package `netcat-openbsd`):

        ```bash
        nc -vz <node-ip> 22
        ```

        The command must report that the connection succeeded.

---

## Known Limitations

- Adding a Linux worker node is currently supported for *Debian 12* and *Debian 13* on a Windows host, and for *Debian 13* only on a Linux host.
- The supported target can be either a physical host or a virtual machine, as long as SSH access and the OS requirements are met.
- The node IP address supplied to `k2s node add` must stay stable. Use a static IP address or a DHCP reservation.
- On a Linux host, GPU workers are not supported yet: `k2s node add` does not configure the NVIDIA Container Toolkit.

---

## Architecture Support (amd64 / arm64)

`k2s node add` auto-detects the target node's CPU architecture over SSH (no `--arch` flag on `node add` itself). **arm64 is supported only for bare-metal/external Debian-family worker nodes** (not Hyper-V guests — Hyper-V on an x86 host cannot run an arm64 guest, so an arm64 control plane or an arm64 Hyper-V worker VM are out of scope). If the detected architecture is arm64 and the distribution is not Debian-family, `k2s node add` fails fast with an "unsupported architecture/distro combination" error before any provisioning starts.

Only **Debian 13 arm64** is tested/validated (see the arm64 CI lanes in `k2s-project/k2s`'s `.github/workflows/`). Debian 12 arm64 runs the same code path but is untested.

Building an **offline node package for arm64** (`k2s system package --node-package --arch arm64`) must run natively on a Linux arm64 host — there is no cross-build or VM path, since the existing Windows/Hyper-V build can only produce amd64 packages. See [Offline Installation of a Linux Worker Node](#offline-installation-of-a-linux-worker-node) below.

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
- **Existing Hyper-V VM** (Windows host only): reachable over SSH, connected to KubeSwitch, and currently running.

### 1. Install and verify the K2s SSH key

When K2s is installed, an SSH public key is available on the K2s host.
This key must be copied to the Linux physical host or VM to establish communication and initiate the installation.
K2s does not install the key on the node for you; it has to be authorized before `k2s node add`.

Copy the public key to the target. For example, from the K2s host:

=== "Windows host"

    ```powershell
    scp -o StrictHostKeyChecking=no "$env:USERPROFILE\.ssh\k2s\id_rsa.pub" <usernameOfNode>@<IpAddressOfNode>:/tmp/temp_k2s.pub
    ```

=== "Linux host (experimental)"

    ```bash
    sudo scp -o StrictHostKeyChecking=no /root/.ssh/k2s/id_ed25519.pub <usernameOfNode>@<IpAddressOfNode>:/tmp/temp_k2s.pub
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

=== "Windows host"

    ```powershell
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "$env:USERPROFILE\.ssh\k2s\id_rsa" <usernameOfNode>@<IpAddressOfNode> "hostname; lsb_release -is; lsb_release -rs; sudo -n true"
    ```

=== "Linux host (experimental)"

    ```bash
    sudo ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i /root/.ssh/k2s/id_ed25519 <usernameOfNode>@<IpAddressOfNode> "hostname; lsb_release -is; lsb_release -rs; sudo -n true"
    ```

The command should print the hostname, `Debian`, `13`, and complete without asking for a password. If `sudo -n true` fails, configure passwordless sudo for the selected user before continuing.

### 2. Add the new node with K2s CLI

=== "Windows host"

    ```console
    k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection>
    ```

    If the node should be installed **offline**, first [create a node package](#offline-installation-of-a-linux-worker-node) and then pass it to `k2s node add`:

    ```console
    k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection> --node-package <PathToNodePackageZip>
    ```

=== "Linux host (experimental)"

    ```console
    sudo k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection>
    ```

    If the node should be installed **offline**, first [create a node package](#offline-installation-of-a-linux-worker-node) and then pass it to `k2s node add`:

    ```console
    sudo k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection> --node-package <PathToNodePackageZip>
    ```

    In online mode the node downloads the Debian packages for its own architecture and pulls the container images itself. Like on a Windows host, the node uses the proxy given at `k2s install` (stored in `/var/lib/k2s/proxy.conf`); without one it needs direct internet access. The local cluster proxy `http://172.19.1.1:8181` of a Linux host only accepts clients from the K2s networks (for example `172.19.1.0/24`) and the host itself; it rejects nodes with other addresses, such as a node in the host's LAN.

    The node gets the role `worker` and is recorded in `/var/lib/k2s/cluster.json`. The command logs to `/var/log/k2s.log`.

### 3. Check new node status

```console
k2s status -o wide
```

### If adding the node fails (Linux host)

On a Linux host, `k2s node add` stops at the first failing step and collects diagnostics from the node into `/var/log/k2s.log`. The node entry in `cluster.json` is kept, so a second `k2s node add` for the same node is rejected. Fix the cause, then clean up and add the node again:

```console
sudo k2s node remove --name <NodeName>
sudo k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection>
```

If the node's operating system or architecture is not supported, the command ends with a warning before it changes the node.

## Offline Installation of a Linux Worker Node

The offline workflow has two phases:

1. Build a node package on a machine that has access to the required artifacts.
2. Use that package while running `k2s node add` against the target machine.

### 1. Create the node package

Generate an OS-specific node package.

=== "Windows host"

    This step requires an installed and running *K2s* cluster on the machine where you run the command. The local cluster proxy `http://172.19.1.1:8181` is used by default, so `--proxy` can be omitted; pass `-p` only to override it.

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

=== "Linux host (experimental)"

    The package is built with the build host's own `apt`, so the build host must run the same Debian release and architecture as the node (see [Node Package on a Linux Host](creating-offline-package.md#node-package-on-a-linux-host)):

    ```console
    sudo k2s system package --node-package --os debian13 --target-dir /tmp/out --name debian13-node.zip
    ```

    `k2s node add` checks that the package architecture matches the node before it changes the node.

!!! note
    The node package contains Linux worker node artifacts such as `.deb` packages and container images needed during `k2s node add`.

!!! note
    The `--os` value must match the target node's distribution. Use the package built for the node you are adding.

!!! note
    The same workflow applies whether the target Linux node is a physical host or an existing VM.

### arm64 node packages

An arm64 node package must be built **on a Linux arm64 host** with `sudo`/root privileges — not on the Windows K2s host, and not cross-compiled. There is no Hyper-V VM involved; the build host's own `apt` is used directly, and the host needs `skopeo` (see [Node Package on a Linux Host](creating-offline-package.md#node-package-on-a-linux-host)):

```console
sudo k2s system package --node-package --os debian13 --arch arm64 --target-dir /tmp/out --name debian13-node-arm64.zip
```

The package contains the `.deb` packages and the Kubernetes, flannel and (with `--include-gpu`) NVIDIA container images as OCI archives, like the amd64 package.

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

!!! note "Linux host (experimental)"
    GPU workers are not supported on a Linux host yet: `k2s node add` does not configure GPU support, also not from a GPU package.

!!! warning "Prerequisites"
    NVIDIA kernel drivers must be pre-installed on the target node. Verify with `nvidia-smi` before running `k2s node add`.

See [GPU Node addon](../user-guide/gpu-node.md#external-gpu-worker-nodes) for complete GPU worker documentation.

### 2. Prepare SSH access to the target node

Follow the [SSH key setup](#1-install-and-verify-the-k2s-ssh-key) described above: copy the K2s public key to the target node and add it to the authorized SSH keys there.

This step is required in both online and offline mode because `k2s node add` still connects to the node over SSH.

### 3. Add the node using the offline package

Run `k2s node add` (with `sudo` on a Linux host) and point it to the node package ZIP:

```console
k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection> --node-package C:\temp\debian13-node.zip
```

### 4. Verify the node joined successfully

```console
k2s status -o wide
```

You can also use `k2s node connect` or `k2s node exec` to confirm SSH connectivity to the node after provisioning.

## Starting, Stopping and Removing Added Nodes

`k2s stop` and `k2s start` also stop and start the added nodes. To stop or start a single node, pass its name:

```console
k2s stop --node <NodeName>
k2s start --node <NodeName>
```

On a Linux host, run the commands with `sudo`. Stopping a node stops kubelet, its pods, and CRI-O on it; starting waits until the node is `Ready` again.

To remove a node from the cluster:

```console
k2s node remove --name <NodeName>
```

The cluster must be running. The node is drained and deleted from the cluster. If it is reachable, K2s resets Kubernetes on it and removes the installed Kubernetes and CRI-O packages and the K2s configuration; the [hardening changes](#changes-made-to-a-debian-13-target) remain. If this cleanup on the node fails, the command ends with a warning and details in the log. The node can be added again afterwards.

`k2s node remove` does not revoke the SSH access you set up in [Install and verify the K2s SSH key](#1-install-and-verify-the-k2s-ssh-key): the K2s host can still log in to the node. If the node does not rejoin, remove the K2s public key on the node and revoke the `sudo` rights you granted for *K2s*. Print the key on the K2s host:

=== "Windows host"

    ```powershell
    Get-Content "$env:USERPROFILE\.ssh\k2s\id_rsa.pub"
    ```

=== "Linux host (experimental)"

    ```bash
    sudo cat /root/.ssh/k2s/id_ed25519.pub
    ```

Then remove it on the node:

```bash
key='<K2sPublicKey>'
grep -vF "$key" ~/.ssh/authorized_keys > /tmp/authorized_keys || true
cat /tmp/authorized_keys > ~/.ssh/authorized_keys && rm /tmp/authorized_keys
```

!!! warning "Linux host (experimental)"
    `k2s uninstall` does not remove added nodes yet. Remove them with `sudo k2s node remove` before uninstalling *K2s*.

## When the Node IP Changes

`k2s node add` stores the node IP address for later management operations. If the node gets a different LAN IP after a reboot or network change, SSH-based operations can fail.

Recommended handling:

1. Configure a static IP address or DHCP reservation for the node.
2. If the IP already changed, remove and re-add the node with the new IP:

```console
k2s node remove --name <NodeName>
k2s node add --ip-addr <NewIpAddress> --username <UserNameForRemoteConnection>
```

If you use offline installation, include `--node-package <PathToNodePackageZip>` again during the re-add operation.
