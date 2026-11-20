<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Rollout — ArgoCD Implementation

## Introduction

ArgoCD is a declarative GitOps continuous delivery tool with a web UI and CLI. It monitors live cluster state against a desired state defined in Git and reports drift, providing manual or automatic sync. The K2s rollout addon installs ArgoCD into the `rollout` namespace.

## Enable ArgoCD

```console
k2s addons enable rollout argocd
```

### Enable with ingress (to expose the ArgoCD dashboard)

```console
k2s addons enable rollout argocd --ingress traefik
k2s addons enable rollout argocd --ingress nginx-gw
```

If the specified ingress addon is not already enabled, it will be enabled automatically.

### Skip addon-sync infrastructure

By default, enabling ArgoCD also deploys the addon-sync infrastructure for OCI-based addon delivery. To skip it:

```console
k2s addons enable rollout argocd --addon-sync=false
```

## Check Status

```console
k2s addons status rollout argocd
```

---

## Access the ArgoCD Dashboard

### Via ingress

Requires ingress nginx, nginx-gw, or traefik to be enabled alongside rollout.

```
https://k2s.cluster.local/rollout
```

### Via port-forwarding

```console
kubectl -n rollout port-forward svc/argocd-server 8080:443
```

Open `https://localhost:8080/rollout`. Accept the self-signed certificate.

---

## Deploy Applications with ArgoCD

### Via CLI

```console
# 1. Log in
argocd login k2s.cluster.local:443 --grpc-web-root-path "rollout"

# 2. Add your Git repository
argocd repo add https://github.com/myorg/myapp.git

# 3. Create an application
argocd app create myapp \
  --repo https://github.com/myorg/myapp.git \
  --path deploy \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default

# 4. Sync
argocd app sync myapp
```

For private repositories, add credentials: `argocd repo add <url> --username <user> --password <pass>`.

### Via Web UI

