<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors
SPDX-License-Identifier: MIT
-->

# Installing *K2s*
## Prerequisites
- *K2s* folder being available locally, see [Getting *K2s*](getting-k2s.md)
- The *Windows* host must match one of the [Supported OS Versions](os-support.md)
- Local admin permissions are currently needed in order to be able to create virtual switches, VMs, etc.
- Please try to install from an folder which is available on `C:\` drive, since most open-source components assume this. We are testing the solution also on other drives, but cannot guarantee that the cluster will work fully.
- Hardware: The system should offer at least 2GB RAM free, as well as 10GB disk space free. Recommended are at least 6 CPU cores, but less are possible.
- CPU virtualization must be enabled in the BIOS. To verify, open the *Task Manager* and check the *Virtualization* property on the *Performance* tab:<br/>
 ![Check Virtualization](assets/check_virtualization.png)
 <br/>If you run the setup inside a VM, enable nested virtualization (e.g. when using *Hyper-V*:<br/>
 ```powershell
 Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true
 ```
 , see [Configure Nested Virtualization](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/enable-nested-virtualization#configure-nested-virtualization){target="_blank"} for details).
- *Docker* (Desktop) must not be running. Either stop *Docker* and set it to start manually or uninstall it completely
- *PowerShell* execution policy must be **RemoteSigned** or less restrictive. To set the policy, run:
  ```powershell 
  Set-ExecutionPolicy RemoteSigned -Force
  ```
- *curl.exe*: the installed version in the *Windows* host must be at least **7.71.0** (to check it call `curl.exe --version` from the command shell).
- *Optional: ssh.exe*: the installed version in the *Windows* host must be at least major version **8** to prevent the installation from hanging in certain situations (to check it call `ssh.exe -V` from the command shell). Normally, only Windows Server 2019 does not fulfill this requirement from the supported operating systems.
- *Optional:* Enable required *Windows Features* beforehand (they will get enabled during the installation anyways, but would require a system restart and installation re-run):
  - *Windows 10/11*
    ```powershell
    Enable-WindowsOptionalFeature -Online -FeatureName $('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V', 'Microsoft-Hyper-V-Tools-All', 'Microsoft-Hyper-V-Management-PowerShell', 'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Services', 'Microsoft-Hyper-V-Management-Clients', 'Containers', 'VirtualMachinePlatform') -All -NoRestart
    ``` 
  - *Windows Server* OSs
    ```powershell 
    Enable-WindowsOptionalFeature -Online -FeatureName $('Microsoft-Hyper-V', 'Microsoft-Hyper-V-Management-PowerShell', 'Containers', 'VirtualMachinePlatform') -All -NoRestart
    ``` 
- *Hyper-V configuration*: after the enabling of Hyper-V on your host using [Set-VMHost](https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmhost) different settings can be configured for Hyper-V, for example in some cases it makes sense to have new default locations for virtual hard disks on that host. Please checkout all possibilities and configure Hyper-V on your host as wanted before doing an install of k2s !


- *Installing in WSL mode*: Enable the WSL 2 feature on Windows. For detailed instructions, see [Configure WSL](https://learn.microsoft.com/windows/wsl/install) or [Manual install (older WSL versions)](https://learn.microsoft.com/windows/wsl/install-manual)
   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName $('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') -All
   ``` 
  
- *VC Runtime 140*: please install the VC runtime dlls, either with choco

   ```choco install vcredist140 -y```

   or download them from [Microsoft](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) directly and install the appropriate VC runtime.

!!! tip
    Environment variables HTTP_PROXY and HTTPS_PROXY shall not be used in Windows when creating a cluster. Usage of an HTTP proxy shall be configured in `control panel` at the `network and internet` section.
    *K2s* will always take the proxy automatically from the Windows proxy configuration and will use that setting (in this case also local networks can be addressed).


