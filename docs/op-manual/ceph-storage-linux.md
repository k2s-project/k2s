<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Ceph Storage for Linux Workloads

This guide covers Linux workloads using the CephFS CSI path.

## Scope and constraints

- This path uses the Ceph provisioner `cephfs.csi.ceph.com` via StorageClass `ceph-cephfs`.
- `storage ceph` and `storage smb` cannot be enabled together.
- Disabling Ceph removes the full Ceph cluster created by the addon, including OSD resources and Ceph-backed PVs from this setup.

## Performance recommendation

For maximum Ceph performance, prefer:

- multiple OSDs with larger capacity,
- multiple dedicated OSD nodes,
- OSD placement not limited to the master/control-plane node.

## Ceph references

- [Ceph OSD architecture overview](https://docs.ceph.com/en/latest/architecture/#object-storage-daemon-osd)
- [Ceph hardware recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/)
- [CephFS volumes and subvolumes](https://docs.ceph.com/en/latest/cephfs/fs-volumes/)

## Add Additional Node for Ceph OSD

### Before Ceph enable

1. Add the node to K2s.
2. Update `addons/storage/ceph/config/ceph-config.json` under `osdHosts`.
3. Enable Ceph:

```console
k2s addons enable storage ceph
```

### After Ceph is already enabled

1. Update `osdHosts` in `addons/storage/ceph/config/ceph-config.json`.
2. Add the node to K2s.
3. Ceph reconciliation updates OSD membership through `addons/storage/ceph/Update.ps1`.

If the OSD section is updated first and then the node is added, the node is attached to Ceph by the update flow.

## Prerequisites

- The Ceph addon is enabled:

```console
k2s addons enable storage ceph
```

- The `ceph-cephfs` StorageClass exists.

## Offline setup using addon export/import

Use this when the target environment has no internet access.

1. On a connected K2s environment, export the Ceph addon artifact:

```console
k2s addons export "storage ceph" -d C:\exports
```

2. Transfer the exported OCI artifact to the offline environment.

3. Import it before enabling Ceph:

```console
k2s addons import "storage ceph" --zip C:\transfer\addons.oci.tar
```

4. If `clusterHost.node` is a Linux worker node, import with `--node` so offline Linux packages and staged files are copied to that worker:

```console
k2s addons import "storage ceph"  -f C:\transfer\addons.oci.tar --node cephosdnode1
```

5. Enable Ceph:

```console
k2s addons enable storage ceph
```

## Verify CephFS components

```console
kubectl get pods -n ceph-csi-operator-system
kubectl get storageclass ceph-cephfs
kubectl get csidriver cephfs.csi.ceph.com
```

## Example: dynamic CephFS PVC and shared access

Create a test PVC:

```powershell
kubectl delete pvc ceph-test-pvc --ignore-not-found
@'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-test-pvc
spec:
  accessModes: [ "ReadWriteMany" ]
  storageClassName: ceph-cephfs
  resources:
    requests:
      storage: 1Gi
'@ | kubectl apply -f -
```

Check binding:

```console
kubectl get pvc ceph-test-pvc
kubectl get pv
```

Create writer pod:

```powershell
@'
apiVersion: v1
kind: Pod
metadata:
  name: ceph-writer
spec:
  containers:
  - name: writer
    image: busybox:latest
    command: ['sh', '-c', 'echo "hello from k2s ceph" > /mnt/data/hello.txt && sleep 3600']
    volumeMounts:
    - name: data
      mountPath: /mnt/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ceph-test-pvc
'@ | kubectl apply -f -

kubectl wait --for=condition=Ready pod/ceph-writer --timeout=120s
kubectl exec ceph-writer -- cat /mnt/data/hello.txt
```

Create reader pod and verify shared file:

```powershell
@'
apiVersion: v1
kind: Pod
metadata:
  name: ceph-reader
spec:
  containers:
  - name: reader
    image: busybox:latest
    command: ['sh', '-c', 'sleep 3600']
    volumeMounts:
    - name: data
      mountPath: /mnt/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ceph-test-pvc
'@ | kubectl apply -f -

kubectl wait --for=condition=Ready pod/ceph-reader --timeout=120s
kubectl exec ceph-reader -- cat /mnt/data/hello.txt
```

Clean up:

```console
kubectl delete pod ceph-writer ceph-reader --ignore-not-found
kubectl delete pvc ceph-test-pvc --ignore-not-found
```
