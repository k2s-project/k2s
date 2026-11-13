<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Configuration Reference

*K2s* uses several configuration files to control cluster behaviour, networking, and runtime state. This page documents all configuration files, their locations, and available settings.

## Install Configuration (YAML)

The `k2s install --config <file>` flag accepts a YAML file that controls how the cluster is created. Two base templates are provided:

### k2s.config.yaml (Host / Linux-Only)

```yaml
kind: k2s            # Setup type: k2s (default Host variant)
apiVersion: v1
nodes:
  - role: control-plane       # Required. Only control-plane is supported.
    resources:
      cpu: 6                  # Virtual CPUs for the Linux VM (default: 6)
      memory: 6GB             # RAM for the Linux VM (minimum: 2GB, default: 6GB)
      disk: 50GB              # Disk for the Linux VM (minimum: 10GB, default: 50GB)
env:
  httpProxy:                  # HTTP proxy URL (e.g. http://proxy:8080)
  additionalHooksDir:         # Path to directory with custom hook scripts
  restartPostInstallCount:    # Number of automatic cluster restarts after install
  k8sBins:                    # Path to locally-built Kubernetes binaries
installBehavior:
  showOutput: false           # Show installation log in terminal
  deleteFilesForOfflineInstallation: false  # Delete offline-only files after install
  forceOnlineInstallation: false           # Force re-download of all dependencies
  wsl: false                  # Use WSL 2 instead of Hyper-V for the Linux VM
  appendLog: false            # Append to existing log file instead of truncating
  skipStart: false            # Do not start the cluster after installation
kubeletOverrides:             # Optional; supported on Windows-host installations
  linuxControlPlane:
    enabled: true
    config:
      maxPods: 100
      systemReserved:
        cpu: "500m"
        memory: "1Gi"
      kubeReserved:
        cpu: "250m"
        memory: "512Mi"
  windowsWorker:
    enabled: true
    config:
      maxPods: 100
```

### buildonly.config.yaml (Development-Only)

```yaml
kind: buildonly       # Development-only setup (no K8s cluster)
apiVersion: v1
nodes:
  - role: control-plane
    resources:
      cpu: 6
      memory: 6GB
      disk: 50GB
env:
  httpProxy:
installBehavior:
  showOutput: false
  deleteFilesForOfflineInstallation: false
  forceOnlineInstallation: false
  wsl: false
  appendLog: false
```

!!! tip
    Use `kind: k2s` for the Host and Linux-Only variants. Use `kind: buildonly` for the Development-Only variant. The `kind` field determines which installation flow is executed.

### Key Fields

| Field | Type | Description |
|-------|------|-------------|
| `kind` | string | Setup type: `k2s` or `buildonly` |
| `nodes[].resources.cpu` | integer | Virtual CPU count for the Linux control-plane VM |
| `nodes[].resources.memory` | string | RAM with unit suffix (e.g. `6GB`) |
| `nodes[].resources.disk` | string | Disk size with unit suffix (e.g. `50GB`) |
| `env.httpProxy` | string | HTTP proxy for network access during install, in the form `[scheme://][user[:password]@]host[:port]`. Percent-encode special characters in the user and password (e.g. `$` as `%24`) |
| `env.additionalHooksDir` | string | Path to custom hook scripts (see [Hook System](hook-system.md)) |
| `env.restartPostInstallCount` | integer | Automatic restarts after install (useful for stabilization) |
| `env.k8sBins` | string | Path to locally-built K8s binaries (kubelet, kubeadm, kubectl) |
| `installBehavior.wsl` | boolean | Host Linux VM in WSL 2 instead of Hyper-V |
| `installBehavior.skipStart` | boolean | Install without starting the cluster |
| `kubeletOverrides.linuxControlPlane.enabled` | boolean | Manage the Linux control-plane kubelet drop-in |
| `kubeletOverrides.windowsWorker.enabled` | boolean | Manage the Windows worker kubelet drop-in when that role exists |
| `kubeletOverrides.<role>.config.maxPods` | positive integer | Maximum pods for the role |
| `kubeletOverrides.<role>.config.systemReserved.cpu` | quantity string | CPU reserved for operating-system processes |
| `kubeletOverrides.<role>.config.systemReserved.memory` | quantity string | Memory reserved for operating-system processes |
| `kubeletOverrides.<role>.config.kubeReserved.cpu` | quantity string | CPU reserved for Kubernetes processes |
| `kubeletOverrides.<role>.config.kubeReserved.memory` | quantity string | Memory reserved for Kubernetes processes |