1. Visit the dashboard URL (see [Access the ArgoCD Dashboard](#access-the-argocd-dashboard))
2. **Settings → Repositories → Connect Repo** — add your Git repository
3. **Applications → New App** — fill in source (repo, path, revision) and destination (cluster, namespace)
4. Click **Sync** in the application overview to deploy

---

## GitOps Addon Delivery (Addon-Sync)

Addon-sync provides GitOps-style addon delivery from an OCI registry into the local K2s addon catalog. After sync, addons can be managed with normal `k2s addons` commands.

> **Sync vs. enable:** Sync only makes addon definitions available locally. It does **not** deploy workloads. Use `k2s addons enable <name>` after sync to install or update the addon in the cluster.

### Prerequisites

- Rollout with ArgoCD enabled
- Reachable OCI registry for addon artifacts
- `oras` available to push exported OCI addon artifacts

Placeholders used below:

- `<REGISTRY_HOST>`: OCI registry host (example only: `k2s.registry.local:30500`)
- `<REGISTRY_URL>`: `oci://<REGISTRY_HOST>`
- `<ADDON_NAME>`: addon repository name under `addons/` (for example `monitoring`)

```console
k2s addons enable rollout argocd
```

### Minimal workflow

1. Export the addon as OCI layout.
2. Push the exported artifact to your registry under `addons/<name>:<tag>`.
3. Wait for addon-sync to detect and pull the new digest.
4. Enable the addon with K2s.

```console
# 1) Export
k2s addons export <ADDON_NAME> -d C:\exports --omit-images --omit-packages

# 2) Push (example)
oras copy --from-oci-layout C:\exports\<exported-addon>.oci.tar:<tag> <REGISTRY_HOST>/addons/<ADDON_NAME>:<tag>

# 3) Verify it is now available locally
k2s addons ls

# 4) Deploy workloads
k2s addons enable <ADDON_NAME>
```

### Custom registry values (example)

Use your own registry host in the push target. For example:

```console
set REGISTRY_HOST=registry.example.local:5000
set REGISTRY_URL=oci://%REGISTRY_HOST%
oras copy --from-oci-layout C:\exports\<exported-addon>.oci.tar:<tag> %REGISTRY_HOST%/addons/<ADDON_NAME>:<tag>
```

Use the same `%REGISTRY_URL%` and repository path (`addons/<ADDON_NAME>`) that your addon-sync configuration watches.

### Configurable options

The `addon-sync-config` ConfigMap controls core addon-sync behavior:

- `REGISTRY_URL`: Registry base URL watched by addon-sync.
- `K2S_INSTALL_DIR`: Windows host K2s installation path.
- `INSECURE`: HTTP/plain mode (`true` or `false`).

For TLS and authentication, configure the registry and ORAS/runtime credentials according to your chosen registry product.

### Install directory behavior (auto-detected and patched)

When you run `k2s addons enable rollout argocd`, `K2S_INSTALL_DIR` is patched automatically to the detected K2s installation path.

If you apply manifests manually, verify and update `addon-sync-config` so `K2S_INSTALL_DIR` matches your actual installation path.

#### Change the polling interval

```console
kubectl edit cronjob addon-sync-poller -n k2s-addon-sync
```

Modify `spec.schedule` (e.g., `*/2 * * * *` for 2-minute polling, `*/10 * * * *` for 10-minute polling).

#### Registry without catalog API

If your registry disables `GET /v2/_catalog` (common with RBAC-restricted Harbor, GHCR, ECR), `oras repo ls` returns no results and the poller skips all addons. Fix this by explicitly listing the addon repositories:

```console
kubectl patch configmap addon-sync-config -n k2s-addon-sync --type merge \
  -p '{"data":{"ADDON_REPOS":"monitoring,security,registry"}}'
```

`Sync-Addons.ps1` reads `ADDON_REPOS` and uses it instead of catalog discovery. Update this list when you add new addons to the registry.

---

### Troubleshooting

- Addon not listed in `k2s addons ls`: confirm artifact path/tag and wait for the next sync cycle.
- Sync appears stalled: check addon-sync poller/jobs and logs in `k2s-addon-sync` namespace.
- Addon listed but nothing deployed: run `k2s addons enable <name>` (sync alone does not deploy).

```console
kubectl get cronjob -n k2s-addon-sync
kubectl get jobs -n k2s-addon-sync --sort-by=.metadata.creationTimestamp
kubectl logs -n k2s-addon-sync -l app.kubernetes.io/component=poller --tail=100
```


## Backup and Restore

Backup/restore is **scoped to the `rollout` namespace only**.

### What gets backed up

- `argocd admin export -n rollout` output (applications, projects, repository connections, settings)
- Optional dashboard ingress resources in namespace `rollout`

> **Note:** The ArgoCD export contains repository credentials. Store the backup archive securely.

### What does not get backed up

- ArgoCD controller manifests and CRDs (re-installed by `k2s addons enable rollout argocd` during restore)
- Resources outside the `rollout` namespace
- The `k2s-addon-sync` namespace — re-deployed automatically when rollout is re-enabled

### Commands

```console
k2s addons backup rollout argocd
k2s addons restore rollout argocd -f <path-to-backup-zip>
```

### Admin import/export

If you need to use `argocd admin export`/`import` directly, specify the `rollout` namespace:

```console
argocd admin export -n rollout > backup.yaml
Get-Content -Raw .\backup.yaml | argocd admin import -n rollout -
```

---

## Disable ArgoCD

```console
k2s addons disable rollout argocd
```

Removes ArgoCD from the `rollout` namespace, the `k2s-addon-sync` namespace, and all addon-sync resources. Ingress addons enabled alongside rollout are not disabled.

---

## Further Reading

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/en/stable/)
- [GitOps Addon Delivery — Full Operational Guide](../../../docs/op-manual/gitops-addon-delivery.md)
