<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Ceph CSI Storage (CephFS)

> **EXPERIMENTAL** — This addon is experimental and not recommended for production use.

The `storage ceph` addon provisions a Ceph cluster and exposes CephFS-backed dynamic storage for K2s.

## What this addon provides

- `ceph-cephfs` StorageClass for Linux workloads (`cephfs.csi.ceph.com`)
- Optional `ceph-smb` StorageClass for Windows workloads when enabled with `-w` (`smb.csi.k8s.io`)
- Mutual exclusion with `storage smb` (only one storage implementation can be enabled)

## Mutual exclusion with `storage smb`

Only one storage addon can be enabled at a time:

- `k2s addons enable storage ceph`
- or `k2s addons enable storage smb`

They cannot be enabled together.

## Requirements

- Ceph cluster host (`clusterHost.node`) must be a Debian 13 K2s node and reachable over SSH.
- OSD hosts from `osdHosts` must resolve to Hyper-V worker nodes in `cluster.json` (`NodeType = VM-EXISTING`).
- `storage smb` must be disabled before enabling Ceph.

Configuration file:

- [`config/ceph-config.json`](config/ceph-config.json)

## Default configuration profile

The shipped default profile is a minimal starter setup:

- `clusterHost.node` is `kubemaster`.
- `osdHosts` contains one host entry (`kubemaster`).
- That host creates one OSD with `osdSizesInGb: [6]`.

This profile is suitable for initial setup. For better throughput and resiliency, scale to multiple OSDs and multiple OSD nodes.

## Configure cluster host and OSD hosts

Edit [`config/ceph-config.json`](config/ceph-config.json).

- `clusterHost.node` selects the Debian 13 bootstrap host where the Ceph cluster is installed.
- `osdHosts` defines which nodes are prepared as OSD hosts and how many OSDs are created per node.
- Each `osdHosts` entry supports:
  - `osdSizesInGb`: one size per OSD, or
  - `osdSizeInGb`: one common size for all OSDs on that host.

```json
{
  "clusterHost": {
    "node": "kubemaster",
    "os": "linux",
    "osdCrushChooseleafType": 0,
    "monCount": 1,
    "mgrCount": 1,
    "mdsCount": 1
  },
  "osdHosts": [
    {
      "node": "kubemaster",
      "os": "linux",
      "osdCount": 1,
      "osdSizesInGb": [6]
    },
    {
      "node": "cephosdnode1",
      "os": "linux",
      "osdCount": 2,
      "osdSizesInGb": [10, 10]
    }
  ]
}
```

## Add an additional node for Ceph (OSD or cluster host)

You can use additional nodes either to host more OSDs or, before initial enable, to bootstrap the Ceph cluster itself.

### Option A: Add node before enabling Ceph

1. Add the node to K2s first.
2. Update `config/ceph-config.json`:
   - set `clusterHost.node` to the new Debian 13 node if you want to install Ceph there, or
   - add the node under `osdHosts` if it should be an OSD node.
3. Run:

```console
k2s addons enable storage ceph
```

With this order (config first, then enable), the node is attached to Ceph during bootstrap.

### Option B: Add node after Ceph is already enabled

1. Update `osdHosts` in `config/ceph-config.json` with the new node and OSD sizing.
2. Add the node (if not yet in the cluster).
3. Trigger reconciliation.

When node-add events occur with Ceph enabled, K2s reconciles Ceph OSD membership via `Update.ps1` and attaches the new OSD host automatically.

If you want to change `clusterHost.node` after Ceph is already enabled, re-provisioning is required (disable and re-enable), because disabling Ceph removes the provisioned cluster.

## Enable

CephFS for Linux:

```console
k2s addons enable storage ceph
```

CephFS for Linux + SMB path for Windows:

```console
k2s addons enable storage ceph -w
```

## Offline workflow (export/import)

Use this workflow when the target K2s environment is air-gapped.

1. Export the Ceph addon artifact on a connected environment:

```console
k2s addons export "storage ceph" -d C:\exports
```

2. Copy the generated OCI artifact to the offline environment.

3. Import the artifact before enabling Ceph:

