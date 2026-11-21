<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Delta Packages

Delta packages provide a bandwidth-efficient way to upgrade *K2s* installations by including only the files that have changed between two versions, rather than redistributing the entire package.

## Overview

A delta package contains:

- **Changed files**: Files that differ between the source and target versions
- **Wholesale directories**: Complete directories that must be replaced entirely (e.g., `bin/kube`, `bin/docker`)
- **Delta manifest**: A JSON file describing the changes and metadata
- **Debian package changes** (optional): Linux package differences for the KubeMaster VM
- **Changed Kubernetes images**: Required control-plane images are exported into the package; creation fails if any changed image cannot be exported
- **Apply script**: A PowerShell script to apply the delta to an existing installation

!!! note "Addons are excluded"
    Delta packages do **not** include addon files. Addons are managed separately via `k2s addons ...` and are not modified during a delta upgrade.

### Delta Package vs Full Package

| Aspect | Full Package | Delta Package |
|--------|--------------|---------------|
| Size | 2-4 GB typically | 50-1000 MB typically |
| Contains | All K2s files | Only changed files |
| Requires | Nothing | Specific source version |
| Use case | Fresh installs, major upgrades | Minor/patch upgrades |

!!! tip "Node packages also support delta mode"
    In addition to cluster-level delta packages, *K2s* supports node-specific packages (full and delta) for upgrading bare-metal or VM-based Linux worker nodes independently of the control plane. See [Node Packages](#node-packages).

## Creating a Delta Package

### Prerequisites

- Two *K2s* offline packages (source and target versions)
- PowerShell 5.1 or later
- Sufficient disk space for extraction (3x package size recommended)

### Basic Usage

```console
k2s system package --delta-package `
    -d C:\packages `
    -n k2s-delta-v1.4.0-to-v1.5.0.zip `
    --package-version-from C:\packages\k2s-v1.4.0.zip `
    --package-version-to C:\packages\k2s-v1.5.0.zip
```

### Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `--delta-package` | Yes | Enables delta package creation mode |
| `-d, --target-dir` | Yes | Target directory for the output package |
| `-n, --name` | Yes | Name of the output delta package ZIP file |
| `--package-version-from` | Yes | Path to the older (source) K2s package ZIP |
| `--package-version-to` | Yes | Path to the newer (target) K2s package ZIP |
| `-c, --certificate` | No | Path to code signing certificate (.pfx file) |
| `-w, --password` | No | Password for the code signing certificate |
| `-o, --output` | No | Show log output in terminal |

### Example with Code Signing

```console
k2s system package --delta-package `
    -d C:\packages `
    -n k2s-delta-v1.4.0-to-v1.5.0.zip `
    --package-version-from C:\packages\k2s-v1.4.0.zip `
    --package-version-to C:\packages\k2s-v1.5.0.zip `
    -c path\to\cert.pfx `
    -w mycertpassword
```

## Delta Package Contents

After creation, the delta package contains:

```
k2s-delta-v1.4.0-to-v1.5.0.zip
├── delta-manifest.json          # Metadata and file lists
├── Apply-Delta.ps1              # Application script
├── bin/                         # Changed binaries
│   ├── kube/                   # Kubernetes binaries (wholesale)
│   ├── docker/                 # Docker binaries (wholesale)
│   ├── containerd/             # Containerd binaries (wholesale)
│   └── cni/                    # CNI plugins (wholesale)
├── lib/                         # Changed library files
├── smallsetup/                  # Changed setup scripts
├── scripts/                     # Delta application scripts
│   ├── apply-debian-delta.sh   # Linux package update script
│   └── verify-debian-delta.sh  # Linux package verification
└── debian-delta/                # (Optional) Debian package changes
    ├── added-packages.txt
    ├── removed-packages.txt
    ├── changed-packages.txt
    └── packages/                # Downloaded .deb files
```

### Delta Manifest Structure

The `delta-manifest.json` file describes the changes between versions. A typical manifest includes:

```json
{
  "ManifestVersion": "2.0",
  "BaseVersion": "2.0.0",
  "TargetVersion": "2.1.0",
  "BaseKubernetesVersion": "v1.36.4",
  "TargetKubernetesVersion": "v1.36.5",
  "Added": ["lib/new-module.psm1"],
  "Changed": ["lib/existing-module.psm1"],
  "Removed": ["lib/deprecated-module.psm1"],
  "WholeDirectories": ["bin/kube", "bin/docker", "bin/cni", "bin/containerd"],
  "DebianDeltaRelativePath": "debian-delta"
}
```

The Kubernetes versions are read from the source and target packages during delta creation. During application, *K2s* requires the live client and server versions to match `TargetKubernetesVersion` before persisting that value to `setup.json`. This check explicitly uses `bin\kube\kubectl.exe` and the `config` kubeconfig from the destination installation, not the old installation's client retained by already-loaded modules. The persisted value is read back from disk before the upgrade can report success. Delta packages created before these manifest fields existed continue to use `debian-delta/expected-k8s-version` when available.

## Applying a Delta Package

### Prerequisites

- An existing *K2s* installation matching the delta's source version
- A running cluster; run `k2s start` from the current installation first. Delta upgrades reject stopped clusters before applying files, Debian packages, or relocation changes.
- Administrator privileges
- The delta package ZIP file

### Where the installation ends up

When a delta package is applied, the **extracted delta folder becomes the new active installation folder**. After the update, `setup.json` (`InstallFolder`) points to this folder and the cluster services run from it.

The upgrade checks the original installation's persisted `setup.json` after relocation and before reporting success. A missing file or mismatched `InstallFolder` fails the upgrade rather than reporting a successful relocation.

Because of this, extract the delta package to the location where you want the upgraded installation to live — typically a versioned folder such as `C:\k2s\<new-version>`:

- The previous installation folder is **left untouched and retained for rollback**. You may delete it after you have verified the upgrade.
- If you instead extract the delta on top of the current installation folder (so the extraction folder equals the existing `InstallFolder`), *K2s* falls back to the legacy in-place update and the installation folder does not change.
- Applying a Kubernetes version delta does not rely on registry access. If a required bundled image is missing or `kubeadm` cannot complete the control-plane upgrade, the update fails and does not record the new Kubernetes version.

### Application Steps

1. Extract the delta package to the desired final installation location (a versioned folder is recommended):
   ```powershell
   Expand-Archive -Path "k2s-delta-v1.4.0-to-v1.5.0.zip" -DestinationPath "C:\k2s\1.5.0"
   ```

2. Run the upgrade from the extracted delta folder:
   ```console
   cd C:\k2s\1.5.0
   k2s system upgrade
   ```

3. Verify the installation:
   ```console
   k2s system status
   ```

   After a successful upgrade, `C:\k2s\1.5.0` is the active installation. The previous installation folder remains on disk for rollback and can be deleted once the upgrade is confirmed.

!!! note "Rollback scope"
    If the update fails after the installation has been re-homed to the new folder, the Windows-side changes (service configuration, `setup.json`, kubeconfig) are automatically rolled back to the previous installation folder. Cluster/Linux-side changes (kubeadm upgrade, Debian package updates) are **not** reverted — this is consistent with the behavior of a full upgrade.

## Node Packages

Node packages contain the Linux packages and container images required to run *K2s* worker nodes (kubelet, kubeadm, kubectl, CRI-O, buildah). They are independent of the control-plane installation, allowing you to upgrade bare-metal or VM-based Linux worker nodes without touching the cluster control plane.

Both full node packages and node delta packages are created with the `--node-package` flag.

### Full Node Package

A full node package bundles everything needed for a fresh node installation or a full node upgrade.

Creating a full node package requires an existing *K2s* cluster on the machine where you run the command, and it must use the local cluster proxy `http://172.19.1.1:8181`.

```console
k2s system package --node-package --os debian12 `
  --target-dir "C:\out" `
  --name "debian12-node.zip" `
  -p http://172.19.1.1:8181
```

#### Full Node Package Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `--node-package` | Yes | Selects node package mode |
| `--os` | Yes | Target Linux distribution (e.g. `debian12`, `debian13`) |
| `-d, --target-dir` | Yes | Output directory |
| `-n, --name` | Yes | Output ZIP file name |
| `-p, --proxy` | Yes | Local cluster proxy, `http://172.19.1.1:8181` |
| `-o, --output` | No | Show log output in terminal |

### Node Delta Package

A node delta package contains only the Debian packages and container images that changed between two node package versions — significantly reducing transfer size for incremental upgrades.

```console
k2s system package --node-package --delta-package `
  --package-version-from C:\packages\debian13-node-v1.7.0.zip `
  --package-version-to C:\packages\debian13-node-v1.8.0.zip `
  -d C:\packages `
  -n debian13-node-delta-v1.7.0-to-v1.8.0.zip
```

The `--os` flag is optional in delta mode — the OS folder is auto-detected from the ZIP structure. Specify it explicitly only when both input ZIPs contain multiple OS directories.

#### Node Delta Package Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `--node-package` | Yes | Selects node package mode |
| `--delta-package` | Yes | Enables delta (diff) mode |
| `--package-version-from` | Yes | Path to the older (base) node package ZIP |
| `--package-version-to` | Yes | Path to the newer (target) node package ZIP |
| `-d, --target-dir` | Yes | Output directory |
| `-n, --name` | Yes | Output ZIP file name |
| `--os` | No | OS folder override (e.g. `debian12`); auto-detected if omitted |
| `-o, --output` | No | Show log output in terminal |

### Node Delta Package Contents

```
deb12-node-delta-v1.7.0-to-v1.8.0.zip
├── delta-manifest.json      # Metadata and file lists (DeltaType: "node-package")
├── Apply-Delta.ps1          # Manual application helper (Windows host)
├── apply-node-delta.sh      # Manual application helper (Linux node)
├── verify-node-delta.sh     # Manual verification helper (Linux node)
├── packages/
│   └── debian13/            # Changed and added .deb files only
│       ├── kubelet_1.35.2-1.1_amd64.deb
│       └── ...
├── images/                  # Changed and added container image archives
│   ├── pause.tar
│   └── ...
├── packages.removed         # (Optional) Removed .deb filenames, one per line
└── images.removed           # (Optional) Removed image tar filenames, one per line
```

The `delta-manifest.json` uses `ManifestVersion: "2.0"` and `DeltaType: "node-package"` to distinguish it from a cluster delta manifest.

### Applying a Node Upgrade

Use `k2s system upgrade --node` to upgrade a worker node. The upgrade mode is **auto-detected** from the ZIP contents:

- ZIP contains `delta-manifest.json` with `DeltaType: "node-package"` → **delta upgrade**  
  (installs only changed/added packages; purges removed ones)
- No `delta-manifest.json` present → **full upgrade**  
  (installs all packages present in the ZIP)

```console
k2s system upgrade --node k2s-nodepkg-debian13 --path "C:\ws\DeltaPackage\debian13-node-delta-v1.7.0-to-v1.8.0.zip" -o
```

The same command works for full node packages:

```console
k2s system upgrade --node k2s-nodepkg-debian13 --path "C:\ws\DeltaPackage\debian13-node-v1.8.0.zip" -o
```

#### `k2s system upgrade --node` Flags

| Flag | Required | Description |
|------|----------|-------------|
| `-n, --node` | Yes | Worker node name as registered in the cluster |
| `--path` | Yes | Path to the node package ZIP (full or delta) |
| `-o, --output` | No | Show detailed log output |

!!! note "`--node` and `--path` are paired flags"
    Both flags must always be specified together. Omitting one while providing the other results in an error.

## Best Practices

### When to Use Delta Packages

✅ **Recommended for:**

- Minor version upgrades (e.g., 1.4.0 → 1.5.0)
- Patch releases (e.g., 1.4.0 → 1.4.1)
- Bandwidth-constrained environments
- Large-scale deployments with many nodes

❌ **Not recommended for:**

- Major version upgrades (e.g., 1.x → 2.x)
- Fresh installations
- Upgrades spanning multiple minor versions

### Version Compatibility

> **⚠️ Version Matching:** Delta packages are version-specific. A delta from v1.4.0 to v1.5.0 can **only** be applied to installations running exactly v1.4.0.

To upgrade across multiple versions, either:

1. Create sequential delta packages (v1.4.0 → v1.4.1 → v1.5.0)
2. Use a full package for the final version

## Troubleshooting

### Common Issues

#### Version Mismatch Error

```
Error: Source version mismatch. Expected 1.4.0, found 1.3.0
```

**Solution**: Ensure your current installation matches the delta's source version, or use `-Force` (with caution).

#### Missing Files After Apply

Check the delta manifest to verify which files were expected:

```powershell
Get-Content delta-manifest.json | ConvertFrom-Json | Select-Object -ExpandProperty filesAdded
```

#### Debian Delta Failures

If Linux package updates fail:

1. Check network connectivity in the VM
2. Verify the `.deb` files exist in `debian-delta/packages/`
3. Run verification script to identify missing packages

### Logs

Delta package creation logs are written to:

- Console output (with `-o` or `--output` flag)
- K2s log directory: `C:\var\log\k2s\`

For more detailed logging, use the verbosity flag:
```console
k2s system package --delta-package ... -o -v debug
```

## Integration with CI/CD

### Automated Delta Generation

```yaml
# Example GitHub Actions workflow snippet
- name: Generate Delta Package
  run: |
    k2s system package --delta-package `
      -d ${{ env.OUTPUT_DIR }} `
      -n "k2s-delta-${{ env.PREV_VERSION }}-to-${{ env.NEW_VERSION }}.zip" `
      --package-version-from "${{ env.PREV_PACKAGE }}" `
      --package-version-to "${{ env.NEW_PACKAGE }}" `
      -o
```

### Artifact Publishing

Delta packages can be published alongside full releases:

```
releases/
├── k2s-v1.5.0.zip                    # Full package
├── k2s-delta-v1.4.0-to-v1.5.0.zip   # Delta from previous minor
└── k2s-delta-v1.4.1-to-v1.5.0.zip   # Delta from previous patch
```

## See Also

- [Creating Offline Package](creating-offline-package.md) - Full offline package creation
- [Upgrading K2s](upgrading-k2s.md) - Standard upgrade procedures
- [Sign K2s Package](signcatalog-k2s.md) - Code signing for packages
