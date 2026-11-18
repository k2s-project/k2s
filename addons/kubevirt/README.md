<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# kubevirt

## Introduction

The `kubevirt` addon provides the possibility to deploy virtual machines in the k2s cluster. [KubeVirt](https://kubevirt.io/) technology addresses the needs of development teams that have adopted or want to adopt Kubernetes but possess existing virtual machine-based workloads that cannot be easily containerized. More specifically, the technology provides a unified development platform where developers can build, modify, and deploy applications residing in both application containers as well as virtual machines in a common, shared environment.

## Getting started

The kubevirt addon can be enabled using the k2s CLI by running the following command:
```console
k2s addons enable kubevirt
```

## Disable kubevirt

The kubevirt addon can be disabled using the k2s CLI by running the following command:
```console
k2s addons disable kubevirt
```

## Using KubeVirt

An example how to deploy virtual machines in Kubernetes can be found [here](https://kubevirt.io/labs/kubernetes/lab1.html).

## Building your own virtual machine image

In order to run a virtual machine as pod inside Kubernetes a virtual machine image has to be created like container images for containers.
For this, *K2s* provides a *PowerShell* the script [BuildKubevirtImage.ps1](BuildKubevirtImage.ps1). With this script, it is possible to build a virtual image from *qcow2* image, e.g.:

```ps
.\BuildKubevirtImage.ps1 -InputQCOW2Image "some\path\windows20h2.qcow2" -ImageName "virt-win20h2"
```

## Backup and restore

The kubevirt addon supports backup and restore via the `k2s` CLI for consistency with other addons.

Because kubevirt is an **infrastructure addon** (nested virtualization, QEMU/libvirt packages, KubeVirt operator/CR, virtctl, VirtViewer), there is **no user-configurable state to back up**. The backup writes a metadata-only manifest; restore succeeds without additional steps once the addon has been re-enabled.

### What gets backed up

- Metadata only (`backup.json` with addon name, K2s version, timestamp).

### What does not get backed up

- Hyper-V nested virtualization settings (recreated by enable)
- Debian packages on the control-plane VM: QEMU, libvirt, fuse3 (reinstalled by enable)
- GRUB cgroup v1 configuration (reconfigured by enable)
- KubeVirt operator and CR (reapplied from static manifests by enable)
- virtctl binary on the VM and Windows host (re-downloaded by enable)
- VirtViewer MSI on the Windows host (re-downloaded and reinstalled by enable)
- User-created VirtualMachines and uploaded VM images (user workloads, outside addon scope)

### Commands

```console
k2s addons backup kubevirt
k2s addons restore kubevirt -f C:\Temp\k2s\Addons\kubevirt_backup_YYYYMMDD_HHMMSS.zip
```
