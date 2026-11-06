<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# storage

## Introduction

The `storage smb` addon provides a Samba share in order to share files between the k2s nodes:

- smb share between k2s nodes can be either hosted by Windows or by Linux (Samba)
- smb share can be accessed by the node's OSs
- StorageClass "smb" based on this smb share for automatic storage volume provisioning

## Getting started

The storage smb addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable storage smb
```

## Backup and restore

Create a backup zip (defaults to `C:\Temp\k2s\Addons` on Windows):
```
k2s addons backup "storage smb"
```

Restore from a backup zip:
```
k2s addons restore "storage smb" -f C:\Temp\k2s\Addons\storage_smb_backup_YYYYMMDD_HHMMSS.zip
```

The backup includes:
- A snapshot of the SMB storage configuration (based on `config/SmbStorage.json`)
- A best-effort snapshot of the addon entry from `setup.json`
- The contents of the configured SMB share folder(s) on the Windows host (`winMountPath`)

Secrets (e.g. the generated `smbcreds` Kubernetes Secret) are not backed up.

## Shared folder

The SMB share folder mappings can be configured in the SmbStorage.json file located at: @(../../../K2s/addons/storage/smb/config/SmbStorage.json)
This configuration allows the definition of multiple shared folder pairs between Windows and Linux environments.

By default, the configuration contains a single shared folder mapping as shown below:

                [
                    {
                        "winMountPath": "C:\\k8s-smb-share",
                        "linuxMountPath": "/mnt/k8s-smb-share",
                        "linuxShareName": "linux-smb-share",
                        "winShareName": "win-smb-share",
                        "storageClassName": "smb"
                    }
                ]

To enable multiple shared folders, the configuration can be extended as follows. You may customize the folder names and paths based on your requirements.
Ensure each shared folder mapping includes a unique storageClassName to avoid conflicts in your k2s environment.
  
                  [
                      {
                          "winMountPath": "C:\\k8s-smb-share1",
                          "linuxMountPath": "/mnt/k8s-smb-share1",
                          "linuxShareName": "linux-smb-share1",
                          "winShareName": "win-smb-share1",
                          "storageClassName": "smb1"
                      }
                      {
                          "winMountPath": "C:\\k8s-smb-share2",
                          "linuxMountPath": "/mnt/k8s-smb-share2",
                          "linuxShareName": "linux-smb-share2",
                          "winShareName": "win-smb-share2",
                          "storageClassName": "smb2"
                      }
                  ]


 

## SMB 3.1.1 POSIX Extensions

The addon supports opt-in SMB 3.1.1 POSIX extensions per storage entry.
This is useful for workloads that require POSIX semantics on an SMB share hosted by a Linux Samba server.

### Configuration

Add the following optional fields to your SmbStorage.json entries:

- **smbDialect** (default: auto → 3.0) - SMB protocol version for fstab mounts. Valid: auto, 3, 3.0, 3.1.1. When set to `auto`, uses the default version (currently 3.0).
- **enablePosixExtensions** (default: false) - Removes noperm from mount options, configures Samba for POSIX (streams_xattr).
- **useServerInode** (default: false) - When true with POSIX, omits noserverino from mount options.

When POSIX extensions are enabled, the addon installs the `samba-vfs-modules` package on the Linux control-plane host (in addition to `cifs-utils` and `samba`), which provides the `streams_xattr` Samba VFS module. The package is acquired through the offline-aware installer and is only downloaded when it is not already cached on the host.

### Limitations

- POSIX extensions are only meaningful with a Linux SMB host (Samba).
- The smbDialect field affects fstab mounts only. StorageClass mounts use the CSI driver negotiation.
- Omitting all three fields preserves the existing default behavior.

### Rollback

To revert a POSIX-enabled share to the previous default behavior:

1. Edit the affected entry in `SmbStorage.json`: set `enablePosixExtensions` to `false` and `smbDialect` to `auto` (or remove all three optional fields).
2. Re-apply the configuration by disabling and re-enabling the addon (`k2s addons disable storage smb` then `k2s addons enable storage smb`), or by re-running the addon configuration step.
3. The host fstab mount reverts to its default SMB dialect (the Windows SMB host uses `vers=3.0`, the Linux Samba host uses `vers=3`, both of which negotiate automatically) and the StorageClass drops the POSIX mount options; the Samba `streams_xattr` settings are removed on the next host setup.

Existing data on the share is not affected by the rollback - no migration is required. Symbolic links created while POSIX was enabled remain on disk but may not be traversable over SMB once POSIX is disabled.

## StorageClass Mount Options

By default, the addon generates the CIFS mount options of each StorageClass, e.g. `dir_mode=0777` and `file_mode=0777`. Some workloads validate strict POSIX-style permissions and refuse to start on such volumes when running as a non-root user.

### Configuration

Add the optional **mountOptions** array to a SmbStorage.json entry to define the mount options of its StorageClass. The array **replaces** the generated mount options entirely - including the options derived from `enablePosixExtensions`, `useServerInode` and `smbDialect` - so it must contain every option the volume needs. Entries without `mountOptions` keep the generated defaults.

Each array entry must be a single mount option, e.g. `dir_mode=0700`, consisting only of letters, digits and the characters `_ . = / + -`. Whitespace, commas, quotes and other YAML-special characters are rejected, as are empty arrays. Invalid options make `k2s addons enable storage smb` fail with an error naming the affected StorageClass, before any share or StorageClass is created.

### PostgreSQL example

PostgreSQL requires its data directory to be accessible only by its owner (`0700`) or by its owner and group (`0750`). Keep the general-purpose `smb` StorageClass unchanged and add a dedicated `smb-postgres` StorageClass whose volumes are owned by the PostgreSQL user (UID/GID `1001` in this example):

```json
[
    {
        "winMountPath": "C:\\k8s-smb-share",
        "linuxMountPath": "/mnt/k8s-smb-share",
        "linuxShareName": "linux-smb-share",
        "winShareName": "win-smb-share",
        "storageClassName": "smb"
    },
    {
        "winMountPath": "C:\\k8s-smb-postgres",
        "linuxMountPath": "/mnt/k8s-smb-postgres",
        "linuxShareName": "linux-smb-postgres-share",
        "winShareName": "win-smb-postgres-share",
        "storageClassName": "smb-postgres",
        "mountOptions": [
            "dir_mode=0700",
            "file_mode=0600",
            "uid=1001",
            "gid=1001",
            "noperm",
            "mfsymlinks",
            "cache=strict",
            "noserverino"
        ]
    }
]
```

Disable the addon before editing `SmbStorage.json` and re-enable it afterwards (see [POSIX-enabled example](#posix-enabled-example)). Then verify the generated StorageClass and the PersistentVolume of a new PersistentVolumeClaim referencing `storageClassName: smb-postgres`:

```
kubectl get storageclass smb-postgres -o yaml
kubectl get pv <pv-name> -o yaml
```

Both must list the configured options under `mountOptions`.

### Limitations

- Mount options are applied by the CSI driver when a volume is mounted on a Linux node; Windows nodes do not use them. They emulate the permissions and ownership reported to the workload; they do not change how the SMB host stores the files, and SMB POSIX extensions alone do not provide local-filesystem POSIX behavior.
- Kubernetes copies the StorageClass mount options into a PersistentVolume when it is provisioned. Existing PersistentVolumes are not updated; delete and re-provision them to apply changed options.
- Set `uid`/`gid` to the user and group the workload runs as (e.g. `securityContext.runAsUser`/`runAsGroup`); workloads such as PostgreSQL verify that they own their data directory.

## Examples

After enabling the addon, reference the StorageClass name (as printed in the enable output and configured in `SmbStorage.json`) from a `PersistentVolumeClaim`. The example below provisions a 1Gi volume from the default `smb` StorageClass and mounts it into a workload at `/mnt/smb`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: smb-example
  namespace: default
spec:
  serviceName: smb-example
  replicas: 1
  selector:
    matchLabels:
      app: smb-example
  template:
    metadata:
      labels:
        app: smb-example
    spec:
      containers:
        - name: smb-example
          image: docker.io/curlimages/curl:8.5.0
          command: ["/bin/sh", "-c", "while true; do echo $(date) >> /mnt/smb/example.file; sleep 5; done"]
          volumeMounts:
            - name: persistent-storage
              mountPath: /mnt/smb
  volumeClaimTemplates:
    - metadata:
        name: persistent-storage
      spec:
        storageClassName: smb
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

Replace `storageClassName: smb` with the StorageClass that matches your `SmbStorage.json` entry (for example `smb-posix` for a POSIX-enabled share).

### POSIX-enabled example

POSIX extensions are configured per storage entry in `SmbStorage.json`, not in the consuming workload. A POSIX-enabled volume is consumed exactly like any other SMB volume - the only difference is the StorageClass it references.

POSIX extensions only apply to a Linux-hosted (Samba) share, so enable the addon with the Linux host type:

```
k2s addons enable storage smb -t linux
```

First, configure a POSIX-enabled entry in `SmbStorage.json` (this creates the `smb-posix` StorageClass on the next enable). Disable the addon before editing `SmbStorage.json`, then re-enable it - the enable/disable flow rewrites this file from the persisted setup config, so edits made while the addon is enabled are overwritten:

```json
[
    {
        "winMountPath": "C:\\k8s-smb-posix",
        "linuxMountPath": "/mnt/k8s-smb-posix",
        "linuxShareName": "linux-smb-posix-share",
        "winShareName": "win-smb-posix-share",
        "storageClassName": "smb-posix",
        "smbDialect": "3.1.1",
        "enablePosixExtensions": true,
        "useServerInode": true
    }
]
```

Then deploy a workload that references the `smb-posix` StorageClass. The example below exercises POSIX semantics by creating a symbolic link on the share (which only succeeds when POSIX extensions are active):

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: smb-posix-example
  namespace: default
spec:
  serviceName: smb-posix-example
  replicas: 1
  selector:
    matchLabels:
      app: smb-posix-example
  template:
    metadata:
      labels:
        app: smb-posix-example
    spec:
      nodeSelector:
        "kubernetes.io/os": linux
      containers:
        - name: smb-posix-example
          image: docker.io/curlimages/curl:8.5.0
          command:
            - "/bin/sh"
            - "-c"
            - set -eu; echo posix-marker > /mnt/smb/marker.txt; ln -sf /mnt/smb/marker.txt /mnt/smb/marker.link; while true; do sleep 30; done
          volumeMounts:
            - name: persistent-storage
              mountPath: /mnt/smb
  volumeClaimTemplates:
    - metadata:
        name: persistent-storage
      spec:
        storageClassName: smb-posix
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

> POSIX extensions only apply to shares hosted by the Linux Samba server. Schedule POSIX workloads onto Linux nodes (as shown via `nodeSelector`).

Additional ready-to-run manifests are available under [k2s/test/e2e/addons/storage/smb/workloads](../../../k2s/test/e2e/addons/storage/smb/workloads/).

## Known Limitations

### Enabling the addon fails on hosts that deny network logon for local accounts

In the default `windows` host type, the Linux control-plane VM mounts the Windows host SMB share over CIFS as the local `remotesmb` account. This requires a network logon for that local account on the Windows host.

On machines hardened by domain/OU group policy, the local-account SID `S-1-5-113` ("Local account") is added to the `SeDenyNetworkLogonRight` user-rights assignment ("Deny access to this computer from the network"). That policy blocks the `remotesmb` network logon, so the CIFS mount cannot complete and `k2s addons enable storage smb` fails with a mount error such as `mount(2) system call failed`.

This is a host security-policy restriction that K2s cannot change. It is recorded here as a known limitation rather than worked around. A machine administrator can address it in one of two ways:

- Adjust the host policy so the `remotesmb` local account is allowed a network logon. The helper script [SetNetworkSharePolicy.ps1](SetNetworkSharePolicy.ps1) documents the relevant `SeDenyNetworkLogonRight` handling.
- Or enable the addon with the Linux host type instead, which serves the share from the Linux Samba server and avoids the Windows network-logon requirement:

```
k2s addons enable storage smb -t linux
```

The enable failure is logged in full to the addon log file; the console shows a single concise note pointing here.
