<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# dicom

## Introduction

The `dicom` addon provides a full fledged DICOM server, which offers besides classic DICOM DIMSE services also DICOM Web APis through REST. 

It is designed to store, manage, and share medical images and related data. It provides a REST API for easy integration with other systems and supports various DICOM operations such as querying, retrieving, and storing medical images. 

In addition this addon also offers a very simple web app, which offers the possibility to interact with the dicom server. 

## Getting started

The dicom addon can be enabled using the k2s CLI by running the following command:

```
k2s addons enable dicom
```
### Storage Configuration with SMB

The DICOM addon now supports integration with the SMB storage addon. You can specify the storage directory in the Linux VM using the `--storagedir` parameter. The DICOM server's storage configuration (`orthanc.json`) will be automatically synchronized with the SMB storage addon settings, ensuring all DICOM data and database files are stored via the storage addon.

To enable the DICOM addon with SMB storage, use:

```
k2s addons enable dicom --storage smb --storagedir /mnt/k8s-smb-share
```
- If the SMB storage addon is not enabled, it will be enabled automatically.
- If the SMB storage addon is already enabled, the specified `--storagedir` will be checked for presence in `SmbStorage.json`. If found, it will be used by the DICOM addon.
- Disabling the DICOM addon will not remove the shared storage content; the SMB storage addon manages the share lifecycle.


### Integration with the ingress addon

The dicom addon can be integrated with the ingress nginx, ingress nginx-gw, or ingress traefik addon so that it can be exposed outside the cluster.

For example, the dicom addon can be enabled along with traefik addon using the following command:

```
k2s addons enable dicom --ingress traefik
```

Or with nginx-gw (NGINX Gateway Fabric) addon:

```
k2s addons enable dicom --ingress nginx-gw
```

_Note:_ The above commands shall enable the respective ingress addon if it is not enabled.

The ingress addon can also be enabled before or after enabling the dicom addon, the effect would be the same !

## Accessing the dicom services

Per default we use port 4242 for the DIMSE classic communication and port 8042 for the DICOM web communication.

## Accessing the dicom UI

The dicom UI can be accessed via the following methods.

### Access directly to pod


### Access using port-forwarding

To access dicom server UI via port-forwarding, the following command can be executed:

```
kubectl -n dicom port-forward svc/dicom 8042:8042
```

In this case, the dicom UI can be accessed at the following URL: <http://localhost:8042/ui/app/>

### Access using ingress

To access the dicom app UI via ingress, the ingress nginx, ingress nginx-gw, or ingress traefik addon has to be enabled.
Once the addons are enabled, then the dicom UI can be accessed at the following URL: <https://k2s.cluster.local/dicom/ui/app/>

DICOM Web APIS are available under the URL: <https://k2s.cluster.local/dicom/dicomweb>
Example call which returns all studies:
```
curl -sS --insecure https://k2s.cluster.local/dicom/dicomweb/studies
```

## Disable dicom

The dicom addon can be disabled using the k2s CLI by running the following command:

```
k2s addons disable dicom
```

_Note:_ The above command will only disable dicom addon. If other addons were enabled while enabling the dicom addon, they will not be disabled.

## License Info

By activating this dicom addon you will download at runtime some Orthanc components. Even if all is open source, please consider the following license terms for Orthanc components: [Orthanc License Terms](https://orthanc.uclouvain.be/book/faq/licensing.html) 

## Backup and restore

Backup/restore is **config-only** and **scoped to the `dicom` namespace**.

### What gets backed up

- Orthanc configuration `ConfigMap/json-configmap` (generated from `orthanc.json`)
- Orthanc configuration `ConfigMap/json-configmap` (contains the effective Orthanc configuration; initially sourced from `orthanc.json`)
- Optional dashboard exposure resources in namespace `dicom` (if present):
	- `Ingress/dicom-nginx-cluster-local`
	- `Ingress/dicom-traefik-cluster-local`
	- `Ingress/dicom-traefik-cluster-local-correct1`
	- `Ingress/dicom-traefik-cluster-local-correct2`
	- `Middleware/strip-prefix`, `Middleware/cors-header`
	- `Middleware/oauth2-proxy-auth` (Traefik secure mode)

### What does not get backed up

- DICOM study data stored on PVCs (Orthanc and Postgres data)
- Controller manifests/CRDs (they are re-installed during restore via `k2s addons enable dicom`)
- Resources outside of the `dicom` namespace

### Commands

```console
k2s addons backup dicom
k2s addons restore dicom -f <path-to-backup-zip>
```
 
## Further Reading

Internally used open source component:
- [Orthanc](https://www.orthanc-server.com/)
