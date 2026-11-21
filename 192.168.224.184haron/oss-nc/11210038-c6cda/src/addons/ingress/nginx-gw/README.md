<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# ingress nginx-gw

## Introduction

The `ingress nginx-gw` addon provides an implementation of the Kubernetes Gateway API
using [NGINX Gateway Fabric](https://github.com/nginxinc/nginx-gateway-fabric).

### What is NGINX Gateway Fabric?

NGINX Gateway Fabric is a modern, production-ready implementation of the Kubernetes Gateway API
that leverages NGINX as its data plane. It is developed and maintained by NGINX, Inc. (part of F5).

**Key Features:**
- **Gateway API Conformance**: Fully implements the Gateway API specification, providing a
  standardized approach to traffic management
- **NGINX Data Plane**: Uses the proven NGINX reverse proxy and load balancer as its
  underlying engine for high performance and reliability
- **Dynamic Configuration**: Automatically configures NGINX based on Gateway API resources
  (Gateway, HTTPRoute, etc.) without requiring manual NGINX configuration
- **Multi-tenancy**: Supports multiple teams sharing the same gateway infrastructure
  with namespace-based isolation
- **Production-Grade**: Built for enterprise use with strong stability, security,
  and performance characteristics

### How it Works

NGINX Gateway Fabric acts as a reverse proxy and load balancer at the edge of your Kubernetes cluster:

1. **Traffic Ingress**: Accepts incoming traffic from outside the cluster via an external IP
2. **Route Matching**: Evaluates incoming requests against configured HTTPRoute rules
   (hostname, path, headers, etc.)
3. **Load Balancing**: Distributes traffic to appropriate backend pods using NGINX's
   load balancing capabilities
4. **TLS Termination**: Handles SSL/TLS encryption at the gateway level, offloading
   this from backend services

The gateway controller watches Gateway API resources in Kubernetes and dynamically
generates NGINX configuration, eliminating manual configuration management.

## Getting started

The ingress nginx-gw addon can be enabled using the `k2s` CLI
by running the following command:

```cmd
k2s addons enable ingress nginx-gw
```

## Backup and restore

The `ingress nginx-gw` addon requires an explicit TLS Secret (`k2s-cluster-local-tls`) for the Gateway HTTPS listener.
If that Secret is missing after restore, TLS will fail closed and HTTPS will not work.

`k2s addons backup ingress nginx-gw` performs a **config-only** backup.

- It backs up the Gateway API resources needed for the shared cluster Gateway setup.
- It does **not** back up certificates or private keys.

`k2s addons restore ingress nginx-gw` runs the addon enable flow first and then reapplies the backed up configuration.
Certificates are (re)created by cert-manager during the enable phase.

```console
k2s addons backup ingress nginx-gw
```

```console
k2s addons restore ingress nginx-gw -f <path-to-backup-zip>
```

During restore, the CA root certificate is imported into the Windows Trusted Root store by the cert-manager enable flow.

## Creating Gateway API routes

NGINX Gateway Fabric uses the standard Kubernetes Gateway API resources to define
traffic routing rules:

- **Gateway**: Defines the load balancer/proxy infrastructure (listeners, ports, protocols)
- **HTTPRoute**: Defines HTTP traffic routing rules (hostname, path matching, backends)
- **ReferenceGrant**: Allows routes to reference resources in other namespaces (if needed)

### Gateway Resources

This addon creates a central Gateway resource that handles both HTTP and HTTPS traffic:

**Gateway Configuration:**
- **Name**: `nginx-cluster-local` (in `nginx-gw` namespace)
- **HTTP Listener**: Port 80 - no certificate required
- **HTTPS Listener**: Port 443 - uses `k2s-cluster-local-tls` secret

The HTTPS listener uses a **CA-signed certificate** that is automatically created during
addon installation via cert-manager. The certificate is signed by the `k2s-ca-issuer`
ClusterIssuer, and the CA root certificate is imported into the Windows trusted root store,
providing trusted HTTPS access without browser warnings.

**Certificate Handling:**
- cert-manager is automatically installed and configured by the nginx-gw addon
- A Certificate resource is created to provision the `k2s-cluster-local-tls` secret
- The certificate is signed by `k2s-ca-issuer` (global CA ClusterIssuer)
- CA root certificate is trusted by Windows, eliminating browser certificate warnings

For more details on Gateway API resources and routing patterns, see the
[Gateway API documentation](https://gateway-api.sigs.k8s.io/).

## Access of the gateway

The gateway is exposed via a LoadBalancer service with an external IP configured through
the NginxProxy resource. The external IP is dynamically set during installation based on
the K2s control plane IP (typically `172.19.1.100`).

**How External IP is Configured:**
1. Enable.ps1 retrieves the control plane IP
2. NginxProxy resource template is populated with this IP
3. When the Gateway is created, it triggers the data plane deployment
4. The data plane service is created with the external IP from NginxProxy configuration

**Access Points:**
- HTTPS: `https://172.19.1.100:443` or `https://k2s.cluster.local`

_Note:_ Only one ingress or gateway controller can be enabled at a time in K2s
(nginx ingress, traefik ingress, or nginx-gw) since they all use the same external IP and ports.

### TLS/HTTPS Configuration

The addon creates a Gateway with both HTTP and HTTPS listeners by default.

**Frontend TLS (Browser → Gateway):**
- **CA-signed certificate** is automatically created during installation via cert-manager
- Certificate CN: `k2s.cluster.local`
- Secret name: `k2s-cluster-local-tls` (in `nginx-gw` namespace)
- Signed by: `k2s-ca-issuer` ClusterIssuer
- Browser access: `https://k2s.cluster.local` (trusted certificate, no warnings)

**Backend TLS (Gateway → Services):**
When HTTPRoutes reference HTTPS backend services, a **BackendTLSPolicy** must be configured
to enable secure backend connections. This is handled automatically by addons that require it.

Example: The dashboard addon configures BackendTLSPolicy to connect to kong-proxy:443:
- Extracts kong's certificate during installation
- Creates `kong-ca-cert` ConfigMap with the CA certificate
- BackendTLSPolicy references this ConfigMap for certificate validation

**Certificate Management:**

The ingress nginx-gw addon automatically installs and configures cert-manager for TLS certificate management:

- **Frontend certificates**: The Gateway uses `k2s-cluster-local-tls` secret, managed by cert-manager
  - Certificate is signed by `k2s-ca-issuer` ClusterIssuer
  - CA root certificate is imported into Windows trusted root store
  - Automatic renewal handled by cert-manager (default: 30 days before expiry)

- **Backend certificates**: When HTTPRoutes reference HTTPS backend services, a **BackendTLSPolicy** must be configured to enable secure backend connections. This is handled automatically by addons that require it.

### Shared Hostname Pattern

Web applications can use the shared hostname `k2s.cluster.local` in their HTTPRoute rules
and do not need to manage frontend TLS certificates themselves, since TLS termination is handled
centrally by the gateway. Multiple HTTPRoutes using the same hostname will be processed
by the gateway controller - the key requirement is to have **distinct path matching rules**
to avoid conflicts.

**Important:** If your backend service uses HTTPS (like kong-proxy, some API servers), you must
configure a BackendTLSPolicy to enable secure communication between the gateway and backend.
See the dashboard addon for a complete example of BackendTLSPolicy configuration.

All K2s addons with a web UI use this pattern and are configured to be reachable
under path-based routing: `k2s.cluster.local/<nameOfAddon>/`

Making web applications available under different paths can be challenging and may
require different approaches depending on the application. Each K2s addon demonstrates
a different technique for achieving path-based routing. The HTTPRoute and BackendTLSPolicy
resource definitions are worth analyzing to understand these mechanisms:

- **Kubernetes Dashboard**:
  - HTTPRoute: [dashboard-nginx-gw.yaml](../../dashboard/manifests/ingress-nginx-gw/dashboard-nginx-gw.yaml)
  - BackendTLSPolicy: [dashboard-backend-tls.yaml](../../dashboard/manifests/ingress-nginx-gw/dashboard-backend-tls.yaml)
  - Shows: Path rewrite, header modification, HTTPS backend with certificate validation

These examples show various routing patterns including path rewrites, header modifications,
backend service configurations, and secure backend communication with BackendTLSPolicy.

## Certificate Management with cert-manager

The `ingress nginx-gw` addon automatically installs and configures [cert-manager](https://cert-manager.io/), a powerful add-on for Kubernetes that automates the management, issuance, and renewal of TLS certificates.

### What gets installed

- **cert-manager controllers**: Services for certificate provisioning and renewing
- **k2s-ca-issuer**: A global `ClusterIssuer` of type CA (Certification Authority) used to sign certificates. See: [CA Issuer](https://cert-manager.io/docs/configuration/ca/)
- **cmctl.exe CLI**: Command-line interface tool installed in the `bin` path of your K2s installation directory
- **Trusted CA Certificate**: The public certificate of the CA Issuer is imported into the trusted authorities of your Windows host
- **Gateway certificate**: A Certificate resource (`k2s-cluster-local-tls`) is automatically created for the Gateway's HTTPS listener

### How it works with Gateway API

Unlike traditional Ingress controllers (nginx/traefik) that support cert-manager annotations, the Gateway API follows a more explicit, declarative approach:

**Traditional Ingress pattern (annotations):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    cert-manager.io/cluster-issuer: k2s-ca-issuer  # Auto-creates certificate
```

**Gateway API pattern (explicit references):**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
spec:
  listeners:
  - name: https
    protocol: HTTPS
    tls:
      certificateRefs:
      - name: k2s-cluster-local-tls  # Secret must exist
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: k2s-cluster-local-tls
spec:
  secretName: k2s-cluster-local-tls
  issuerRef:
    name: k2s-ca-issuer
    kind: ClusterIssuer
```

The Gateway API design is **security-first and fails closed**: certificates must be explicitly created before referencing them in Gateway resources. This addon handles this automatically by creating the Certificate resource during installation.

### Creating additional certificates

To secure additional hostnames or services, create Certificate resources:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app-tls
  namespace: my-namespace
spec:
  secretName: my-app-tls-secret
  duration: 8760h # 1 year
  renewBefore: 720h # 30 days before expiry
  dnsNames:
    - my-app.cluster.local
  issuerRef:
    name: k2s-ca-issuer
    kind: ClusterIssuer
```

Then reference this secret in your Gateway or HTTPRoute:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
spec:
  listeners:
  - name: https
    tls:
      certificateRefs:
      - name: my-app-tls-secret
```

### Inspecting certificates

You can use the command line interface `cmctl.exe` to interact with cert-manager:

```cmd
# Check cert-manager API status
cmctl.exe check api

# View certificate details
kubectl get certificate -n nginx-gw
kubectl describe certificate k2s-cluster-local-tls -n nginx-gw

# Renew a specific certificate
cmctl.exe renew k2s-cluster-local-tls -n nginx-gw

# Renew all certificates
cmctl.exe renew --all --all-namespaces
```

If you enable the `dashboard` addon, you can inspect the server certificate by visiting the dashboard URL in your browser and clicking on the lock icon: <https://k2s.cluster.local>.

### Browser security considerations

Browsers keep track of several security-related properties of web sites. If you encounter weaker security settings than previously, the browser may assume it's an attack.

You can **reset HSTS** of your site stored by your browser by navigating to:

```
chrome://net-internals/#hsts
```

and deleting the settings for `k2s.cluster.local`.

## Further Reading

- [Kubernetes Gateway API Official Documentation](https://gateway-api.sigs.k8s.io/) -
  Comprehensive guide to the Gateway API specification, concepts, and best practices
- [NGINX Gateway Fabric Documentation](https://docs.nginx.com/nginx-gateway-fabric/) -
  Official documentation for NGINX Gateway Fabric, including configuration guides and examples
- [NGINX Gateway Fabric GitHub Repository](https://github.com/nginxinc/nginx-gateway-fabric) -
  Source code, issue tracking, and community contributions
- [Gateway API Guides](https://gateway-api.sigs.k8s.io/guides/) -
  Practical guides for common routing scenarios (HTTP routing, traffic splitting, etc.)

