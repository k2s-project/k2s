<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Assignment of Cluster IP Addresses for Services

*K2s* includes a **mutating admission webhook** that automatically assigns Cluster IPs to Services based on their target OS. You no longer need to specify `clusterIP` manually in your Service manifests.

- **Linux** services receive IPs from `172.21.0.50–254` (subnet `172.21.0.0/24`)
- **Windows** services receive IPs from `172.21.1.50–254` (subnet `172.21.1.0/24`)
- IPs up to `.49` in each subnet are reserved for *K2s* infrastructure.

## *Linux*-based workloads
Linux is the default. Simply create a Service without any special label — the webhook assigns a `172.21.0.x` Cluster IP automatically.

!!! example
    ```yaml linenums="1" title="example-service-manifest.yaml"
    apiVersion: v1
    kind: Service
    metadata:
      name: linux-example
    spec:
      selector:
        app: linux-example
      ports:
        - protocol: TCP
          port: 80
          targetPort: 80
    ```

## *Windows*-based workloads
No special label is needed. The webhook automatically detects that the Service targets a Windows workload by inspecting the `nodeSelector` of matching Deployments, StatefulSets, or DaemonSets. If the workload has `kubernetes.io/os: windows` in its `nodeSelector`, the Service receives a `172.21.1.x` Cluster IP.

!!! example
    ```yaml linenums="1" title="example-service-manifest.yaml"
    apiVersion: v1
    kind: Service
    metadata:
      name: windows-example
    spec:
      selector:
        app: windows-example
      ports:
        - protocol: TCP
          port: 80
          targetPort: 80
    ```

## How it works

The `clusterip-webhook` runs as a Deployment in the `k2s-webhook` namespace. It intercepts both **Service** and **workload** (Deployment, StatefulSet, DaemonSet) CREATE requests via two mutating admission webhooks.

### Service CREATE

1. Checks if the Service already has an explicit `clusterIP` (or is headless / ExternalName) — if so, it does nothing.
2. Checks an **in-memory cache** populated by recent workload admissions (handles the simultaneous-apply case).
3. Looks up Deployments, StatefulSets, and DaemonSets in the same namespace whose pod template labels match the Service selector. If the workload has `kubernetes.io/os: windows` in its `nodeSelector`, the Windows subnet is used.
4. If no matching workload is found, checks running Pods and their Node's `kubernetes.io/os` label as a fallback.
5. Defaults to the Linux subnet if no OS can be determined.
6. Lists existing Services to find which IPs are already in use.
7. Picks the first free IP in the target subnet range (`.50` – `.254`).
8. Returns a JSON Patch that sets `spec.clusterIP` on the Service.

### Workload CREATE (Deployment / StatefulSet / DaemonSet)

When a workload with `kubernetes.io/os` in its `nodeSelector` is created, the webhook caches the OS information for the workload's pod template labels. If the workload targets **Windows**, it additionally:

1. Scans existing Services whose selector matches the workload's pod labels.
2. If any such Service has a ClusterIP in the Linux subnet (assigned by default before the Windows workload existed), the webhook **deletes and recreates** it without a `clusterIP`, triggering a new Service admission that now picks the correct Windows IP from the cache.

This reconciliation handles the common `kubectl apply -k` case where Services and Deployments are submitted simultaneously — Kubernetes processes Services first, before the backing workload exists. Workloads without a `kubernetes.io/os` nodeSelector are ignored since Services default to the Linux subnet anyway.

TLS certificates for the webhook are generated automatically by an init container on each Pod startup. The init container creates a self-signed certificate (valid for one year) and patches the webhook configuration. Certificate renewal happens automatically whenever the webhook Pod is recreated — for example, via `k2s system certificate renew`, deployment rollout, or pod deletion.

!!! note
    You can still set `clusterIP` manually if needed (e.g., for infrastructure services in the reserved `.0–.49` range). The webhook will skip any Service that already has `clusterIP` set.