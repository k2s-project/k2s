<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# *K2s* Addons
*K2s* provides a rich set of addons that offer optional, pre-configured 3rd-party open-source OTS in a plugin-like manner for rapid prototyping, testing and OTS evaluation. They can also be used in product scenarios, check yourself if they fit well to your needs.

<span style="color:orange;font-size:medium">**⚠** </span> The 3rd-party software versions and configurations provided by these addons are partially taken from other open source projects. Please check yourself if these configurations are appropriate.

## Addons List
The following addons will be deployed with **K2s**:

<!-- GENERATED! Use the script Update-Readme.ps1 to update the following section -->
<!-- addons-list-start -->
|Addon|Description|
|---|---|
| [autoscaling](./autoscaling/README.md) | Horizontally scale workloads based on external events or triggers with KEDA (Kubernetes Event-Driven Autoscaling) | 
| [dashboard](./dashboard/README.md) | Headlamp - Kubernetes Dashboard (kubernetes-sigs) | 
| [dicom](./dicom/README.md) | DICOM client/server for medical imaging data running in Kubernetes | 
| [gpu-node](./gpu-node/README.md) | Configure the control plane node to utilize GPUs for direct GPU access and high-performance computing tasks. | 
| [ingress nginx](./ingress/nginx/README.md) | Ingress Controller for external access that uses nginx as a reverse proxy | 
| [ingress traefik](./ingress/traefik/README.md) | Ingress Controller for external access that uses traefik as a reverse proxy | 
| [ingress nginx-gw](./ingress/nginx-gw/README.md) | Ingress Controller for external access that uses NGINX Gateway Fabric | 
| [kserve](./kserve/README.md) | Standard-mode model serving with KServe and optional CPU or GPU LLM examples |
| [kubevirt](./kubevirt/README.md) | Manage VM workloads with k2s | 
| [logging](./logging/README.md) | Dashboard for Kubernetes container logs | 
| [metrics](./metrics/README.md) | Kubernetes metrics server for API Access to service metrics | 
| [monitoring](./monitoring/README.md) | Dashboard for cluster resource monitoring and logging | 
| [registry](./registry/README.md) | Private image registry running in the Kubernetes cluster exposed on k2s.registry.local | 
| [rollout argocd](./rollout/argocd/README.md) | Automating the deployment/updating of applications using ArgoCD | 
| [rollout fluxcd](./rollout/fluxcd/README.md) | Automating the deployment/updating of applications using FluxCD | 
| [security](./security/README.md) | Enables secure communication into and inside the cluster | 
| [storage smb](./storage/smb/README.md) | StorageClass provisioning based on SMB share between K8s nodes (Windows/Linux) | 
| [viewer](./viewer/README.md) | Private clinical image viewer running in the Kubernetes cluster | 
<!-- addons-list-end -->

## Command line options

On command line you can get all the addons available in your setup:
```
k2s addons ls                                         - lists all the available addons
```
Enabling one addon (in this example the **ingress** addon with **nginx** implementation):
```
k2s addons enable ingress nginx                       - enables the ingress nginx ingress controller
```
Disabling the same addon:
```
k2s addons disable ingress nginx                      - disables the ingress nginx ingress controller
```
Exporting addons for the offline usage afterwards:
```
k2s addons export -d d:\                              - exports all addons to a specific location 
k2s addons export "ingress nginx" -d d:\              - exports implementation 'nginx' of addon 'ingress' to a specific location 
k2s addons export ingress -d d:\                      - exports all implementations of addon 'ingress' to a specific location 
```
Importing all addons from an previously exported file:
```
k2s addons import -f d:\addons.oci.tar                    - imports all addons from a specific archive
k2s addons import "ingress nginx" -f d:\addons.oci.tar    - imports implementation 'nginx' of addon 'ingress' from a specific archive
k2s addons import ingress -f d:\addons.oci.tar            - imports all implementations of addon 'ingress' from a specific archive
```
Importing without the images of a functionality that will not be enabled (repeatable, optionally scoped;
an image is only skipped when no selected addon still requires it, the archive itself stays unchanged):
```
k2s addons import security -f d:\addons.oci.tar --omit omitKeycloak                          - skips the Keycloak images
k2s addons import security -f d:\addons.oci.tar --omit omitKeycloak --omit omitOAuth2Proxy   - skips the Keycloak and OAuth2-Proxy images
k2s addons import -f d:\addons.oci.tar --omit ingress/nginx:omitCertMgr                      - scopes the omit option to one implementation
```
Backing up addon data:
```
k2s addons backup registry -f d:\registry-backup.zip           - creates a backup zip for addon 'registry'
k2s addons backup "ingress nginx" -f d:\ingress-nginx.zip      - creates a backup zip for implementation 'nginx' of addon 'ingress'
k2s addons backup "ingress nginx"                              - creates a backup in the default backup folder
```
Restoring addon data from backup:
```
k2s addons restore registry -f d:\registry-backup.zip          - restores addon 'registry' from backup zip
k2s addons restore "ingress nginx" -f d:\ingress-nginx.zip     - restores implementation 'nginx' of addon 'ingress' from backup zip
k2s addons restore "ingress nginx"                             - restores from latest matching backup in default backup folder
```
Showing status of single addons:
```
k2s addons status ingress nginx                       - shows the status of the implementation 'nginx' of addon 'ingress'
```

## Contributing
To add a new addon to this repo, the following steps are necessary:
1. create a **new addon folder** next to the [existing addon folders](./)
2. create a **addon.manifest.yaml** inside that folder containing at least the mandatory addon metadata
   - this metadata must comply with the [addon.manifest.schema.json](addon.manifest.schema.json) file
   - this metadata gets validated against the [addon.manifest.schema.json](addon.manifest.schema.json) file when addon-related commands are executed via *K2s.exe*, e.g. `k2s addons ls` or even `k2s addons -h`
   - refer to existing addon manifests for examples, e.g. [dashboard addon manifest](./dashboard/addon.manifest.yaml) or [ingress addon manifest](./ingress/addon.manifest.yaml)
   - the CLI flags and *PowerShell* parameters can differ in names (hence the parameter mapping config in the manifest file), but not in values, meaning e.g. if the CLI flag value for *SMB* host type is *windows*, it must be also *windows* for the *PowerShell* parameter value
   - for additional documentation on addons metadata refer to the [addon.manifest.schema.json](addon.manifest.schema.json) file
3. create mandatory ***PowerShell* scripts** (see existing addons) -> support import/export/upgrade, etc.
4. create mandatory **README.md** file
5. **run [Update-Readme.ps1](./Update-Readme.ps1)** to update [this list](#addons-list)
6. optional: add addon-specific code/config files
