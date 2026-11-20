<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Rollout — Flux CD Implementation

## Introduction

Flux CD is a GitOps operator that continuously reconciles cluster state with sources of truth — Git repositories, Helm repositories, or OCI registries. Unlike ArgoCD, Flux has **no web UI** and is managed entirely via `kubectl` and YAML custom resources.

## Enable Flux

```cmd
k2s addons enable rollout fluxcd
```

Enabling `rollout fluxcd` also installs the Flux CLI on the Windows host at `bin\\flux.exe`.

### Optional: Enable Webhooks (for Git push notifications)

```cmd
k2s addons enable rollout fluxcd --ingress nginx
```

Most users don't need this — Flux polls its sources by default.

### Skip addon-sync infrastructure

By default, enabling Flux also deploys the **addon-sync** infrastructure that lets you deliver K2s addons from an OCI registry. To skip it:

```cmd
k2s addons enable rollout fluxcd --addon-sync=false
```

## Check Status

```cmd
k2s addons status rollout fluxcd
```

---

## Deploy Applications with Flux

### Git-based deployment

Create a `GitRepository` and a `Kustomization` pointing to your manifests:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: myapp
  namespace: rollout
spec:
  interval: 1m
  url: https://github.com/myorg/myapp
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
  namespace: rollout
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: myapp
  path: ./deploy
  prune: true
  targetNamespace: default
```

### 3. Apply

```cmd
kubectl apply -f gitrepository.yaml
kubectl apply -f kustomization.yaml
```

### Helm chart deployment

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: bitnami
  namespace: rollout
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
---
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: nginx
  namespace: default
spec:
  interval: 5m
  chart:
    spec:
      chart: nginx
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: rollout
  values:
    replicaCount: 2
```

---

## GitOps Addon Delivery (Addon-Sync)

Addon-sync delivers addon definition content (manifests, charts, scripts, metadata) from an OCI registry into the local K2s addon catalog so teams can publish addons through GitOps workflows.

> **Sync vs. enable:** sync makes addon files available locally, but it does **not** deploy workloads. Deploy remains an explicit action with `k2s addons enable <name>`.

### Prerequisites

- Flux CD is enabled.
- Cluster can reach the OCI registry that stores addon artifacts.
- Addons intended for sync are registered for Flux reconciliation.

### Placeholder reference

- `<REGISTRY_HOST>`: OCI registry host (example only: `k2s.registry.local:30500`)
- `<REGISTRY_URL>`: `oci://<REGISTRY_HOST>`
- `<ADDON_NAME>`: addon repository name under `addons/` (for example `monitoring`)

### Register addon for Flux sync (one-time per addon)

In Flux mode, this registration is required per addon. For each addon, create both resources in namespace `k2s-addon-sync`:

- `OCIRepository` (watches the addon artifact in your registry)
- `Kustomization` (applies synced addon content locally)

Use the templates from:

`<K2S_INSTALL_DIR>\addons\common\manifests\addon-sync\fluxcd\per-addon`

Replace placeholders (for example `<ADDON_NAME>`, `<REGISTRY_HOST>`, and insecure flag) and then apply and verify:

```console
kubectl apply -f <path-to-ocirepository.yaml>
kubectl apply -f <path-to-kustomization.yaml>
kubectl -n k2s-addon-sync get ocirepository,kustomization
```

### Minimal workflow

1. Export the addon as OCI layout.
2. Push the exported artifact to your registry.
3. Flux detects the new tag and addon-sync updates the local addon catalog.
4. Enable the addon explicitly.

```console
k2s addons export <ADDON_NAME> -d <export-dir> --omit-images --omit-packages
oras copy --from-oci-layout <exported-oci-tar>:<tag> <REGISTRY_URL>/addons/<ADDON_NAME>:<tag>
k2s addons ls
k2s addons enable <ADDON_NAME>
```

### Custom registry values (example)

Use your own registry host when publishing addon artifacts.

```console
set REGISTRY_HOST=<REGISTRY_HOST>
oras copy --from-oci-layout <exported-oci-tar>:<tag> oci://%REGISTRY_HOST%/addons/<ADDON_NAME>:<tag>
```

Use the same registry host that your addon-sync configuration watches.

### Configurable options

`addon-sync-config` controls default sync behavior:

- `REGISTRY_URL`: `oci://<REGISTRY_HOST>` used by addon-sync
- `K2S_INSTALL_DIR`: host install directory used by sync scripts
- `INSECURE`: enable insecure registry access (`true`/`false`)

Flux-specific tunables are set per addon resource:

- `OCIRepository.spec.interval`: how often Flux checks for new addon tags
- Optional `OCIRepository.spec.ref.semver`: constrain which versions are selected

### Install directory behavior (auto-detected and patched)

When you run `k2s addons enable rollout fluxcd`, K2s normally patches `K2S_INSTALL_DIR` automatically to the actual install path.

If you apply manifests manually, verify `addon-sync-config` still has the correct `K2S_INSTALL_DIR` value and update it if needed.

### Flux-specific note

Flux addon-sync registers and reconciles addons per addon, so publishing one addon version triggers sync for that addon only.

### Troubleshooting

- Addon not listed after push: verify artifact location/tag and wait for the next reconcile interval.
- Sync looks stale: check Flux source and kustomization status in `k2s-addon-sync`.
- Addon listed but not running: run `k2s addons enable <ADDON_NAME>` (sync alone does not deploy).


## Disable Flux

```cmd
k2s addons disable rollout fluxcd
```

Removes all Flux controllers, CRDs from the `rollout` namespace, and the `k2s-addon-sync` namespace (including all `OCIRepository` and `Kustomization` resources registered for addon-sync).

---

## Backup and Restore

Backup/restore is scoped to the `rollout` namespace only.

### What gets backed up

- Flux CD custom resources in namespace `rollout` (`GitRepository`, `Kustomization`, `HelmRelease`, notifications, image automation)
- Secrets in namespace `rollout` referenced by Flux resources (`secretRef.name`)
- Optional webhook Ingress resources in namespace `rollout`

### What does not get backed up

- Flux controllers and CRDs (re-installed by `k2s addons enable rollout fluxcd` during restore)
- Resources outside of the `rollout` namespace
- Host binary `bin\\flux.exe` (installed on `enable`; in offline environments it is carried by `k2s addons export` / `k2s addons import`)

### Commands

```cmd
k2s addons backup rollout fluxcd
k2s addons restore rollout fluxcd -f <path-to-backup-zip>
```

---

## Further Reading

- [Flux Documentation](https://fluxcd.io/docs/)
- [Flux Guides](https://fluxcd.io/flux/guides/)
- [GitOps Addon Delivery — Full Operational Guide](../../../docs/op-manual/gitops-addon-delivery.md)
