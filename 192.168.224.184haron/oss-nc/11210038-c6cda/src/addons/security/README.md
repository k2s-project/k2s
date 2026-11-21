<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# security addon

Purpose: Enables secure communication into / out of the cluster (basic) and inside the cluster (enhanced).

Our strategy is to achieve **security through infrastructure**, effectively offloading fundamental security concerns like mutual TLS encryption, authentication, and authorization from the application layer. Instead of requiring every development team to build and maintain these complex security features within their own code, we leverage platform-level tools like service meshes (e.g., Linkerd), identity providers (e.g., Keycloak), and certificate managers (e.g., cert-manager). This allows application developers to focus solely on core business logic, accelerates development cycles, and ensures a consistent, standardized security posture enforced by the platform, not reinvented in every application (container or non-container).

![Upstream - downstream](doc/downstream-upstream.drawio.png)

## Getting Started

The `security` addon can be enabled using the `k2s` CLI:

```cmd
k2s addons enable security
```

For enabling basic or enhanced security please use the parameter:

```cmd
 -t, --type string (basic or enhanced)
```

K2s also has many addons like **dashboard**, **logging**, **monitoring**, and ingress options (**nginx**, **traefik**, **nginx-gw**) which are bringing in web apps and external access capabilities.
By enabling the security addon they will be automatically also secured.

## Disable security

The `security` addon can be disabled using the k2s CLI:

```cmd
k2s addons disable security
```

