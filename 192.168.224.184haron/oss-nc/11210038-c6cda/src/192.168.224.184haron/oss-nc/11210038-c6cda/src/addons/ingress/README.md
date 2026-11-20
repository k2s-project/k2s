<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# ingress

## Introduction

The `ingress` addon provides an Ingress Controller for external access to services running in the K2s cluster. It offers three implementations:

- **[nginx](./nginx/README.md)** — Ingress Controller using [NGINX](https://github.com/kubernetes/ingress-nginx) as a reverse proxy
- **[traefik](./traefik/README.md)** — Ingress Controller using [Traefik](https://github.com/traefik/traefik) as a reverse proxy
- **[nginx-gw](./nginx-gw/README.md)** — Gateway API controller using [NGINX Gateway Fabric](https://github.com/nginxinc/nginx-gateway-fabric)

## Getting started

Enable an ingress implementation using the k2s CLI:

```console
k2s addons enable ingress nginx
```

```console
k2s addons enable ingress traefik
```

```console
k2s addons enable ingress nginx-gw
```

## Disable ingress

```console
k2s addons disable ingress nginx
```
