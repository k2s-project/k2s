<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# CLI Shortcuts
To interact with the *K2s* cluster, the following shortcuts can be used:

| Shortcut | Command                                                                  | Description                                         |
| -------- | ------------------------------------------------------------------------ | --------------------------------------------------- |
| `c`      | `crictl`                                                                 | Client for CRI                                      |
| `d`      | `docker`                                                                 | A self-sufficient runtime for containers            |
| `k`      | `kubectl`                                                                | *kubectl* controls the *Kubernetes* cluster manager |
| `ka`     | `kubectl apply`                                                          | Apply something to cluster                          |
| `kaf`    | `kubectl apply -f`                                                       | Apply specified YAML manifest                       |
| `kcp`    | `kubectl delete pod --field-selector=status.phase==Succeeded,Evicted -A` | Cleanup of all succeeded *Pods*                     |
| `kd`     | `kubectl describe`                                                       | Describe *Kubernetes* resource                      |
| `kdp`    | `kubectl describe pod`                                                   | Describe *Pod*                                      |
| `kdpn`   | `kubectl describe pod -n`                                                | Describe all *Pods* inside the specified namespace  |
| `kg`     | `kubectl get`                                                            | Get *Kubernetes* resource                           |
| `kgn`    | `kubectl get nodes -o wide`                                              | Get all cluster nodes                               |
| `kgp`    | `kubectl get pods -o wide -A`                                            | Get all *Pods* of all namespaces                    |
| `kl`     | `kubectl logs`                                                           | Show logs of *Kubernetes* resource                  |
| `krp`    | `kubectl delete pod`                                                     | Remove specified *Pod*                              |
| `ks`     | `k2s status -o wide`                                                     | Inspect *K2s* system health                         |

## Krew support

*K2s* bundles [Krew](https://krew.sigs.k8s.io/){target="_blank"}, the official *kubectl* plugin
manager, together with *kubectl* on **both** the Windows host and the Linux control-plane node. Krew is
part of the offline package, so no additional download is required — after installing *K2s* you can
immediately run:

=== "Windows host"

    ```powershell
    kubectl krew version
    ```

=== "Linux control-plane"

    ```console
    kubectl krew version
    ```

!!! note
    Installing plugins (for example `kubectl krew install ctx`) fetches the plugin index and packages
    from the internet and is therefore an online, user-initiated action. It is never performed during
    *K2s* installation, preserving *K2s*'s offline guarantees. *K2s* bundles Krew itself, but never
    bundles or installs plugins.

### Initializing the plugin index

*K2s* provides the Krew binary; the plugin index and the plugin lifecycle stay user-managed. Before
plugins can be searched or installed, initialize the index once per user:

```console
kubectl krew update
```

This command clones Krew's plugin index and therefore requires **Git** and **network access**. *K2s*
does not bundle Git on either platform — install it yourself if it is missing:

| Platform | Install Git via |
| -------- | --------------- |
| Windows host | [Git for Windows](https://git-scm.com/download/win){target="_blank"} |
| Linux control-plane | `sudo apt-get install git` |

Until the index is initialized, `kubectl krew list` and `kubectl krew search` report
`krew local plugin index is not initialized`, while `kubectl krew version` already works. This is
expected Krew behaviour and does not affect the *K2s* installation itself, which remains fully
offline-capable. The same model applies to *Helm*, where *K2s* ships the binary and you add chart
repositories yourself.

### Plugin directories and PATH

Krew installs plugins into a per-user directory, which *K2s* adds to `PATH` for the user that installed
*K2s* so that installed plugins are discoverable right away:

| Platform | Plugin directory | How `PATH` is configured |
| -------- | ---------------- | ------------------------ |
| Windows  | `%USERPROFILE%\.krew\bin` | User-scope `PATH` of the installing user |
| Linux control-plane | `$HOME/.krew/bin` | `~/.profile` of the node user |

Any additional user follows Krew's standard
[one-time PATH setup](https://krew.sigs.k8s.io/docs/user-guide/setup/install/){target="_blank"} to
expose their own plugins.

Plugins are **user-owned state**: *K2s* never backs up, migrates, upgrades or deletes `~/.krew`
(`%USERPROFILE%\.krew` on Windows). Plugins therefore survive a *K2s* upgrade and are not removed by
`k2s uninstall`. Use `kubectl krew upgrade` to update plugins yourself.

