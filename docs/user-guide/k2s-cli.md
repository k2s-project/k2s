<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: MIT
-->

# k2s CLI

The *k2s* CLI is the primary interface for managing a *K2s* cluster. It covers the full lifecycle — installation, startup, upgrade, image management, addon management, and system maintenance.

!!! warning "Linux Host Support — Experimental"
    Running the *k2s* CLI on a **Linux host** is an experimental feature. Core cluster lifecycle commands (`install`, `start`, `stop`, `uninstall`, `status`), image/addon management, and `system backup` work, but some system commands (`system upgrade`, `system package`, `system restore`) are not yet implemented on Linux. See [Hosting Variants](hosting-variants.md#linux-host) for details.

Every command supports `--output` / `-o` (show log in terminal) and `--verbosity` / `-v` (log level, default `info`) as global flags.

```console
k2s -h
```

!!! tip
    When *K2s* is installed, the executables including *k2s* CLI have been added to `PATH`, so that the CLI can be called by using its name only.

!!! note
    Most of the *k2s* CLI commands require administrator privileges.

---

## install

Installs a *K2s* Kubernetes cluster on the host machine.

```console
k2s install [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--master-cpus` | | Number of CPUs allocated to master VM |
| `--master-memory` | | RAM for master VM (minimum 2 GB) |
| `--master-memory-min` | | Minimum RAM for dynamic memory (enables dynamic memory) |
| `--master-memory-max` | | Maximum RAM for dynamic memory (enables dynamic memory) |
| `--master-disk` | | Disk size for master VM (minimum 10 GB) |
| `--proxy` | `-p` | HTTP proxy |
| `--no-proxy` | | No-proxy hosts/domains (comma-separated) |
| `--config` | `-c` | Path to config file |
| `--wsl` | | Use WSL 2 for hosting the KubeMaster |
| `--linux-only` | | No Windows worker node |
| `--force-online-installation` | `-f` | Force online installation |
| `--delete-files-for-offline-installation` | `-d` | Delete offline-only files after online install |
| `--k8s-bins` | | Path to locally built Kubernetes binaries |
| `--skip-start` | | Do not start the cluster after installation |
| `--append-log` | | Append to existing log file |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

**Dynamic Memory Examples:**

```console
# Static memory (default behavior)
k2s install --master-memory 4GB

# Dynamic memory - starts with 2GB, can grow based on host capacity
k2s install --master-memory-min 2GB
# Max auto-calculated: 50% of host RAM (e.g., 16GB on 32GB host)

# Dynamic memory - starts with 6GB (default), can shrink to 2GB when idle, grow to 8GB
k2s install --master-memory-max 8GB
# Min auto-calculated: 30% of startup (2GB, with 2GB floor)

# Dynamic memory with min and max - starts with 2GB, can grow up to 8GB
k2s install --master-memory-min 2GB --master-memory-max 8GB

# Dynamic memory with explicit startup - starts with 4GB, scales between 2GB-8GB
k2s install --master-memory 4GB --master-memory-min 2GB --master-memory-max 8GB
```

!!! note "Dynamic Memory with Intelligent Defaults"
    - Specifying `--master-memory-min` or `--master-memory-max` **automatically enables** Hyper-V dynamic memory
    
    **Intelligent Defaults:**
    - **Min not specified:** Defaults to 30% of startup (floor: 2GB) - allows VM to shrink significantly when idle
    - **Max not specified:** Defaults to 50% of host RAM (floor: 8GB, ceiling: 32GB) - allows VM to grow as needed
    - **Startup not specified with min:** VM starts with minimum memory for optimal resource efficiency
    
    **Validation Rules:**
    - Minimum memory must be ≤ maximum memory
    - Minimum memory must be ≤ startup memory (if specified)
    - Maximum memory must be ≥ startup memory (if specified)
    - Dynamic memory is **not supported with WSL2** (`--wsl` flag uses static memory only)

### install buildonly

Installs a minimal *buildonly* setup (Linux VM without Windows worker node, intended for container image building only).

```console
k2s install buildonly [flags]
```

Accepts the same VM-resource, proxy, and config flags as `install`.

---

## uninstall

Removes the *K2s* cluster from the host machine.

```console
k2s uninstall [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--skip-purge` | | Keep installation files on disk |
| `--delete-files-for-offline-installation` | `-d` | Delete offline-only files |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

---

## start

Starts a previously installed *K2s* cluster.

```console
k2s start [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ignore-if-running` | `-i` | Skip if already running |
| `--autouse-cached-vswitch` | | Re-use the cached vSwitch (cbr0 / KubeSwitch) |
| `--node` | | Start only the specified additional node |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

---

## stop

Stops the running *K2s* cluster.

```console
k2s stop [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--cache-vswitch` | | Cache vswitches for cluster connectivity |
| `--node` | | Stop only the specified additional node |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

---

## status

Prints status information about the *K2s* cluster.

```console
k2s status [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--output` | `-o` | Output format: `wide`, `json` |

---

## version

Prints the installed *K2s* version.

```console
k2s version
```

---

## image

Manage container images on the cluster nodes.

### image ls

List images on all nodes.

```console
k2s image ls [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--include-k8s-images` | `-A` | Include Kubernetes system images |
| `--output` | `-o` | Output format: `json` |

### image build

Build a container image.

> [!NOTE]
> Building Windows container images (`--windows`) is only supported on Windows worker nodes and will return an error when invoked on a Linux-only installation.

```console
k2s image build [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--input-folder` | `-d` | Build context directory (default `.`) |
| `--dockerfile` | `-f` | Dockerfile location |
| `--image-name` | `-n` | Image name |
| `--image-tag` | `-t` | Image tag |
| `--build-arg` | | Build arguments (repeatable) |
| `--windows` | `-w` | Build a Windows container image |
| `--push` | `-p` | Push to private registry after build |

### image pull

Pull an image onto a Kubernetes node.

```console
k2s image pull <image> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--windows` | `-w` | Pull onto the Windows node |

### image push

Push an image into a registry.

```console
k2s image push [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--id` | | Image ID |
| `--image-name` | `-n` | Image name including tag |

### image tag

Tag an existing image with a new name.

```console
k2s image tag [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--id` | | Image ID |
| `--image-name` | `-n` | Current image name including tag |
| `--target-name` | `-t` | New image name including tag |

### image export

Export an image to a tar archive.

```console
k2s image export [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--id` | | Image ID |
| `--name` | `-n` | Image name including tag |
| `--tar` | `-t` | Output tar file path |
| `--docker-archive` | | Export as docker-archive (default: oci-archive) |

### image import

Import an image from a tar archive.

```console
k2s image import [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--tar` | `-t` | Path to oci-archive tar |
| `--dir` | `-d` | Directory containing multiple oci-archive tars |
| `--windows` | `-w` | Import as Windows image |
| `--docker-archive` | | Import from docker-archive tar |

!!! note "Multi-image Docker archives"
    When importing a Linux image archive, K2s inspects its `manifest.json`. If the archive is a Docker archive containing several images (for example, created with `docker save image1 image2`), K2s detects this automatically, even without `--docker-archive`. It then imports each image separately with its tags from `manifest.json`; layers shared by the images are stored only once. Entries that are invalid (for example, referencing missing files) are skipped. If any image fails, the command reports an error, and images that were already imported are kept.

    Single-image archives are imported as before. On Linux nodes, multi-image OCI archives (an `index.json` with several images and no Docker `manifest.json`) are not supported.

    If an archive contains a `manifest.json` that is empty, malformed, not a list of image entries, present more than once, or unreadable, the archive is not imported on any node type, and the command reports an error. A fallback import could import only part of such an archive and still report success. An archive that cannot be listed at all is passed to the container runtime unchanged, which reports its own error. Paths in `manifest.json` must be relative to the archive root. When a multi-image archive is imported from a Windows host on a Linux node, an entry that references an absolute, drive-qualified, UNC, or `..` path outside the archive is skipped as invalid; on a native Linux host, Buildah fails to import such an entry. In both cases the other entries are imported and the command reports an error.

    On a native Linux host (experimental), reading `manifest.json` requires `jq`, which the K2s Linux host installation already requires as a host prerequisite (no download happens at import time). If `jq` is missing, the import of a Docker archive fails with an error instead of falling back to a single-image import. On a native Linux host, a file that is not a tar archive is also rejected before Buildah runs. Because Buildah archive references use `:` as a separator, an archive whose path contains `:` is rejected on a native Linux host; rename or move it before importing. OCI archives without `manifest.json` do not need `jq`.

    Windows image archives (`-w`, or a Windows node selected with `--node`/`--nodes`) are imported by containerd in a single operation, which imports all images of the archive and stores shared layers only once. Afterwards, K2s checks that every tag listed in `manifest.json` is present in the `k8s.io` namespace and reports the missing images as an error. Because containerd does not import untagged Docker archive entries, such an archive is reported as failed. If the image list cannot be read after the import, the import is also reported as failed, because the image names could not be verified. Archives without a Docker `manifest.json` (for example OCI archives) are imported as before, but their image names are not verified. If any layer of the archive is missing, containerd imports no image at all. On a native Linux host, `-w` imports into the Windows VM with `ctr` without this name check.

    On both Linux and Windows, if several entries of an archive use the same tag, the tag refers to the last of them and a warning is logged.

### image rm

Remove a container image.

```console
k2s image rm [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--id` | | Image ID |
| `--name` | | Image name |
| `--from-registry` | | Remove from local registry |
| `--force` | | Force removal (removes containers using the image first) |

### image clean

Remove all non-system container images from every node.

```console
k2s image clean
```

### image reset-win-storage

Reset the containerd and Docker image storage on Windows nodes.

> [!NOTE]
> Resetting Windows container storage is Windows-specific and is not supported on Linux-only or Linux host installations.

```console
k2s image reset-win-storage [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--containerd` | | Containerd directory |
| `--docker` | | Docker directory |
| `--max-retry` | | Max retries for directory deletion (default `1`) |
| `--force-zap` | `-z` | Use `zap.exe` to forcefully remove directories |
| `--force` | `-f` | No user prompts |

### image registry

Manage configured container registries.

On Linux hosts, registry additions and removals configure `/etc/containers/registries.conf.d/` drop-in files and Buildah credentials natively without PowerShell.

#### image registry add

```console
k2s image registry add <registry-url> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--username` | `-u` | Registry username |
| `--password` | `-p` | Registry password |
| `--skip-verify` | | Skip HTTPS certificate verification |
| `--plain-http` | | Allow plain HTTP fallback |

#### image registry rm

```console
k2s image registry rm <registry-url>
```

#### image registry ls

```console
k2s image registry ls
```

---

## addons

Manage optional cluster addons. See the [Addons](addons.md) page for a full overview.

### addons ls

List all available addons and their status.

```console
k2s addons ls [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--output` | `-o` | Output format: `json` |

### addons enable / disable

Enable or disable a specific addon. The subcommands and their flags are defined dynamically from each addon's `addon.manifest.yaml`.

```console
k2s addons enable <addon> [flags]
k2s addons disable <addon>
```

!!! example
    ```console
    k2s addons enable ingress
    k2s addons enable registry
    k2s addons disable dashboard
    ```

### addons status

Print the status of a specific addon.

```console
k2s addons status <addon> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--output` | `-o` | Output format: `json` |

### addons export

Export an addon and its container images as an OCI artifact.

```console
k2s addons export <addon> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--directory` | `-d` | Target directory for the exported artifact |

### addons import

Import a previously exported addon from an OCI artifact.

```console
k2s addons import <addon> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | Path to the OCI artifact tar file |
| `--node` | | Target node name for addon image import (e.g. `worker-1`); defaults to control-plane and local Windows host when omitted |
| `--nodes` | | Target node names (comma-separated) for addon image import (e.g. `worker-1,worker-2`) |

By default the addon images are imported onto the control-plane node and the local Windows host. Use `--node` to import them onto a specific worker node, control-plane, or local Windows host, or `--nodes` to import them onto multiple nodes. When both `--node` and `--nodes` are provided, `--nodes` takes precedence. Target nodes must exist and be in the `Ready` state; otherwise the command fails without importing anything.

```console
# Import an addon and distribute its images to a specific worker node
k2s addons import registry -f C:\tmp\addons.oci.tar --node worker-1

# Import an addon and distribute its images to multiple worker nodes
k2s addons import registry -f C:\tmp\addons.oci.tar --nodes worker-1,worker-2
```

### addons backup

Back up addon data (persistent volumes, configuration).

```console
k2s addons backup <addon> [implementation] [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | Output zip file path |

### addons restore

Restore addon data from a backup.

```console
k2s addons restore <addon> [implementation] [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | Input zip file path (default: newest match in `C:\Temp\k2s\Addons`) |

---

## system

Perform system-level tasks — upgrading, packaging, backup/restore, diagnostics, certificates, proxy, users, and network reset.

### system upgrade

Upgrade the installed *K2s* cluster to the version of the package (full upgrade or in-place delta update).

```console
k2s system upgrade [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--skip-resources` | `-s` | Skip takeover of K8s resources |
| `--skip-images` | `-i` | Skip takeover of container images |
| `--delete-files` | `-d` | Delete downloaded files after upgrade |
| `--config` | `-c` | Path to config file |
| `--proxy` | `-p` | HTTP proxy |
| `--backup-dir` | `-b` | Backup directory |
| `--force` | `-f` | Force upgrade even if versions are not consecutive |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

### system package

Build a *K2s* zip package (optionally offline, delta, node-package, or code-signed).

```console
k2s system package [flags]
```

**Full Package Flags**

| Flag | Short | Description |
|------|-------|-------------|
| `--target-dir` | `-d` | **Required.** Target directory |
| `--name` | `-n` | **Required.** Package zip file name |
| `--for-offline-installation` | | Create offline package |
| `--delta-package` | | Create a delta package |
| `--package-version-from` | | Base full-package zip (required with `--delta-package`) |
| `--package-version-to` | | Target full-package zip (required with `--delta-package`) |
| `--certificate` | `-c` | Code-signing certificate (.pfx) |
| `--password` | `-w` | Certificate password |
| `--profile` | | Packaging profile: `Dev` (default) or `Lite`; Lite skips optional build and large intermediate artifacts |
| `--addons-list` | | Comma-separated addons to include |
| `--master-cpus` | | CPUs for master VM |
| `--master-memory` | | Memory for master VM |
| `--master-disk` | | Disk for master VM |
| `--proxy` | `-p` | HTTP proxy. Optional for `--node-package`; when omitted the local cluster proxy `http://172.19.1.1:8181` is used by default |
| `--k8s-bins` | | Path to locally built Kubernetes binaries |
| `--node-package` | | Create a Linux worker node package. Requires an installed and running *K2s* cluster. The local cluster proxy is used by default; override with `-p` if needed |
| `--os` | | Target Linux distribution for `--node-package`, for example `debian12` or `debian13` |
| `--include-gpu` | | Include NVIDIA Container Toolkit packages for GPU support. When `k2s node add` uses a package built with this flag, GPU support is auto-configured if an NVIDIA GPU is detected |

Example for node package creation:

```console
k2s system package --node-package --os debian12 --target-dir "C:\out" --name "debian12-node.zip"
```

Example for node package with GPU support:

```console
k2s system package --node-package --os debian13 --include-gpu --target-dir "C:\out" --name "debian13-gpu.zip"
```

### system backup

Back up the cluster (resources, persistent volumes, user images). Supported on both Windows and Linux hosts.

```console
k2s system backup [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | Output zip file path (default: temp directory) |
| `--skip-images` | | Skip container image backup |
| `--skip-pvs` | | Skip persistent volume backup |
| `--additional-hooks-dir` | | Directory with additional hook scripts |
| `--output` | `-o` | Show command output in terminal |

**Examples:**

```console
# Full backup (Windows)
k2s system backup -f C:\backups\k2s-backup.zip

# Full backup (Linux)
k2s system backup -f /tmp/backups/k2s-backup.zip

# Fast backup skipping images and persistent volumes with output display
k2s system backup -f /tmp/backups/k2s-backup.zip --skip-images --skip-pvs -o
```

### system restore

Restore a *K2s* cluster from a backup.

```console
k2s system restore [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | **Required.** Backup zip file |
| `--error-on-failure` | `-e` | Fail on resource-restore errors |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

### system dump

Dump full system status to a folder for diagnostics.

```console
k2s system dump [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--skip-open` | `-S` | Do not open the dump folder afterwards |

### system certificate renew

Renew Kubernetes certificates.

```console
k2s system certificate renew [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--force` | `-f` | Force renewal |

### system proxy

Manage HTTP proxy settings for the cluster.

```console
k2s system proxy set <proxy-uri>
k2s system proxy get
k2s system proxy show
k2s system proxy reset
```

#### system proxy override

Manage no-proxy overrides.

```console
k2s system proxy override add <hosts...>
k2s system proxy override delete <hosts...>
k2s system proxy override ls
```

### system users add

Grant a Windows user access to the *K2s* cluster.

```console
k2s system users add [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--username` | `-u` | Windows user name (mutually exclusive with `--id`) |
| `--id` | `-i` | Windows user ID (mutually exclusive with `--username`) |

### system reset

Reset the local K2s system state.

```console
k2s system reset
```

On Windows this runs the standard host reset flow.

On Linux hosts this runs the native uninstall-style cleanup for the installed Linux-only setup, removing the cluster state, common CNI interfaces, and persisted K2s runtime configuration so a fresh install can be started afterwards. Host-network-only cleanup remains the responsibility of `k2s system reset network`.

### system reset network

Reset the host network configuration (requires reboot).

```console
k2s system reset network [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--force` | `-f` | Force network reset |

When a setup is still installed, uninstall it first or run `k2s system reset` before using the standalone network reset. On Linux hosts, `k2s system reset network` is the host-network cleanup path; `k2s system reset` removes only the installed Linux-only cluster state and persisted K2s runtime state.

---

## node

Manage additional cluster nodes.

Currently, `node` commands document and support additional Linux worker nodes on physical hosts or existing VMs. Support for Windows worker nodes will follow.

### node add

Add a node to the cluster. Currently, this is documented for Linux worker nodes.

```console
k2s node add [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ip-addr` | `-i` | **Required.** IP address of the node |
| `--username` | `-u` | **Required.** SSH username |
| `--name` | `-m` | Hostname of the node |
| `--role` | `-r` | Node role (default `worker`) |
| `--node-package` | `-p` | Path to a node package ZIP for offline installation |

Use `--node-package` together with a node package created through `k2s system package --node-package --os ...` on an installed *K2s* cluster when adding a Linux worker node without internet access.

### node remove

Remove a node from the cluster.

```console
k2s node remove [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--name` | `-m` | **Required.** Hostname of the node |

### node copy

Copy files or folders between the host and a node.

```console
k2s node copy [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ip-addr` | `-i` | **Required.** Node IP address |
| `--username` | `-u` | **Required.** SSH username |
| `--source` | `-s` | **Required.** Source path |
| `--target` | `-t` | **Required.** Target path |
| `--reverse` | `-r` | Copy from node to host |
| `--port` | `-p` | SSH port |
| `--timeout` | | Connection timeout |

### node exec

Execute a command on a remote node.

```console
k2s node exec [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ip-addr` | `-i` | **Required.** Node IP address |
| `--username` | `-u` | **Required.** SSH username |
| `--command` | `-c` | **Required.** Command to execute |
| `--port` | `-p` | SSH port |
| `--timeout` | | Connection timeout |
| `--raw` | `-r` | Print only remote output |

### node connect

Open an interactive SSH session to a remote node.

```console
k2s node connect [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ip-addr` | `-i` | **Required.** Node IP address |
| `--username` | `-u` | **Required.** SSH username |
| `--port` | `-p` | SSH port |
| `--timeout` | | Connection timeout |