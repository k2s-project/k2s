<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# HSTS & Certificate Issues (`k2s.cluster.local`)

Browsers maintain internal security mechanisms to protect connections to web services. When accessing *K2s* web endpoints on `k2s.cluster.local` (e.g., the `dashboard`, `logging`, or `viewer` addons), you may encounter connection errors such as **"Your connection is not private"** (`NET::ERR_CERT_AUTHORITY_INVALID` or `NET::ERR_CERT_COMMON_NAME_INVALID`).

This guide explains why this happens in *K2s* and how to resolve it — **even after the CA certificate has already been imported into the Windows certificate store**.

## How TLS works in K2s

Before troubleshooting, it helps to know what *K2s* sets up automatically:

- `k2s.cluster.local` resolves to the control-plane IP `172.19.1.100` via the Windows hosts file (`C:\Windows\System32\drivers\etc\hosts`) and CoreDNS.
- When you enable an ingress addon (`nginx`, `traefik`, `nginx-gw`) or the `security` addon, [cert-manager](https://cert-manager.io/){target="_blank"} issues a TLS certificate for `k2s.cluster.local` from the `k2s-ca-issuer`.
- The root CA public certificate (`K2s Self-Signed CA`) is **automatically imported into the Windows Trusted Root Certification Authorities** store (`Cert:\LocalMachine\Root`).
- Every *K2s*-issued certificate already contains a **Subject Alternative Name (SAN)** entry for `k2s.cluster.local`.

Because store placement and the SAN are handled automatically, they are **not** the usual cause of a persistent certificate error. The most common cause is a **stale HSTS policy cached by the browser**, which is described below. See [Certificate Management](../user-guide/certificate-management.md) for the full certificate architecture.

## Understanding HSTS Enforceability

**HSTS (HTTP Strict Transport Security)** is an IETF web security standard ([RFC 6797](https://datatracker.ietf.org/doc/html/rfc6797){target="_blank"}). When a service sends a `Strict-Transport-Security` HTTP response header, browsers strictly force all subsequent connections to that domain over HTTPS.

### Why this affects K2s

- **Unbypassable security warnings:** Unlike standard self-signed certificate warnings, when HSTS is active for a domain, Chrome and Edge **disable the ability to bypass** the warning screen (the "Proceed to site (unsafe)" link is hidden or non-functional).
- **Persistent cache:** Browsers cache HSTS policies locally based on the `max-age` directive.
- **CA re-issuing:** *K2s* re-issues the CA and TLS certificates when you re-enable an ingress addon or enable/disable the `security` addon. The browser still has the **old** HSTS/certificate state cached and rejects the new certificate — even though *K2s* has already imported the new CA into the trusted root store.

This is why the error can persist after a fresh certificate import: the fix is to clear the cached browser state, not to re-import the certificate.

## Resolving the Issue

### Step 1: Delete the cached HSTS policy

Clear the policy from your browser's internal network settings:

1. Open your browser and navigate to:
    - **Chrome:** `chrome://net-internals/#hsts`
    - **Edge:** `edge://net-internals/#hsts`
2. In the **Query HSTS/PKP domain** section:
    - Input domain: `k2s.cluster.local`
    - Click **Query**. If `Found` is displayed, HSTS is currently enforced for this host.
3. In the **Delete domain security policies** section:
    - Input domain: `k2s.cluster.local` *(do not include `https://`, port numbers, or trailing slashes)*
    - Click **Delete**.

### Step 2: Flush cached DNS and sockets

To ensure Windows and the browser use the updated certificate session:

1. Flush the Windows DNS cache from PowerShell or Command Prompt:
    ```console
    ipconfig /flushdns
    ```
2. Flush the browser's cached sockets so new connections re-negotiate TLS:
    - **Chrome:** navigate to `chrome://net-internals/#sockets` and click **Flush socket pools**.
    - **Edge:** navigate to `edge://net-internals/#sockets` and click **Flush socket pools**.

### Step 3: Restart the browser

Fully close and reopen the browser, then access the endpoint again (e.g., <https://k2s.cluster.local>).

!!! note
    If the ingress or web application serving `k2s.cluster.local` keeps sending the `Strict-Transport-Security` header, the browser will re-register HSTS on the next HTTPS connection. That is expected — you only need to reset HSTS again if the certificate itself was re-issued (e.g., after re-enabling an ingress addon or toggling the `security` addon).

## Still failing? Verify the CA in Windows

If, after resetting HSTS, Chrome still shows `NET::ERR_CERT_AUTHORITY_INVALID`, confirm the current *K2s* CA is present and trusted. *K2s* imports it automatically, but a manually replaced or re-issued CA can leave a stale entry.

1. List the imported *K2s* CA in the trusted root store:
    ```powershell
    Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like '*K2s Self-Signed CA*' }
    ```
2. If a stale/old `K2s Self-Signed CA` certificate exists alongside the current one, remove the outdated entry (match by thumbprint) and let *K2s* re-import the current CA by re-enabling the ingress addon.

!!! tip
    When you use an **external Certificate Authority** (the `--omitCertMgr` workflow), *K2s* does not manage the CA import for you. Ensure your organization's root CA is installed under **Trusted Root Certification Authorities** and that the certificate includes a **SAN** entry for `k2s.cluster.local`. See [Certificate Management → Using an External Certificate Authority](../user-guide/certificate-management.md#using-an-external-certificate-authority).