Malformed `cpu`, `memory`, `disk`, `restartPostInstallCount` and `httpProxy` values as well as unknown roles, fields, invalid quantity strings, and mistyped values are rejected before installation starts. Omitting `kubeletOverrides` preserves previous behavior. See [Customizing Kubelet Configuration](customizing-kubelet.md) for topology and lifecycle details.

---

## Runtime Configuration (setup.json)

After installation, *K2s* persists cluster state in `setup.json`, located in the directory configured via `configDir.k2s` (default: `C:\ProgramData\K2s`). This file is managed automatically — do not edit it manually.

| Key | Type | Description |
|-----|------|-------------|
| `SetupType` | string | Active setup type: `k2s`, `buildonly`, or `linuxonly` |
| `Version` | string | Installed *K2s* product version |
| `ClusterName` | string | Cluster name (default: `k2s-cluster`) |
| `ControlPlaneNodeHostname` | string | Hostname of the Linux control-plane VM |
| `KubernetesVersion` | string | Installed Kubernetes version |
| `InstallFolder` | string | *K2s* installation directory |
| `WSL` | boolean | Whether WSL 2 mode is active |
| `LinuxOnly` | boolean | Whether the cluster runs Linux-only (no Windows worker) |
| `HostGW` | boolean | Whether flannel host-gateway mode is enabled |
| `Registries` | array | Configured container registries |
| `EnabledAddons` | array | List of enabled addons with implementation names |
| `Corrupted` | boolean | Whether the system is in a corrupted state |
| `UsedStorageLocalDriveLetter` | string | Drive letter used for local storage |
| `EffectiveInstallConfigPath` | string | Internal link to the protected normalized install configuration snapshot |

The effective snapshot is stored next to `setup.json` as `effective-install-config.json`. It contains the resolved embedded defaults, user configuration, and CLI overrides. K2s writes it atomically with restricted access, does not log its contents, and keeps it separate from `cfg\config.json`.

---

## Cluster Configuration (cluster.json)

Multi-node cluster topology is stored in `C:\ProgramData\K2s\cluster.json`. This file tracks every node in the cluster.

### Node Properties

| Property | Type | Values | Description |
|----------|------|--------|-------------|
| `Name` | string | | Hostname of the node |
| `IpAddress` | string | | IP address for SSH/API access |
| `Username` | string | | SSH username |
| `NodeType` | string | `HOST`, `VM-EXISTING` | How the node is provisioned |
| `Role` | string | `worker`, `control-plane` | Kubernetes role |
| `OS` | string | `windows`, `linux` | Node operating system |
| `Proxy` | string | | Per-node HTTP proxy |
| `PodCIDR` | string | | Per-node pod network CIDR |

**Node types:**

- `HOST` — the local Windows host machine acting as a worker node
- `VM-EXISTING` — a pre-existing VM or bare-metal machine joined to the cluster

Use `k2s node add` / `k2s node remove` to manage nodes rather than editing this file directly.

---

## Network Configuration (config.json)

The file `cfg\config.json` defines cluster-wide network addressing, registry mirrors, VFP rules, and backup exclusions. This file is read during installation and at runtime.

### Network CIDRs

