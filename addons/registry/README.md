<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# registry

## Introduction

The `registry` addon provides a local [Zot Registry](https://github.com/project-zot/zot) running inside k2s which makes it easy to store container images locally and pull them during deployment.

## Getting started

The registry addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable registry
```

### Integration with ingress nginx and ingress traefik addons

The registry addon can be integrated with the ingress nginx, ingress nginx-gw, or ingress traefik addon so that it can be exposed outside the cluster.

By default `k2s addons enable registry` enables ingress nginx addon in a first step.

The registry addon can also be enabled along with ingress traefik addon using the following command:
```
k2s addons enable registry --ingress traefik
```

Or with nginx-gw addon using the following command:
```
k2s addons enable registry --ingress nginx-gw
```
_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

### Placement options

Use `--snode` (`-s`) to select the node for the registry's persistent volume storage (defaults to the control plane) and `--infra-node-selector` to constrain the registry infrastructure to nodes matching a label selector:
```
k2s addons enable registry --snode worker1
k2s addons enable registry --infra-node-selector kubernetes.io/hostname=kubemaster
```

## Access to registry

### Ingress

In order to push container images to the local registry during `k2s image build -p` by using an ingress tagging must look like the following:

```
k2s.registry.local/<imagename>:<imagetag>
```

_Note:_ If a proxy server is configured in the Windows Proxy settings, please add the host **k2s-registry.local** as a proxy override.

### NodePort

In order to push container images to the local registry during `k2s image build -p` with node port configuration tagging must look like the following:

```
k2s.registry.local:<nodeport>/<imagename>:<imagetag>
```

## Disable registry

The registry addon can be disabled using the k2s CLI by running the following command:
```
k2s addons disable registry
```

To also delete the local image storage, use `--delete-images` (`-d`):
```
k2s addons disable registry --delete-images
```

_Note:_ The above command will only disable registry addon. If other addons were enabled while enabling the registry addon, they will not be disabled.

## Backup and restore

The registry addon supports backup/restore via the k2s CLI:

```
k2s addons backup registry
k2s addons restore registry -f <backup.zip>
```

Backup creates a tar.gz of the registry data directory on the control plane (`/registry/repository`) and stores it in the backup zip. Restore overwrites the existing registry data on the control plane and restarts the registry StatefulSet.

## Further Reading
- [Zot Registry](https://github.com/project-zot/zot)
