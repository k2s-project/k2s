<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Architecture & Tools

This page describes the high-level architecture of a *K2s* cluster, the Go CLI structure, the supporting tools bundled with the distribution, and the layout of the PowerShell and Bash automation.

## High-Level Architecture

*K2s* supports two host configurations: a **Windows host** (the original and default) and a **Linux host** (inverted setup, **experimental**). Both produce a Kubernetes cluster with a Linux control plane and an optional worker node of the opposite OS.

### Windows Host (Default)

A single Windows machine runs the CLI, PowerShell modules, and a Linux VM as the Kubernetes control plane:

```
┌─────────────────────────────────────────────────────────┐
│  Windows Host                                           │
│                                                         │
│  ┌──────────────────┐    ┌───────────────────────────┐  │
│  │ Windows Worker   │    │ Linux VM (KubeMaster)     │  │
│  │                  │    │                           │  │
│  │ • containerd     │    │ • CRI-O                   │  │
│  │ • kubelet        │    │ • kubelet                 │  │
│  │ • kube-proxy     │    │ • kube-apiserver          │  │
│  │ • flannel (CNI)  │    │ • kube-scheduler          │  │
│  │ • Docker (opt.)  │    │ • kube-controller-manager │  │
│  │                  │    │ • etcd                    │  │
│  └──────────────────┘    │ • flannel (CNI)           │  │
│                          │ • CoreDNS                 │  │
│  k2s.exe CLI             │ • buildah                 │  │
│  httpproxy.exe           └───────────────────────────┘  │
│  PowerShell modules                                     │
│                                                         │
│  ─── Hyper-V / WSL 2 ────────────────────────────────── │
└─────────────────────────────────────────────────────────┘
```

On Windows, the CLI delegates platform operations to PowerShell scripts under `lib/scripts/windows/` which use the modules under `lib/modules/windows/`.

### Linux Host (Inverted Setup, Experimental)

A Debian 13 Linux machine runs the CLI natively, hosts the Kubernetes control plane directly, and can provision a Windows VM as an optional worker node:

```
┌─────────────────────────────────────────────────────────┐
│  Linux Host (Debian 13)                                 │
│                                                         │
│  ┌───────────────────────┐    ┌──────────────────────┐  │
│  │ Linux Control Plane   │    │ Windows VM (Worker,  │  │
│  │                       │    │ optional)            │  │
│  │ • CRI-O               │    │                      │  │
│  │ • kubelet             │    │ • containerd         │  │
│  │ • kube-apiserver      │    │ • kubelet            │  │
│  │ • kube-scheduler      │    │ • kube-proxy         │  │
│  │ • kube-controller-mgr │    │ • flannel (CNI)      │  │
│  │ • etcd                │    └──────────────────────┘  │
│  │ • flannel (CNI)       │                              │
│  │ • CoreDNS             │    k2s CLI (native binary)   │
│  │ • buildah             │    Bash lifecycle scripts    │
│  └───────────────────────┘    No PowerShell required    │
│                                                         │
│  ─── KVM / libvirt (QEMU + OVMF UEFI) ───────────────── │
└─────────────────────────────────────────────────────────┘
```

On Linux, the CLI is a native Go binary with **no PowerShell dependency**:

- **Cluster lifecycle** (install, start, stop, uninstall, system reset) is dispatched by the Go provider through `internal/linux/lifecycle` to root-only Bash entry scripts in `lib/scripts/linux/debian/linuxonly/`. These scripts source the Bash modules in `lib/modules/linux/`, which run `kubeadm`, configure CRI-O, and provision the Windows worker VM via `virsh`/libvirt with OVMF UEFI firmware and VirtIO drivers.
- **Cluster status** (`k2s status`) stays Go-native (kubectl-based) to preserve its typed output contract.
- **Worker node join** (`k2s node add`) runs `lib/scripts/linux/debian/worker/bare-metal/Add.sh` and requires an offline node package (`--node-package`).
- **Image operations** dispatch to Bash scripts in `lib/scripts/linux/debian/host/image/` (CRI-O tooling and Buildah).
- **Addons, health checks, backup, and certificate operations** are implemented in Go.

