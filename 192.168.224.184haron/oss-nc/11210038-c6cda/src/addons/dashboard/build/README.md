<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Headlamp plugin OCI images — build, publish & lifecycle

This folder is the **producer** for the K2s‑owned Headlamp plugin OCI images that the
`dashboard` addon injects into the Headlamp deployment as init‑containers.

K2s owns these images (it does **not** consume upstream plugin images at runtime): each
plugin is built from a vendored, checksum‑pinned compiled bundle and published to the
private registry **`shsk2s.azurecr.io`**, so the whole flow is offline‑reproducible and
air‑gap friendly.

> Looking for how plugins are *activated* at runtime? See
> [`../dashboard.module.psm1`](../dashboard.module.psm1) (`Sync-HeadlampPlugins`) and the
> "Headlamp plugins" section of [`../README.md`](../README.md).

---

## 1. Lifecycle (end to end)

```
plugin <name>-<ver>.tar.gz            (vendored compiled bundle — build/plugins/)
        │
        ▼
headlamp-plugins.lock.json            (single source of truth: name, version,
        │                              pluginDir, image ref, sha256, bundle URL)
        ▼
Build-HeadlampPluginImages.ps1 -Push  (crane append bundle → busybox base; crane push)
        │      (invoked by the dashboard autoupdate workflow — see §4)
        ▼
shsk2s.azurecr.io/headlamp-plugin-*   (published OCI image, manifest-verified)
        │
        ▼
addon.manifest.yaml additionalImages  (declares the images to the offline packager)
        │
        ▼
addons/Export.ps1 → Export-Image.ps1  (buildah pull <ref> → oci-archive tar)
        │
        ▼
offline package                       (addon OCI tar bundled for air-gapped install)
        │
        ▼
Import-Image.ps1                       (buildah pull oci-archive → node image store)
        │
        ▼
Sync-HeadlampPlugins                   (capability detected → init-container patch)
        │
        ▼
Headlamp                              (plugin loaded from /plugins/<pluginDir>/)
```

The image build happens **once**, at CI/autoupdate time. Enabling an addon never builds
an image — runtime only **activates** an already‑published image.

---

## 2. Responsibilities (file by file)

| Artifact | Responsibility |
|---|---|
| **`plugins/<name>-<ver>.tar.gz`** | Vendored, compiled Headlamp plugin bundle (the upstream GitHub Release asset). Contains `main.js` + `package.json`. Committed in‑repo so the image is reproducible from a clean checkout with no network egress. Each has a `.license` sidecar. |
| **`headlamp-plugins.lock.json`** | **Single source of truth.** For every plugin it pins: `name`, `version`, `pluginDir`, the published `image` ref (`shsk2s.azurecr.io/headlamp-plugin-<name>:<ver>`), the `baseImage`, and `prebuilt.{url,localPath,sha256}`. Consumed by the producer and validated by `headlamp-plugin-images.unit.tests.ps1`. Must stay in lock‑step with `addon.manifest.yaml` (`additionalImages`) and `Get-RegisteredHeadlampPlugins`. |
| **`Build-HeadlampPluginImages.ps1`** | Thin orchestrator (the **producer**). Reads the lock, then per plugin: acquire bundle → build layer tar → `crane append` onto the pinned busybox base → validate image layout → (with `-Push`) `crane push` to ACR. Flags: `-LockFile`, `-OutputDir`, `-CraneExe`, `-Mode prebuilt|source`, `-PluginName`, `-Push`, `-UpdateLock`, `-Proxy`. |
| **`Build-HeadlampPluginImages.Methods.ps1`** | Dot‑sourced core methods: `Get-HeadlampPluginLock`, `Resolve-CraneExe`, `Invoke-PluginAcquisition` (vendored‑bundle‑first, sha256‑gated), `Expand-PluginTarball`, `Build-PluginFromSource` (optional `-Mode source` via node/npm), `Test-PluginBundleLayout`, `New-PluginLayerTar`, `Build-PluginOciImage`, `Test-PluginImageLayout`. Self‑contained logging (`[HlPlugin]`) so it runs in CI containers without the k2s modules. |
| **`headlamp-plugin-images.unit.tests.ps1`** | Parity guard: fails the build if lock ↔ `addon.manifest.yaml` `additionalImages` ↔ `Get-RegisteredHeadlampPlugins` ever drift (image names, versions, bundle paths, sha256). |
| **`../addon.manifest.yaml` → `additionalImages`** | Declares the plugin image refs to the **offline packager** (`addons/Export.ps1`). This is what causes the images to be pulled and bundled into the offline package. |
| **`Sync-HeadlampPlugins` (`../dashboard.module.psm1`)** | Runtime **activator** (not a builder). When the dashboard addon is enabled, it iterates the plugin registry, runs each plugin's capability detector, and patches the Headlamp deployment with an init‑container per detected plugin that copies `/plugins/<pluginDir>/` into the shared `headlamp-plugins` volume. Never builds or pulls images. |

---

## 3. Image layout contract

