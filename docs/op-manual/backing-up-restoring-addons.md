<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: MIT
-->

# Backing Up and Restoring *K2s* Addons

*K2s* provides built-in CLI commands to back up and restore addon configuration and data. This allows you to preserve addon state across upgrade, migration, or disaster-recovery scenarios.

Each addon ships its own `Backup.ps1` and `Restore.ps1` scripts that know exactly which Kubernetes resources, configuration files, or persistent data to capture. The CLI orchestrates staging, zip creation/extraction, manifest validation, and the addon re-enable cycle automatically.

## Prerequisites

- **Administrator privileges** — all backup and restore commands must run in an elevated shell.
- **Cluster running** — the *K2s* cluster must be started before executing backup or restore (exception: *storage smb* can back up local data even when the cluster is not running).
- **Addon enabled** — an addon must be **enabled** for backup to capture its state.
- **Addon disabled** — an addon must be **disabled** before restore. The CLI enforces this and returns an error otherwise.

## Backup Command

```console
k2s addons backup ADDON [IMPLEMENTATION] [-f <path>]
```

Creates a zip archive containing the addon's backed-up resources and a `backup.json` manifest.

### Flags

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--file` | `-f` | Output zip file path | Auto-generated in `C:\Temp\k2s\Addons` |

### Default Behavior

When `-f` is omitted the zip is written to `C:\Temp\k2s\Addons` with the naming pattern:

```
{addon_name}_backup_{yyyyMMdd_HHmmss}.zip
```

Spaces and slashes in the addon name are replaced with underscores (e.g. `ingress nginx` → `ingress_nginx_backup_20260219_143012.zip`).

### Examples

```console
# Backup a single addon to the default location
k2s addons backup registry

# Backup an addon implementation to a custom path
k2s addons backup "ingress nginx" -f D:\backups\ingress-nginx.zip

# Backup an addon implementation to the default folder
k2s addons backup "ingress traefik"
```

## Restore Command

```console
k2s addons restore ADDON [IMPLEMENTATION] [-f <path>]
```

Restores an addon from a previously created backup zip. The restore flow is:

1. Extract the zip to a temporary staging directory.
2. Validate the `backup.json` manifest (addon name, implementation, K2s version).
3. Re-enable the addon (using `EnableForRestore.ps1` if available, otherwise standard `Enable.ps1`).
4. Execute the addon's `Restore.ps1` to apply backed-up resources.
5. Clean up staging files.

### Flags

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--file` | `-f` | Input zip file path | Newest matching zip in `C:\Temp\k2s\Addons` |

When `-f` is omitted the CLI searches `C:\Temp\k2s\Addons` for files matching `{addon_name}_backup_*.zip` and picks the most recently modified one.

> **⚠️ Warning:** The addon **must be disabled** before running restore. If the addon is still enabled the command will fail with: `addon '<name>' must be disabled before restore`.

### Examples

```console
# Restore from an explicit backup file
k2s addons restore registry -f D:\backups\registry-backup.zip

# Restore from the latest backup in the default folder
k2s addons restore "ingress nginx"

# Restore a specific addon implementation
k2s addons restore "storage smb" -f C:\Temp\k2s\Addons\storage_smb_backup_20260219_143012.zip
```

## Typical Workflow

A common scenario is backing up addons before a *K2s* upgrade and restoring them afterwards:

```console
# 1. Back up the addons you want to preserve
k2s addons backup registry
k2s addons backup "ingress nginx"
k2s addons backup security

# 2. Disable the addons
k2s addons disable registry
k2s addons disable ingress nginx
k2s addons disable security

# 3. Perform the upgrade
k2s system upgrade

# 4. Restore each addon (re-enables automatically)
k2s addons restore registry
k2s addons restore "ingress nginx"
k2s addons restore security
```

After restore each addon is re-enabled with its backed-up configuration applied on top.

## \[Experimental\] Linux Host

