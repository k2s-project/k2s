<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# GitOps Addon Delivery

K2s supports delivering addons to a cluster using GitOps workflows via **FluxCD** or **ArgoCD**. Addons exported as OCI artifacts can be pushed to an OCI registry, and the GitOps tooling automatically syncs them into the cluster — making them discoverable by `k2s addons ls` and ready for enablement via `k2s addons enable`.

## Overview

The GitOps addon delivery flow:

1. **Export** addons as OCI artifacts using `k2s addons export`
2. **Push** the OCI Image Layout artifact to a registry using `oras copy`
3. **GitOps tool detects** the new artifact digest in the registry
4. **Sync runs** on the Windows node to extract addon layers into the K2s addons directory
5. **Addons appear** in `k2s addons ls` and can be enabled normally

!!! important "Sync updates the addon catalog -- it does not auto-enable addon workloads"
    Addon-sync extracts definition files (manifests, scripts, config) into the local addon catalog on the Windows host. Container workloads are **not** started automatically. After sync completes, run `k2s addons enable <ADDON_NAME>` to deploy the addon's Kubernetes workloads.

Only layers 0-3 (config, manifests, charts, scripts) are synced. Image layers (4/5) and package layers (6) are **omitted** -- container images are pulled directly from the registry when the addon is enabled.

## Placeholder conventions

This guide uses the following placeholders:

- `<REGISTRY_HOST>` -- reachable OCI registry host (for example, `registry.example.local:5000`)
- `<REGISTRY_URL>` -- `oci://<REGISTRY_HOST>`
- `<ADDON_NAME>` -- addon repository name under `addons/`
- `<TAG>` -- addon artifact tag (typically the exported addon version)

## Prerequisites

- K2s must be installed and running
- A reachable OCI-compatible registry must be available to producer and consumer nodes
- `k2s addons enable registry` is optional for local K2s dev/test setups
- The **rollout** addon must be enabled with either the `fluxcd` or the `argocd` implementation

## Setup

### Using FluxCD

Use any reachable OCI registry. For local K2s dev/test only, you can enable the bundled registry addon:

```console
k2s addons enable registry
```

Then enable the FluxCD rollout implementation:

```console
k2s addons enable rollout fluxcd
```

By default, the rollout enable script deploys the **addon-sync infrastructure** into the `k2s-addon-sync` namespace. This installs:

| Resource | Purpose |
|----------|---------|
| `Namespace` `k2s-addon-sync` | Isolates addon-sync workloads |
| `ServiceAccount` `addon-sync-processor` | Identity for HostProcess Jobs |
| `ConfigMap` `addon-sync-config` | Registry URL, K2s install dir, insecure flag |
| `ConfigMap` `addon-sync-script` | Contains `Sync-Addons.ps1` (generated from file) |

