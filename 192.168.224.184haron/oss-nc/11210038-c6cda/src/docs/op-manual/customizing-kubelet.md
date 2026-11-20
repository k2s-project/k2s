<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Customizing Kubelet Configuration

By default, *K2s* installs kubelet with standard Kubernetes defaults on both the Linux control-plane node and the Windows worker node. This page describes managed role-based overrides in the install configuration and manual customization through the **kubelet configuration drop-in directory**, a feature that became generally available in Kubernetes 1.30.

## Overview

Kubelet reads its configuration from a base file (`config.yaml`, managed by kubeadm) and then merges any partial override files found in a **drop-in directory**:

| Node | Base config | Drop-in directory |
|------|------------|-------------------|
| Linux control-plane | `/var/lib/kubelet/config.yaml` | `/etc/kubernetes/kubelet.conf.d/` |
| Windows worker | `C:\var\lib\kubelet\config.yaml` | `C:\etc\kubernetes\kubelet.conf.d\` |

Drop-in files are read in **alphabetical order**. Each file is a partial `KubeletConfiguration` — only include the fields you want to override. Later files override earlier ones, and all override the base config.

!!! note
    *K2s* configures the kubelet drop-in directory on both Linux and Windows nodes during installation. Use managed install configuration for supported settings, or place a separate manual override file and restart kubelet.

## Managed Overrides in Install Configuration

On a Windows host, `k2s install -c <file>` can manage overrides for the Linux control plane and the optional Windows worker. This works with both Hyper-V and supported WSL control-plane installations. Native Linux-host installation is unchanged.

```yaml
kubeletOverrides:
  linuxControlPlane:
    enabled: true
    config:
      maxPods: 100
      systemReserved:
        cpu: "500m"
        memory: "1Gi"
      kubeReserved:
        cpu: "250m"
        memory: "512Mi"
  windowsWorker:
    enabled: true
    config:
      maxPods: 100
```

Only `maxPods`, `systemReserved.cpu`, `systemReserved.memory`, `kubeReserved.cpu`, and `kubeReserved.memory` are accepted. Resource values use Kubernetes quantity syntax. Unknown roles or fields, invalid quantities, and mistyped values fail validation before provisioning starts.

K2s renders deterministic partial `KubeletConfiguration` files at these fixed paths:

| Role | Managed file |
|------|--------------|
| Linux control plane | `/etc/kubernetes/kubelet.conf.d/20-k2s-install-config.conf` |
| Windows worker | `C:\etc\kubernetes\kubelet.conf.d\20-k2s-install-config.conf` |

The first line is `# This file is managed by K2s. Do not edit.` K2s changes only this fixed file and leaves unrelated drop-ins untouched. If the fixed path already contains an unmarked file, installation fails instead of replacing it. Omitting a role or setting `enabled: false` removes a previous K2s-managed file for that role. A running kubelet is restarted only when managed content changes.

For `k2s install --linux-only` on a Windows host, Linux control-plane overrides are applied and configured Windows worker overrides are skipped with a warning. The optional role does not cause installation to fail when its node is absent.

The feature requires no network access. The normalized install configuration is passed internally to node provisioning, so the same behavior is available for air-gapped installation.

## Manual Overrides on the Linux Control-Plane Node

On the Linux node, kubeadm configures the kubelet systemd unit with `--config-dir=/etc/kubernetes/kubelet.conf.d` automatically (Kubernetes >= 1.30). Drop-in files placed in this directory are read on kubelet startup without any additional changes.

### 1. Create an override file

Create a YAML file containing only the `KubeletConfiguration` fields you want to change. For example, to reserve resources for the system and set eviction thresholds:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 200
systemReserved:
  cpu: "500m"
  memory: "1Gi"
kubeReserved:
  cpu: "250m"
  memory: "512Mi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
```

Save this file locally, for example as `C:\temp\30-custom.conf`.

### 2. Copy the file to the Linux node

```console
k2s node copy -i 172.19.1.100 -u remote -s C:\temp\30-custom.conf -t /tmp/30-custom.conf
```

### 3. Place it in the drop-in directory

```console
k2s node exec -i 172.19.1.100 -u remote -c "sudo mkdir -p /etc/kubernetes/kubelet.conf.d && sudo cp /tmp/30-custom.conf /etc/kubernetes/kubelet.conf.d/30-custom.conf"
```

### 4. Restart kubelet

```console
k2s node exec -i 172.19.1.100 -u remote -c "sudo systemctl restart kubelet"
```

### 5. Verify

```console
k2s node exec -i 172.19.1.100 -u remote -c "cat /var/lib/kubelet/config.yaml" -r
```

Check that the node reflects the new settings:

```console
kubectl describe node kubemaster
```

Look for `Allocatable` and `Capacity` in the output.

## Customizing the Windows Worker Node

*K2s* configures the Windows kubelet with `--config-dir=C:\etc\kubernetes\kubelet.conf.d` and deploys a default drop-in file (`00-k2s-defaults.conf`) that sets `enforceNodeAllocatable: []`. To add custom overrides, create additional `.conf` files in the same directory.

### 1. Create an override file

Open an **elevated PowerShell** prompt on the Windows host:

```powershell
@"
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 100
systemReserved:
  cpu: "500m"
  memory: "1Gi"
