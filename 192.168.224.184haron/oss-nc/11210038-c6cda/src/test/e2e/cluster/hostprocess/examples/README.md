<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# HostProcess Integration Examples

These examples accompany the guide
[Integrating Native Host Processes into Kubernetes & K2s](https://k2s-project.github.io/k2s/next/op-manual/integrating-native-processes/).

They show the **two options** for integrating a native Windows host process into a *K2s* cluster, using the
[`albumswin`](../albumswin/main.go) test executable as the example workload.

| Option | Folder | Lifecycle owner | Network identity |
|--------|--------|-----------------|------------------|
| **1 — Managed outside Kubernetes** | [`option-1-external-service`](./option-1-external-service) | You / the OS | KubeSwitch host IP `172.19.1.1` |
| **2 — Managed by Kubernetes (HostProcess)** | [`option-2-hostprocess-compartment`](./option-2-hostprocess-compartment) | kubelet / containerd | Pod IP (anchor compartment) |

## Prerequisites

* A running *K2s* cluster (`k2s status`), Windows worker node present.
* `albumswin.exe` built. From the repo root:

  ```powershell
  go build -o test/e2e/cluster/hostprocess/albumswin/albumswin.exe ./test/e2e/cluster/hostprocess/albumswin
  ```

* For Option 2 zero‑trust policies: the `security` addon (enhanced) enabled:

  ```powershell
  k2s addons enable security --type enhanced
  ```

## Cluster‑friendly configuration (both options)

`albumswin` is configurable from the outside — bind address, ports and compartment are all environment
variables. Always include the **KubeSwitch IP `172.19.1.1`** so the process is reachable from any pod:

| Env variable | Purpose | Example |
|--------------|---------|---------|
| `BIND_ADDRESS` | Application interface | `0.0.0.0` or `172.19.1.1` |
| `PORT` | Application port | `8080` |
| `HEALTH_BIND_ADDRESS` | Health interface | `172.19.1.1` |
| `HEALTH_PORT` | Health port | `8081` |
| `COMPARTMENT_ID_ATTACH` | Windows compartment to join | *(unset for Option 1)* |
| `RESOURCE` | Route/name of the app | `albums-win` |