After disabled security also please reset the policies (navigate to [chrome://net-internals/#hsts](chrome://net-internals/#hsts)) for the following domain:

```cmd
k2s.cluster.local
```

## Optional Components

By default, the security addon installs all components listed below. You can now selectively omit certain open source frameworks during installation using flags:

- `-OmitHydra`: Omits the setup of hydra and the local login implementation (useful if no local user management is needed).
- `-OmitKeycloak`: Omits the setup of keycloak and its database (useful if you want oauth2-proxy to reference an external OAuth2 provider).
- `-OmitOAuth2Proxy`: Omits the OAuth2 proxy deployment (useful if you want to use an external authentication proxy or no authentication at all).
- `-OmitPolicyEnf`: Omits the Kyverno policy enforcement framework (useful if you want to manage admission policies through a different mechanism or none at all).

Example usage:

```powershell
# Omit hydra and login
k2s addons enable security --omitHydra

# Omit keycloak
k2s addons enable security --omitKeycloak

# Omit OAuth2 proxy
k2s addons enable security --omitOAuth2Proxy

# Omit Kyverno policy enforcement
k2s addons enable security --omitPolicyEnf

# Omit all authentication components (cert-manager and linkerd only)
k2s addons enable security --omitHydra --omitKeycloak --omitOAuth2Proxy

# Omit both
k2s addons enable security --omitHydra --omitKeycloak
```

If a component is omitted, the corresponding authentication or user management features will not be available in the cluster, and you must provide your own external solution if needed.

## Components used

This addon installs workloads needed to secure the network communication by configuration. This includes (all optional via flags except cert-manager, trust-manager, and linkerd):

- [cert-manager](https://cert-manager.io/) - services for certificate provisioning and renewing, based on annotations. `cert-manager` observes these annotations and automates obtaining and renewing certificates. Note: cert-manager is typically created when enabling ingress addons (nginx, traefik, or nginx-gw). The security addon verifies its existence and creates it if not already available.

- [keycloak](https://www.keycloak.org/) - services for identity and access management. `keycloak` provides user federation, strong authentication, user management, fine-grained authorization, and more. _(Can be omitted with -OmitKeycloak)_

- [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) - trust-manager is a small Kubernetes operator which reduces the overhead of managing TLS trust bundles in your clusters, providing a much quicker way to update trust stores when they need to change.

- [linkerd](https://linkerd.io/) - service mesh implementation. `linkerd` adds security, observability, and reliability to any Kubernetes cluster. Linkerd latest versions are adapted to work also on windows hosts for windows containers.

- [ory hydra](https://github.com/ory/hydra) - using this "headless" OAuth2 and OIDC provider for providing the local user management on the windows host as part of the identity provider. _(Can be omitted with -OmitHydra)_

- [oauth2 proxy](https://github.com/oauth2-proxy/oauth2-proxy) - OAuth2 Proxy offloads the burden of implementing authentication logic from your applications.

- [kyverno](https://kyverno.io/) - policy enforcement framework. `kyverno` acts as a Kubernetes admission controller providing validate, mutate, and generate rules for cluster resources. K2s currently includes the framework without default policies, with `failurePolicy: Ignore` on all webhooks. Default policies may be added later based on feedback and further discussion. _(Can be omitted with -OmitPolicyEnf)_

## How to use it

### Certificate Management with cert-manager

Cert-manager is a powerful and widely-adopted add-on for Kubernetes that automates the management, issuance, and renewal of TLS certificates. It brings the crucial task of securing communication with Transport Layer Security (TLS) directly into the Kubernetes ecosystem, eliminating the need for manual certificate handling and reducing the risk of outages due to expired certificates.

In terms of [cert-manager](https://cert-manager.io/docs/), this addon configures a global `ClusterIssuer` of type CA (Certification Authority) named: **k2s-ca-issuer**. This issuer can be used in annotations to obtain and renew certificates.  
See: [CA Issuer](https://cert-manager.io/docs/configuration/ca/)

The addon also imports the public certificate of the CA Issuer into the trusted authorities of your windows host, and installs the `cmctl.exe` CLI.

In order to secure the ingress to your _Kubernetes_ application, follow [this description](https://cert-manager.io/docs/usage/ingress/#how-it-works):

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

cert-manager will observe annotations, create a certificate and store it in the secret named 'your-secret-name' so that the ingress class uses it.

If you enable one of `ingress nginx`, `ingress traefik`, or `ingress nginx-gw` addon, and also the `dashboard` addon, you can inspect the
server certificate by visiting the dashboard URL in your browser and clicking on the lock icon: <https://k2s.cluster.local>. This is done with [this manifest file](../ingress/nginx/manifests/cluster-local-ingress.yaml).

Note: cert-manager is automatically installed when you enable any ingress addon (nginx, traefik, or nginx-gw). The security addon checks if cert-manager already exists before attempting to create it, ensuring no conflicts or duplications occur.

You can also use the command line interface `cmctl.exe` to interact with cert-manager, it is installed in the `bin` path of your K2s install directory.

### Identity and access management with keycloak

Keycloak is a widely adopted open-source Identity and Access Management (IAM) solution that provides a comprehensive set of features for securing modern applications and services. When deployed in Kubernetes, Keycloak acts as a centralized authentication and authorization server for applications running within the cluster and potentially external to it.
Documentation related to `keycloak` you will find here: [keycloak docs](https://www.keycloak.org/guides).

The security addon adds in addition to the already many available identity providers also one for the local windows users.
Local users on the host where K2s was setup can than be used for identity and access management.

### Linkerd Service mesh

Linkerd is a lightweight, open-source service mesh designed specifically for Kubernetes. Its primary goal is to make running cloud-native applications easier and safer by providing a layer of infrastructure that handles the complexities of service-to-service communication.

In order to secure your workload please use the following annotation:

```cmd
     annotations:
       linkerd.io/inject: enabled
```

This is the only mandatory annotation to use, please check other annotations from the linkerd documenetation.

#### Resource limits for Linkerd sidecars

Linkerd automatically injects two sidecar containers into every annotated pod:

- `linkerd-proxy` — the data-plane proxy (Rust-based) that handles all mTLS traffic
- `linkerd-init` — an init container that configures iptables routing ruleses

Both containers are configured with the following resource constraints:

| Container | CPU Request | CPU Limit | Memory Limit |
|-----------|-------------|-----------|--------------|
| `linkerd-proxy` | `100m` | `100m` | `100Mi` |
| `linkerd-init` | `100m` | `100m` | `20Mi` |

This ensures compatibility with Kubernetes `ResourceQuota` policies that require CPU limits and requests on all containers in a namespace. If your workloads require higher proxy throughput, re-enable the addon after adjusting the limits in `Enable.ps1`.
For using the linkerd dashboard please first install the dashboard resources:

```cmd
linkerd viz install | kubectl apply -f -
```

After all pods are ready please start dashoboard with (you can use also another port if there is some conflict):

```cmd
linkerd viz dashboard --port 60888 &
```

Documentation related to `linkerd` you will find here: [linkerd docs](https://www.keycloak.org/guides).

### Trust manager

The primary role of trust-manager is to orchestrate and distribute bundles of trusted X.509 Certificate Authority (CA) certificates across your Kubernetes cluster.
These bundles are crucial for applications to validate the authenticity of other services they communicate with, primarily during TLS handshakes.
It also automates the process of keeping these trust stores up-to-date.

Traditionally, trust stores might be baked into container images. trust-manager decouples this by managing trust bundles at runtime. This means you can update trusted CAs without needing to rebuild and redeploy all your application containers.

While cert-manager is a popular Kubernetes tool for automating the issuance and renewal of X.509 certificates (the actual server/client certificates), trust-manager focuses on managing the trust anchors (CA certificates) that are used to verify those certificates.

### OAuth2 Proxy

OAuth2 Proxy emerges as a popular and effective solution for adding an authentication layer to your services, particularly when integrated with ingress controllers. It acts as a reverse proxy that intercepts incoming requests and enforces authentication using various identity providers before forwarding the request to the actual application.

Essentially, OAuth2 Proxy offloads the burden of implementing authentication logic from your applications. Instead of each application needing to handle user login, session management, and interaction with identity providers, OAuth2 Proxy handles this centrally.

### Ory Hydra

Ory Hydra is an open-source implementation of the OAuth 2.0 authorization framework and the OpenID Connect Core 1.0 specifications.
Unlike traditional identity platforms that bundle user management, Hydra is designed as a "headless" OAuth2 and OIDC provider. This means it focuses solely on the OAuth2 and OIDC protocols, delegating concerns like user login, consent flows, and user data management to separate, customizable components.


### Policy Enforcement with Kyverno

By default, the security addon installs [Kyverno](https://kyverno.io/) as a policy enforcement framework in the `kyverno` namespace. Kyverno acts as a Kubernetes admission controller that can **validate**, **mutate**, and **generate** resources based on policies.

**K2s currently adds the framework only. No default policies are installed.** The `addons/security/manifests/kyverno/policies/` folder is ready for your own policies. This means enabling the security addon with Kyverno changes nothing about your cluster's admission behaviour until you add policies. Default policies may be added later based on feedback and further discussion about what works well across environments.

All Kyverno webhooks are configured with `failurePolicy: Ignore`, ensuring the cluster remains operational even if Kyverno is temporarily unavailable (e.g. during a restart or upgrade).

#### Adding policies

Place `ClusterPolicy` or `Policy` manifest files in `addons/security/manifests/kyverno/policies/` and re-enable the addon, or apply them directly with `kubectl`:

```console
kubectl apply -f my-policy.yaml
```

See the [Policy Enforcement Guide](../../docs/security/policy-enforcement.md) for sample policies, audit vs enforce mode, and `PolicyException` usage.

#### Opting out

```powershell
k2s addons enable security --omitPolicyEnf
```

## Backup & Restore

The security addon supports backup and restore through the K2s CLI.

### Backup

```console
k2s addons backup security
```

**What gets backed up:**

| Artifact | Description |
|---|---|
| CA root Secret | The `ca-issuer-root-secret` from the `cert-manager` namespace. Preserving this ensures the entire TLS trust chain (cert-manager → linkerd identity → pod mTLS) can be restored without invalidating existing certificates. |
| Keycloak PostgreSQL database | A `pg_dump` of the Keycloak database containing realms, users, clients, and sessions. The default `demo-app` realm configuration self-heals from a ConfigMap, but any custom realms, users, or clients are only preserved through the database dump. |
| Enhanced security marker | The `enhancedsecurity.json` file (if present) that records whether `--type enhanced` was used. |
| Kyverno policies | All `ClusterPolicy`, `Policy`, and `PolicyException` resources exported as `kyverno-policies.yaml` (only present if Kyverno is enabled and at least one policy exists). |
| Enable parameters | Detected configuration flags (`--type`, `--ingress`, `--omitKeycloak`, `--omitHydra`, `--omitOAuth2Proxy`, `--omitPolicyEnf`) stored in `backup.json` so the addon can be re-enabled with the original settings. |

**What is NOT backed up (self-healing):**

- Linkerd identity certificates — regenerated by cert-manager from the CA root
- Pod mTLS certificates — re-issued by linkerd from identity certificates
- Hydra SQLite database — recreated on enable via `client.json` POST
- OAuth2 Proxy / Redis state — stateless; reconstructed on deploy

### Restore

```console
k2s addons restore security
```

The restore flow:

1. The CLI calls `EnableForRestore.ps1` which reads `backup.json` and re-enables the addon with the original flags.
2. After the addon is running, the CLI calls `Restore.ps1` which:
   - Replaces the auto-generated CA root Secret with the backed-up one
   - Restarts cert-manager to reconcile derived certificates
   - Scales down Keycloak, drops and restores the PostgreSQL database from the dump, then scales Keycloak back up
   - Restores the enhanced security marker file (if present)
   - Applies `kyverno-policies.yaml` (if present in the backup) after Kyverno is ready

## Further Reading

- Docs: <https://cert-manager.io/docs/>
- Code: <https://github.com/cert-manager/cert-manager>
- Docs: <https://www.keycloak.org/documentation>
- Code: <https://github.com/keycloak/keycloak>
- Docs: <https://linkerd.io/2-edge/overview/>
- Code: <https://github.com/linkerd/linkerd2>
- Docs: <https://cert-manager.io/docs/trust/trust-manager/>
- Code: <https://github.com/cert-manager/trust-manager>
- Docs: <https://oauth2-proxy.github.io/oauth2-proxy/>
- Code: <https://github.com/oauth2-proxy/oauth2-proxy>
- Docs: <https://www.ory.sh/hydra>
- Code: <https://github.com/ory/hydra>
- Docs: <https://kyverno.io/docs/>
- Code: <https://github.com/kyverno/kyverno>

## Knowledge Base

- **HSTS:** Browsers keep track on several security-related properties of web sites. If they encounter weaker security settings that they encountered last time, they assume it is an attack and will not allow the navigation to that site. This is the case when you enable the security addon, browse a secure site of your cluster, and then disable the security addon. The browser will not trust the site you used before anymore.

  You can **reset HSTS** of your site stored by your browser by navigating to:

  ```cmd
  chrome://net-internals/#hsts
  ```

  and deleting the settings for your site.

## Guiding Principle

The guiding principle is to provide security as an inherent property of the infrastructure, rather than an optional add-on implemented per application. By deploying components that transparently handle TLS encryption (cert-manager, service mesh), manage identities and tokens (Keycloak), and mediate access (service mesh, API gateways), we abstract away the underlying complexity for application developers. This allows us to move towards a 'secure by default' environment, where essential security mechanisms are automatically applied to workloads simply by deploying them onto the meshed or protected infrastructure, without requiring explicit security code within the application itself.
