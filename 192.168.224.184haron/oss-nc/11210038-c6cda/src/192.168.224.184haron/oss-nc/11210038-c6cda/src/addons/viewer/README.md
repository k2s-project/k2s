<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# viewer

## Introduction

The `viewer` addon provides a local Dicom images viewer based in the [OHIF Viewer v3.12.0](https://github.com/OHIF/Viewers/releases/tag/v3.12.0) running inside k2s.

## Getting started

The viewer addon can be enabled using the k2s CLI by running the following command:

```
k2s addons enable viewer
```

### Integration with ingress nginx and ingress traefik addons

The viewer addon can be integrated with the ingress nginx, ingress nginx-gw, or ingress traefik addon so that it can be exposed outside the cluster.

By default `k2s addons enable viewer` enables ingress nginx addon in a first step.

The viewer addon can also be enabled along with ingress traefik addon using the following command:

```
k2s addons enable viewer --ingress traefik
```

Or with nginx-gw addon using the following command:

```
k2s addons enable viewer --ingress nginx-gw
```

_Note:_ The above commands shall enable the respective ingress addon if it is not enabled.

## Access to viewer

The viewer can be accessed from an browser under the following url:
https://k2s.cluster.local/viewer/

## Disable viewer

The viewer addon can be disabled using the k2s CLI by running the following command:

```
k2s addons disable viewer
```

_Note:_ The above command will only disable viewer addon. If other addons were enabled while enabling the viewer addon, they will not be disabled.

## Backup and restore

The viewer addon is mostly stateless. Backup/restore captures the Kubernetes objects that commonly change at runtime:

- `ConfigMap/config-json` in namespace `viewer` (viewer configuration)
- `Service/viewerwebapp` in namespace `viewer` (includes NodePort)
- Ingress resources in namespace `viewer` depending on which ingress controller is installed:
	- nginx: `Ingress/viewer-nginx-cluster-local`
	- traefik: `Ingress/viewer-traefik-cluster-local` (and optional `Middleware/oauth2-proxy-auth` if Traefik CRDs are installed)

```console
k2s addons backup viewer
```

```console
k2s addons restore viewer -f <path-to-backup-zip>
```

## License Info

By activating this viewer addon you will download at runtime some OHIF components. Even if all is open source, please consider the following license terms for OHIF components: [OHIF License Terms](https://github.com/OHIF/Viewers/blob/master/LICENSE) 

## Further Reading

Internally used open source component:
- [OHIF](https://ohif.org/)