On a native [Linux host](../user-guide/hosting-variants.md#linux-host), `k2s addons backup` and `k2s addons restore` run without *PowerShell* for the addons that the Linux host manages natively:

| Addon | What Gets Backed Up |
|-------|---------------------|
| **registry** | `tar.gz` of `/registry/repository` on the host, `registry-config` ConfigMap |
| **ingress nginx** | Controller ConfigMap, optional cluster-local Ingress |
| **ingress traefik** | Cluster-local Ingress |

The zip archive has the same layout and `backup.json` format as on a *Windows* host, so a backup can be restored on either host variant. The restore flow is the same as described above: the addon must be disabled, the CLI re-enables it and then applies the backed-up data.

Run the commands with root privileges, e.g.:

```console
sudo ./k2s addons backup registry
sudo ./k2s addons restore registry
```

When `-f` is omitted, backups are written to and looked up in `$TMPDIR/k2s/Addons` (`/tmp/k2s/Addons` by default).

Other addons are rejected with a *not supported* error before anything is changed. Backups that record an infrastructure node selector cannot be restored on a Linux host, because selector placement is supported on *Windows*-hosted clusters only.

## What Gets Backed Up — Summary

The following table shows at a glance what each addon's backup contains.

| Addon | Backup Type | What Gets Backed Up | Notes |
|-------|-------------|---------------------|-------|
| **autoscaling** | Config | ConfigMaps in `autoscaling` namespace | `EnableForRestore.ps1` with best-effort pod readiness |
| **dashboard** | Metadata | Ingress type, metrics-addon-enabled flag | Headlamp (Headlamp replaces retired kubernetes/dashboard); restore calls `Update.ps1`; may re-enable metrics addon |
| **dicom** | Config | Orthanc ConfigMap, ingress resources, Traefik middlewares | Restarts deployment after config restore |
| **gpu-node** | Metadata | Nothing (infrastructure-only) | Re-enable fully restores functionality |
| **ingress nginx** | Config | Controller ConfigMap, cluster-local Ingress | Waits for controller pod readiness |
| **ingress nginx-gw** | Config | Gateway CR, NginxGateway CR | Certificates regenerated on enable; not backed up |
| **ingress traefik** | Config | Cluster-local Ingress | Waits for traefik pod readiness |
| **kubevirt** | Metadata | Nothing (infrastructure-only) | Re-enable fully restores functionality |
| **logging** | Config | 4 ConfigMaps (OpenSearch, Fluent Bit Linux/Windows) | Rollout-restarts StatefulSet, Deployments, DaemonSets |
| **metrics** | Config | Metrics-server Deployment, APIService, Windows exporter resources | Rollout-restarts after apply |
| **monitoring** | Config | User Grafana dashboards/datasources, Ingress resources, non-Helm Prometheus CRs | Secrets and PV data **not** backed up; Helm-managed resources skipped |
| **registry** | Data | `tar.gz` of `/registry/repository` from control-plane VM, ConfigMap | Overwrites existing data; SSH to VM |
| **rollout argocd** | Data | ArgoCD state export, ingress resources, Traefik middleware | Export **contains credentials** (repo creds) |
| **rollout fluxcd** | Config | All Flux CRs, referenced Secrets, webhook ingress | Secrets backed up (Flux requires them) |
| **security** | Data | CA root Secret, Keycloak PostgreSQL dump, Kyverno policies, enhanced-security marker | `EnableForRestore.ps1` reconstructs original enable flags; drops/recreates Keycloak DB; re-applies Kyverno policies after framework is ready |
| **storage smb** | Data | `SmbStorage.json`, addon config snapshot, SMB share file data | Disable/enable cycle with `-Keep`; works offline |
| **storage ceph** | Config | Ceph connection configuration (`clusterHostNode`, `cephfsPool`, `cephfsFilesystem`) | No user data copied — a fresh Ceph cluster is provisioned on re-enable |
| **viewer** | Config | ConfigMap, Service, ingress resources, Traefik middleware | Runs `Update.ps1` after restore |

**Backup Types:**

- **Config** — Kubernetes resources (ConfigMaps, Ingresses, CRDs) exported as YAML/JSON. No persistent volume data.
- **Data** — Includes files or database dumps copied from the cluster or VM, in addition to configuration.
- **Metadata** — Only `backup.json` manifest with flags/settings. No files are captured; re-enabling restores full functionality.

## Per-Addon Details

### autoscaling

**Backup:** Exports all ConfigMaps in the `autoscaling` namespace (excluding `kube-root-ca.crt`) as YAML files.

**Restore:** Uses `EnableForRestore.ps1` which applies the KEDA manifest with best-effort readiness checks, allowing restore to proceed even if the keda-operator pod is temporarily unhealthy. Applies backed-up ConfigMaps with server-side apply fallback on conflict. Waits for KEDA pods (admission-webhooks, metrics-apiserver, operator).

### dashboard

**Backup:** Metadata-only — records the active ingress type (`none`, `nginx`, `traefik`, or `nginx-gw`) and whether the metrics addon was enabled. No Kubernetes resources are exported.

**Restore:** Re-enables the metrics addon if it was enabled at backup time. Ensures the correct ingress addon is enabled. Calls `Update.ps1` to re-apply ingress integration and Linkerd service-mesh patches. Waits for the Headlamp pod availability.

> **Note:** This addon uses [Headlamp](https://headlamp.dev) (kubernetes-sigs) as the Kubernetes dashboard. The previous `kubernetes/dashboard` (Kong proxy architecture) has been retired.

### dicom

**Backup:** Exports the Orthanc `json-configmap` ConfigMap (required), plus optional ingress resources: nginx Ingress, traefik Ingress (including `correct1`/`correct2` variants), nginx-gw HTTPRoutes (http + https), and Traefik middlewares (`strip-prefix`, `cors-header`, `oauth2-proxy-auth`). Resources are exported as minimal JSON with server-managed fields stripped.

**Restore:** Detects the active ingress controller and skips non-matching ingress resources. Waits for DICOM deployments, applies resources, restarts the DICOM deployment if configuration was restored, then runs `Update.ps1`.

### gpu-node

**Backup:** No-op. This is an infrastructure-only addon — `backup.json` contains `files: []`. Re-enabling the addon fully restores GPU passthrough functionality.

### ingress nginx

**Backup:** Exports the `ingress-nginx-controller` ConfigMap and the optional `nginx-cluster-local` Ingress resource.

**Restore:** Waits for the ingress-nginx controller pod, then applies resources with conflict fallback.

### ingress nginx-gw

**Backup:** Exports the `nginx-cluster-local` Gateway and `nginx-gw-config` NginxGateway CR as minimal JSON. TLS certificates are **intentionally not backed up** — they are regenerated when the addon is re-enabled.

**Restore:** Applies backed-up resources, then applies the NginxProxy configuration with the current control-plane IP. Waits for the controller pod. Runs `Update.ps1`.

### ingress traefik

**Backup:** Exports the `traefik-cluster-local` Ingress as YAML.

**Restore:** Waits for the traefik pod to become ready, then applies the Ingress with conflict fallback.

### kubevirt

**Backup:** No-op. Infrastructure-only addon — `backup.json` contains `files: []`. Re-enabling fully restores KubeVirt functionality.

### logging

**Backup:** Exports the `opensearch-cluster-master-config` ConfigMap as minimal JSON. The Fluent Bit ConfigMaps (`fluent-bit`, `fluent-bit-win-parsers`, `fluent-bit-win-config`) are intentionally **not** backed up — they are generated artifacts regenerated by `Enable.ps1`, and the Windows config contains host-specific log paths (the configured K2s log root is substituted at enable time). Backing them up and restoring them on a host with a different log root would reintroduce stale paths.

**Restore:** Applies the OpenSearch configuration, then performs best-effort rollout restarts of the OpenSearch StatefulSet, Dashboards Deployment, and Fluent Bit DaemonSets (Linux and Windows) so pods pick up the configuration that `Enable.ps1` regenerated for the restore host. Waits for rollout completion with a 600-second timeout. Older backups that still contain `fluent-bit*.json` files are ignored.

### metrics

**Backup:** Exports the `metrics-server` Deployment (from `metrics` namespace), the `v1beta1.metrics.k8s.io` APIService (cluster-scoped), and Windows exporter resources in `kube-system` namespace (ConfigMap, DaemonSet, Service) plus the `windows-exporter` ServiceMonitor in the `monitoring` namespace. All exported as minimal JSON.

**Restore:** Applies all files, then performs rollout restarts of the `metrics-server` Deployment and `windows-exporter` DaemonSet.

### monitoring

**Backup:** Exports user-created (non-Helm-managed) Grafana dashboard and datasource ConfigMaps (labeled `grafana_dashboard=1` / `grafana_datasource=1`; default `kube-prometheus-stack-*` ConfigMaps are also excluded), all Ingress/HTTPRoute/IngressRoute/Middleware resources, and non-Helm-managed Prometheus Operator CRs (Prometheus, Alertmanager, PrometheusRule, ServiceMonitor, PodMonitor, AlertmanagerConfig).

> **ℹ️ Note:** Secrets and PersistentVolume data are **not** backed up. Helm-managed resources are skipped — they are recreated when the addon is re-enabled.

**Restore:** Skips ingress resources that do not match the currently active ingress controller. Uses server-side apply with sanitized fields (removes `resourceVersion`, `uid`, `managedFields`). Performs best-effort rollout status checks for all monitoring workloads.

### registry

**Backup:** Creates a `tar.gz` archive of `/registry/repository` on the control-plane VM via SSH, copies it to the staging directory. Also exports the `registry-config` ConfigMap.

> **⚠️ Warning:** Restore **overwrites** any existing registry data. The StatefulSet is scaled to zero during restore.

**Restore:** Scales the StatefulSet to 0, waits for pod termination, copies the archive to the VM via SSH, deletes existing data, extracts the archive, optionally restores the ConfigMap, then scales back to 1.

### rollout argocd

**Backup:** Uses `argocd admin export` to capture the full ArgoCD state (applications, projects, repositories, clusters). Also exports ingress resources (nginx Ingress, traefik Ingress, nginx-gw HTTPRoutes) and the Traefik `oauth2-proxy-auth` Middleware. The export is run via the host `argocd.exe` binary if available, otherwise via `kubectl exec` into the argocd-server pod.

> **⚠️ Warning:** The ArgoCD export **contains credentials** (repository secrets). Handle the backup zip with care.

**Restore:** Waits for ArgoCD deployments and StatefulSets. Applies ingress resources matching the active controller only. Uses `argocd admin import` with sanitized YAML. Runs `Update.ps1`. Cleans up export files to prevent credential lingering.

### rollout fluxcd

**Backup:** Exports all Flux custom resources in the `rollout` namespace (GitRepository, Kustomization, HelmRelease, HelmRepository, OCIRepository, Bucket, ImageRepository, ImagePolicy, ImageUpdateAutomation, Provider, Alert, Receiver), plus referenced Secrets (discovered via recursive `secretRef` scanning), plus webhook ingress resources. Secrets are written first in the manifest's file list.

The host Flux CLI (`bin\\flux.exe`) is not part of backup data. It is installed when `k2s addons enable rollout fluxcd` runs.

**Restore:** Waits for Flux controller deployments. Applies resources with ingress-aware filtering. Runs `Update.ps1`.

During restore, the addon re-enable step ensures `bin\\flux.exe` is present on the host.

### security

**Backup:** Exports the CA root Secret (`ca-issuer-root-secret` from `cert-manager` namespace), a PostgreSQL dump of the Keycloak database (via `pg_dump` exec into the pod), the enhanced-security marker file, and all Kyverno `ClusterPolicy`, `Policy`, and `PolicyException` resources as `kyverno-policies.yaml` (only included if Kyverno is enabled and at least one policy exists). Detects and records the current enable flags (`--type`, `--ingress`, `--omitKeycloak`, `--omitHydra`, `--omitOAuth2Proxy`, `--omitPolicyEnf`).

**Restore:** Uses `EnableForRestore.ps1` which reads `backup.json` to reconstruct the original enable flags (including `--omitPolicyEnf`) and delegates to `Enable.ps1`. Restores the CA Secret with `--force` and restarts cert-manager. For Keycloak: scales down the Keycloak pod, drops and recreates the database, imports the dump via `psql` exec, then scales back up. Restores the enhanced-security marker file. If `kyverno-policies.yaml` is present in the backup, waits for Kyverno to become available and applies the policies with `--server-side`.

### storage smb

**Backup:** Copies the `SmbStorage.json` configuration file, an addon config snapshot from `setup.json`, and the SMB share data from the Windows mount path. Works even when the cluster is not running (local data only).

**Restore:** Restores the config snapshot, determines the SMB host type from addon configuration, performs a disable/enable cycle with the `-Keep` flag, then restores the share data.

### storage ceph

**Backup:** Snapshots the Ceph connection configuration (`clusterHostNode`, plus the `cephfsPool` / `cephfsFilesystem` names from `config/ceph-config.json`) into a zip archive. It also records whether the addon had been enabled with Windows SMB support (`-w`) so restore can replay the same enable mode. No user data is copied — it resides in the provisioned Ceph cluster.

**Restore:** Re-applies the configuration snapshot and re-enables the addon, which provisions a fresh single-node Ceph cluster on the configured Debian 13 node. If the original backup was taken from a `storage ceph -w` deployment, restore re-enables the Ceph SMB Windows path as well. The same configuration is preserved automatically across `k2s system backup`/`restore`/`upgrade` via backup/restore hooks registered while the addon is enabled.

### viewer

**Backup:** Exports the `config-json` ConfigMap, the `viewerwebapp` Service, and ingress resources for all three ingress types, plus the Traefik `oauth2-proxy-auth` Middleware.

**Restore:** Detects the active ingress controller, waits for the viewer deployment, applies resources with ingress-aware filtering (skips non-matching), handles missing CRDs gracefully. Runs `Update.ps1`.

## Backup Manifest Format

Each backup zip contains a `backup.json` file at the root with the following structure:

```json
{
  "k2sVersion": "1.5.0",
  "files": ["configmap.yaml", "ingress.json"],
  "addon": "registry",
  "implementation": "registry",
  "createdAt": "2026-02-19T14:30:12Z"
}
```

| Field | Description |
|-------|-------------|
| `k2sVersion` | The *K2s* version that created the backup |
| `files` | List of files in the zip (may be empty for metadata-only backups) |
| `addon` | Addon name |
| `implementation` | Implementation name (omitted when addon has a single implementation) |
| `createdAt` | Timestamp of backup creation |

Some addons add extra fields (e.g. `ingress`, `enableParams`, `scope`, `storageUsage`) that their `Restore.ps1` / `EnableForRestore.ps1` scripts use to customize the restore flow.

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| `addon '<name>' must be disabled before restore` | The addon is still enabled | Run `k2s addons disable <name>` first |
| `no backup zip found` | No matching zip in `C:\Temp\k2s\Addons` | Provide an explicit path with `-f` |
| Manifest addon/implementation mismatch | The zip was created for a different addon | Use the correct zip file for the target addon |
| `No Backup.ps1 found` | Addon does not support backup | Nothing to back up — the addon is fully recreated on enable |
| `'addons backup' is not supported on this platform` | The addon has no native backup on a Linux host yet | Back up the addon on a *Windows* host, or recreate its configuration after enabling it |
| Restore fails during re-enable | Cluster resources unavailable | Check cluster health with `k2s system status` and retry |
| Registry restore overwrites data | By design — restore replaces existing repository contents | Back up the current state first if needed |
| ArgoCD credentials in backup | `argocd admin export` includes repo secrets | Store the backup zip securely; delete after restore |