| Key | Default | Description |
|-----|---------|-------------|
| `masterIP` | `172.19.1.100` | IP address of the Linux control-plane VM |
| `kubeSwitch` | `172.19.1.1` | Hyper-V virtual switch gateway |
| `masterNetworkCIDR` | `172.19.1.0/24` | Control-plane-to-host network |
| `podNetworkCIDR` | `172.20.0.0/16` | Cluster-wide pod network |
| `podNetworkMasterCIDR` | `172.20.0.0/24` | Pod network for the control-plane node |
| `podNetworkWorkerCIDR` | `172.20.1.0/24` | Pod network for the first Windows worker |
| `servicesCIDR` | `172.21.0.0/16` | Kubernetes service network |
| `servicesCIDRLinux` | `172.21.0.0/24` | Service subnet for Linux workloads |
| `servicesCIDRWindows` | `172.21.1.0/24` | Service subnet for Windows workloads |
| `kubeDnsServiceIP` | `172.21.0.10` | CoreDNS service IP |

### Loopback Adapter

| Key | Default | Description |
|-----|---------|-------------|
| `loopbackAdapterCIDR` | `172.22.1.0/24` | Loopback adapter network |
| `loopbackGateway` | `172.22.1.1` | Loopback gateway IP |
| `loopback` | `172.22.1.2` | Loopback adapter IP |

The loopback adapter provides a stable network path between the Windows host and cluster services regardless of the physical network configuration.

