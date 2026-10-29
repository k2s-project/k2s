<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: MIT
-->

# Addons

*K2s* provides a rich set of **addons** that deliver optional, pre-configured open-source components in a plugin-like manner. Addons can be enabled, disabled, exported, imported, backed up, and restored entirely through the `k2s` CLI.

## Why Use Addons?

Deploying individual workloads (e.g., manually installing an ingress controller, a monitoring stack, or a container registry) requires:

- Finding and validating compatible Helm charts or manifests for your Kubernetes version
- Configuring networking, storage, and security to match your cluster
- Managing updates and version compatibility across components
- Handling offline image pre-loading for air-gapped environments
- Writing custom backup/restore logic for each component

**K2s addons solve all of these problems out of the box.** Each addon:

- **Is pre-tested** against the shipped Kubernetes version — no compatibility guesswork
- **Integrates with the K2s cluster** networking, storage, and proxy configuration automatically
- **Supports offline usage** — addon images can be exported as OCI artifacts and imported without network access
- **Provides lifecycle management** — enable, disable, update, backup, and restore via single CLI commands
- **Is versioned with K2s** — addon updates are coordinated with cluster upgrades
- **Follows consistent patterns** — same CLI workflow for every addon, reducing operational complexity

### Comparison: Addons vs. Manual Workloads

| Aspect | K2s Addon | Manual Workload |
|--------|-----------|-----------------|
| Installation | `k2s addons enable <name>` | Find charts, write values, `helm install`, debug |
| Offline support | `k2s addons export` / `import` | Manual image pull, save, transfer, load |
| Configuration | Pre-configured for K2s | Manual adjustment for networking, storage, proxy |
| Updates | `k2s addons enable <name>` (re-enable with new version) | Manual chart/manifest version management |
| Backup & Restore | `k2s addons backup` / `restore` | Custom scripts per component |
| Status check | `k2s addons status <name>` | Manual `kubectl` queries per component |
| GitOps deployment | Rollout addon with ArgoCD or Flux CD | Set up GitOps tooling from scratch |
| Version compatibility | Tested with shipped K8s version | User must verify compatibility |

## Available Addons

| Addon | Description |
|-------|-------------|
| **autoscaling** | Horizontal workload scaling based on external events with KEDA |
| **dashboard** | Headlamp - Kubernetes Dashboard (kubernetes-sigs) |
| **dicom** | DICOM server based on Orthanc |
| **gpu-node** | GPU access for the control plane node |
| **ingress** | Ingress controllers (nginx, nginx-gw, traefik implementations) |
| **kserve** | Standard-mode model serving with optional CPU/GPU LLM examples (Windows hosts) |
| **kubevirt** | VM workload management on Kubernetes |
| **logging** | Container log dashboard |
| **metrics** | Kubernetes metrics server for API access to service metrics |
| **monitoring** | Cluster resource monitoring and logging dashboard |
| **registry** | Private image registry on `k2s.registry.local` |
| **rollout** | GitOps deployment automation (ArgoCD or Flux CD) |
| **security** | Secure communication inside the cluster |
| **storage** | Persistent StorageClass provisioning (`smb` file shares between K8s nodes, or `ceph` CephFS storage using ceph and ceph-smb provisioner) |
| **viewer** | Clinical image viewer |

!!! tip
    Some addons have multiple **implementations**. For example, the *ingress* addon offers `nginx`, `nginx-gw`, and `traefik`. Specify the implementation when enabling: `k2s addons enable ingress nginx`.

## Addon Configuration Details

This section documents the CLI flags available for each addon. Flags without defaults are optional unless marked otherwise.

### ingress

Three mutually exclusive implementations for external access:

| Implementation | Engine | Description |
|----------------|--------|-------------|
| `nginx` | NGINX Ingress Controller | Reverse proxy based on NGINX |
| `traefik` | Traefik Proxy | Cloud-native reverse proxy |
| `nginx-gw` | NGINX Gateway Fabric | Gateway API-based NGINX controller |

| Enable Flag | Type | Default | Description |
|-------------|------|---------|-------------|
| `--omitCertMgr` | boolean | `false` | Omit cert-manager installation. Use when you want to provide your own certificate issuer. See [Certificate Management](certificate-management.md). |

```console
k2s addons enable ingress nginx
k2s addons enable ingress traefik
k2s addons enable ingress nginx-gw

# Without default cert-manager (bring your own issuer)
k2s addons enable ingress nginx --omitCertMgr
```

