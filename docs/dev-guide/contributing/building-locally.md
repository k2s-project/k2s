<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Building Locally
## Workspace Prerequisites
All the prerequisites mentioned in [Installation Prerequisites](../../op-manual/installing-k2s.md#prerequisites) must be fulfilled.

* Install [*Go*](https://go.dev/dl/){target="_blank"} for *Windows*.

## First Step After Clone

Go-built binaries are **not committed** to the git repository. After cloning the repo, you **must** build them locally before using *K2s*:

```console
C:\ws\k2s\bin\bgow
```

This builds all 10 Go executables for Windows (`k2s.exe`, `bridge.exe`, `cloudinitisobuilder.exe`, `devgon.exe`, `httpproxy.exe`, `l4proxy.exe`, `vfprules.exe`, `yaml2json.exe`, `zap.exe`, `cplauncher.exe`) and places them in their expected locations (`bin/`, `bin/cni/`, and the repo root).

For Linux cross-compilation, use:

```console
C:\ws\k2s\bin\bgol
```

!!! warning
    Without this step, `k2s.exe` and supporting tools will be missing and *K2s* will not function.

## Build *Go* projects
Building *Go* based projects is done through [BuildGoExe.ps1](https://github.com/k2s-project/k2s/blob/main/smallsetup/common/BuildGoExe.ps1){target="_blank"}

!!! tip
    `bgow.cmd` / `bgol.cmd` are shortcut commands to build all Go executables for Windows / Linux respectively.<br/>
    `bgo.cmd` is a shortcut for `BuildGoExe.ps1` to build individual executables.<br/>
    If you have not installed *K2s* yet, then your `PATH` is not updated with the required locations. In this case, look for the `.cmd` files in the `bin/` directory and invoke the build command.

In the below example, `c:\ws\k2s` is the root of the *Git* repo:
```console
where bgo
C:\ws\k2s\bin\bgo.cmd
```

Building `httpproxy` *Go* project:
```console
C:\ws\k2s\bin\bgo -ProjectDir "C:\ws\k2s\cmd\httpproxy\" -ExeOutDir "c:\ws\k2s\bin"
```

!!! info
    The `k2s` CLI can be built without any parameters:
```console
C:\ws\k2s\bin\bgo
```

To build all *Go* executables:
```console
C:\ws\k2s\bin\bgow
```

To cross-compile all *Go* executables for Linux:
```console
C:\ws\k2s\bin\bgol
```

If *K2s* is installed then just simply execute the command without the full path:
```console
bgo -ProjectDir "C:\ws\k2s\cmd\httpproxy\" -ExeOutDir "c:\ws\k2s\bin"
bgow
bgol
```

## Cross-Compiling for Linux

The *K2s* CLI supports both Windows and Linux hosts. The easiest way to cross-compile all Go executables for Linux is:

```console
bgol
```

Alternatively, you can use standard Go tools directly:

```bash
# Build the Linux binary
GOOS=linux go build -o k2s ./cmd/k2s

# Verify the build compiles for both platforms
GOOS=windows go build ./cmd/k2s
GOOS=linux go build ./cmd/k2s
```

!!! note
    On Linux, the CLI uses native Go APIs (kubeadm, kubectl, libvirt/KVM, SSH) instead of PowerShell. The platform-specific logic is encapsulated in the [Provider Architecture](../architecture.md#provider-architecture).

## Building Natively on Linux (no PowerShell)

On a Linux developer machine you can build the Linux executables without PowerShell using the `build.sh` script (or the `Makefile` wrapper) in the repository root. Both mirror the same Go build flags and version metadata as [BuildGoExe.ps1](https://github.com/k2s-project/k2s/blob/main/smallsetup/common/BuildGoExe.ps1){target="_blank"}.

Prerequisite: install [*Go*](https://go.dev/dl/){target="_blank"} (see `go.mod` for the required version).

After cloning, make the build script executable before running it:

```bash
chmod +x ./build.sh
```

```bash
# Build all Linux executables
./build.sh

# Or via the Makefile wrapper
make build

# Remove the produced binaries
make clean
```

This builds the CLI as `k2s` in the repository root and builds `cloudinitisobuilder`, `httpproxy`, and `yaml2json` into `bin/`. To route Go module downloads through a proxy, pass `./build.sh --proxy http://proxy.example.com:8080`.
