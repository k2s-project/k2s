<!--
SPDX-FileCopyrightText: © 2025 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# rollout

## Introduction

The `rollout` addon automates the deployment and updating of applications on K2s using a [GitOps](https://www.gitops.tech/) approach. It provides two mutually exclusive implementations:

- **[ArgoCD](https://argo-cd.readthedocs.io/en/stable/)** — a declarative GitOps continuous delivery tool with a web-based dashboard and CLI. Ideal when you want visual insight into application state and UI-driven workflows.
- **[Flux CD](https://fluxcd.io/)** — a lightweight GitOps toolkit managed entirely via CLI and YAML manifests. Best suited for teams that prefer a pure infrastructure-as-code workflow with no additional UI.

Both implementations are installed into the `rollout` namespace and share the same CLI flags and addon lifecycle (enable, disable, backup, restore, status).

## Choosing an Implementation

| Feature | ArgoCD | Flux CD |
|---|---|---|
| Web dashboard | Yes | No |
| CLI management | Dedicated `argocd` CLI | Standard `kubectl` + Flux CRDs |
| Ingress purpose | Expose the ArgoCD dashboard | Optional app ingress for workloads managed by Flux |
| Default sync behavior | Real-time (watches Git) | Polling every 1 minute |
| Helm support | Via `Application` CRD | Native `HelmRelease` CRD |
| Addon-sync mechanism | `addon-sync-poller` HostProcess CronJob polling every 5 minutes | Native `OCIRepository` + `Kustomization` |

**Pick ArgoCD** if you want a visual dashboard for managing deployments, reviewing diffs, and triggering syncs from a UI.

**Pick Flux CD** if you prefer a fully declarative, YAML-first workflow managed with Git, `kubectl`, and Flux CRDs — the `flux` CLI is also available for managing sources and releases.

> **Note:** The two implementations are mutually exclusive. You must disable one before enabling the other.

## Getting Started

### Enable with ArgoCD 

```console
k2s addons enable rollout argocd
```

### Enable with Flux CD

```console
k2s addons enable rollout fluxcd
```

### Enable with ingress integration

Expose the ArgoCD dashboard (or your own app endpoints) via an ingress controller:

```console
k2s addons enable rollout argocd --ingress traefik
k2s addons enable rollout argocd --ingress nginx-gw
k2s addons enable rollout fluxcd --ingress nginx
```

If the specified ingress addon is not already enabled, it will be enabled automatically.

### Check status

```console
k2s addons status rollout argocd
k2s addons status rollout fluxcd
```

## CLI Flags

Both implementations share the same flags:

| Flag | Shorthand | Default | Description |
|---|---|---|---|
| `--ingress` | `-i` | `none` | Ingress controller to use. Valid values: `none`, `nginx`, `nginx-gw`, `traefik` |
| `--addon-sync` | | `true` | Deploy addon-sync infrastructure for OCI-based GitOps addon delivery |

### Examples

```console
# Enable ArgoCD with Traefik ingress
k2s addons enable rollout argocd --ingress traefik

# Enable Flux CD without addon-sync
k2s addons enable rollout fluxcd --addon-sync=false

# Enable ArgoCD with nginx-gw ingress and no addon-sync
k2s addons enable rollout argocd -i nginx-gw --addon-sync=false
```

## Deploying Applications

### With ArgoCD

ArgoCD provides two ways to deploy applications:

1. **Web UI** — Access the dashboard at `https://k2s.cluster.local/rollout` (requires ingress) or via port-forwarding:

   ```console
   kubectl -n rollout port-forward svc/argocd-server 8080:443
   ```

   Then open `https://localhost:8080/rollout`.

2. **CLI** — Use the `argocd` CLI to log in, add repositories, create applications, and sync:

   ```console
   argocd login k2s.cluster.local:443 --grpc-web-root-path "rollout"
   argocd app create myapp --repo <git-url> --path <path> --dest-server https://kubernetes.default.svc --dest-namespace <namespace>
   argocd app sync myapp
   ```

For detailed step-by-step instructions, see the [ArgoCD implementation README](argocd/README.md).

### With Flux CD

Flux CD uses Kubernetes custom resources to define what to sync and from where:

1. **Git sources** — Create a `GitRepository` + `Kustomization` to sync plain manifests or Kustomize overlays from Git.
2. **Helm charts** — Create a `HelmRepository` + `HelmRelease` to deploy Helm charts.

Apply the resources with `kubectl`:

```console
kubectl apply -f gitrepository.yaml
kubectl apply -f kustomization.yaml
```

Flux will continuously reconcile the cluster state with the desired state defined in your sources.

For detailed examples and YAML templates, see the [Flux CD implementation README](fluxcd/README.md).

## GitOps Addon Delivery (Addon-Sync)

The rollout addon includes an **addon-sync** feature (enabled by default via `--addon-sync`) that delivers K2s addon definition files from an OCI registry to the Windows host filesystem — making addons discoverable and installable without copying files manually.

### How it works

1. **Export** — create an OCI artifact from a K2s addon: `k2s addons export <name> -d C:\exports --omit-images --omit-packages`
2. **Push** _(manual, consumer)_ — publish the artifact to the registry: `oras copy --from-oci-layout ... <registry>/addons/<name>:<version>`
3. **Detect** — the GitOps tool detects the new artifact digest
4. **Sync** — a Windows HostProcess job extracts definition files (manifests, scripts, Helm charts, config) to the addon catalog on the Windows host
5. **Enable** _(manual, consumer)_ — `k2s addons enable <name>` starts the addon's Kubernetes workloads

> Sync copies addon definitions only — it does not start workloads. Enabling is always a deliberate manual step.

### What's different between ArgoCD and FluxCD

| | ArgoCD | Flux CD |
|---|---|---|
| Detection mechanism | `addon-sync-poller` HostProcess CronJob polls registry every 5 minutes | Per-addon `OCIRepository` polls `addons/<name>` every 1 minute |
| Per-addon setup | **None required** — poller discovers all `addons/*` repos automatically | **One-time per addon** — apply `ocirepository-template.yaml` + `kustomization-template.yaml` |
| Push required | Single versioned tag push | Single versioned tag push (no `latest` needed) |
| Multi-addon | All registered repos checked in each poll cycle | Each addon has independent reconciliation |
| Registry compatibility | Any OCI Distribution Spec registry | Any OCI Distribution Spec registry |

### Prerequisites

- The **registry** addon must be enabled: `k2s addons enable registry`

### Opt out

```console
k2s addons enable rollout argocd --addon-sync=false
k2s addons enable rollout fluxcd --addon-sync=false
```

### Implementation guides

For full step-by-step consumer workflows — one-time setup, per-addon registration, export/push, multi-addon batching, troubleshooting, and customization:

- **[ArgoCD addon-sync guide →](argocd/README.md#gitops-addon-delivery-addon-sync)**
- **[Flux CD addon-sync guide →](fluxcd/README.md#gitops-addon-delivery-addon-sync)**
- **[Full operational reference →](../../docs/op-manual/gitops-addon-delivery.md)**

## Backup and Restore

Both implementations support backup and restore scoped to the `rollout` namespace.

### Commands

```console
# Backup
k2s addons backup rollout argocd
k2s addons backup rollout fluxcd

# Restore
k2s addons restore rollout argocd -f <path-to-backup-zip>
k2s addons restore rollout fluxcd -f <path-to-backup-zip>
```

### What gets backed up

- **ArgoCD**: ArgoCD admin export (applications, projects, repo connections, settings) + optional ingress resources.
- **Flux CD**: Flux custom resources (`GitRepository`, `Kustomization`, `HelmRelease`, etc.) + referenced Secrets + optional ingress resources.

### What does not get backed up

- Controller manifests and CRDs — these are re-installed when the addon is re-enabled during restore.
- Resources outside of the `rollout` namespace.

For implementation-specific backup details, see the [ArgoCD README](argocd/README.md#backup-and-restore) and [Flux CD README](fluxcd/README.md#backup-and-restore).

## Disable Rollout

```console
k2s addons disable rollout
```

This removes all rollout resources from the `rollout` namespace. If addon-sync was enabled, the `k2s-addon-sync` namespace is also removed.

> **Note:** Disabling rollout does not disable other addons (e.g., ingress) that were enabled alongside it.

## Further Reading

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/en/stable/)
- [Flux CD Documentation](https://fluxcd.io/docs/)
- [ArgoCD Implementation Details](argocd/README.md)
- [Flux CD Implementation Details](fluxcd/README.md)
- [GitOps Addon Delivery — Operational Guide](../../docs/op-manual/gitops-addon-delivery.md)