Only one ingress implementation can be active at a time. By default, cert-manager is installed with a self-signed CA. See [Certificate Management](certificate-management.md) for details on using external certificate authorities.

### kserve

Standard-mode KServe model serving for Windows-hosted K2s clusters, without
Knative or Istio. No model is started by default.

| Enable Flag | Type | Default | Description |
|-------------|------|---------|-------------|
| `--model` | string | `none` | Optional `qwen-cpu` or `qwen-gpu` example; explicitly downloads public weights |
| `--proxy` | string | `auto` | Model download proxy: K2s host proxy, an HTTP(S) URL, or `none` for direct access |
| `--ca-bundle` | string | empty | Approved public PEM CA bundle for model download HTTPS |

```console
k2s addons enable kserve
k2s addons status kserve
k2s addons disable kserve
```

Requires Kubernetes 1.32+, a Linux node, and additional CPU/RAM capacity for
model workloads. The GPU example also requires compatible NVIDIA drivers,
container runtime integration and an advertised GPU resource.
Webhook certificates are addon-owned and independent of cert-manager, ingress and
security. Certificate checks and renewal use the addon's existing cluster-start
hook; `k2s system certificate renew` does not rotate KServe's webhook certificate.
Disable retains CRDs, namespaces and model storage, and refuses while custom model
workloads still require the controller. Offline export includes images, not model
weights; pre-stage weights on a PVC for disconnected inference.
See the [KServe addon README](https://github.com/k2s-project/k2s/blob/main/addons/kserve/README.md)
for model access, proxy/CA setup and prerequisites.

### dashboard

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | | string | `none` | Ingress controller to expose the dashboard (`none`, `nginx`, `nginx-gw`, `traefik`) |
| `--enable-metrics` | | boolean | `false` | Enable metrics display in the dashboard |

```console
k2s addons enable dashboard --ingress nginx --enable-metrics
```

### monitoring

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `none` | Ingress controller for the monitoring dashboard (`none`, `nginx`, `nginx-gw`, `traefik`) |

Includes Windows node metrics collection via `windows-exporter` alongside Linux metrics via `node-exporter`.

### logging

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | | string | `none` | Ingress controller for log dashboards (`none`, `nginx`, `nginx-gw`, `traefik`) |

### registry

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `nginx` | Ingress controller for the registry (`nginx`, `nginx-gw`, `traefik`) |

| Disable Flag | Short | Type | Default | Description |
|--------------|-------|------|---------|-------------|
| `--delete-images` | `-d` | boolean | `false` | Delete all images stored in the local registry |

The registry is exposed on `k2s.registry.local`.

### security

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `nginx` | Ingress controller (`nginx`, `traefik`, `nginx-gw`) |
| `--type` | `-t` | string | `basic` | Security level: `basic` (cert-manager only) or `enhanced` (zero trust with Linkerd + OAuth2) |
| `--omitHydra` | | boolean | `false` | Skip Ory Hydra and Windows login integration |
| `--omitKeycloak` | | boolean | `false` | Skip Keycloak — use an external OAuth2 provider instead |
| `--omitOAuth2Proxy` | | boolean | `false` | Skip OAuth2 Proxy deployment |
| `--omitPolicyEnf` | | boolean | `false` | Skip Kyverno policy enforcement framework |

```console
# Basic: cert-manager only
k2s addons enable security

# Enhanced: zero trust with full authentication stack
k2s addons enable security --type enhanced --ingress nginx

# Enhanced with external IdP (no Keycloak)
k2s addons enable security --type enhanced --omitKeycloak
```

See [Security Features](../security/security-features.md) for details on the zero-trust architecture.

!!! tip
    In offline scenarios the container images of an omitted part do not have to be imported at all —
    see [Omitting Images During Import](#omitting-images-during-import).

### rollout

Two mutually exclusive GitOps implementations:

**ArgoCD:**

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `none` | Ingress controller for the ArgoCD dashboard (`none`, `nginx`, `nginx-gw`, `traefik`) |

**Flux CD:**

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `none` | Ingress controller for the webhook receiver (`none`, `nginx`, `nginx-gw`, `traefik`) |

When you enable `rollout fluxcd`, *K2s* installs the host Flux CLI at `bin\\flux.exe`. In offline environments the CLI zip is bundled in the addon export and extracted on import.

```console
k2s addons enable rollout argocd --ingress nginx
k2s addons enable rollout fluxcd --ingress traefik
```

### storage

Two mutually exclusive storage implementations are available:

- `storage smb` for SMB file sharing between K8s nodes
- `storage ceph` for CephFS storage (Linux) and optional Ceph SMB access (Windows)

Only one can be enabled at a time.

**smb:**

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--smbHostType` | `-t` | string | `windows` | SMB host type: `windows` or `linux` |

| Disable Flag | Short | Type | Default | Description |
|--------------|-------|------|---------|-------------|
| `--force` | `-f` | boolean | `false` | Disable and **delete all data** without confirmation |
| `--keep` | `-k` | boolean | `false` | Disable and **keep all data** without confirmation |

!!! warning
    `--force` and `--keep` are mutually exclusive.

```console
k2s addons enable storage smb --smbHostType linux
k2s addons disable storage smb --keep
```

**ceph:**

Provisions a Ceph cluster on a **Debian 13** K2s node and wires up CephFS via the upstream `ceph-csi-operator`.

- `ceph-cephfs` StorageClass (`cephfs.csi.ceph.com`) for Linux workloads
- optional `ceph-smb` StorageClass (`smb.csi.k8s.io`) for Windows workloads when enabled with `-w`

Cluster host and OSD sizing are read from `addons/storage/ceph/config/ceph-config.json`.

Ceph enable commands:

```console
# Linux CephFS only
k2s addons enable storage ceph

# Linux CephFS + Windows Ceph SMB path
k2s addons enable storage ceph -w
```

When `-w` is used, K2s configures Ceph `mgr/smb`, creates SMB CSI resources, and creates Secret `smbcreds` (in namespace `storage-smb-ceph` by default) with `username` and `password` for the `ceph-smb` StorageClass.

| Disable Flag | Short | Type | Default | Description |
|--------------|-------|------|---------|-------------|
| `--force` | `-f` | boolean | `false` | Disable without confirmation prompt |

!!! warning
    Disabling Ceph always tears down the provisioned Ceph cluster, including OSD resources and Ceph-backed PVs from this setup. Ceph data is permanently lost after disable.

```console
k2s addons disable storage ceph
k2s addons disable storage ceph -f
```


### dicom

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | | string | `none` | Ingress controller (`none`, `nginx`, `nginx-gw`, `traefik`) |
| `--storage` | | string | `none` | Storage addon for persistent DICOM data (`none`, `smb`) |
| `--storagedir` | | string | `none` | Path to SMB storage directory (e.g. `/mnt/k8s-smb-share`) |

| Disable Flag | Short | Type | Default | Description |
|--------------|-------|------|---------|-------------|
| `--force` | `-f` | boolean | `false` | Disable and **delete all data** without confirmation |

```console
k2s addons enable dicom --ingress nginx --storage smb --storagedir /mnt/k8s-smb-share
```

### viewer

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `nginx` | Ingress controller (`nginx`, `nginx-gw`, `traefik`) |
| `--nodeport` | `-n` | integer | `0` | NodePort for direct viewer access (range: 30000–32767, `0` = disabled) |

```console
k2s addons enable viewer --ingress traefik --nodeport 31000
```

### kubevirt

No CLI flags. Enables VM workload management on Kubernetes.

When used offline, the addon installs QEMU, libvirt, and `virtctl` on the Linux VM, and `virt-viewer` MSI plus `virtctl` on the Windows host.

Online enablement and addon export download the Windows `virt-viewer` 11.0 MSI from the [official GitLab release](https://gitlab.com/virt-viewer/virt-viewer/-/releases/v11.0).

Additional helper scripts:

- `BuildKubevirtImage.ps1` — build VM disk images for KubeVirt
- `UploadImage.ps1` — upload disk images to a running KubeVirt instance

### gpu-node

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--time-slices` | `-t` | integer | `1` | Number of virtual GPU slots per physical GPU. `1` = exclusive access. Set `>1` to share the GPU across multiple pods simultaneously via CUDA time-slicing (max `16`). |

```console
k2s addons enable gpu-node
k2s addons enable gpu-node --time-slices 4
```

Installs the NVIDIA Container Toolkit on the Linux VM and deploys the NVIDIA Device Plugin DaemonSet. For Hyper-V setups, also configures GPU-PV passthrough and installs the WSL2 kernel. For WSL2 setups, the GPU libraries are already available via the shared dxcore stack.

See [GPU Node](gpu-node.md) for full usage details including how to write GPU pod specs, time-slicing, offline workflow, and known limitations.

### autoscaling

No CLI flags. Installs [KEDA](https://keda.sh){target="_blank"} (Kubernetes Event-Driven Autoscaling) for horizontally scaling workloads based on external events or triggers.

### metrics

No CLI flags. Installs the Kubernetes **metrics server**, enabling `kubectl top nodes`, `kubectl top pods`, and Horizontal Pod Autoscaler (HPA) support.

## Managing Addons

### Listing Addons

```console
k2s addons ls
```

### Enabling an Addon

```console
# Enable an addon (single implementation)
k2s addons enable dashboard

# Enable an addon with a specific implementation
k2s addons enable ingress nginx

# Enable with flags
k2s addons enable dashboard --ingress
```

### Disabling an Addon

```console
k2s addons disable dashboard
k2s addons disable ingress nginx
```

### Checking Addon Status

```console
k2s addons status dashboard
k2s addons status ingress nginx

# JSON output
k2s addons status registry -o json
```

## Offline Usage: OCI Export & Import

One of the most powerful addon features is the ability to **export addons as OCI-compliant artifacts** and **import them on air-gapped systems**. This enables fully offline addon deployment without any network access.

### How It Works

When you export an addon, K2s packages everything needed into a single OCI-compliant tar archive:

- Container images (Linux and Windows)
- Kubernetes manifests
- Helm charts
- Configuration files
- Enable/Disable scripts

The resulting `.oci.tar` file follows the [OCI Image Layout Specification](https://github.com/opencontainers/image-spec/blob/main/image-layout.md){target="_blank"}, making it compatible with standard container tooling.

### Exporting Addons

```console
# Export all addons
k2s addons export -d C:\export

# Export a specific addon
k2s addons export registry -d C:\export

# Export a specific implementation
k2s addons export "ingress nginx" -d C:\export
```

The export produces a file like `addons.oci.tar` containing all requested addon artifacts.

### Importing Addons

On the target system (which may be offline), import the previously exported archive:

```console
# Import all addons from archive
k2s addons import -f C:\transfer\addons.oci.tar

# Import a specific addon
k2s addons import registry -f C:\transfer\addons.oci.tar

# Import a specific implementation
k2s addons import ingress nginx -f C:\transfer\addons.oci.tar

# Import several addons/implementations at once
k2s addons import ingress nginx registry -f C:\transfer\addons.oci.tar
```

After import, the addon images are loaded into the cluster's container runtime and the addon can be enabled normally.

!!! note
    If you name addons on the command line, only those addons take part in the import. If you name
    none, all addons contained in the artifact are selected. An addon that is present in the artifact
    but not selected is skipped entirely — its images are not imported.

### Omitting Images During Import

Some addons can be enabled without parts of their functionality, e.g. `k2s addons enable security --omitKeycloak`.
The container images of those parts are still contained in the artifact, but they do not have to be
loaded into the container runtime. `k2s addons import --omit` skips them and thereby reduces the
disk footprint of an offline installation.

#### Basic usage

Pass the name of the `enable` flag whose functionality you do not intend to use:

```console
k2s addons import security -f C:\transfer\addons.oci.tar --omit omitKeycloak
```

The images belonging to Keycloak are not imported; everything else is imported as usual.

#### Multiple omit options

`--omit` is repeatable:

```console
k2s addons import security -f C:\transfer\addons.oci.tar --omit omitKeycloak --omit omitOAuth2Proxy
```

#### Multiple addons and scoping

An import can select several addons and implementations. Omit processing only applies to the
implementations that were selected for **this** import:

```console
k2s addons import ingress nginx security -f C:\transfer\addons.oci.tar --omit omitCertMgr
```

An omit option can be scoped so that it only applies to one addon or one implementation:

| Token | Applies to |
| --- | --- |
| `omitCertMgr` | every selected implementation declaring that flag |
| `ingress:omitCertMgr` | all selected implementations of the `ingress` addon |
| `ingress/nginx:omitCertMgr` | the `ingress nginx` implementation only |

Unknown or wrongly scoped options are ignored with a warning and never cause additional images to be
skipped.

#### Shared images

Addons can share images. An image is only skipped when **no selected implementation still requires it**.

For example, `ingress nginx` can omit cert-manager, but the `security` addon always requires it:

```console
k2s addons import ingress nginx security -f C:\transfer\addons.oci.tar --omit omitCertMgr
```

Result: the cert-manager images **are imported**, because `security` — which is part of the same
import — still needs them. Importing `ingress nginx` alone with the same option does skip them.

#### The artifact remains unchanged

`--omit` does **not** modify, shrink or repack the OCI artifact. It only controls which images are
loaded into the local container runtime. Importing with `--omit` also never deletes images that are
already present locally.

#### Re-import

Because the artifact is untouched, importing it again later without `--omit` adds the previously
skipped images:

```console
# initially imported without the Keycloak images
k2s addons import security -f C:\transfer\addons.oci.tar --omit omitKeycloak

# later on: add the missing images from the very same artifact
k2s addons import security -f C:\transfer\addons.oci.tar
```

No re-export is required.

#### Air-gapped environments

If an image is omitted during import and the corresponding functionality is enabled later, that image
must be available locally — an air-gapped cluster cannot pull it from a registry. Either keep the
artifact available for a re-import, or enable the addon with the matching omit flag.

!!! warning "Enable-time limitation"
    The `--omit` choice made during import is **not** persisted as addon enable state. Running

    ```console
    k2s addons import security -f C:\transfer\addons.oci.tar --omit omitKeycloak
    ```

    does **not** make a later `k2s addons enable security` behave like `k2s addons enable security --omitKeycloak`.
    Enable the addon with the matching flag, or re-import the artifact without `--omit` beforehand.

### Typical Offline Workflow

1. **On an online machine** with K2s installed, export the addons you need:
   ```console
   k2s addons export ingress nginx registry monitoring -d C:\export
   ```
2. **Transfer** the `.oci.tar` file to the air-gapped environment (USB drive, secure file transfer, etc.)
3. **On the offline machine**, import and enable:
   ```console
   k2s addons import -f D:\transfer\addons.oci.tar
   k2s addons enable ingress nginx
   k2s addons enable registry
   k2s addons enable monitoring
   ```

## Backup & Restore

Addons support data backup and restore for disaster recovery or migration scenarios.

### Backing Up Addon Data

```console
# Backup to a specific file
k2s addons backup registry -f C:\backups\registry-backup.zip

# Backup to default location (C:\Temp\k2s\Addons)
k2s addons backup registry
```

### Restoring Addon Data

```console
# Restore from a specific file
k2s addons restore registry -f C:\backups\registry-backup.zip

# Restore newest backup from default location
k2s addons restore registry
```

## GitOps with the Rollout Addon

The **rollout** addon provides GitOps-based continuous deployment using either **ArgoCD** or **Flux CD**. This is especially powerful when combined with addon OCI export/import for offline environments.

### Why GitOps?

- **Declarative deployments** — desired state is defined in Git, not applied manually
- **Audit trail** — every change is a Git commit
- **Automated reconciliation** — drift from desired state is automatically corrected
- **Reproducible environments** — same Git repo produces identical deployments

### ArgoCD Implementation

```console
k2s addons enable rollout argocd
```

ArgoCD provides a web dashboard at `https://k2s.cluster.local/rollout` (when ingress is configured) for visual deployment management. It supports:

- Application deployment from Git repositories
- Sync status visualization
- Rollback capabilities
- Multi-application management

Optional ingress integration:
```console
k2s addons enable rollout argocd --ingress nginx
```

### Flux CD Implementation

```console
k2s addons enable rollout fluxcd
```

Flux CD provides a CLI/YAML-only GitOps experience with:

- `GitRepository`, `Kustomization`, `HelmRepository`, `HelmRelease` CRDs
- Automatic polling of Git repositories (default: every 1 minute)
- Optional webhook ingress for push-based notifications

Optional ingress integration:
```console
k2s addons enable rollout fluxcd --ingress traefik
```

### Offline GitOps Workflow

Combining OCI export/import with the rollout addon enables GitOps in air-gapped environments:

1. **Export** the rollout addon (and any other addons your applications depend on):
   ```console
   k2s addons export rollout ingress nginx registry -d C:\export
   ```
2. **Transfer** and **import** on the offline cluster:
   ```console
   k2s addons import -f D:\transfer\addons.oci.tar
   k2s addons enable rollout argocd --ingress nginx
   ```
3. **Configure ArgoCD/Flux** to point to a local Git server (also deployed in the cluster or available on the local network) containing your application manifests.

!!! note
    Only one rollout implementation can be active at a time — ArgoCD and Flux CD are mutually exclusive.

## See Also

- [Creating Offline Package](../op-manual/creating-offline-package.md) — includes addon packaging in the K2s offline package
- [Upgrading K2s](../op-manual/upgrading-k2s.md) — addon behavior during cluster upgrades