"@ | Set-Content -Path "C:\etc\kubernetes\kubelet.conf.d\30-custom.conf" -Encoding UTF8
```

### 2. Restart the cluster

```console
k2s stop
k2s start
```

Alternatively, restart only the kubelet service (please consider dependencies):

```powershell
nssm restart kubelet
```

### 3. Verify

```console
kubectl describe node %COMPUTERNAME%
```

Check kubelet logs for any configuration errors:

```powershell
Get-Content "C:\var\log\kubelet\kubelet_stderr.log" -Tail 50
```

## Common Kubelet Settings

The table below lists commonly customized `KubeletConfiguration` fields. For the full reference, see the [Kubernetes KubeletConfiguration API](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/).

| Field | Description | Default |
|-------|-------------|---------|
| `maxPods` | Maximum number of pods per node | `110` |
| `systemReserved` | Resources reserved for OS processes | *(none)* |
| `kubeReserved` | Resources reserved for Kubernetes system daemons | *(none)* |
| `evictionHard` | Hard eviction thresholds (pods evicted immediately) | `memory.available: "100Mi"`, `nodefs.available: "10%"` |
| `evictionSoft` | Soft eviction thresholds (grace period before eviction) | *(none)* |
| `evictionSoftGracePeriod` | How long soft thresholds must be exceeded | *(none)* |
| `containerLogMaxSize` | Maximum size of a container log file before rotation | `"10Mi"` |
| `containerLogMaxFiles` | Maximum number of rotated container log files | `5` |
| `imageGCHighThresholdPercent` | Disk usage percentage that triggers image garbage collection | `85` |
| `imageGCLowThresholdPercent` | Disk usage percentage at which image GC stops | `80` |
| `clusterDNS` | DNS server IP addresses for pods | *(set by kubeadm)* |
| `cpuManagerPolicy` | CPU management policy (`none` or `static`) | `"none"` |
| `topologyManagerPolicy` | NUMA topology management policy | `"none"` |

## Example: Resource Reservation

A practical example that prevents kubelet from advertising all system resources as available capacity:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "1Gi"
kubeReserved:
  cpu: "250m"
  memory: "512Mi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
```

With these settings, the Kubernetes scheduler sees reduced `Allocatable` resources, preventing workloads from consuming all node capacity.

## Important Notes

!!! warning "Manual drop-ins are lost on install and upgrade"
    Drop-in files persist across `k2s stop` / `k2s start` cycles because kubelet re-reads them on every startup.

    Managed `kubeletOverrides` are recreated automatically during installation and full upgrade. When `k2s system upgrade` is run without `-c`, K2s reuses the previous effective install configuration. Supplying `-c` replaces it, and rollback uses the staged previous configuration.

    Separate user-created drop-ins are still lost during a full reinstall:

    - **Windows**: The entire `C:\etc\` directory tree is deleted and recreated
    - **Linux**: The VM is destroyed and provisioned from scratch

    The K2s default drop-in (`00-k2s-defaults.conf`) and managed `20-k2s-install-config.conf` are re-deployed automatically. Other user-created files (for example, `30-custom.conf`) must be re-applied manually.

    For settings outside the managed allowlist, re-apply the manual drop-in after every install or full upgrade.

    Recommended manual workflow:

    1. Store manual drop-in files in a version-controlled location outside K2s (for example, a Git repository or shared drive).
    2. After `k2s install` or `k2s system upgrade` completes, re-apply them:

    ```powershell
    # Windows worker node
    Copy-Item ".\my-kubelet-overrides\30-custom.conf" "C:\etc\kubernetes\kubelet.conf.d\"
    nssm restart kubelet
    ```

    ```console
    # Linux control-plane node
    k2s node copy -i 172.19.1.100 -u remote -s .\my-kubelet-overrides\30-custom.conf -t /tmp/30-custom.conf
    k2s node exec -i 172.19.1.100 -u remote -c "sudo cp /tmp/30-custom.conf /etc/kubernetes/kubelet.conf.d/30-custom.conf && sudo systemctl restart kubelet"
    ```

    Alternatively, use the [Hook System](hook-system.md) to automate re-application via a post-install hook script.

!!! info "K2s defaults"
    *K2s* ships a `00-k2s-defaults.conf` drop-in file on the Windows worker node that sets `enforceNodeAllocatable: []`. The managed `20-k2s-install-config.conf` is merged after it. Name separate manual files later in lexical order, for example `30-custom.conf`, when they must override managed values.

!!! info "Validation"
    Kubelet validates the merged configuration on startup. If an override file contains invalid field names or values, kubelet will fail to start. Always check kubelet logs after applying changes.

!!! info "Windows field support"
    Not all `KubeletConfiguration` fields are supported on Windows. Unsupported fields may be silently ignored or cause startup errors. Consult the [Kubernetes Windows documentation](https://kubernetes.io/docs/concepts/windows/) for details.
