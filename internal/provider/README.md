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
| `ImageProvider` | Build, Import, Export, List, Remove | Container image operations |
| `NodeProvider` | Add, Remove, List | Worker node management |
| `SystemProvider` | Package, Upgrade, Backup, Restore | System-level operations |
| `AddonProvider` | Enable, Disable, Status, Backup, Restore | Addon lifecycle and addon data backup/restore |

## File Layout

```
provider/
├── provider.go             # Registry struct, ProviderConfig
├── cluster.go              # ClusterProvider interface + config/result types
├── image.go                # ImageProvider interface + config types
├── node.go                 # NodeProvider interface + config types
├── system.go               # SystemProvider interface + config types
├── addon.go                # AddonProvider interface + config types
├── errors.go               # ErrNotSupported, UnsupportedOperationError
├── registry_windows.go     # Build-tagged factory → Windows providers
├── registry_linux.go       # Build-tagged factory → Linux providers
├── cluster_windows.go      # Windows: delegates to PowerShell scripts
├── cluster_linux.go        # Linux: native Go (kubeadm, kubectl, libvirt)
├── image_windows.go        # Windows: delegates to PowerShell scripts
├── image_linux.go          # Linux: native crictl/nerdctl/ctr + SSH
├── node_windows.go         # Windows: delegates to PowerShell scripts
├── node_linux.go           # Linux: native SSH + kubeadm
├── system_windows.go       # Windows: delegates to PowerShell scripts
├── system_linux.go         # Linux: native Go implementations
├── addon_windows.go        # Windows: delegates to PowerShell scripts
├── addon_linux.go          # Linux: native kubectl
├── ps_result_windows.go    # Windows-only: local PS result types (avoids import cycle)
└── README.md               # This file
```

## Experimental Status

> **Linux host support is experimental.** The Linux providers are functional for core cluster lifecycle, image management, node management, addon enable/disable, and addon backup/restore for `registry`, `ingress nginx` and `ingress traefik`. System-level operations (offline packaging, backup/restore, upgrade) are not yet implemented and return `ErrNotSupported`. A runtime warning is printed to stderr on every CLI invocation on Linux.

## How It Works

1. **Initialisation**: During `PersistentPreRunE` in `cmd.go`, a `Registry` is created via `NewRegistry(ProviderConfig{...})`. The build-tagged factory (`registry_windows.go` or `registry_linux.go`) instantiates the correct implementations.

2. **Access**: The `Registry` is stored in the `CmdContext` and accessed by command handlers via `context.Providers()`.

3. **Dispatch**: Command handlers call e.g. `context.Providers().Cluster.Start(config)` — fully platform-agnostic.

4. **Windows path**: Providers delegate to PowerShell scripts via `powershell.ExecutePsWithStructuredResult`, preserving the established Go ↔ PS bridge.

5. **Linux path**: Providers use native Go APIs (kubeadm, kubectl, libvirt/KVM, SSH, crictl) with no PowerShell dependency.

6. **Unsupported ops**: Methods not available on the current platform return `ErrNotSupported` (or the more detailed `UnsupportedOperationError`).

## Adding a New Provider

1. Define the interface in a new `<domain>.go` file.
2. Create `<domain>_windows.go` and `<domain>_linux.go` with implementations.
3. Add the field to `Registry` and wire it in both `registry_*.go` factories.
4. Call the provider from command handlers via `context.Providers().<Domain>.Method(...)`.

## Import Cycle Note

The Windows providers need to return result types compatible with the CLI command layer (`common.CmdResult`, `common.CmdFailure`). To avoid an import cycle (`provider` → `cmd/common` → `provider`), local mirror types are defined in `ps_result_windows.go`. These are structurally identical and are used only within the Windows provider implementations.