K2s sets `SkipAsSource` on the `loopback` address at every start, so that it is not returned when the host resolves its own computer name. See [Known Issues](../troubleshooting/known-issues.md#k2s-adapter-ips-returned-for-the-hosts-own-name).

### Storage

| Key | Default | Description |
|-----|---------|-------------|
| `storageLocalDriveLetter` | `""` (auto) | Drive letter for local persistent storage |
| `storageLocalDriveFolder` | `""` | Folder path for local persistent storage |

### Container Registries

| Key | Default | Description |
|-----|---------|-------------|
| `defaultRegistry` | `shsk2s.azurecr.io` | Default container registry |
| `mirrorRegistries` | Array | Registry mirror mappings |

Mirror registries allow redirecting image pulls from public registries to private mirrors:

```json
"mirrorRegistries": [
  {
    "registry": "docker.io",
    "server": "registry-1.docker.io",
    "mirror": "shsk2s.azurecr.io"
  }
]
```

### Backup Exclusions

The `backup` section configures what is excluded from `k2s system backup`:

| Key | Description |
|-----|-------------|
| `excludednamespaces` | Comma-separated namespaces to skip (system and addon namespaces) |
| `excludednamespacedresources` | Resource types to skip (e.g. `endpoints,endpointslices`) |
| `excludedclusterresources` | Cluster-scoped resource types to skip |
| `excludedaddonpersistentvolumes` | Addon PV names to skip |

### Configuration Directories

| Key | Default | Description |
|-----|---------|-------------|
| `configDir.ssh` | `~/.ssh` | SSH configuration directory |
| `configDir.kube` | `~/.kube` | Kubernetes config directory |
| `configDir.docker` | `~/.docker` | Docker config directory |
| `configDir.k2s` | `C:\ProgramData\K2s` | K2s runtime data directory |
| `clusterName` | `k2s-cluster` | Kubernetes cluster name |

---

## Containerd Configuration

The containerd template at `cfg\containerd\config.toml.template` is processed during installation with placeholder substitution:

| Placeholder | Description |
|-------------|-------------|
| `%BEST-DRIVE%` | Installation drive letter |
| `%INSTALLATION_DIRECTORY%` | K2s installation path |
| `%CONTAINERD_TOKEN%` | Authentication token for the default registry |

Notable configuration features in the template:

- **OCI encrypted image support** — `ocicrypt` stream processors are configured for image decryption using keys at `C:\k\bin\certs\encrypt\`
- **Registry mirror config path** — `C:\etc\containerd\certs.d` for per-registry TLS/mirror configuration
- **Platform support** — configured for `windows/amd64` and `linux/amd64`
- **gRPC limits** — 16 MB max send/receive message size

---

## Flannel CNI Backends

Two CNI backend templates are available in `cfg\cni\`:

| Template | Backend | Description |
|----------|---------|-------------|
| `net-conf.json.template` | `host-gw` | Default. Routes pod traffic directly via host routing tables. Best performance. |
| `net-conf-vxlan.json.template` | `vxlan` | Encapsulates pod traffic in VXLAN tunnels (VNI 4096, port 4789). Use when host-gw is not feasible. |

---

## Kubeadm Templates

Join templates for additional nodes are in `cfg\kubeadm\`:

| Template | Purpose |
|----------|---------|
| `joinnode.template.yaml` | Windows worker node join configuration (kubeadm v1beta4) |
| `joinnode-linux.template.yaml` | Linux worker node join configuration |

---

## Libvirt Templates (Linux Host)

!!! note
    This section applies only to the **Linux Host** variant, which uses libvirt/KVM to provision the optional Windows worker VM.

Default libvirt XML templates are shipped in `cfg/libvirt/` and compiled into the `k2s` binary. At install time `k2s` checks for user-customised versions on disk **before** falling back to the built-in defaults.

### Template Files

| Template | Purpose |
|----------|---------|
| `cfg/libvirt/domain.xml.tmpl` | VM definition: CPU, memory, disk, UEFI firmware, Hyper-V enlightenments, VirtIO devices |
| `cfg/libvirt/network.xml.tmpl` | NAT network: bridge, DHCP range, static reservation for the Windows VM |

### Customising Templates

To customise the VM or network definition **before** running `k2s install`:

1. Copy the template to the K2s config directory:

    ```console
    sudo mkdir -p /var/lib/k2s/libvirt
    sudo cp cfg/libvirt/domain.xml.tmpl  /var/lib/k2s/libvirt/domain.xml.tmpl
    sudo cp cfg/libvirt/network.xml.tmpl /var/lib/k2s/libvirt/network.xml.tmpl
    ```

2. Edit the copies as needed. The files are standard Go `text/template` files — keep the `{{ .VariableName }}` placeholders intact.

3. Run `k2s install`. The installer will pick up the custom templates automatically and log:

    ```
    [Libvirt] Using custom template  path=/var/lib/k2s/libvirt/domain.xml.tmpl
    ```

If no custom file is found at `/var/lib/k2s/libvirt/<name>`, the compiled-in default is used.

### Domain Template Variables

| Variable | Type | Description |
|----------|------|-------------|
| `{{.Name}}` | string | VM name (e.g. `k2s-win-worker`) |
| `{{.MemoryKB}}` | integer | Memory in KiB |
| `{{.CPUCount}}` | integer | Number of vCPUs |
| `{{.DiskPath}}` | string | Absolute path to the QCOW2 disk image |
| `{{.NetworkBridge}}` | string | Libvirt network name (e.g. `k2s`) |
| `{{.FirmwarePath}}` | string | Path to OVMF UEFI firmware |
| `{{.NVRAMPath}}` | string | Path to per-VM EFI variable store |

### Network Template Variables

| Variable | Type | Description |
|----------|------|-------------|
| `{{.Name}}` | string | Network name (e.g. `k2s`) |
| `{{.BridgeName}}` | string | Bridge interface name (e.g. `virbr-k2s`) |
| `{{.HostIP}}` | string | Host-side IP on the bridge |
| `{{.Netmask}}` | string | Network mask |
| `{{.DHCPRangeStart}}` | string | First DHCP address |
| `{{.DHCPRangeEnd}}` | string | Last DHCP address |
| `{{.WinVMMac}}` | string | MAC address for the Windows VM (DHCP reservation) |
| `{{.WinVMIP}}` | string | Static IP assigned to the Windows VM |

### Common Customisations

**Increase VM memory and CPUs** — edit the install config YAML (`nodes[].resources.cpu` / `memory`) instead; the template variables are populated from that config.

**Change the network range** — edit `network.xml.tmpl` to alter `{{.HostIP}}`, DHCP range, and static reservation. Also update `cfg/config.json` network CIDRs to match.

**Add a second disk** — add a `<disk>` block to `domain.xml.tmpl` with a new `<source file='...'/>` path.

**Enable VNC/Spice console** — add a `<graphics>` element to the `<devices>` section in `domain.xml.tmpl`.

---

## See Also

- [Installing K2s](installing-k2s.md) — using config files during installation
- [Hook System](hook-system.md) — the `env.additionalHooksDir` config option
- [Networking Architecture](networking-architecture.md) — host-gw and network design details
