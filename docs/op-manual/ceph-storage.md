<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Ceph Storage

This section documents how to operate K2s Ceph storage per workload OS.

- Linux workloads use CephFS through the `ceph-cephfs` StorageClass.
- Windows workloads use Ceph over SMB through the `ceph-smb` StorageClass (enabled with `-w`).

## Important behavior

- `storage ceph` and `storage smb` are mutually exclusive. Only one can be enabled at a time.
- Disabling Ceph removes the entire addon-provisioned Ceph cluster, including OSD resources and Ceph-backed PVs created by this setup.

## Default configuration profile

The default Ceph configuration is intentionally minimal:

- `clusterHost.node` = `kubemaster`
- `osdHosts` contains `kubemaster`
- single OSD with `osdSizesInGb: [6]`

Use this as a starter profile and scale out for production-like performance.

## Cross-OS guidance

For Linux + Windows workload environments:

- Enable Ceph with `-w`.
- Use `ceph-cephfs` provisioner for Linux workloads.
- Use `ceph-smb` provisioner for Windows workloads.

## Offline guidance (addon export/import)

For air-gapped environments, export and import the Ceph addon before enable:

```console
k2s addons export "storage ceph" -d C:\exports
k2s addons import "storage ceph"  -f C:\transfer\addons.oci.tar
```

If `clusterHost.node` is a Linux worker node, include `--node <worker-node-name>` on import so offline Ceph bootstrap prerequisites are staged on the target Ceph host.

## Performance recommendation

To get better Ceph storage performance, it is recommended to:

- create multiple OSDs with higher storage capacity,
- distribute OSDs across multiple OSD nodes,
- keep OSD placement beyond only the master/control-plane node.

This improves throughput, balancing, and resilience.

## Ceph reference documentation

- [CephFS volumes and subvolumes](https://docs.ceph.com/en/latest/cephfs/fs-volumes/)
- [Ceph OSD architecture overview](https://docs.ceph.com/en/latest/architecture/#object-storage-daemon-osd)
- [Ceph hardware recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/)
- [Ceph upstream documentation portal](https://docs.ceph.com/)

## Configure cluster host and OSD hosts

Edit `addons/storage/ceph/config/ceph-config.json`.

- `clusterHost.node` defines where Ceph cluster bootstrap runs.
- `osdHosts` defines OSD nodes and OSD sizing.
- `osdSizesInGb` can set per-OSD sizes; `osdSizeInGb` can set one common size for that host.

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

## Add Additional Node for Ceph (OSD Host or Cluster Host)

You can add extra nodes for OSD expansion, and you can also bootstrap Ceph on an additional Debian node.

### Add node before enabling Ceph

1. Add the node to K2s.
2. Update Ceph config:
	 - set `clusterHost.node` to that node (to install Ceph there), or
	 - add that node in `osdHosts` (to use it for OSDs).
3. Enable Ceph.

```console
k2s addons enable storage ceph
```

If OSD config is prepared first and then the node is added, Ceph uses that node during setup.

### Add node after Ceph is already enabled

1. Update `osdHosts` in `addons/storage/ceph/config/ceph-config.json`.
2. Add the node to K2s.
3. Reconciliation updates Ceph via `addons/storage/ceph/Update.ps1`.

If Ceph is already enabled, update config and then add node; the node is attached to Ceph through the update flow.

Changing `clusterHost.node` after Ceph is enabled requires re-provisioning (disable and re-enable Ceph).

Choose the guide that matches your workload pattern:

- [Ceph Storage for Linux Workloads](ceph-storage-linux.md)
- [Ceph Storage for Cross-OS Shared Workloads](ceph-storage-cross-os.md)

For addon-level essentials, see the Ceph addon README in the repository at `addons/storage/ceph/README.md`.
