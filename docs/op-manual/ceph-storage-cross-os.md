<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Ceph Storage for Cross-OS Shared Workloads

Windows pods cannot use the native CephFS CSI node plugin directly. In K2s, Windows consumes CephFS through SMB.

Use this guide when both Linux and Windows containers need to communicate through the same shared storage.

## Scope and constraints

- This path uses the Ceph SMB provisioner `smb.csi.k8s.io` via StorageClass `ceph-smb`.
- `storage ceph` and `storage smb` cannot be enabled together.
- Disabling Ceph removes the full Ceph cluster created by the addon, including OSD resources and Ceph-backed PVs from this setup.

For mixed Linux and Windows workloads, use Ceph with `-w`: Linux workloads consume `ceph-cephfs`, while Windows workloads consume `ceph-smb`.

## Performance recommendation

For maximum Ceph performance in mixed OS environments, prefer:

- multiple OSDs with larger capacity,
- multiple dedicated OSD nodes,
- OSD placement not limited to the master/control-plane node.

## Ceph references

- [CephFS volumes and subvolumes](https://docs.ceph.com/en/latest/cephfs/fs-volumes/)
- [Ceph OSD architecture overview](https://docs.ceph.com/en/latest/architecture/#object-storage-daemon-osd)
- [Ceph hardware recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/)

## Prerequisites

Enable Ceph with Windows SMB integration:

```console
k2s addons enable storage ceph -w
```

This creates:

- `ceph-smb` StorageClass (provisioner `smb.csi.k8s.io`)
- SMB CSI controller and node plugins in `smb.namespace` (default `storage-smb-ceph`)
- A Ceph `mgr/smb` share backed by a CephFS subvolume

The Windows SMB user is created automatically by the Ceph `mgr/smb` setup. If no custom `smb.userName` is configured in `config/ceph-config.json`, the default user name is `smbuser`. K2s then generates a random password and stores it in the Kubernetes Secret `smbcreds` in the same namespace used for the SMB CSI manifests (default `storage-smb-ceph`). The Secret contains `username` and `password`, and the `ceph-smb` StorageClass uses those credentials.

## Offline setup using addon export/import

Use this when the target environment is air-gapped.

1. On a connected K2s environment, export the Ceph addon artifact:

```console
k2s addons export "storage ceph" -d C:\exports
```

2. Transfer the exported OCI artifact to the offline environment.

3. Import it before enable:

```console
k2s addons import "storage ceph" --zip C:\transfer\addons.oci.tar
```

4. If `clusterHost.node` is a Linux worker node, use `--node` so Ceph bootstrap prerequisites are staged on the actual Ceph host:

```console
k2s addons import "storage ceph"  -f C:\transfer\addons.oci.tar --node cephosdnode1
```

5. Enable Ceph with Windows integration:

```console
k2s addons enable storage ceph -w
```

## Verify SMB path

```console
kubectl get pods -n storage-smb-ceph
kubectl get storageclass ceph-smb
```

Expected pods include `csi-smb-controller`, `csi-smb-node`, and `csi-smb-node-win`.

## Example: Cross-OS read/write validation with Ceph SMB

This example validates real shared-volume behavior by mounting the same `ceph-smb` PVC from:

- one Linux pod that writes and reads files,
- one Windows pod that writes and reads files.

Windows workloads in K2s must include both a Windows node selector and the `OS=Windows:NoSchedule` toleration.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ceph-crossos-test
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-crossos-pvc
  namespace: ceph-crossos-test
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: ceph-smb
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ceph-crossos-linux
  namespace: ceph-crossos-test
spec:
  nodeSelector:
    kubernetes.io/os: linux
  containers:
  - name: writer-reader
    image: docker.io/alpine:3.20
    command:
    - /bin/sh
    - -c
    - |
      set -eu
      echo "hello-from-linux" > /data/linux.txt
      while true; do
        date -Iseconds >> /data/linux-heartbeat.log
        if [ -f /data/windows.txt ]; then
          echo "linux sees windows.txt:"
          cat /data/windows.txt
        fi
        sleep 5
      done
    volumeMounts:
    - name: shared
      mountPath: /data
  volumes:
  - name: shared
    persistentVolumeClaim:
      claimName: ceph-crossos-pvc
---
apiVersion: v1
kind: Pod
metadata:
  name: ceph-crossos-windows
  namespace: ceph-crossos-test
spec:
  nodeSelector:
    kubernetes.io/os: windows
  tolerations:
  - key: "OS"
    operator: "Equal"
    value: "Windows"
    effect: "NoSchedule"
  containers:
  - name: writer-reader
    image: mcr.microsoft.com/windows/servercore:ltsc2025
    command:
    - powershell.exe
    - -Command
    - |
      New-Item -ItemType Directory -Path C:\data -Force | Out-Null
      'hello-from-windows' | Set-Content -Path C:\data\windows.txt
      while ($true) {
        (Get-Date).ToString('o') | Add-Content -Path C:\data\windows-heartbeat.log
        if (Test-Path C:\data\linux.txt) {
          Write-Output 'windows sees linux.txt:'
          Get-Content C:\data\linux.txt
        }
        Start-Sleep -Seconds 5
      }
    volumeMounts:
    - name: shared
      mountPath: C:\\data
  volumes:
  - name: shared
    persistentVolumeClaim:
      claimName: ceph-crossos-pvc
```

Apply and verify:

```console
kubectl apply -f ceph-crossos-test.yaml
kubectl get pvc -n ceph-crossos-test ceph-crossos-pvc
kubectl get pods -n ceph-crossos-test -o wide
kubectl logs -n ceph-crossos-test ceph-crossos-linux --tail=40
kubectl logs -n ceph-crossos-test ceph-crossos-windows --tail=40
kubectl exec -n ceph-crossos-test ceph-crossos-linux -- ls -la /data
```

The pod-created files can be seen in the below path:

```powershell
C:\k8s-ceph-share\pvc-cedc059c-94f2-443b-9a7c-a39d80f96269
```

Cleanup:

```console
kubectl delete namespace ceph-crossos-test
```

For SMB addon-specific behavior and non-Ceph SMB examples, see the SMB addon README at `addons/storage/smb/README.md`.
