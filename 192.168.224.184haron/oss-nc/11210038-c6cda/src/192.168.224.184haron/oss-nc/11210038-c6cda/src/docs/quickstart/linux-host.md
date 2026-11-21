<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Quick Start on a Linux Host

!!! warning "Experimental"
    Linux host support is experimental. Some features may be incomplete or change without notice.

This guide sets up a single-node *K2s* cluster on a *Linux* machine. In the [Linux Host](../user-guide/hosting-variants.md#linux-host) variant, the *Kubernetes* control plane runs natively on the host with *CRI-O* as its container runtime. No *PowerShell* is required. Optionally, *K2s* adds a managed *Windows* worker VM through *libvirt/KVM*. That step is covered at the end.

## Prerequisites
- *Debian 13* on an *x86-64* (amd64) machine. The installer reads `/etc/os-release` and stops on any other distribution or version.
- Root permissions through `sudo`.
- Swap must be disabled. The installer stops while any swap device is active:
    ```console
    sudo swapoff -a
    ```
    Also remove or comment out the swap entries in `/etc/fstab` so that swap stays disabled after a reboot. `swapon --show` must not print anything.
- No existing *Kubernetes* installation on the host. The installer stops if `/etc/kubernetes/admin.conf` already exists.
- Internet access, either directly or through an HTTP proxy. The installer downloads version-pinned *Kubernetes* and *CRI-O* *Debian* packages.
- The tools used by the build and the installer:
    ```console
    sudo apt-get update
    sudo apt-get install -y git curl jq iproute2 procps kmod e2fsprogs
    ```
- [*Go*](https://go.dev/dl/){target="_blank"} in the version required by `go.mod`, to build the `k2s` CLI. The release packages contain only the *Windows* CLI.

## 1. Get and Build *K2s*
Clone the repository and build the *Linux* executables:
```console
git clone https://github.com/k2s-project/k2s.git
cd k2s
bash ./build.sh
```

This builds the `k2s` CLI in the repository root and its helper executables in `bin/`. See [Building Natively on Linux](../dev-guide/contributing/building-locally.md#building-natively-on-linux-no-powershell) for details, e.g. building behind a proxy.

!!! note
    The cloned folder is the installation folder. The *K2s* system services run executables from it, so do not move or delete it while *K2s* is installed.

## 2. Install *K2s*
Install the control plane without a *Windows* worker:
```console
sudo ./k2s install --linux-only
```

Behind a corporate proxy, pass it to the installer:
```console
sudo ./k2s install --linux-only --proxy http://proxy.example:8080 --no-proxy localhost,127.0.0.1
```

The installer provisions the *Kubernetes* and *CRI-O* packages, initializes the control plane with *kubeadm*, deploys *Flannel*, and starts the *K2s* HTTP proxy and DNS proxy services. Progress is logged to `/var/log/k2s.log`. See [Installing *K2s*](../op-manual/installing-k2s.md#experimental-linux-host) for all options.

!!! warning
    The installer copies the cluster's kubeconfig to `~/.kube/config` of the user who runs `sudo`, replacing any existing file. Back it up first if you use other clusters.

## 3. Check the Cluster
```console
sudo ./k2s status
```

The kubeconfig is placed in your home folder, so `kubectl` works without `sudo`:
```console
kubectl get nodes -o wide
```

The host is the only node. It runs the control plane and also accepts workloads.

## 4. Deploy a Test Workload
```console
kubectl create deployment hello-k2s --image=docker.io/library/nginx:stable
kubectl rollout status deployment/hello-k2s
kubectl expose deployment hello-k2s --port=80
```

*K2s* forwards cluster DNS names to the host resolver while the cluster runs (see [Native Linux Host DNS](../op-manual/native-linux-host-dns.md)), so the service is reachable from the host by name:
```console
curl http://hello-k2s.default.svc.cluster.local
```

If your shell sets `http_proxy`, add `--noproxy '*'` so that `curl` connects to the service directly.

Remove the test workload afterwards:
```console
kubectl delete service,deployment hello-k2s
```

## 5. Stop, Start and Uninstall
```console
sudo ./k2s stop
sudo ./k2s start
sudo ./k2s uninstall
```

`k2s uninstall` removes the cluster, the *K2s* services and their state from the host.

## Optional: Add a Managed *Windows* Worker
Running *Windows* containers requires a *Windows* worker VM managed by *K2s*. Choose it at installation time: a `--linux-only` installation cannot add the worker later, so uninstall *K2s* first.

Additional prerequisites:

- Hardware virtualization: `/dev/kvm` must exist. When the host is itself a VM, enable nested virtualization.
- A prepared *Windows* worker image, see [Preparing a Windows Worker QCOW2](../op-manual/preparing-windows-worker-qcow2.md).
- Enough resources for the worker (by default 4 CPUs, 8GB RAM and a 64GB disk) plus a remaining host reserve of 2GB memory and 20GB disk. The worker memory must not exceed 75% of the host memory.

The installer installs *QEMU/KVM* and *libvirt* itself. Install without `--linux-only` and pass the image:
```console
sudo ./k2s install --windows-qcow2-path /path/to/WindowsWorker-Base.qcow2
```

Use `--worker-cpus`, `--worker-memory` and `--worker-disk` to change the worker's resources. `kubectl get nodes` then lists the *Windows* worker next to the host. Schedule *Windows* workloads on it with the node selector `kubernetes.io/os: windows`.

## Next Steps
- [*k2s* CLI](../user-guide/k2s-cli.md) and [Image Commands](../dev-guide/hosting-variants-features-matrix.md#image-commands) on *Linux* hosts
- [*K2s* Addons](../user-guide/addons.md): on *Linux* hosts, `registry` and `ingress` (`nginx`, `traefik`, `nginx-gw`) have native implementations
- [Native Linux Host DNS](../op-manual/native-linux-host-dns.md)

!!! note
    Not all *k2s* CLI commands are available on *Linux* hosts yet, e.g. `k2s system upgrade`, `k2s system package` and `k2s system restore`.
