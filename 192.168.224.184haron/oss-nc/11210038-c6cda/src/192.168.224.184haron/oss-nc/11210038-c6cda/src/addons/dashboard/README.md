<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# dashboard

## Introduction

The `dashboard` addon provides **Headlamp** — a lightweight, extensible Kubernetes web UI developed under the `kubernetes-sigs` organization (CNCF sandbox project). It allows users to browse and manage cluster resources, inspect workloads, view logs, and troubleshoot containerized applications.

## Getting started

The Headlamp dashboard can be enabled using the k2s CLI:

```console
k2s addons enable dashboard
```

### Integration with metrics addon

By enabling the metrics addon, Headlamp can display resource usage metrics (CPU/memory) for pods and nodes.

```console
k2s addons enable metrics
k2s addons enable dashboard
```

Or enable both together:

```console
k2s addons enable dashboard --enable-metrics
```

### Integration with ingress addons

The dashboard addon can be integrated with the ingress nginx, ingress traefik, or ingress nginx-gw addon to expose Headlamp outside the cluster.

```console
k2s addons enable dashboard --ingress traefik
```

```console
k2s addons enable dashboard --ingress nginx
```

```console
k2s addons enable dashboard --ingress nginx-gw
```

_Note:_ The above commands will enable the respective ingress addon if it is not already enabled.

## Accessing the dashboard

### Access using ingress

Once an ingress addon is enabled, the Headlamp UI is accessible at:

```
https://k2s.cluster.local/dashboard/
```

_Note:_ If a proxy server is configured in Windows Proxy settings, add `k2s.cluster.local` as a proxy override.

### Access using port-forwarding

```console
kubectl port-forward svc/headlamp -n dashboard 4466:4466
```

The Headlamp UI will be accessible at: <http://localhost:4466/dashboard/>

_Note:_ Any available local port can be substituted for `4466`.

### Authentication

When you open Headlamp for the first time, a **token login screen is displayed — this is expected and normal**. Headlamp requires a bearer token for cluster access.

To generate a ServiceAccount token and log in:

```console
kubectl -n dashboard create token headlamp --duration 24h
```

Copy the printed token and paste it into the Headlamp login screen, then click **Authenticate**.

> **Tip:** The `headlamp` ServiceAccount has `cluster-admin` rights, so it can see all cluster resources.

## Disable dashboard

```console
k2s addons disable dashboard
```

_Note:_ Only the dashboard addon is disabled. Other addons enabled alongside it (e.g. ingress) are not disabled.

## Backup and restore

The dashboard addon supports backup and restore via the `k2s` CLI.

Backup stores restore-relevant metadata:
- Selected ingress integration (`none`/`nginx`/`traefik`/`nginx-gw`)
- Whether the `metrics` addon was enabled

```console
k2s addons backup dashboard
k2s addons restore dashboard -f C:\Temp\k2s\Addons\dashboard_backup_YYYYMMDD_HHMMSS.zip
```

## Headlamp plugins (capability-based)

Headlamp is extended with K2s‑owned **plugins** that light up extra UI views when the
matching capability is present in the cluster. Plugins are **activated automatically** —
there is nothing to enable per plugin:

| Plugin | UI it adds | Activated when… |
|--------|------------|-----------------|
| cert-manager | cert-manager certificates/issuers view | the `cert-manager` capability is present (installed by `ingress nginx`/`traefik`/`nginx-gw` or `security`) |
| flux | Flux GitOps view | the Flux capability is present (`rollout fluxcd` or external Flux) |
| prometheus | Prometheus/metrics view | the monitoring capability is present |
| keda | KEDA autoscaling (ScaledObjects/ScaledJobs) view | the KEDA capability is present (`autoscaling` addon or external KEDA) |

How it works:

- Each plugin is an **OCI image** owned by K2s and published to
  `shsk2s.azurecr.io/headlamp-plugin-<name>:<version>`.
- When the `dashboard` addon is enabled, `Sync-HeadlampPlugins` detects available
  capabilities and patches the Headlamp deployment with one **init‑container per detected
  plugin** that copies the plugin into Headlamp's plugins volume. Removing a capability
  removes the plugin on the next sync.
- Activation never builds or downloads images at enable time. In offline installs the
  plugin images travel inside the offline package.

Plugin images are **built and published once** by the dashboard autoupdate CI workflow
(`K2s-Support/ci/autoupdate/27-update-addons-dashboard.yaml`) from checksum‑pinned bundles.
For the full producer/lifecycle/update documentation see
[`build/README.md`](build/README.md).

## Further Reading

- Headlamp Documentation: <https://headlamp.dev/docs/latest/>
- Headlamp GitHub: <https://github.com/kubernetes-sigs/headlamp>
