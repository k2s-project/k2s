<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# ingress nginx

## Introduction

The `ingress nginx` addon provides an implementation of the Ingress Controller
with [ingressClassName: nginx](https://github.com/kubernetes/ingress-nginx).
An Ingress controller acts as a reverse proxy and load balancer.
It implements a Kubernetes Ingress.
The ingress controller adds a layer of abstraction to traffic routing,
accepting traffic from outside the Kubernetes platform and load balancing
it to pods running inside the platform.

## Getting started

The ingress nginx addon can be enabled using the `k2s` CLI
by running the following command:

```cmd
k2s addons enable ingress nginx
```

## Backup and restore

Create a backup zip (defaults to `C:\Temp\k2s\Addons` on Windows):
```cmd
k2s addons backup ingress nginx
```

Restore from a backup zip:
```cmd
k2s addons restore ingress nginx -f C:\Temp\k2s\Addons\ingress_nginx_backup_YYYYMMDD_HHMMSS.zip
```

The backup includes:
- The `ingress-nginx-controller` ConfigMap from namespace `ingress-nginx`.
- The optional Ingress `nginx-cluster-local` from namespace `ingress-nginx` (if present).
## Creating ingress routes

The Ingress NGINX Controller supports standard Kubernetes networking
definitions in order to reach cluster workloads.
How to create an ingress route can be found
[here](https://kubernetes.io/docs/concepts/services-networking/ingress/).

## Access of the ingress controller

The ingress controller is configured so that it can be reached from outside
the cluster via the external IP Address `172.19.1.100`.

_Note:_ It is only possible to enable one ingress controller or gateway
controller (ingress nginx, ingress traefik or gateway-api) in the K2s cluster at the
same time since they use the same ports.

This Addon prepares one central TLS termination, matching the hostname
`k2s.cluster.local`, and using as certificate a secret named
`k2s-cluster-local-tls` which is configured to be created and updated by
`cert-manager` - it will be installed along with ingress addon.
See also [Security Addon](../../security/README.md).

Web applications can use this host name in their ingress rules
and do not need to care about TLS anymore, since it is handled by this
central ingress. All rules using the same host will me merged by the ingress
controller - so the only important thing is to have distinct Prefix rules.

All Addons with a Web UI use this feature,
and are configured to be reachable under two endpoints:

- k2s-_nameOfAddOn_.cluster.local/
- k2s.cluster.local/_nameOfAddOn_/

Making web applications available under different paths is not trivial,
and might even not be possible. In fact, it turns out that each of the Addons
provided by K2s uses another mechanism to make this possible.
The Ingress Resource definitions are worth being analyzed,
to understand the different mechanisms:

- Kubernetes Dashboard:
  [NGINX Ingresses](../../dashboard/manifests/ingress-nginx/dashboard-nginx-ingress.yaml).
- Logging:
  [NGINX Ingress](../../logging/manifests/opensearch-dashboards/ingress.yaml).
- Monitoring:
  [NGINX Ingress](../../monitoring/manifests/grafana/ingress.yaml).

## Certificate Management with cert-manager

When you enable the `ingress nginx` addon, it automatically installs and configures [cert-manager](https://cert-manager.io/), a powerful add-on for Kubernetes that automates the management, issuance, and renewal of TLS certificates. This brings the crucial task of securing communication with Transport Layer Security (TLS) directly into the Kubernetes ecosystem, eliminating the need for manual certificate handling and reducing the risk of outages due to expired certificates.

### What gets installed

The ingress nginx addon configures:

- **cert-manager controllers**: Services for certificate provisioning and renewing, based on annotations. `cert-manager` observes these annotations and automates obtaining and renewing certificates.
- **k2s-ca-issuer**: A global `ClusterIssuer` of type CA (Certification Authority) that can be used in annotations to obtain and renew certificates. See: [CA Issuer](https://cert-manager.io/docs/configuration/ca/)
- **cmctl.exe CLI**: Command-line interface tool installed in the `bin` path of your K2s installation directory for interacting with cert-manager.
- **Trusted CA Certificate**: The public certificate of the CA Issuer is imported into the trusted authorities of your Windows host.

### Securing your application with TLS

To secure the ingress to your Kubernetes application, add the following annotations to your Ingress resource:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    ...
    cert-manager.io/cluster-issuer: k2s-ca-issuer
    cert-manager.io/common-name: your-ingress-host.domain
...
spec:
...
  tls:
  - hosts:
    - your-ingress-host.domain
    secretName: your-secret-name
```

cert-manager will observe these annotations, create a certificate, and store it in the secret named 'your-secret-name' so that the ingress controller uses it.

### Inspecting certificates

If you also enable the `dashboard` addon, you can inspect the server certificate by visiting the dashboard URL in your browser and clicking on the lock icon: <https://k2s.cluster.local>.

You can also use the command line interface `cmctl.exe` to interact with cert-manager:

```cmd
# Check cert-manager API status
cmctl.exe check api

# Renew a specific certificate
cmctl.exe renew k2s-cluster-local-tls -n ingress-nginx

# Renew all certificates
cmctl.exe renew --all --all-namespaces
```

### Browser security considerations

Browsers keep track of several security-related properties of web sites. If you encounter weaker security settings than previously, the browser may assume it's an attack.

You can **reset HSTS** of your site stored by your browser by navigating to:

```
chrome://net-internals/#hsts
```

and deleting the settings for `k2s.cluster.local`.

## Further Reading

- [Services, Load Balancing, and Networking](https://kubernetes.io/docs/concepts/services-networking/)
- [NGINX Ingress Controller](https://docs.nginx.com/nginx-ingress-controller/)
