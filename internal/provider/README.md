<!--
SPDX-FileCopyrightText: © 2025 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Provider Package

The `provider` package defines **platform-agnostic interfaces** for all K2s operations and supplies build-tagged implementations for each supported host OS (Windows, Linux).

## Purpose

Command handlers in `cmd/k2s/cmd/` call provider interfaces exclusively, eliminating any `runtime.GOOS` checks or build-tagged dispatch files from the command layer. All platform differences are encapsulated here.

## Interfaces

| Interface | Methods | Responsibility |
|-----------|---------|----------------|
| `ClusterProvider` | Install, Uninstall, Start, Stop, Status | Cluster lifecycle management |
| `ImageProvider` | List, Pull, Remove, Build, Import, Export, Tag, Push, Clean, Repair, RegistryAdd, RegistryRemove | Container image and registry operations |
| `NodeProvider` | Add, Remove, Rename | Worker node management |
| `SystemProvider` | Dump, Upgrade, Package, Reset, ResetNetwork, Compact, Backup, Restore, CertificateRenew, CertificateAutoRotation, Check | System-level operations and read-only health checks |
| `AddonProvider` | Enable, Disable, List, Status, Export, Import, RunCommand | Addon lifecycle |

## File Layout

```
provider/
├── provider.go             # Registry struct, ProviderConfig
├── cluster.go              # ClusterProvider interface + config/result types
├── image.go                # ImageProvider interface + config types
├── node.go                 # NodeProvider interface + config types
├── system.go               # SystemProvider interface + config types
├── addon.go                # AddonProvider interface + config types
├── errors.go               # ErrNotSupported, UnsupportedOperationError, NotSupportedError(), ProviderFailure
├── registry_windows.go     # Build-tagged factory → Windows providers
├── registry_linux.go       # Build-tagged factory → Linux providers (prints experimental warning)
├── cluster_windows.go      # Windows: delegates to PowerShell scripts
├── cluster_linux.go        # Linux: lifecycle → Bash via internal/linux/lifecycle; Status native Go (kubectl)
├── image_windows.go        # Windows: delegates to PowerShell scripts
├── image_linux.go          # Linux: Bash image scripts + crictl/nerdctl/ctr/buildah
├── kubectl_linux.go        # Linux: kubectl helpers
├── node_windows.go         # Windows: delegates to PowerShell scripts
├── node_linux.go           # Linux: node add via Bash (worker/bare-metal/Add.sh), remove via kubectl
├── node_package_*linux.go  # Linux: node package creation (incl. images)
├── system_windows.go       # Windows: delegates to PowerShell scripts
├── system_linux.go         # Linux: reset via Bash lifecycle; dump, certificates in Go
├── system_backup_linux.go  # Linux: system backup
├── system_check_*.go       # Read-only health checks (k2s system check)
├── addon_windows.go        # Windows: delegates to PowerShell scripts
├── addon_linux.go          # Linux: native kubectl
├── ps_result_windows.go    # Windows-only: local PS result types (avoids import cycle)
└── README.md               # This file
```

## Experimental Status

> **Linux host support is experimental.** The Linux providers cover cluster lifecycle (install, start, stop, uninstall, reset), status, image management, addon enable/disable/list/status, node add (from an offline node package) and removal, system dump, backup, certificate operations, and health checks. Not yet available on Linux: system upgrade, restore, compact, full offline packaging, node delta packages, addon export/import, node add without `--node-package`, node rename, and image repair. These return an unsupported or not-implemented error. A runtime warning is printed to stderr on every CLI invocation on Linux.

## How It Works

1. **Initialisation**: During `PersistentPreRunE` in `cmd.go`, a `Registry` is created via `NewRegistry(ProviderConfig{...})`. The build-tagged factory (`registry_windows.go` or `registry_linux.go`) instantiates the correct implementations.

2. **Access**: The `Registry` is stored in the `CmdContext` and accessed by command handlers via `context.Providers()`.

3. **Dispatch**: Command handlers call e.g. `context.Providers().Cluster.Start(config)` — fully platform-agnostic.

4. **Windows path**: Providers delegate to PowerShell scripts via `powershell.ExecutePsWithStructuredResult`, preserving the established Go ↔ PS bridge.

5. **Linux path**: Cluster lifecycle operations are dispatched via `internal/linux/lifecycle` to the Bash entry scripts in `lib/scripts/linux/debian/linuxonly/`, which use the modules in `lib/modules/linux/` (kubeadm, CRI-O, libvirt/virsh). All other operations use Go with native tools (kubectl, crictl, buildah, nerdctl, SSH). There is no PowerShell dependency.

6. **Unsupported ops**: Methods not available on the current platform return an error created by `NotSupportedError(...)` (an `UnsupportedOperationError` that matches `ErrNotSupported` via `errors.Is`).

## Adding a New Provider

1. Define the interface in a new `<domain>.go` file.
2. Create `<domain>_windows.go` and `<domain>_linux.go` with implementations.
3. Add the field to `Registry` and wire it in both `registry_*.go` factories.
4. Call the provider from command handlers via `context.Providers().<Domain>.Method(...)`.

## Import Cycle Note

The Windows providers need to return result types compatible with the CLI command layer (`common.CmdResult`, `common.CmdFailure`). To avoid an import cycle (`provider` → `cmd/common` → `provider`), local mirror types are defined in `ps_result_windows.go`. These are structurally identical and are used only within the Windows provider implementations.