Each image is `busybox:1.36` + one layer containing `plugins/<pluginDir>/{main.js,package.json}`.
`Test-PluginImageLayout` verifies `/plugins/<pluginDir>/main.js` and `package.json` exist in
the built image before it is considered valid. At runtime the init‑container copies
`/plugins/<pluginDir>/.` into the Headlamp `pluginsDir` volume, so the `pluginDir` in the lock
must equal the init‑container name produced by `Get-RegisteredHeadlampPlugins`.

---

## 4. Update workflow

### Official publication (CI — the normal path)

Plugin images are built and published by the **dashboard autoupdate Argo workflow**,
`K2s-Support/ci/autoupdate/27-update-addons-dashboard.yaml`, in the
`build-and-push-headlamp-plugin-images` step. That step:

1. installs `crane`,
2. logs in to `shsk2s.azurecr.io` using the `shsk2s-push-credentials` secret
   (`crane auth login … --password-stdin`),
3. clones K2s (for the producer, lock, and vendored bundles),
4. invokes the **existing producer** — `Build-HeadlampPluginImages.ps1 -Push` — so no
   build logic is duplicated in YAML,
5. **verifies** every published image with `crane manifest` (and prints the digest).

It runs **before** the plugin update PR steps so the referenced tags already exist in ACR
when anything points at them — the same ordering guarantee used by
`build-and-push-fluent-bit-win-image` in `33-update-addons-logging.yaml`. The step
hard‑fails on any build, push, or manifest‑verification error.

### How a new plugin *version* flows through the system

1. **Bundle + lock** — add/replace `plugins/<name>-<newver>.tar.gz` (+ `.license`) and
   update the matching entry in `headlamp-plugins.lock.json` (`version`, `image`,
   `prebuilt.localPath`, `prebuilt.sha256`). Run `-UpdateLock` once to pin a fresh sha256.
2. **OCI image build + ACR publication** — the autoupdate workflow runs the producer with
   `-Push`, building from the new bundle and publishing
   `shsk2s.azurecr.io/headlamp-plugin-<name>:<newver>`, then verifies the manifest.
3. **Declared references** — update the matching refs in `addon.manifest.yaml`
   (`additionalImages`) and `Get-RegisteredHeadlampPlugins` so all three stay in lock‑step
   (the parity test enforces this).
4. **Runtime activation** — no rebuild at enable time; `Sync-HeadlampPlugins` activates the
   new image the next time the capability is present.

### Adding a brand‑new plugin

1. add a `Test-<Capability>CapabilityAvailable` detector + a row in
   `Get-RegisteredHeadlampPlugins` (registration),
2. vendor the bundle + add a lock entry + add the `additionalImages` ref (image availability),
3. ensure an addon that provides the capability calls the guarded `Sync-HeadlampPlugins`
   (addon‑to‑plugin mapping).

No enable‑time build is ever introduced.

---

## 5. Local development vs official publication

| | Local developer testing | Official publication |
|---|---|---|
| **Who** | A developer, manually | The dashboard autoupdate Argo workflow |
| **Command** | `Build-HeadlampPluginImages.ps1` (build to offline tarballs in `out/`) or `-Push` to a test registry | `Build-HeadlampPluginImages.ps1 -Push` to `shsk2s.azurecr.io` |
| **Auth** | none needed for `out/` tarballs; your own `crane auth login` for a test push | `shsk2s-push-credentials` secret via `crane auth login --password-stdin` |
| **Prerequisite** | `crane` on `PATH` (or `-CraneExe`); the vendored bundles are already committed | crane installed in the CI pod |
| **Result** | local OCI tarballs / test images for inspection | the canonical ACR images consumed by the offline packager |

Local build (no push), for inspection:

```powershell
# from repo root; requires crane on PATH (or pass -CraneExe)
./addons/dashboard/build/Build-HeadlampPluginImages.ps1 -OutputDir ./addons/dashboard/build/out
# build a single plugin only:
./addons/dashboard/build/Build-HeadlampPluginImages.ps1 -PluginName cert-manager -OutputDir ./out
```

> `crane` (google/go-containerregistry) is a build‑time prerequisite and is **not**
> committed under `bin/`. Install it from
> <https://github.com/google/go-containerregistry/releases> or pass `-CraneExe <path>`.

The **only** sanctioned way to publish to `shsk2s.azurecr.io` is the autoupdate workflow.
Developers should not push to ACR from a workstation.

---

## 6. Offline packaging

The published images are declared in `addon.manifest.yaml` under
`offline_usage.linux.additionalImages`. `addons/Export.ps1` reads that list, `buildah pull`s
each image from ACR, and `Export-Image.ps1` writes it to an `oci-archive` tar inside the addon
OCI artifact. On the target, `Import-Image.ps1` loads it (`buildah pull oci-archive:`) so the
init‑container images are present for fully offline activation. The producer's local `out/`
tarballs are **not** consumed by the offline packager — packaging pulls by reference from ACR.

---

## 7. Source of truth & invariants

`headlamp-plugins.lock.json` is authoritative. Three coordinates must agree (enforced by
`headlamp-plugin-images.unit.tests.ps1`):

- `headlamp-plugins.lock.json` — `plugins[].image`
- `addon.manifest.yaml` — `offline_usage.linux.additionalImages`
- `dashboard.module.psm1` — `Get-RegisteredHeadlampPlugins` image refs

Keep version, `pluginDir`, and image name identical across all three.