Linux host support is experimental: the Linux provider registry prints an `[EXPERIMENTAL]` warning on every CLI invocation. See [Linux Host Capability Status](#linux-host-capability-status) for operations that are not yet available.

### Key Design Decisions

- **Flannel CNI with host-gateway mode** — routes pod traffic directly through host routing tables for maximum performance and simplicity. A VXLAN backend template is also available.
- **Mixed OS support** — Windows containers run on the Windows node via containerd; Linux containers run on the Linux node via CRI-O.
- **Offline-first** — all dependencies are bundled or downloadable as offline packages. No runtime network fetches unless explicitly triggered.
- **Single-binary CLI** — `k2s` is the only user-facing tool; all operations route through it.
- **Dual-platform host support** — the same CLI source is built for each platform via Go build tags (`k2s.exe` on Windows, `k2s` on Linux). Platform differences are encapsulated in the [Provider Architecture](#provider-architecture).
- **Provider abstraction** — command handlers are platform-agnostic; all platform-specific logic lives behind provider interfaces (see below).

### Hosting Variants

| Variant | `kind` | Host OS | Worker VM | Use Case |
|---------|--------|---------|-----------|----------|
| Host (default) | `k2s` | Windows | Linux VM (control plane + worker) | Full mixed-OS cluster |
| Host + Linux-Only | `k2s` + `--linux-only` | Windows | Linux VM (control plane only) | Linux-only workloads |
| Host + WSL 2 | `k2s` + `--wsl` | Windows | Linux VM via WSL 2 | Lighter footprint, shared kernel |
| Development-Only | `buildonly` | Windows | Linux VM | Container image building only, no K8s |
| Linux Host | `k2s` | Linux (Debian 13) | Windows VM (worker, optional) | **Experimental** — Inverted setup, Linux-native control plane |

See [Hosting Variants](../user-guide/hosting-variants.md) and the [Features Matrix](hosting-variants-features-matrix.md) for detailed comparisons.

---

## Go Code Structure

All Go code lives in a single module (`github.com/k2s-project/k2s`) at the repository root:

| Location | Purpose |
|----------|---------|
| `cmd/k2s/` | Cobra-based CLI. `main.go` is the entry point; commands live in `cmd/k2s/cmd/<command>/`; logging helpers in `cmd/k2s/utils/logging/`. |
| `cmd/<tool>/` | Supporting executables and container-image components (see [Bundled Tools](#bundled-tools)). |
| `internal/provider/` | Platform-agnostic provider interfaces with build-tagged Windows and Linux implementations. |
| `internal/core/`, `internal/contracts/` | Domain logic and shared models used by both commands and adapters. |
| `internal/providers/` | Concrete adapters: `powershell`, `bash`, `kubectl`, `k8s`, `ssh`, `kubeconfig`, `http`, `acl`, `osusers`. |
| `internal/linux/lifecycle/` | Dispatcher from the Linux cluster provider to the native Bash lifecycle scripts. |
| `internal/setuporchestration/` | Linux libvirt/KVM helpers (domain and network templates, VM management). Lifecycle orchestration itself is Bash-owned. |
| `internal/healthcheck/`, `internal/effectiveconfig/` | Read-only health checks (`k2s system check`) and effective configuration snapshots. |
| `internal/cli/`, `internal/output/`, `internal/logging/`, ... | Exit codes, streaming output, logging, and other shared utilities. |

See [internal/README.md](https://github.com/k2s-project/k2s/blob/main/internal/README.md){target="_blank"} for the full package overview.

---

## Provider Architecture

The Go CLI uses a **provider pattern** to abstract all platform-specific operations behind a set of domain interfaces. This decouples command handlers from platform details and makes it straightforward to add new host platforms.

### Design

```
┌──────────────────────────────────────────────────────────┐
│  Command Layer (cmd/k2s/cmd/)                            │
│  install, start, stop, status, image, node, system, ...  │
│                                                          │
│  context.Providers().Cluster.Install(config)             │
│  context.Providers().Image.Build(config)                 │
│  context.Providers().System.Package(config)              │
└──────────────┬───────────────────────────────────────────┘
               │ (interface calls)
┌──────────────▼───────────────────────────────────────────┐
│  Provider Interfaces (internal/provider/)                │
│                                                          │
│  ClusterProvider   — cluster lifecycle and status        │
│  ImageProvider     — container images and registries     │
│  NodeProvider      — worker node add, remove, rename     │
│  SystemProvider    — package, upgrade, backup, check ... │
│  AddonProvider     — addon lifecycle and commands        │
└──────────────┬────────────────────────────┬──────────────┘
               │                            │
┌──────────────▼─────────────┐ ┌────────────▼──────────────┐
│  Windows Provider          │ │  Linux Provider           │
│  (*_windows.go)            │ │  (*_linux.go)             │
│                            │ │                           │
│  Delegates to PowerShell   │ │  Lifecycle → Bash scripts │
│  via ExecutePsWith-        │ │  (internal/linux/         │
│  StructuredResult          │ │   lifecycle)              │
│                            │ │  Status, addons, checks → │
│  Supports all setup types  │ │  Go + kubectl, crictl,    │
│  (k2s, linux-only,         │ │  buildah, nerdctl, ssh    │
│  buildonly)                │ │  No PowerShell dependency │
└────────────────────────────┘ └───────────────────────────┘
```

### Key Components

| File | Purpose |
|------|---------|
| `provider.go` | `Registry` struct (holds all providers) and `ProviderConfig` |
| `cluster.go` | `ClusterProvider` — Install, Uninstall, Start, Stop, Status |
| `image.go` | `ImageProvider` — List, Pull, Remove, Build, Import, Export, Tag, Push, Clean, Repair, RegistryAdd, RegistryRemove |
| `node.go` | `NodeProvider` — Add, Remove, Rename |
| `system.go` | `SystemProvider` — Dump, Upgrade, Package, Reset, ResetNetwork, Compact, Backup, Restore, CertificateRenew, CertificateAutoRotation, Check |
| `addon.go` | `AddonProvider` — Enable, Disable, List, Status, Export, Import, RunCommand |
| `errors.go` | `ErrNotSupported` sentinel, `UnsupportedOperationError`, `NotSupportedError()` helper, `ProviderFailure` |
| `registry_windows.go` | Build-tagged factory creating Windows providers |
| `registry_linux.go` | Build-tagged factory creating Linux providers (prints the experimental warning) |
| `ps_result_windows.go` | Windows-only mirror of CLI result types (avoids an import cycle with `cmd/k2s/cmd/common`) |

### How It Works

1. During CLI initialisation (`PersistentPreRunE` in `cmd/k2s/cmd/cmd.go`), a `provider.Registry` is created via `provider.NewRegistry(config)`. The build-tagged factory selects Windows or Linux implementations.
2. The registry is stored in the Cobra command context via `CmdContext`.
3. Command handlers call `context.Providers().Cluster.Start(...)` etc. — no `if runtime.GOOS == ...` checks anywhere in command code.
4. On **Windows**, providers delegate to PowerShell scripts via `powershell.ExecutePsWithStructuredResult` (`internal/providers/powershell`), preserving the Go ↔ PowerShell bridge. Scripts report structured results back with `Send-ToCli`.
5. On **Linux**, lifecycle operations are dispatched by `lifecycle.Execute` to the Bash entry scripts in `lib/scripts/linux/debian/linuxonly/`. Non-secret inputs are passed in a temporary `0600` JSON operation file (`--operation-file`); credentials are read by the scripts themselves. All other Linux operations use Go with native tools (`kubectl`, `crictl`, `buildah`, `nerdctl`, `ssh`).
6. Operations not available on the current platform should return an error created by `provider.NotSupportedError(...)`, which matches `provider.ErrNotSupported` via `errors.Is`.

### Linux Host Capability Status

The following operations are **not yet available** on Linux hosts and return an unsupported/not-implemented error:

| Area | Operation |
|------|-----------|
| System | `upgrade`, `restore`, `compact`, full offline `package`, node delta package |
| Addons | `export`, `import` |
| Nodes | `node rename`; `node add` without `--node-package` |
| Images | `image repair` (Windows-only) |

### Adding a New Provider Domain

1. Define the interface in `internal/provider/<domain>.go`.
2. Create `<domain>_windows.go` and `<domain>_linux.go` with concrete implementations.
3. Add the provider field to `Registry` and wire it in both `registry_*.go` factories.
4. Call the provider from the relevant command handler via `context.Providers().<Domain>.Method()`.
5. Verify that both targets compile, e.g. `GOOS=linux go build ./cmd/k2s` and `GOOS=windows go build ./cmd/k2s`.

---

## Bundled Tools

*K2s* ships several supporting executables beyond the main `k2s` CLI. All are built from source under `cmd/`.

### Windows Executables

`BuildGoExe.ps1 -BuildAll` (shortcut `bgow`) builds the following executables. `k2s.exe` is placed in the installation root; helper tools go to `bin/` or `bin/cni/`.

| Tool | Source | Output | Purpose |
|------|--------|--------|---------|
| **k2s.exe** | `cmd/k2s/` | root | The K2s CLI. |
| **httpproxy.exe** | `cmd/httpproxy/` | `bin/` | HTTP forward proxy running on the Windows host. Transparently proxies internet traffic for the Linux VM when a corporate proxy is configured. |
| **cloudinitisobuilder.exe** | `cmd/cloudinitisobuilder/` | `bin/` | Builds cloud-init ISO images (ISO 9660) for provisioning the Linux VM with network config, SSH keys, and initial setup scripts. |
| **devgon.exe** | `cmd/devgon/` | `bin/` | Go reimplementation of Microsoft's `devcon.exe` (Device Console). Manages network adapters without requiring the VC Runtime (`vcruntime140.dll`). |
| **yaml2json.exe** | `cmd/yaml2json/` | `bin/` | Converts YAML to JSON. Used internally by scripts that need JSON input from YAML sources. |
| **zap.exe** | `cmd/zap/` | `bin/` | Forcefully removes directories that Windows file locks prevent from being deleted (used by `k2s image reset-win-storage --force-zap`). |
| **vfprules.exe** | `cmd/vfprules/` | `bin/cni/` | Manages Virtual Filtering Platform (VFP) rules on the `cbr0` Hyper-V external switch. Routes pod and service traffic between the host and the Linux VM. |
| **bridge.exe** | `cmd/bridge/` | `bin/cni/` | Windows CNI bridge plugin (based on Microsoft's windows-container-networking). Creates the `cbr0` bridge for pod networking on the Windows worker. |
| **l4proxy.exe** | `cmd/l4proxy/` | `bin/cni/` | Layer 4 (TCP/UDP) proxy used in CNI networking for forwarding traffic between network namespaces. |
| **cplauncher.exe** | `cmd/cplauncher/` | `bin/cni/` | Compartment Launcher — starts Windows processes inside a specific network compartment, enabling Linkerd service mesh on Windows. Resolves compartments from Kubernetes pod labels and optionally injects a DLL for per-thread compartment switching. |

### Container Image Components

These are built separately (see the `README.md` in each folder) and shipped as container images rather than host executables:

| Component | Source | Purpose |
|-----------|--------|---------|
| **pause** | `cmd/pause/` | Windows pause container. Every Windows pod includes this as the infrastructure container (holds the network namespace). Ships with its own Dockerfile. |
| **login** | `cmd/login/` | OAuth2/OIDC login provider using Ory Hydra. Provides Windows-logon-based authentication for the security addon's zero-trust mode. |
| **clusterip-webhook** | `cmd/clusterip-webhook/` | Mutating admission webhook that assigns Service ClusterIPs from OS-specific subnets (Linux vs. Windows). |
| **linkerdinit** | `cmd/linkerdinit/` | Replacement for the upstream `linkerd2-proxy-init` inside the Windows Linkerd data-plane image. |
| **linkerdproxyidentity** | `cmd/linkerdproxyidentity/` | Prepares the Linkerd proxy identity material (key and CSR) for the Windows Linkerd proxy. |

### Building Tools from Source

All Go tools can be built locally. **After cloning the repository, building is mandatory** — Go-built binaries are not committed to git.

On a Windows development machine:

```console
# Build all Go executables for Windows (required after clone)
bgow

# Cross-compile all Go executables for Linux
bgol

# Build k2s.exe only
bgo

# Build a specific tool
bgo -ProjectDir "cmd\httpproxy" -ExeOutDir "bin"
```

On a Linux development machine (no PowerShell required):

```console
./build.sh
# or
make build
```

`build.sh` builds the `k2s` CLI into the repository root and `cloudinitisobuilder`, `httpproxy`, and `yaml2json` into `bin/`, and places a pinned, checksum-verified `dnsproxy` binary into `bin/`.

See [Building Locally](contributing/building-locally.md) for prerequisites.

---

## PowerShell Module Structure

*K2s* organises its Windows PowerShell automation into four major modules under `lib/modules/windows/<ownership>/`:

### k2s.infra.module — Infrastructure & Configuration (`infra/`)

| Submodule | Purpose |
|-----------|---------|
| `config/config.module.psm1` | Reads and writes cluster configuration (`setup.json`, `config.json`). Exports functions for querying setup type, flags, proxy settings, mirror registries, K8s version, etc. |
| `config/cluster.config.module.psm1` | Multi-node cluster topology management (`cluster.json`). CRUD operations for node entries. |
| `hooks/hooks.module.psm1` | Hook system — discovers and executes lifecycle hook scripts. See [Hook System](../op-manual/hook-system.md). |
| `log/` | Logging infrastructure (`Initialize-Logging`, `Write-Log`, `Write-ErrorMessage`). |
| `cli-messages/` | `Send-ToCli` — structured messages returned from scripts to the Go CLI. |
| `errors/` | Error object creation (`New-Error`) and well-known error codes (`Get-ErrCode*`). |
| `archive/` | Safe archive extraction (`Expand-ZipWithProgress`) with path traversal protection. |
| `network/` | Windows host network management (adapters, routes, DNS). |
| `validation/` | Path validation, pattern matching, hashtable comparison utilities. |
| `ctr/` | `ctr` (containerd CLI) invocation helper. |
| `yaml/` | YAML file reading helpers. |
| `dump/` | Diagnostic dump file generation. |
| `path/` | K2s installation path resolution. |

### k2s.cluster.module — Cluster Lifecycle (`cluster/`)

| Submodule | Purpose |
|-----------|---------|
| `upgrade/` | Full cluster upgrade orchestration (export/import resources, uninstall/install, re-enable addons). |
| `update/` | Delta update application (in-place file replacement, Debian package diff, container image update). |
| `setup/` | Cluster setup helpers, including kubeconfig-scoped `kubectl` invocation. |
| `status/` | Cluster status and availability checks (`Get-Status`, `Test-SystemAvailability`). |
| `system/` | Time sync, API server readiness checks, node label/taint management. |
| `image/` | Container image management and backup/restore of images. |
| `setupinfo/` | Setup information queries. |
| `runningstate/` | Cluster running state checks. |
| `k8s-api/` | Kubernetes API integration helpers (e.g. `Wait-ForPodCondition`). |

### k2s.node.module — Node Management (`node/`)

| Submodule | Purpose |
|-----------|---------|
| `linuxnode/baseimage/` | Linux VM base image building, cloud-init provisioning templates. |
| `linuxnode/distros/` | Multi-distro support: Debian and Ubuntu with distro-specific network configuration. |
| `linuxnode/network/` | KubeSwitch creation and VM network adapter management (Hyper-V and WSL). |
| `linuxnode/setup/` | Control-plane and worker node setup, Hyper-V/WSL VM creation, GPU worker, certificates. |
| `linuxnode/security/` | SSH key generation and deployment (`New-SshKey`, `Copy-LocalPublicSshKeyToRemoteComputer`). |
| `linuxnode/vm/` | Hyper-V VM lifecycle management for the control-plane node. |
| `windowsnode/` | Windows worker node setup: base image, binary downloads, network config, proxy, services, system configuration. |
| `vmnode/` | Generic VM node management for additional cluster nodes. |

### k2s.signing.module — Code Signing (`common/`)

| Function | Purpose |
|----------|---------|
| `Set-K2sFileSignature` | Signs all K2s executables (.exe, .dll, .msi) and PowerShell scripts (.ps1, .psm1) using a PFX certificate with Authenticode. |
| `Get-SignableFiles` | Discovers signable files with built-in exclusion lists. |

See [Security Features](../security/security-features.md) for details.

---

## Script Layers

| Layer | Location | Purpose |
|-------|----------|---------|
| **CLI orchestration** | `lib/scripts/windows/host/` | Top-level Windows scripts invoked by `k2s.exe`: install, start, stop, uninstall, status, image management, system operations, and shared script helpers. |
| **Host provisioning** | `smallsetup/` | Windows host environment bootstrap: loopback adapter, HNS network, kubeadm flags, Go build script (`common/BuildGoExe.ps1`), debug helpers, network repair scripts. |
| **Addon lifecycle** | `addons/` | Per-addon Enable/Disable/Backup/Restore/Update/Get-Status scripts and Kubernetes manifests. |
| **Multi-variant installs** | `lib/scripts/windows/buildonly/`, `lib/scripts/windows/linuxonly/` | Variant-specific install/uninstall/start/stop scripts. |
| **Worker node setup** | `lib/scripts/windows/worker/` | Setup scripts for Windows-hosted Windows and Linux worker nodes. |
| **Control plane** | `lib/scripts/control-plane/` | Control-plane Install/Start/Stop/Uninstall scripts. |
| **Packaging** | `lib/scripts/windows/host/system/package/` | Full and delta package creation, image acquisition, signing, Debian diff, addon packaging. |
| **Native Debian host lifecycle** | `lib/scripts/linux/debian/linuxonly/` | Root-only Debian 13 lifecycle entry points (Install, Start, Stop, Uninstall, ProvisionPackages). Invoked by the Linux cluster provider with an `--operation-file`. |
| **Native Debian host operations** | `lib/scripts/linux/debian/host/` | Host entry points delegating to the `linuxonly/` lifecycle, plus image scripts (`host/image/`) used by the Linux image provider. |
| **Native Debian worker nodes** | `lib/scripts/linux/debian/worker/bare-metal/` | `Add.sh` joins a Debian 13 (amd64/arm64) worker node from an offline node package; invoked by `k2s node add` on Linux hosts. |
| **Native Linux modules** | `lib/modules/linux/{common,infra,cluster,node,networking,services}/` | Reusable Bash modules: logging, validation, paths, proxy, SSH, kubeadm lifecycle, CRI-O, Buildah, Debian packages, Windows worker VM, Linux worker-node join, DNS, systemd. |

---

## Automation Layout Contract

Platform-specific automation is organized under `lib/scripts/<host-os>/` and
`lib/modules/<host-os>/`. New automation must be added to this layout; the
legacy `lib/scripts/{k2s,linuxonly,buildonly,worker}/` and
`lib/modules/k2s/` locations must not be recreated.

| Host | Script locations | Module locations | Implementation boundary |
|---|---|---|---|
| Windows | `lib/scripts/windows/{host,linuxonly,buildonly,worker}/` | `lib/modules/windows/{common,infra,cluster,node}/` | Go providers dispatch to PowerShell entry scripts; PowerShell modules own host operations. |
| Debian 13 | `lib/scripts/linux/debian/{host,linuxonly,worker}/` | `lib/modules/linux/{common,infra,cluster,node,networking,services}/` | Go providers dispatch lifecycle operations to Bash entry scripts; Bash modules own install, start, stop, uninstall, and compact. `k2s status` remains Go-native to preserve typed status output. `worker/` contains worker-node automation (`bare-metal/Add.sh`). |

`cfg/nodeextension/<os>/` contains only operating-system-specific assets used
to extend a cluster with nodes. It is not a location for host lifecycle
automation. Debian package assets remain in `cfg/nodeextension/debian13/`
because Windows-host Linux node provisioning also consumes them.

Run `bash test/native-linux-layout.sh` on a Bash-capable host after changing
automation layout. The check validates the required Linux module graph and
rejects tracked legacy paths or active references.

---

## Configuration Files Overview

| File | Location | Purpose |
|------|----------|---------|
| `config.json` | `cfg/` | Network CIDRs, registries, VFP rules, backup exclusions |
| `config.toml.template` | `cfg/containerd/` | Containerd runtime configuration template |
| `flannel-l2bridge.conf.template` | `cfg/containerd/` | Flannel l2bridge CNI configuration template for containerd |
| `net-conf.json.template` | `cfg/cni/` | Flannel host-gw CNI backend |
| `net-conf-vxlan.json.template` | `cfg/cni/` | Flannel VXLAN CNI backend |
| `applockerrules.xml` | `cfg/applocker/` | AppLocker policies for container accounts |
| `joinnode.template.yaml` | `cfg/kubeadm/` | Windows node kubeadm join template |
| `joinnode-linux.template.yaml` | `cfg/kubeadm/` | Linux node kubeadm join template |
| `domain.xml.tmpl`, `network.xml.tmpl` | `cfg/libvirt/` | libvirt domain and network templates for Linux hosts; custom overrides are read from the `libvirt/` folder in the K2s config directory |
| `debian12/`, `debian13/` | `cfg/nodeextension/` | OS-specific assets for extending a cluster with Linux nodes |

See [Configuration Reference](../op-manual/configuration-reference.md) for detailed documentation of each file.

## See Also

- [Configuration Reference](../op-manual/configuration-reference.md) — all config files and settings
- [Hosting Variants](../user-guide/hosting-variants.md) — setup types
- [Networking Architecture](../op-manual/networking-architecture.md) — CNI and network design
- [Building Locally](contributing/building-locally.md) — building Go tools from source
- [Linux Development](contributing/linux-development/linux-development.md) — developing on a Linux host
