<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: MIT
-->

# Security Features

*K2s* provides multiple layers of security — from code signing and package integrity verification to runtime security addons and encrypted container images. This page provides an overview of all security capabilities.

## Code Signing

*K2s* packages can be code-signed using Authenticode to ensure integrity and provenance. The signing module signs all executables, DLLs, MSI installers, and PowerShell scripts within a package.

### Signing During Package Creation

Pass a PFX certificate to the `k2s system package` command:

```console
k2s system package -d C:\output -n k2s-signed.zip --certificate C:\certs\signing.pfx --password <cert-password>
```

This signs all signable files before they are included in the zip package.

### What Gets Signed

| File Type | Extensions |
|-----------|-----------|
| Executables | `.exe`, `.dll`, `.msi` |
| PowerShell scripts | `.ps1`, `.psm1` |

The signing module (`k2s.signing.module`) provides:

- `Set-K2sFileSignature` — signs all K2s files using a PFX certificate with Authenticode
- `Get-SignableFiles` — discovers signable files with built-in exclusion lists for vendored third-party binaries

### Certificate Requirements

- **Format:** PFX (PKCS#12) with private key
- **For testing:** self-signed certificates work (see [Code Signing](../op-manual/code-signing.md) for creation steps)
- **For production:** use certificates from a trusted CA or an organization-managed PKI
- The PFX is imported to `LocalMachine\My` certificate store during signing

!!! tip
    For detailed step-by-step instructions including CI/CD integration, certificate creation, and verification, see the [Code Signing Guide](../op-manual/code-signing.md).

---

## Catalog Signing (WDAC / Device Guard)

For environments using Windows Defender Application Control (WDAC) or Device Guard, *K2s* supports Windows catalog file signing.

A catalog file (`.cat`) lists cryptographic hashes of all files in the distribution. Once signed with a trusted certificate, Windows can verify every file's integrity before execution.

### How It Works

1. *K2s* includes catalog definition files (`build/catalog/k2s.cdf`) that enumerate all distributed files.
2. During packaging, `PackageInspector.exe` generates the catalog file `k2s.cat`.
3. The catalog is signed using `signtool.exe` with an Authenticode certificate.
4. On target machines, the signed catalog is installed — WDAC then trusts all files listed in the catalog.

For detailed instructions, see [Sign K2s Package](../op-manual/signcatalog-k2s.md).

---

## AppLocker Policies

*K2s* ships pre-built AppLocker rules in `cfg\applocker\applockerrules.xml` for environments where AppLocker is enforced.

The rules grant the `ContainerAdministrator` account (SID `S-1-5-93-2-2`) permission to run executables from `C:\*`. This is necessary because Windows containers run processes under `ContainerAdministrator`, and AppLocker blocks execution by default for non-administrator accounts.

!!! note
    These rules only need to be imported on Windows hosts where AppLocker policies are active. In environments without AppLocker, they have no effect.

---

## SSH Key Management

*K2s* automates SSH key generation and deployment for secure communication between the Windows host and the Linux control-plane VM.

### Automated Workflow

During installation, the `k2s.node.module/linuxnode/security/` module:

1. **Generates an SSH key pair** (`New-SshKey`) — Ed25519 keys placed in the user's `~/.ssh` directory
2. **Deploys the public key** (`Copy-LocalPublicSshKeyToRemoteComputer`) — copies the public key to the Linux VM's `authorized_keys`
3. **Disables password authentication** (`Remove-ControlPlaneAccessViaUserAndPwd`) — after key deployment, password-based SSH is disabled

### Adding Additional Users

When granting a Windows user access to *K2s* via `k2s system users add`, their SSH key pair is created and deployed automatically. See [Adding K2s Users](../op-manual/adding-k2s-users.md) for the full workflow.

---

## OCI Image Encryption

The containerd configuration template (`cfg\containerd\config.toml.template`) includes support for OCI image encryption and decryption via the `ocicrypt` stream processors.

### Configuration

Encryption keys are expected at:

```
C:\k\bin\certs\encrypt\
```

The containerd configuration includes `ocicrypt` stream processors that handle transparent decryption of encrypted container image layers at pull time.

!!! note
    Image encryption is an advanced feature. Standard *K2s* deployments use unencrypted images. Enable this when deploying sensitive container images that must be protected at rest.

---

## Security Addon

The **security** addon provides runtime security features for the cluster, with two modes:

### Basic Mode (Default)

```console
k2s addons enable security
```

Installs **cert-manager** for automatic TLS certificate management within the cluster. See [Certificate Management](../user-guide/certificate-management.md) for details on the default self-signed CA, using external certificate authorities, and the `--omitCertMgr` flag.

### Enhanced Mode (Zero Trust)

```console
k2s addons enable security --type enhanced
```

Adds the following on top of basic mode:

| Component | Purpose |
|-----------|---------|
| **Linkerd** | Service mesh providing mutual TLS (mTLS) between all pods — zero-trust networking |
| **Ory Hydra** | OAuth2/OIDC provider for authentication flows |
| **Keycloak** | Identity and access management |
| **OAuth2 Proxy** | Reverse proxy for adding authentication to any service |

Optional flags to customize the security stack:

| Flag | Effect |
|------|--------|
| `--omitHydra` | Skip Hydra and the Windows login integration |
| `--omitKeycloak` | Skip Keycloak and use an external OAuth2 provider |
| `--omitOAuth2Proxy` | Skip the OAuth2 Proxy deployment |
| `--omitPolicyEnf` | Skip Kyverno policy enforcement framework |

The `login.exe` tool (bundled in `bin/`) provides Windows-logon-based authentication for the Hydra OAuth2 flow, enabling single sign-on from the Windows host.

!!! tip
    The enhanced security mode with Linkerd also enables the [Compartment Launcher](../dev-guide/architecture.md) (`cplauncher.exe`) for Windows service mesh support.

---

## Policy Enforcement

*K2s* ships [Kyverno](https://kyverno.io/) as a policy enforcement framework within the `security` addon. Kyverno runs as a Kubernetes admission controller in the `kyverno` namespace and can **validate**, **mutate**, and **generate** Kubernetes resources based on declarative policies.

### What currently ships

- **Framework only.** No default policies are installed. The cluster admission behaviour is unchanged until you add policies. Default policies may be added later based on feedback and further discussion about what works well for K2s users. Use `--omitPolicyEnf` to skip Kyverno installation entirely.
- All webhooks use `failurePolicy: Ignore`. Kyverno being unavailable never blocks cluster operations.
- Runs in standalone mode (1 replica per controller) suited for K2s single control-plane topology.

### Policy types

| Type | Purpose |
|------|---------|
| `ClusterPolicy` | Cluster-wide rules applied to all namespaces |
| `Policy` | Namespace-scoped rules |
| `PolicyException` | Exempt specific resources from a policy |

### Audit vs Enforce mode

Policies can run in two modes:

- **`audit`**: violations are reported (via `PolicyReport`) but resources are **not blocked**. Use this to assess impact before enforcing.
- **`enforce`**: non-compliant resources are **rejected** at admission time.

Set the mode per policy rule with `validationFailureAction: Audit` or `validationFailureAction: Enforce`.

### Opting out

```console
k2s addons enable security --omitPolicyEnf
```

In **enhanced security mode** the `kyverno` namespace is meshed into Linkerd (`linkerd.io/inject: enabled`), so the Kyverno controllers run inside the zero-trust mTLS perimeter; the admission webhook port (`9443`) is excluded from inbound proxying so the API server can still reach it. In basic mode Kyverno runs without a sidecar.

For full usage examples, sample policies, and `PolicyException` guidance, see the [Policy Enforcement Guide](policy-enforcement.md).

---

## SBOM Generation

*K2s* supports Software Bill of Materials (SBOM) generation for supply chain transparency, using:

- **Trivy** — vulnerability scanner and SBOM generator
- **CycloneDX** — standard SBOM format

### Generating an SBOM

```console
powershell -File build\bom\GenerateBom.ps1
```

The script:

1. Scans all container images in the running cluster
2. Scans addon manifests for additional images
3. Generates a CycloneDX-format SBOM
4. Optionally annotates components with clearance information (`-Annotate`)

### Image Inventory

A separate script dumps all container images used by *K2s*:

```console
powershell -File build\bom\DumpK2sImages.ps1
```

This produces `kubernetes_images.json` listing every image across the cluster and all addon manifests.

---

## Debian 13 Node Hardening

New Windows-hosted Debian 13 control-plane images and newly added external Debian 13 workers use shared hardening during provisioning. The supported worker-add workflow targets existing VMs or physical hosts; it does not create managed worker VMs. Existing installations, cached older images and native Linux K2s hosts are not migrated. Rebuild the base image to validate this behavior.

### Package policy

| Candidates | Reason |
|-----------|--------|
| `man-db`, `manpages`, `manpages-dev`, `groff`, `groff-base`, `doc-debian`, `info`, `install-info` | Documentation viewers and formatting, not node execution |
| `nano`, `vim-tiny`, `ed` | Interactive editing is not required for managed provisioning |
| `exim4`, `exim4-base`, `exim4-config`, `exim4-daemon-light`, `exim4-daemon-heavy` | A Kubernetes node is not a mail server |
| `avahi-daemon` | Node discovery does not use multicast DNS |

Only installed candidates are considered. The complete purge/autoremove transaction is simulated before execution; held, essential, required-priority and explicitly protected operational packages block unsafe removal. Protection covers Kubernetes, CRI-O, Buildah and nftables, boot/kernel and guest agents, SSH/sudo/systemd, networking (including `ebtables` and `ipset`), DNS, clock and storage/mount tools. In particular, `rpcbind`, `nfs-common`, `cifs-utils`, `btrfs-progs`, `xfsprogs`, `mdadm` and `multipath-tools` are not blanket removal candidates. Dependency metadata alone cannot prove addon compatibility; regression testing remains mandatory.

Hardening requires no package downloads. `/var/lib/k2s/hardening/removal-plan.log` records the simulation and `reinstall.tsv` records planned removed package names and versions, including transitive removals. A checked post-purge inventory verifies removal before updating `removed.tsv`; a query failure stops cleanup rather than treating packages as absent. Preserve these records when investigating partial failures. Repeated cleanup retains the reinstall list.

### Timers, documentation and updates

Automatic `apt-daily` and `apt-daily-upgrade` services/timers are masked before K2s package operations. Timer triggers stop; existing package transactions finish under bounded waiting. Timeout fails provisioning without deleting locks or killing package processes. `motd-news.timer` is disabled when present.

Cloud-init completion with recoverable errors (exit code 2) logs a warning and its full status diagnostics; fatal errors and timeouts stop provisioning. Stopped APT timers have their failed state cleared without terminating active package services.

Late cleanup follows required package/tool installation and precedes image sealing or external-worker join. `/etc/dpkg/dpkg.cfg.d/01_nodoc` excludes documentation under `/usr/share/{doc,man,groff,info,lintian,linda}` from subsequent package installs. Copyright/license notices and runtime examples are retained; locales and common licenses are untouched. APT archive-cache cleanup does not remove retained K2s offline payloads under the provisioning user's home directory.

!!! warning "Controlled security patching remains necessary"
    Disabling automatic APT jobs does not patch Debian vulnerabilities. Image maintainers must regularly rebuild and validate patched images; operators must deliver approved OS updates through controlled maintenance, including verified offline Debian/delta payloads. Kubernetes-only upgrades do not guarantee OS security patch coverage. Do not assume security updates still run automatically.

### Validation and recovery

1. Retain the previous image/package and capture an equivalent unhardened package inventory, rootfs SBOM, vulnerability scan and size baseline before cleanup.
2. Smoke-test fresh control-plane and worker nodes, reboot, repeat hardening and check masks, package/tool availability and documentation exclusions. Check exclusions after offline package/delta updates.
3. Run install/start/stop/restart, addon enable/disable, worker-add and offline delta-upgrade regression suites before publication. Compare rootfs CycloneDX component counts and vulnerability identities using identical Trivy/database versions and equivalent OS/K2s package inputs. Record guest-used bytes and packaged-artifact sizes; fewer guest files do not guarantee VHDX shrinkage, lower RAM or faster boots.
4. Rehearse recovery on a disposable test image before staged publication. Retaining the previous image is the image rollback; replacing a live control-plane disk is not a substitute for a verified cluster/data backup and restore.
5. If a tool is needed later, review `reinstall.tsv` and restore recorded versions from approved available packages, accounting for dependencies. Reinstallation does not restore configuration/data lost during purge. A failed simulation aborts before purge; a later failure is not transactional rollback.

Package-safety mocks and isolated filesystem checks of the actual documentation cleanup run through existing Pester unit-test discovery, using Git for Windows Bash. A missing Bash executable or a failed check fails the test; these checks do not replace Debian guest, offline-update or reboot validation. Run just these checks with:

```powershell
Invoke-Pester -Path .\test\debian13-hardening.unit.tests.ps1 -Tag unit -Output Detailed
```

---

## Package Integrity

The `build/catalog/` directory contains Windows catalog files (`.cat`, `.cdf`) used for file integrity verification:

1. `PackageInspector.exe` scans the *K2s* distribution and records file hashes in a catalog definition file (`.cdf`)
2. The `.cdf` is compiled into a `.cat` catalog file
3. The catalog is signed with `signtool.exe`
4. On target machines, Windows verifies each file's hash against the catalog before execution

This provides tamper detection for the entire *K2s* distribution without requiring individual file signing.

---

## Summary

| Feature | Scope | Tool/Component |
|---------|-------|----------------|
| Code signing | Packaging | `k2s.signing.module`, `k2s system package --certificate` |
| Catalog signing | Distribution integrity | `signtool.exe`, `PackageInspector.exe` |
| AppLocker rules | Enterprise host lockdown | `cfg/applocker/applockerrules.xml` |
| SSH key management | Host-to-VM communication | `k2s.node.module/linuxnode/security/` |
| OCI image encryption | Container image protection | containerd `ocicrypt` stream processors |
| Basic security addon | TLS certificate management | cert-manager |
| Enhanced security addon | Zero trust, SSO | Linkerd, Hydra, Keycloak, OAuth2 Proxy |
| SBOM generation | Supply chain transparency | Trivy, CycloneDX |
| Package integrity | Tamper detection | Windows catalog files |

## See Also

- [Code Signing Guide](../op-manual/code-signing.md) — detailed signing workflow
- [Sign K2s Package](../op-manual/signcatalog-k2s.md) — catalog signing for WDAC
- [Adding K2s Users](../op-manual/adding-k2s-users.md) — SSH key deployment for users
- [Addons](../user-guide/addons.md) — security addon details
- [Architecture & Tools](../dev-guide/architecture.md) — bundled security tools