Per-addon FluxCD resources (`OCIRepository addon-sync-<ADDON_NAME>` and `Kustomization addon-sync-<ADDON_NAME>`) are **not** deployed during setup. They are registered once per addon by applying the per-addon templates (see [Register addon for FluxCD sync](#register-addon-for-fluxcd-sync-one-time-per-addon)).

**How FluxCD triggers sync:**

1. Each addon has its own `OCIRepository addon-sync-<ADDON_NAME>` watching `addons/<ADDON_NAME>` every minute -- Flux selects the highest matching semver tag via `ref.semver: ">=0.0.0-0"` and detects when the selected revision changes
2. When a new revision is selected, Flux extracts the **manifests layer** from the artifact (using `layerSelector` with media type `application/vnd.k2s.addon.manifests.v1.tar+gzip`)
3. The manifests layer contains a `gitops-sync/` directory with a `sync-job.yaml` -- a HostProcess Job template injected by `Export.ps1` during export, with the addon name embedded
4. The per-addon `Kustomization addon-sync-<ADDON_NAME>` applies `gitops-sync/sync-job.yaml`, which creates a HostProcess Job on the Windows node
5. The Job runs `Sync-Addons.ps1 -AddonName <ADDON_NAME>` which pulls only the specific addon artifact and extracts layers 0-3 to the addons directory

!!! success "No global trigger required"
    Each addon has its own `OCIRepository` watching only its repository (`addons/<ADDON_NAME>`).
    Pushing a new versioned tag only triggers reconciliation for that specific addon, not all addons at once.
    FluxCD polls every minute (`interval: 1m` on `OCIRepository`). The ArgoCD poller CronJob runs every 5 minutes — a deliberate trade-off for simplicity (no separate Linux pod, no K8s API state).

!!! info "The export timestamp"
    `Export.ps1` replaces a timestamp placeholder in the Job annotation on each export. Combined with Flux's `force: true` setting, this ensures the Job is recreated every time the artifact changes.

### Using ArgoCD

Use any reachable OCI registry. For local K2s dev/test only, you can enable the bundled registry addon:

```console
k2s addons enable registry
```

Then enable the ArgoCD rollout implementation:

```console
k2s addons enable rollout argocd
```

The addon-sync infrastructure deployed for ArgoCD includes:

| Resource | Kind | Purpose |
|----------|------|---------|
| `k2s-addon-sync` | `Namespace` | Isolates addon-sync workloads |
| `addon-sync-poller` | `CronJob` | Windows HostProcess, runs `Sync-Addons.ps1 -CheckDigest true` every 5 minutes |
| `addon-sync-processor` | `ServiceAccount` | Identity for the poller CronJob (no K8s API RBAC needed — state on host filesystem) |
| `addon-sync-config` | `ConfigMap` | Registry URL, K2s install dir, insecure flag |
| `addon-sync-script` | `ConfigMap` | Contains `Sync-Addons.ps1` (generated from file) |

**How ArgoCD triggers sync:**

ArgoCD cannot natively watch raw OCI artifact layers (unlike FluxCD's `OCIRepository`). Instead, the `addon-sync-poller` CronJob polls the registry directly, running as a Windows HostProcess at the same privilege level as the sync Jobs:

1. A **consumer manually pushes** an OCI artifact to `addons/<ADDON_NAME>` in the registry
2. The `addon-sync-poller` CronJob runs every 5 minutes on the Windows node
3. `Sync-Addons.ps1 -CheckDigest true` calls `oras repo ls` to discover `addons/*` repositories, selects the tag per repo (`latest` if present, otherwise the highest available semver tag), and fetches the manifest digest
4. The digest is compared against a per-addon file at `$K2sInstallDir\addons\.addon-sync-digests\<ADDON_NAME>` on the Windows host filesystem
5. If the digest changed, the script pulls the artifact via `oras` and extracts layers 0-3 (config, manifests, Helm charts, scripts) to the K2s addons directory; the digest file is updated
6. After the sync completes, the addon appears in `k2s addons ls`
7. The **consumer manually enables** the addon with `k2s addons enable <ADDON_NAME>` to deploy its workloads

!!! important "Push and enable are manual consumer steps"
    The poller automates the download and extraction of addon artifacts. Pushing artifacts to the registry **and** enabling addons are both deliberate actions taken by the consumer.

### Disabling Addon-Sync

To deploy FluxCD or ArgoCD without the addon-sync infrastructure:

```console
k2s addons enable rollout fluxcd --addon-sync=false
k2s addons enable rollout argocd --addon-sync=false
```

This only deploys the GitOps tool itself. You can add addon-sync later by applying the kustomize overlay directly:

```console
kubectl apply -k <K2S_INSTALL_DIR>\addons\common\manifests\addon-sync\fluxcd\
kubectl apply -k <K2S_INSTALL_DIR>\addons\common\manifests\addon-sync\argocd\
```

### Removing Addon-Sync

When the rollout addon is disabled, the `k2s-addon-sync` namespace and all its resources are automatically cleaned up:

```console
k2s addons disable rollout fluxcd
k2s addons disable rollout argocd
```

## Delivering Addons via GitOps

### Export addon

Export one or more addons by name. For GitOps use, add `--omit-images` and `--omit-packages` since containers pull images directly from the registry:

```console
k2s addons export monitoring -d C:\exports --omit-images --omit-packages
```

Export multiple addons:

```console
k2s addons export registry ingress nginx -d C:\exports --omit-images --omit-packages
```

Export all addons (omit addon names):

```console
k2s addons export -d C:\exports --omit-images --omit-packages
```

The export produces a file like `K2s-<TAG>-addons-*.oci.tar` -- an OCI Image Layout archive containing `oci-layout`, `index.json`, and `blobs/sha256/`.

### Push to registry

The exported `.oci.tar` contains an OCI Image Layout at its root. The export process tags the artifact with the addon version (from `addon.manifest.yaml`).

The registry layout expected by addon-sync uses a **per-addon repository** structure:

```
addons/<ADDON_NAME>:<TAG>    <- per-addon artifact (versioned tag, e.g. v1.2.3)
```

Addon-sync discovers all repos matching `addons/*` automatically (ArgoCD).
For FluxCD, each addon's `OCIRepository addon-sync-<ADDON_NAME>` selects the highest semver-matching tag in `addons/<ADDON_NAME>` via `ref.semver: ">=0.0.0-0"`. A single versioned push is sufficient -- no `latest` tag is needed.

To find the tag, inspect the exported `index.json`:

```powershell
$tarFile = Get-Item C:\exports\K2s-*-addons-*.oci.tar | Select-Object -First 1

# Extract and check the tag
$tempDir = Join-Path $env:TEMP "oci-inspect"
mkdir $tempDir -Force | Out-Null
tar -xf $tarFile.FullName -C $tempDir oci-layout index.json
$index = Get-Content "$tempDir\index.json" | ConvertFrom-Json
$tag = $index.manifests[0].annotations.'org.opencontainers.image.ref.name'
Remove-Item $tempDir -Recurse -Force

Write-Host "Exported tag: $tag"
```

Push to the per-addon repository with the versioned tag:

```powershell
$orasExe = Join-Path $k2sInstallDir 'bin\oras.exe'

# One push -- FluxCD semver selection and ArgoCD tag selection both pick it up automatically
& $orasExe copy --from-oci-layout "${tarFile}:$tag" --to-plain-http <REGISTRY_HOST>/addons/<ADDON_NAME>:$tag
```

Complete example with the monitoring addon:

```powershell
$orasExe = Join-Path $k2sInstallDir 'bin\oras.exe'

# Export monitoring addon (omit images/packages for GitOps)
k2s addons export monitoring -d C:\exports --omit-images --omit-packages

# Find the tar and extract its version tag
$tar = (Get-ChildItem C:\exports -Filter *monitoring*.oci.tar)[0].FullName
$tempDir = Join-Path $env:TEMP "oci-inspect"
mkdir $tempDir -Force | Out-Null
tar -xf $tar -C $tempDir oci-layout index.json
$tag = (Get-Content "$tempDir\index.json" | ConvertFrom-Json).manifests[0].annotations.'org.opencontainers.image.ref.name'
Remove-Item $tempDir -Recurse -Force

# One push -- versioned tag is sufficient
& $orasExe copy --from-oci-layout "${tar}:$tag" --to-plain-http <REGISTRY_HOST>/addons/<ADDON_NAME>:$tag
```

!!! success "FluxCD sync triggers automatically"
    Once pushed, FluxCD's per-addon `OCIRepository` selects the new highest semver tag and creates a sync Job for that addon. No `latest` tag push is required.

!!! info "Tag format"
    Export.ps1 tags artifacts using the version from `addon.manifest.yaml` (e.g., `v1.0.0`). The source tag is required for `--from-oci-layout`, but you can retag to `latest` (or any tag) at the destination registry.

!!! success "Verified approach"
    This `--from-oci-layout` method works directly with the `.oci.tar` file without requiring full extraction. Only `index.json` needs to be inspected to discover the tag.

!!! tip "Multiple addons in one artifact"
    If you exported multiple addons with different implementations, the OCI Image Index contains multiple manifests. The addon-sync system processes all manifests in the index automatically.

!!! warning "Why not `oras push`?"
    `oras push` uploads individual files as opaque blobs, which loses the multi-layer OCI structure (layer media types, manifest references, per-addon annotations, etc.). Always use `oras copy --from-oci-layout` to preserve the complete artifact structure that `Sync-Addons.ps1` and FluxCD's `layerSelector` depend on.

### Register addon for FluxCD sync (one-time per addon)

For FluxCD, each addon needs its own `OCIRepository` and `Kustomization` in `k2s-addon-sync`.
These are created once per addon and remain in the cluster across pushes -- subsequent pushes
of new versioned tags to `addons/<ADDON_NAME>` are detected automatically without re-applying these resources.

Template files are located at:

```
<K2S_INSTALL_DIR>\addons\common\manifests\addon-sync\fluxcd\per-addon\
  ocirepository-template.yaml
  kustomization-template.yaml
```

Substitute placeholders and apply:

```powershell
$k2sInstallDir = (kubectl get configmap addon-sync-config -n k2s-addon-sync -o jsonpath='{.data.K2S_INSTALL_DIR}').Trim()
$addonName     = '<ADDON_NAME>'                 # <-- change to your addon folder name
$registryHost  = '<REGISTRY_HOST>'              # <-- e.g. k2s.registry.local:30500
$insecure      = 'true'                         # <-- set to 'false' for TLS registries

$templateDir = Join-Path $k2sInstallDir 'addons\common\manifests\addon-sync\fluxcd\per-addon'

$tmpDir = Join-Path $env:TEMP "addon-sync-register-$addonName"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

foreach ($template in @('ocirepository-template.yaml', 'kustomization-template.yaml')) {
    $content = Get-Content (Join-Path $templateDir $template) -Raw
    $content = $content -replace 'ADDON_NAME_PLACEHOLDER',    $addonName
    $content = $content -replace 'REGISTRY_HOST_PLACEHOLDER', $registryHost
    $content = $content -replace 'INSECURE_PLACEHOLDER',      $insecure
    Set-Content -Path (Join-Path $tmpDir $template) -Value $content -Encoding UTF8
}

kubectl apply -f $tmpDir
Remove-Item $tmpDir -Recurse -Force
```

Verify the resources were created:

```powershell
kubectl get ocirepository addon-sync-monitoring -n k2s-addon-sync
kubectl get kustomization addon-sync-monitoring -n k2s-addon-sync
```

!!! note "ArgoCD does not require this step"
    ArgoCD uses a shared poller (`addons/common/manifests/addon-sync/argocd/addon-sync-poller.yaml`) that
    discovers `addons/*` repositories and checks digest changes every 5 minutes.
    No per-addon resource registration is required.

!!! note "Custom registry URL"
    Example local K2s setup uses base registry URL `k2s.registry.local:30500`. Per-addon repositories at `addons/<ADDON_NAME>` are discovered automatically. For any reachable registry, update the `addon-sync-config` ConfigMap:

    ```console
    kubectl edit configmap addon-sync-config -n k2s-addon-sync
    ```

## How It Works

### OCI Artifact Layers

Each exported addon artifact contains up to 7 layers:

| Layer | Content | Media Type | GitOps Sync |
|-------|---------|-----------|-------------|
| 0 | Config files (`addon.manifest.yaml`, `values.yaml`) | `vnd.k2s.addon.configfiles.v1.tar+gzip` | Extracted |
| 1 | K8s Manifests (YAML, kustomization, CRDs) | `vnd.k2s.addon.manifests.v1.tar+gzip` | Extracted |
| 2 | Helm Charts (`.tgz` packages) | `vnd.cncf.helm.chart.content.v1.tar+gzip` | Extracted |
| 3 | Scripts (`Enable.ps1`, `Disable.ps1`, etc.) | `vnd.k2s.addon.scripts.v1.tar+gzip` | Extracted |
| 4 | Linux Images (tar-of-tars) | `vnd.oci.image.layer.v1.tar` | Skipped |
| 5 | Windows Images (tar-of-tars) | `vnd.k2s.addon.images-windows.v1.tar` | Skipped |
| 6 | Packages (`.deb` files, binaries) | `vnd.k2s.addon.packages.v1.tar+gzip` | Skipped |

For multi-addon exports, the artifact uses an OCI Image Index with per-addon manifests.

### Addon-Sync Directory Structure

The addon-sync infrastructure uses kustomize overlays:

```
addons/common/manifests/addon-sync/
|- base/                        # Shared resources (both flows)
|  |- kustomization.yaml        # configMapGenerator for Sync-Addons.ps1
|  |- namespace.yaml            # k2s-addon-sync namespace
|  |- rbac.yaml                 # ServiceAccount for HostProcess Jobs
|  |- configmap.yaml            # Registry URL, K2s install dir, insecure flag
|  \- scripts/
|     \- Sync-Addons.ps1       # Sync processor script
|- fluxcd/                      # FluxCD overlay
|  |- kustomization.yaml        # References ../base only (no global trigger)
|  \- per-addon/                # Templates for per-addon FluxCD registration
|     |- ocirepository-template.yaml
|     \- kustomization-template.yaml
|- argocd/                      # ArgoCD overlay
|  |- kustomization.yaml        # References ../base + addon-sync-poller.yaml
|  \- addon-sync-poller.yaml    # HostProcess CronJob for digest-based registry polling
\- gitops-sync/                # Embedded in OCI artifact by Export.ps1
   |- kustomization.yaml
   \- sync-job.yaml            # HostProcess Job applied by Flux
```

### FluxCD Flow

1. `OCIRepository addon-sync-<ADDON_NAME>` polls the per-addon repository (`addons/<ADDON_NAME>`) and detects a new selected semver revision.
2. Flux extracts the manifests layer and applies `./gitops-sync/sync-job.yaml` through `Kustomization addon-sync-<ADDON_NAME>`.
3. The HostProcess Job runs `Sync-Addons.ps1`, pulls the OCI artifact, validates layout, extracts layers 0-3, and skips layers 4-6.
4. Result: the addon appears in `k2s addons ls` and can be enabled normally.

Key details:

- `Export.ps1` injects a `gitops-sync/` directory into every addon's manifests layer containing a Job template (`sync-job.yaml`) and a `kustomization.yaml`
- The export timestamp annotation in the Job ensures Flux (with `force: true`) recreates the Job on each new artifact revision
- The Flux `Kustomization` uses `path: ./gitops-sync` to apply only the sync Job, not the addon's own K8s manifests
- `prune: true` cleans up old completed Jobs; `wait: true` reports Job completion status

### ArgoCD Flow

1. A consumer manually pushes `addons/<ADDON_NAME>:<TAG>` to the registry.
2. `addon-sync-poller` CronJob runs every 5 minutes on the Windows node as a HostProcess container.
3. `Sync-Addons.ps1 -CheckDigest true` discovers `addons/*` repositories, selects the tag per repo (`latest` if present, otherwise the highest available semver tag), and compares manifest digests to local digest files.
4. For changed digests, the poller pulls artifacts, validates layout, extracts layers 0-3, and skips layers 4-6.
5. Result: synced addons appear in `k2s addons ls`; consumer then runs `k2s addons enable <ADDON_NAME>`.

Key details:

- The poller runs directly on the Windows node as a HostProcess CronJob and uses `oras` for repository discovery and digest checks
- Both **pushing an artifact** to the registry and **enabling an addon** are deliberate manual steps taken by the consumer
- Polling interval is configured by the CronJob schedule (`*/5 * * * *` by default)
- Digest state is stored on the host filesystem under `addons/.addon-sync-digests/`

### Sync-Addons.ps1

`Sync-Addons.ps1` is a self-contained PowerShell script that runs inside HostProcess containers on the Windows node. It inlines helper functions from `oci.module.psm1` so it does not depend on K2s PowerShell modules being imported.

**Processing steps:**

1. (Optional) **Digest check** -- when `-CheckDigest` is set, compare registry digest with stored digest
2. **Pull** -- `oras copy --to-oci-layout` downloads the full OCI artifact to a temp directory as an OCI Image Layout
3. **Validate** -- verify `oci-layout` file, `blobs/sha256/`, `index.json` structure
4. **Enumerate** -- parse `index.json` to find per-addon manifests with `vnd.k2s.addon.name` annotations; when annotations are absent from index entries (stripped during registry round-trip via `oras copy`), they are read directly from the manifest blob
5. **Extract layers 0-3** -- for each addon, by media type:
    - Layer 0 (config): `addon.manifest.yaml`, `values.yaml`, settings -> addon root directory
    - Layer 1 (manifests): K8s YAML, kustomization files -> `manifests/` subdirectory
    - Layer 2 (charts): Helm `.tgz` packages -> `manifests/chart/` subdirectory
    - Layer 3 (scripts): `Enable.ps1`, `Disable.ps1`, etc. -> addon implementation directory
6. **Merge manifests** -- for multi-implementation addons (e.g., ingress with nginx and traefik), merge `addon.manifest.yaml` implementations using `yq`
7. (Optional) **Persist digest** -- when `-CheckDigest` is set, save the current digest for next run

### What Happens After Sync

After the sync completes:

1. The addon's `addon.manifest.yaml`, scripts, manifests, and config files are written to the `addons/` directory
2. The Go CLI discovers the addon via `addon.manifest.yaml` and creates Cobra commands dynamically
3. `k2s addons ls` lists the synced addon
4. `k2s addons enable <ADDON_NAME>` runs the addon's `Enable.ps1` script, which applies K8s manifests and pulls container images from the registry as needed

## Customization

### Registry URL and Configuration

The `addon-sync-config` ConfigMap controls the sync target:

```console
kubectl edit configmap addon-sync-config -n k2s-addon-sync
```

| Key | Default | Description |
|-----|---------|-------------|
| `REGISTRY_URL` | Example local value: `oci://k2s.registry.local:30500` | Base OCI registry URL (registry host only, no repository path). Sync-Addons.ps1 discovers per-addon repos at `addons/<ADDON_NAME>` automatically |
| `K2S_INSTALL_DIR` | `C:\k` | K2s installation directory on the Windows host |
| `INSECURE` | `true` | Allow HTTP registry connections (required for local insecure registries, such as local K2s dev/test) |

### Polling Interval

**FluxCD** -- edit the per-addon `OCIRepository` interval (replace `<ADDON_NAME>` with the addon folder name):

```console
kubectl edit ocirepository addon-sync-<ADDON_NAME> -n k2s-addon-sync
```

Change `spec.interval` (e.g., `1m` for faster polling, `30m` for less frequent checks).

**ArgoCD** -- addon sync runs via the `addon-sync-poller` CronJob on a polling schedule. To inspect or adjust the schedule:

```console
kubectl edit cronjob addon-sync-poller -n k2s-addon-sync
```

### FluxCD: Custom Layer Selector

The per-addon `OCIRepository` extracts only the manifests layer. To change which layer FluxCD extracts (replace `<ADDON_NAME>` with the addon folder name):

```console
kubectl edit ocirepository addon-sync-<ADDON_NAME> -n k2s-addon-sync
```

Modify `spec.layerSelector.mediaType` to match a different layer's media type.

## Troubleshooting

### Check addon-sync namespace

```console
kubectl get all -n k2s-addon-sync
```

### FluxCD: Check OCIRepository status

Replace `<ADDON_NAME>` with the addon folder name (e.g., `monitoring`):

```console
kubectl get ocirepository addon-sync-<ADDON_NAME> -n k2s-addon-sync -o yaml
```

Look for `status.conditions` -- the `Ready` condition should be `True` and `status.artifact.revision` should show the latest digest.

### FluxCD: Check Kustomization status

```console
kubectl get kustomization addon-sync-<ADDON_NAME> -n k2s-addon-sync -o yaml
```

Look for `status.conditions` -- `Ready` should be `True` and `lastAppliedRevision` should match the OCIRepository's artifact revision.

### ArgoCD: Check poller CronJob and recent Jobs

```console
kubectl get cronjob addon-sync-poller -n k2s-addon-sync
kubectl get jobs -n k2s-addon-sync --sort-by=.metadata.creationTimestamp
```

Verify `addon-sync-poller` exists and the latest scheduled runs complete successfully. Check `COMPLETIONS` and `AGE` columns to confirm recent sync Jobs ran.

### Check sync Job logs

```console
kubectl logs -n k2s-addon-sync -l app.kubernetes.io/name=addon-sync --tail=100
```

All log lines are prefixed with `[AddonSync]`. Look for:

- `[AddonSync] Digest changed -- proceeding with full sync` -- a new artifact was detected and sync is running
- `[AddonSync][ERROR]` -- sync failures with details

### Verify synced addons

```console
k2s addons ls
```

### ArgoCD: Check poller logs

```console
kubectl logs -n k2s-addon-sync -l app.kubernetes.io/name=addon-sync -l app.kubernetes.io/component=poller --tail=100
```

Look for digest checks and sync decisions for changed addons.

### Common issues

| Issue | Cause | Resolution |
|-------|-------|------------|
| OCIRepository shows `not found` | No artifact pushed to registry | Push via `oras copy --from-oci-layout` -- see [Push to registry](#push-to-registry) |
| Job fails with `oras pull failed` | Registry unreachable or wrong URL | Check `addon-sync-config` ConfigMap |
| Addon not appearing in `k2s addons ls` | Sync not complete or `addon.manifest.yaml` invalid | Check Job logs for `[AddonSync][ERROR]` |
| ArgoCD poller not running | Addon-sync not deployed or CronJob suspended | Check `kubectl get cronjob addon-sync-poller -n k2s-addon-sync`; re-enable with `k2s addons enable rollout argocd` |
| New addon not detected yet | Poll interval not elapsed or digest unchanged | Wait for next schedule, or trigger a manual Job from the CronJob for immediate sync |
| FluxCD Job not recreated | Export timestamp unchanged | Re-export the addon to generate a new timestamp |
| `yq.exe not found` in logs | Missing `yq` binary | Ensure `<K2S_INSTALL_DIR>\bin\windowsnode\yaml\yq.exe` exists |

## Common Use Cases

### Use case A -- New addon becomes available via sync

A new addon (one that does not yet exist locally) is published to the registry. After the artifact is pushed, the addon appears in `k2s addons ls` and can be enabled.

**Steps:**

1. Export and push the new addon to the registry (see [Push to registry](#push-to-registry)).
2. For FluxCD: the per-addon `OCIRepository` detects the new highest semver tag and triggers sync automatically. For ArgoCD: `addon-sync-poller` detects changed digests on its next run and syncs changed addons.
3. Verify the addon is discoverable:
   ```console
   k2s addons ls
   ```
4. Enable the addon to start its workloads:
   ```console
    k2s addons enable <ADDON_NAME>
   ```

### Use case B -- Updated addon version is published

An existing addon is re-exported with a newer version and pushed to the registry. Addon-sync detects the changed artifact, extracts the updated definition files, and updates the local catalog entry.

**Steps:**

1. Export the updated addon and push a new versioned tag to `addons/<ADDON_NAME>`.
2. For FluxCD: the per-addon `OCIRepository` detects the new highest semver tag and triggers sync automatically -- no extra push needed.
3. Wait for the next sync cycle.
4. The local addon directory is updated with the new scripts, manifests, and config.
5. If the addon was already enabled, disable and re-enable it to apply the updated manifests:
   ```console
    k2s addons disable <ADDON_NAME>
    k2s addons enable <ADDON_NAME>
   ```

## Offline vs GitOps

Both approaches can coexist. Use `k2s addons import` for air-gapped environments and GitOps for connected clusters:

| Feature | Offline (`k2s addons import`) | GitOps (FluxCD/ArgoCD) |
|---------|-------------------------------|------------------------|
| Trigger | Manual import from `.oci.tar` file | Automatic -- FluxCD polls per-addon OCIRepository; ArgoCD polls via `addon-sync-poller` CronJob |
| Images | Imported into container runtime from layers 4/5 | Pulled from registry at enable time |
| Packages | Installed from layer 6 | Skipped (not needed when registry is reachable) |
| Network | Air-gapped compatible | Requires registry access |
| Layers processed | All 7 layers | Layers 0-3 only |
| Addon discovery | Immediate after import | FluxCD: after poll interval (e.g., 1m); ArgoCD: after poll interval (default 5m) |