## Installation via *k2s* CLI
The *K2s* setup provides a variety of installation options. Based on the [Hosting Variants](../user-guide/hosting-variants.md), select one of the following setup variants:

 - [Option 1: Host](#option-1-host-default) (Default, *Windows* host acts as a worker node).
 - [Option 2: Development-Only](#option-2-development-only) (no *K8s* cluster, for building and testing containers only)

To inspect the different install options, run:
```console
<repo>\k2s.exe install -h
```
!!! warning
    If the installer detects more than one `k2s.exe` in your system `PATH`, installation will fail.
    Please review the error message for all detected `k2s.exe` locations and remove any outdated or duplicate directories from your `PATH` environment variable before retrying installation.

!!! info
    By default, the installation assumes 6 CPU cores to be available on the host system. If less cores are available, reduce the number of virtual cores used by *K2s* according to the actual amount, e.g. when 4 cores are available, assign max. 4 virtual cores to *K2s*:
    ```console
    <repo>\k2s.exe install --master-cpus 4
    ```

!!! tip
    If you acquired *K2s* via [Cloning the *Git* repository](getting-k2s.md#option-1-cloning-git-repository), you might want to checkout a specific version first, e.g.:
    ```console
    git checkout tags/v1.4.0
    ```
    Also make sure you have built the Go binaries (`.\bin\bgow` on *Windows*, `./bin/bgol` on *Linux*) as described in the [cloning instructions](getting-k2s.md#option-1-cloning-git-repository).

!!! note
    *K2s* will start automatically after the installation has finished.

!!! note "Control-plane base-image preparation"
    When `k2s install` prepares a new control-plane base image, Buildah is installed
    separately from the Kubernetes packages. Registry configuration is restored
    after the Buildah packages are installed. Preparation stops on failed registry
    updates, CRI-O restart/readiness checks, or required image pulls instead of
    producing an unusable base image. CRI-O restart failures include service status
    and recent journal output in `k2s.log`.

!!! note "Windows reboot recovery"
    Post-reboot networking recovery defers to an active `k2s install` or
    `k2s start` operation, or a proxy reconfiguration (`k2s system proxy set`,
    `reset`, or `override add/delete`) that owns the Flannel restart.
    Other CLI commands, such as `k2s image import` or
    `k2s status`, do not suppress recovery of the Windows networking services.

!!! note "Windows loopback adapter discovery"
    During `k2s install`, Windows worker setup checks the device installer's exit
    code and logs its output. It waits for the loopback adapter to become visible
    using up to 31 queries, two seconds apart, rather than failing immediately
    after device creation. Existing loopback devices removed during setup must
    disappear before another device is installed; the same polling limit applies.
    Device-command failures, discovery timeouts and multiple adapters remain
    explicit installation errors. For diagnosis, inspect `k2s.log` in the configured
    log directory (normally `C:\var\log`) and `C:\Windows\INF\setupapi.dev.log`.
    This behavior applies to packages containing the fix, not older release packages.

### Installing Using Config Files
Instead of assembling many command-line parameters/flags to customize the installation, you can also pass a YAML file to the `k2s install` command configuring install parameters like node resource definitions (e.g. CPU, RAM or size of the hard drive):
```console
<repo>\k2s.exe install [-c|--config] <path-to-config-file>
```

!!! example
    Create a custom install config:
    ```yaml linenums="1" title="my_config.yaml"
    kind: k2s
    apiVersion: v1
    nodes:
      - role: control-plane
        resources:
          cpu: 8
          memory: 7GB
          disk: 60GB
    env:
      httpProxy: 192.168.178.100:8765
    installBehavior:
      showOutput: true
    ```
    Start the installation passing this config:
    ```console
    <repo>\k2s.exe install -c c:\temp\my_config.yaml
    ```

!!! example "Dynamic Memory Config"
    Enable dynamic memory with custom minimum and maximum values:
    ```yaml linenums="1" title="dynamic_memory_config.yaml"
    kind: k2s
    apiVersion: v1
    nodes:
      - role: control-plane
        resources:
          cpu: 6
          memory: 4GB           # Startup memory (optional - see defaults below)
          memoryMin: 2GB        # Minimum memory (automatically enables dynamic memory)
          memoryMax: 8GB        # Maximum memory (automatically enables dynamic memory)
          disk: 50GB
    ```

!!! note "Dynamic Memory with Intelligent Defaults"
    - Specifying `memoryMin` or `memoryMax` automatically enables Hyper-V dynamic memory management
    
    **When only `memoryMin` is specified:**
    - VM starts with minimum memory for optimal resource efficiency
    - Maximum auto-calculated as 50% of host RAM (floor: 8GB, ceiling: 32GB)
    - Example: On 32GB host, VM can grow from 2GB → 16GB
    
    **When only `memoryMax` is specified:**
    - VM starts with default 6GB
    - Minimum auto-calculated as 30% of startup (floor: 2GB)
    - Example: 6GB startup can shrink to 2GB when idle (saves 4GB!)
    
    **When both `memoryMin` and `memoryMax` are specified:**
    - VM starts with minimum memory
    - Full dynamic range between min and max available
    
    **To override auto-calculation:**
    - Set `memory` explicitly to control startup value (must be between min and max)

To create a user-defined configuration for any of the hosting variants, take one of the corresponding [Base Configuration Files](https://github.com/k2s-project/k2s/tree/main/cmd/k2s/cmd/install/config/embed){target="_blank"} as a template.

### Online vs. Offline
Downloading all dependencies (i.e. binaries) on-the-fly is referred to as *online* installation, whereas *offline* refers to an installation package containing parts of or all the dependencies. If *K2s* was acquired via [Downloading the Official Release Package](getting-k2s.md#option-2-downloading-official-release-package), parts of the dependencies are already available locally. If an offline package was create according to [Creating Offline Package](creating-offline-package.md), all dependencies are available offline.

As per default, the *k2s* CLI keeps downloaded files as well as the *Linux*-based control-plane image and reuses them. To change this behavior, use the following CLI flags (they apply to all installation variants[^1]).

To delete all downloaded binaries and the control-plane image after installation, run:
```console
<repo>\k2s.exe install -d
```

To force the download of all binaries and the re-creation of the control-plane image regardless of their local presence, run:
```console
<repo>\k2s.exe install -f
```

??? info "Offline vs. Online Installation Diagram"
   ```mermaid
   graph TD
       CallScript["Installation scripts\n (Default, BuildOnlySetup)\n\n with\n [-DeleteFilesForOfflineInstallation]\n [-ForceOnlineInstallation]"] --> if_force_online_installation{"Switch\n ForceOnlineInstallation\n used ?"}
       if_force_online_installation --> |yes| BuildAndProvisionKubemasterBaseImage
       if_force_online_installation --> |no| if_base_image_available{"c\k\bin\Kubemaster-Base.vhdx\n available?"}
       if_base_image_available --> |yes| CopyBaseImage
       if_base_image_available --> |no| BuildAndProvisionKubemasterBaseImage
       BuildAndProvisionKubemasterBaseImage("Build and provision base image") --> PublishBaseImage("Publish base image as\n c\k\bin\Kubemaster-Base.vhdx")
       PublishBaseImage --> CopyBaseImage("Copy published base image to\n C\Users\Public\Documents\Hyper-V\Virtual hard disks")
       CopyBaseImage --> InstallLinuxNode("Install Linux node")
       InstallLinuxNode --> if_delete_files_for_offline_installation{"Switch\n -DeleteFilesForOfflineInstallation\n used ?"}
       if_delete_files_for_offline_installation --> |yes| DeleteBaseImage("Delete file c\k\bin\Kubemaster-Base.vhdx")
       if_delete_files_for_offline_installation --> |no| End
       DeleteBaseImage --> End
   ```

[^1]: Creating of and installing from an offline package is currently supported for [Host Variant](../user-guide/hosting-variants.md#host-default) and [Development-Only](../user-guide/hosting-variants.md#development-only) only. 

### \[Option 1\] Host (Default)
Simply run:
```console
<repo>\k2s.exe install
```

#### WSL
To install the control-plane in WSL 2 instead of a dedicated *Linux* VM, run:
```console
<repo>\k2s.exe install --wsl
```

### \[Option 2\] Development-Only
To build and test containers without a *K8s* cluster, run:
```console
<repo>\k2s.exe install buildonly
```

### \[Experimental\] Linux Host

The native Linux-host implementation supports **Debian 13**. The Kubernetes
control plane runs directly on the host and uses **CRI-O** as its container
runtime. By default, K2s also provisions one K2s-managed Windows worker with
libvirt/KVM. Use `--linux-only` to install the native control plane without a
Windows worker.

Run the Linux binary with elevated privileges:

```console
sudo ./k2s install --linux-only --proxy http://proxy.example:8080 --no-proxy localhost,127.0.0.1

# Install the native control plane and a managed Windows worker from a prepared QCOW2 image.
sudo ./k2s install --worker-cpus 4 --worker-memory 8GB --worker-disk 64GB --windows-qcow2-path /path/to/WindowsWorker-Base.qcow2
```

The equivalent platform-first lifecycle entry point is
`lib/scripts/linux/debian/linuxonly/Install.sh`. It validates root access,
records the dispatch in `/var/log/k2s.log`, and invokes the same `k2s` CLI
implementation. The sibling `Start.sh`, `Stop.sh`, `Status.sh`, and
`Uninstall.sh` scripts use that same lifecycle module. The corresponding
`lib/scripts/linux/debian/host/` scripts delegate to these entry points; they
do not maintain a separate native Linux implementation.

The installer downloads the version-pinned Kubernetes and CRI-O Debian
packages, then starts a local `httpproxy` service on `127.0.0.1:8181`. The
service forwards external traffic through `--proxy` when supplied. The given
`--no-proxy` values are merged with K2s internal addresses and applied only to
K2s services; the installer does not change global proxy environment settings.

For workload pods and the managed Windows worker, the same proxy is available at the configured
`smallsetup.kubeSwitch` address from [cfg/config.json](https://github.com/k2s-project/k2s/blob/main/cfg/config.json){target="_blank"}
on port `8181`. The Linux implementation creates a K2s-owned `k2s-switch`
libvirt NAT network with the same addressing contract as KubeSwitch. The proxy
only accepts loopback, pod-CIDR, service-CIDR, and K2s-switch clients.

The managed worker requires nested virtualization, `/dev/kvm`, a running
`libvirtd` or `virtqemud`, `virsh`, `qemu-img`, OpenSSH tools, and a minimum remaining host
reserve of 2GB memory and 20GB disk after the worker allocation. Worker memory
must not exceed 75% of total host memory. Its default
allocation is 4 CPUs, 8GB RAM, and a 64GB disk. K2s owns the domain, disk,
network, and lifecycle; `k2s uninstall` removes these K2s-managed resources.

For the first installation, supply a prepared Windows worker image with
`--windows-qcow2-path`. K2s validates the QCOW2 format, imports it into the
managed base-image cache at `/var/lib/libvirt/images/k2s/WindowsWorker-Base.qcow2`,
and creates a disposable QCOW2 overlay from that cache for the worker. For
repeatable offline use, preserve the cached image under
`/var/lib/libvirt/images/k2s/` for later installations.

Prepare the image with the temporary `remote` password bootstrap used to install
the generated worker SSH key. See [Preparing a Windows Worker
QCOW2](preparing-windows-worker-qcow2.md).

The worker automatically selects legacy BIOS for an MBR partition table and
standard OVMF UEFI for GPT. Its VNC console listens only on `127.0.0.1`; use
`sudo virsh vncdisplay k2s-win-worker` to obtain the display number when
diagnosing a failed boot. On an SSH timeout, K2s saves a console screenshot at
`/var/lib/k2s/k2s-win-worker-console.png`.

The following options are intentionally unavailable on a native Linux host:

- `--master-cpus`, `--master-memory`, `--master-disk`, dynamic-memory options,
  and `--wsl`
- `--force-online-installation`, offline artifact cleanup, and `--k8s-bins`

Native Linux exposes `--worker-cpus`, `--worker-memory`, `--worker-disk`, and
`--windows-qcow2-path`; Windows hosts do not expose these options. In an install
configuration, the corresponding resource fields belong to the `worker` node
entry and `windowsQCOW2Path` supplies the prepared image location.

The administrator invoking `sudo` receives the generated kubeconfig at
`~/.kube/config` after a successful installation.

## WSL 2 vs. Hyper-V

The Linux control-plane VM can be hosted in either Hyper-V (default) or WSL 2. The table below summarises the trade-offs:

| Aspect | Hyper-V (default) | WSL 2 (`--wsl`) |
|--------|-------------------|-----------------|
| Isolation | Full hardware-level VM | Lightweight utility VM, shared kernel |
| Startup time | Slower (full VM boot) | Faster (managed by Windows) |
| Resource overhead | Higher (dedicated memory reservation) | Lower (dynamic memory) |
| Nested virtualisation | Required when running inside a VM | Required when running inside a VM |
| L2Bridge networking | Yes | Yes |
| DNSProxy support | Yes | Yes |
| HttpProxy support | Yes | Yes |
| VFP rules | Yes | No |
| Disk passthrough | Dedicated VHDX | WSL 2 managed VHDX |

!!! tip
    Use Hyper-V for production-like environments and full feature support. Use WSL 2 for development environments where faster startup and lower overhead are preferred.

See the [Hosting Variants Features Matrix](../dev-guide/hosting-variants-features-matrix.md) for the complete feature comparison.

## Advanced Installation Options

### Install Without Starting

To install the cluster without automatically starting it (useful for pre-provisioning):

```console
<repo>\k2s.exe install --skip-start
```

Start the cluster later with `k2s start`.

### Using Locally-Built Kubernetes Binaries

For development or testing with custom Kubernetes builds:

```console
<repo>\k2s.exe install --k8s-bins "C:\path\to\k8s-binaries"
```

The directory must contain the Kubernetes binaries (kubelet, kubeadm, kubectl, kube-proxy).

### Post-Install Restarts

The `restartPostInstallCount` config option triggers automatic cluster restarts after installation. This can help stabilise the cluster on systems where the first start encounters transient issues:

```yaml
env:
  restartPostInstallCount: 1
```

### Configuration Reference

For the full list of configuration files and their settings (network CIDRs, registry mirrors, runtime state, and more), see the [Configuration Reference](configuration-reference.md).
