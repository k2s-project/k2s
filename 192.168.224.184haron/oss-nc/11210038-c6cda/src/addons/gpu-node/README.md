<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# gpu-node

## Introduction
The `gpu-node` addon provides the possibility to configure the KubeMaster Linux VM as GPU node in order to run GPU workloads. When enabling this addon the KubeMaster Linux VM is configured to use the WSL2 Linux Kernel which is able to access the GPU of the Windows host machine and use it as shared instance together with the Windows host machine. The [k8s device plugin](https://github.com/NVIDIA/k8s-device-plugin) from Nvidia is responsible for deploying GPU workloads.

Optionally, the addon can be enabled in node-targeted mode by passing one or more cluster node names with `--node`. In that mode, if kubemaster node name is not passed then KubeMaster GPU setup is skipped and no NVIDIA addon workload/images are prepared on KubeMaster.

> **Supported hosting variants:** The `gpu-node` addon is fully supported on both **Hyper-V** and **WSL2** K2s setups.

## Getting started

### Prerequisites

1. **WSL (Windows Subsystem for Linux)** must be installed on the Windows host. This provides the GPU paravirtualization library (`libdxcore.so`) required by both the Hyper-V and WSL2 hosting variants. No Linux distribution is needed:
   ```console
   wsl --install --no-distribution
   ```

2. **NVIDIA drivers** must be installed on the Windows host: https://www.nvidia.com/Download/index.aspx

**NOTE:** A reboot may be necessary after installing either component.

The gpu-node addon can be enabled using the k2s CLI by running the following command:
```console
k2s addons enable gpu-node
```

To target only specific cluster node(s):

```console
k2s addons enable gpu-node --node my-gpu-worker
```

Multiple workers can be passed as a comma-separated list:

```console
k2s addons enable gpu-node --node gpu-worker-a,gpu-worker-b,kubemaster
```

If you include spaces after commas in PowerShell, quote the whole value:

```console
k2s addons enable gpu-node --node "gpu-worker-a, gpu-worker-b, kubemaster"
```

### GPU time-slicing (optional)

By default each pod gets exclusive access to the physical GPU. To share the GPU across multiple pods simultaneously, use the `--time-slices` flag:

```console
k2s addons enable gpu-node --time-slices 4
```

This configures the NVIDIA device plugin to advertise `4` virtual GPU slots backed by one physical GPU. Any integer between `2` and `16` is accepted. Pods schedule onto the GPU concurrently; CUDA time-slicing handles multiplexing transparently.

> **Note:** Time-slicing shares compute time but **does not** partition GPU memory. All pods on the same physical GPU share the same memory pool. Use exclusive mode (`--time-slices 1`, the default) for workloads with large memory requirements.

## Deploy a sample CUDA workload

The following example schedules a CUDA workload using the NVIDIA vectorAdd sample to verify GPU allocation and compute access:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never
  containers:
  - name: gpu-test
    image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1
    imagePullPolicy: IfNotPresent
    resources:
      limits:
        nvidia.com/gpu: 1
```

```console
kubectl apply -f gpu-test.yaml
kubectl wait pod gpu-test --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
kubectl logs gpu-test
kubectl delete pod gpu-test
```

## GPU Libraries Injected via CDI

The NVIDIA Device Plugin uses CDI (Container Device Interface) to inject GPU resources into containers. When a pod requests `nvidia.com/gpu`, the following are automatically mounted:

| Resource | Path | Purpose |
|----------|------|---------|
| Device | `/dev/dxg` | DirectX GPU device for WSL2/GPU-PV |
| Libraries | `/usr/lib/wsl/lib` | CUDA runtime (`libcuda.so`), D3D12 (`libd3d12.so`), dxcore (`libdxcore.so`) |
| Drivers | `/usr/lib/wsl/drivers` | Vendor-specific drivers (e.g., `libnvwgf2umx.so` for NVIDIA OpenGL) |

The `LD_LIBRARY_PATH` environment variable is also set to `/usr/lib/wsl/lib` so that applications can discover these libraries at runtime.

Expected output includes `Test PASSED`. Works on both Hyper-V GPU-PV and WSL2 setups.


## External GPU Worker Nodes

In addition to the KubeMaster VM, you can add external Linux machines with NVIDIA GPUs as GPU-capable worker nodes. This allows scaling GPU workloads across multiple physical machines.

### Prerequisites for External GPU Workers

1. **NVIDIA kernel drivers** must be pre-installed on the external Linux machine
2. The machine must be accessible via SSH from the K2s host
3. The machine must have a physical network connection (not on the KubeSwitch)

### Adding a GPU-Capable External Worker

GPU support is **automatically detected and configured** when adding a node. K2s checks for NVIDIA GPU hardware on the target machine and configures GPU support if detected.

```console
# Online installation - GPU support auto-detected and configured if NVIDIA GPU present
k2s node add --ip-addr 192.168.1.50 --username admin

# Offline installation - GPU packages used automatically if included in the node package
k2s node add --ip-addr 192.168.1.50 --username admin --node-package C:\packages\debian13-node-gpu.zip
```

When an NVIDIA GPU is detected, K2s automatically:
1. Verifies NVIDIA drivers are installed and functional (nvidia-smi)
2. Installs the NVIDIA Container Toolkit packages (online) or copies from node package (offline)
3. Configures CRI-O with CDI support
4. Labels the node with `gpu=true` and `accelerator=nvidia`

If no NVIDIA GPU is detected (or a non-NVIDIA GPU like AMD/Intel is present), GPU configuration is skipped automatically.

### Creating an Offline GPU Node Package

To add GPU workers in air-gapped environments:

```console
# Create a node package with GPU support (use --include-gpu to include NVIDIA packages)
k2s system package --node-package --os debian13 --include-gpu --target-dir C:\packages --name debian13-node-gpu.zip

# Transfer the package to the air-gapped environment and use it
# GPU support will be configured automatically if the node has an NVIDIA GPU
k2s node add --ip-addr 192.168.1.50 --username admin --node-package C:\packages\debian13-node-gpu.zip
```

### Lifecycle Considerations

- **Automatic GPU detection**: GPU workers are automatically configured when an NVIDIA GPU is detected during node addition
- **Order-independent**: GPU workers can be added before or after enabling the gpu-node addon
- **The addon must be enabled** for GPU workloads to run: `k2s addons enable gpu-node` (or node-targeted mode: `k2s addons enable gpu-node --node <node-name>`)
- **Labels coordinate scheduling**: The NVIDIA device plugin DaemonSet targets nodes with `gpu=true`
- **Disabling is global**: `k2s addons disable gpu-node` does not take `--node` and removes the device plugin DaemonSet cluster-wide
- **External worker labels are preserved on disable**: remove manually if needed with `kubectl label node <node-name> gpu- accelerator-`

### Disable Behavior

Use the single command below to disable the addon:

```console
k2s addons disable gpu-node
```

Notes:
- No node name is required or accepted for disable.
- The NVIDIA device plugin workload is removed from all nodes.
- Control-plane local GPU runtime cleanup is executed as part of disable.
- External worker GPU labels/configuration are intentionally kept.

### Check GPU Worker Status

```console
# View all GPU-capable nodes
kubectl get nodes -l gpu=true

# Check addon status including external workers
k2s addons status gpu-node
```


## Backup and restore

The gpu-node addon supports backup and restore via the `k2s` CLI for consistency with other addons.

Because gpu-node is a **pure infrastructure addon** (Hyper-V GPU passthrough, NVIDIA driver copy, WSL2 kernel swap, container toolkit installation, static Kubernetes manifests), there is **no user-configurable state to back up**. The backup writes a metadata-only manifest; restore succeeds without additional steps once the addon has been re-enabled.

### What gets backed up

- Metadata only (`backup.json` with addon name, K2s version, timestamp).

### What does not get backed up

- Hyper-V GPU partition adapter settings (recreated by enable)
- NVIDIA driver files and WSL2 kernel on the control-plane VM (reinstalled by enable)
- NVIDIA Container Toolkit APT packages (reinstalled by enable)
- NVIDIA Device Plugin Deployment and DCGM Exporter DaemonSet (reapplied from static manifests by enable)
- GPU configuration on external worker nodes (preserved; workers remain GPU-capable)

### Commands

```console
k2s addons backup gpu-node
k2s addons restore gpu-node -f C:\Temp\k2s\Addons\gpu-node_backup_YYYYMMDD_HHMMSS.zip
```

## Further Reading
- [WSL2 Linux Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