```console
k2s addons import "storage ceph" -f C:\transfer\addons.oci.tar
```

Use `--node` when `clusterHost.node` points to a Linux worker node (not `kubemaster`) so Linux packages and staged files are placed on the node that will bootstrap Ceph:

```console
k2s addons import "storage ceph" -f C:\transfer\addons.oci.tar --node cephosdnode1
```

After import, enable Ceph normally:

```console
k2s addons enable storage ceph
```

or for cross-OS workloads:

```console
k2s addons enable storage ceph -w
```

## Verify

```console
kubectl get pods -n ceph-csi-operator-system
kubectl get storageclass | Select-String ceph
```

Expected StorageClasses:

- `ceph-cephfs` (Linux)
- `ceph-smb` (Windows, only when enabled with `-w`)

## Windows Ceph SMB user and credentials

When Ceph is enabled with `-w`, K2s creates the Ceph `mgr/smb` user automatically. If you do not set a custom value in `config/ceph-config.json` under `smb.userName`, the default SMB user name is `smbuser`.

The addon also generates a random password for that user and stores the credentials in the Kubernetes Secret named `smbcreds` in the namespace `storage-smb-ceph`. The Secret contains the fields:

- `username`
- `password`

This Secret is then consumed by the `ceph-smb` StorageClass for the SMB CSI driver.

## Disable

```console
k2s addons disable storage ceph
```

Force disable without prompt:

```console
k2s addons disable storage ceph -f
```

Disabling removes the entire Ceph cluster that was provisioned by this addon.

It also removes:

- the associated Ceph storage resources in Kubernetes,
- dynamically created PersistentVolumes from this Ceph setup,
- and the Ceph OSD disks/OSD daemons created by the addon.

Ceph data is lost after disable.

## Cross-OS storage guidance (Linux and Windows)

If your workloads span Linux and Windows nodes:

- Use the Ceph addon with `-w` to enable both provisioners in the Ceph flow.
- Linux workloads use `ceph-cephfs` (`cephfs.csi.ceph.com`).
- Windows workloads use `ceph-smb` (`smb.csi.k8s.io`).

If your workloads are Linux-only, use the Ceph provisioner (`ceph-cephfs`) without `-w`.

## Performance note

For better Ceph performance and resilience, prefer a multi-OSD and multi-node layout:

- Create multiple OSDs with higher storage capacity.
- Use multiple dedicated OSD nodes.
- Avoid relying only on the master/control-plane node for all OSD placement.

This improves parallel I/O throughput, reduces hotspot risk, and improves behavior during node or disk failures.

## Backup and Restore

```console
k2s addons backup storage ceph
k2s addons restore storage ceph
```

`backup` captures the Ceph addon configuration and any SMB-related Kubernetes resources that were created alongside it. It also preserves whether the addon had been enabled with `-w` so restore can replay the Windows SMB setup. It does not back up the actual Ceph user data because the data resides on the external Ceph cluster, not on the K2s addon folder.

`restore` re-applies the saved Ceph configuration and re-enables the addon with the same mode that was backed up. If the backup came from a `k2s addons enable storage ceph -w` deployment, restore re-enables the Ceph SMB Windows path as well. It does not restore the Ceph data itself; it only restores the addon configuration needed to reconnect and re-enable the storage setup.

## Detailed usage and examples

- Linux CephFS operations and examples:
  [`docs/op-manual/ceph-storage-linux.md`](../../../docs/op-manual/ceph-storage-linux.md)
- Cross-OS shared storage operations and examples for Linux and Windows workloads:
  [`docs/op-manual/ceph-storage-cross-os.md`](../../../docs/op-manual/ceph-storage-cross-os.md)

## References

- [Ceph CSI Operator](https://github.com/ceph/ceph-csi-operator)
- [Ceph documentation](https://docs.ceph.com/)
- [CephFS volumes and subvolumes](https://docs.ceph.com/en/latest/cephfs/fs-volumes/)
- [Ceph OSD overview](https://docs.ceph.com/en/latest/architecture/#object-storage-daemon-osd)
- [Ceph hardware recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/)
- [Storage implementations guide](../STORAGE_IMPLEMENTATIONS.md)
