<!--
SPDX-FileCopyrightText: © 2025 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# AI Coding Assistant Project Instructions (K2s)

These instructions make an AI agent immediately productive in this repository. Keep responses concise, apply these conventions automatically, and prefer concrete edits (not vague advice).

## 1. Big Picture
K2s is a dual‑platform Kubernetes distribution supporting both Windows and Linux hosts, with strong offline support. On Windows it bundles a Linux VM (Hyper-V or WSL) plus curated OSS components. On Linux (**experimental**) it runs the control plane natively and optionally provisions a Windows VM via libvirt/KVM. Repo delivers:
- `k2s` CLI (Go) under `cmd/...` operating orchestration & lifecycle. Builds for both Windows and Linux via `go build` tags.
- PowerShell modules & scripts for host provisioning, packaging, offline builds, addon management (`lib/modules`, `lib/scripts`, `addons/`) — used on Windows only.
- Provider architecture (`internal/provider/`) abstracts all platform-specific logic behind domain interfaces. Commands use providers exclusively — no `runtime.GOOS` checks in command handlers.
- Addon system: each addon = folder with `addon.manifest.yaml`, enable/disable scripts, and manifests.
- Offline packaging pipeline producing large ZIPs containing binaries, images, VHDX base disks, and addon assets.
- Documentation site built via MkDocs (`mkdocs.yml`, `docs/`).

## 2. Key Directories
- `k2s/` Go sources (CLI root). Subdirs `cmd/*` for individual commands; shared logic in `internal/`.
  - `internal/provider/` Platform-agnostic interfaces + build-tagged implementations (Windows ↔ PowerShell, Linux ↔ native Go). This is the primary abstraction layer for dual-platform support.
  - `internal/setuporchestration/` Linux-native cluster provisioning (kubeadm, libvirt/KVM, SSH).
- `lib/modules/windows/<ownership>/k2s.*.module/` PowerShell modules (logging, infra, node, cluster, signing, etc.) — Windows only.
- `lib/scripts/windows/host/system/package/` Packaging & delta generation scripts (`New-K2sDeltaPackage.ps1`, helpers file).
- `addons/` Addon definitions; each addon has `Enable.ps1`, `Disable.ps1`, optional `Get-Status.ps1`, `Update.ps1`, `README.md`.
- `smallsetup/` Windows environment bootstrap (loopback adapter, HNS, kubeadm flags, etc.).
- `bin/` Pre-bundled third‑party executables (kubectl, helm, nerdctl, jq, plink, etc.). Do NOT modify vendored binaries—never rewrite.
- `build/` BOM, catalog metadata used for reproducibility & signing.
- `docs/` MkDocs sources; includes dev guide, ops manual, troubleshooting.

### Platform-First Automation Layout

Treat the following locations as an enforced repository contract:

- Windows scripts: `lib/scripts/windows/{host,linuxonly,buildonly,worker}/`
- Windows modules: `lib/modules/windows/{common,infra,cluster,node}/`
- Native Debian 13 scripts: `lib/scripts/linux/debian/{host,linuxonly,worker}/`
- Native Linux modules: `lib/modules/linux/{common,infra,cluster,node,networking,services}/`
- OS-specific node-extension assets only: `cfg/nodeextension/<os>/`

Do not create or reintroduce `lib/scripts/k2s/`, `lib/scripts/linuxonly/`,
`lib/scripts/buildonly/`, `lib/scripts/worker/`, or `lib/modules/k2s/`.
When relocating automation, update all Go provider paths, PowerShell/Bash
imports, tests, package/catalog/signing inputs, and documentation in the same
change. Native Linux install/start/stop/uninstall are Bash-owned through
`lib/scripts/linux/debian/linuxonly/` and `lib/modules/linux/`; retain
Go-native `k2s status` so its typed output contract is unchanged.

Run `bash test/native-linux-layout.sh` on a Bash-capable host after modifying
these paths. It rejects tracked legacy locations and active legacy references.

## 2a. Documentation Guidelines
- **Document at the k2s CLI level**: The `k2s.exe` CLI is the primary user-facing API. Documentation examples should use `k2s` commands (e.g., `k2s system package`, `k2s system upgrade`, `k2s addons enable`) rather than direct PowerShell script invocations.
- PowerShell scripts are implementation details; users interact via the CLI.
- When documenting new features, ensure corresponding CLI commands exist or are planned.
- Use `console` code blocks for CLI examples; use `powershell` blocks only when showing PowerShell-specific operations (e.g., `Expand-Archive`).

## 3. PowerShell Conventions
- All logging goes through functions from `k2s.infra.module` (`Write-Log`, `Write-ErrorMessage`). Don’t use `Write-Host` directly for new code.
  - Usage: `Write-Log "message" -Console` (logs to file + console) or `Write-Log "message"` (file only).
  - Tag log messages with bracketed category prefixes: `Write-Log "[DebPkg] Processing packages"`.
- Scripts meant for reuse go into a helper `.ps1` and are dot-sourced; keep orchestration thin (see `New-K2sDeltaPackage.ps1` + `New-K2sDeltaMethods.ps1`).
- Long phases wrapped with `Start-Phase` / `Stop-Phase` for timing (imported from helper files like `New-K2sDelta.Phase.ps1`).
- Hash objects expose both `.Sha256` and `.Hash` for backward compatibility.
- Avoid assigning to automatic variables (`$args`). Use explicit names (`$sshParams`, `$scpParams`).
- When adding guest/Hyper-V interactions, clean up resources (switch, NAT, VM) even on error.
- Secure inputs: new code should accept `SecureString` or `PSCredential` for secrets (legacy plain strings exist—don't proliferate).
- Path handling: Quote paths when passing to external tools (e.g., `kubectl delete -f "$path"`). PowerShell handles paths with spaces automatically in most contexts, but external tools need explicit quoting.

## 4. Delta Packaging Pattern
- Extraction: `Expand-ZipWithProgress` with path sanitization & traversal prevention.
- Hashing: `Get-FileMap` builds maps; diff logic excludes wholesale directories & special large artifacts (VHDX, MSI, archives).
- Debian diff: Boot temporary VM from Kubemaster VHDX → SSH → `dpkg-query` → compute Added/Removed/Changed. Offline acquisition attempts to download changed .deb files (`Invoke-GuestDebAcquisition`).
- Generated artifacts under staging include `delta-manifest.json`, optionally `debian-delta/*` (lists, scripts, downloaded packages).

## 5. Addon Pattern
Each addon folder contains:
- `addon.manifest.yaml` (metadata, dependencies, toggles) conforming to `addons/addon.manifest.schema.json`.
- Enable/Disable scripts modify cluster state via kubectl/helm/yaml manifests under `manifests/`.
  - Import standard modules: `$clusterModule`, `$infraModule`, `$addonsModule` (see `addons/autoscaling/Enable.ps1` for template).
  - Initialize logging: `Initialize-Logging -ShowLogs:$ShowLogs`.
  - Check cluster status: `Test-SystemAvailability -Structured`.
  - Test addon state: `Test-IsAddonEnabled -Addon ([PSCustomObject]@{Name = 'addonname'})`.
  - Wait for resources: `Wait-ForPodCondition -Condition Ready -Label 'app=...' -Namespace '...' -TimeoutSeconds 120`.
- Status scripts (optional) typically query deployments/CRDs; follow existing naming (`Get-Status.ps1`).
- Update scripts (optional) for version/config changes (`Update.ps1`).
New addon: copy a minimal existing one (e.g. `addons/autoscaling/`) and adjust manifest + scripts.

## 6. Go Code (CLI)
- Each command in `cmd/<name>` with its own `main.go` or cobra-style setup (inspect existing patterns before introducing new flags/roots).
  - CLI uses Cobra framework (`github.com/spf13/cobra`). See `cmd/k2s/main.go` for root command pattern.
  - Structured logging via `slog` with custom logger from `cmd/k2s/utils/logging`.
  - Exit codes defined in `internal/cli` (ExitCodeSuccess, ExitCodeFailure).
- **Provider architecture**: All platform-specific logic is behind provider interfaces in `internal/provider/`. Command handlers call `context.Providers().Cluster.Start(config)` etc. — never use `runtime.GOOS` or build-tagged files in command code.
- Shared functionality lives under `internal/...`. Reuse before creating duplicates.
  - Common packages: `cli`, `host`, `powershell`, `logging`, `json`, `yaml`, `os`, `terminal`, `windows`, `provider`, `setuporchestration`.
- Keep binaries buildable offline: avoid introducing network-time fetches at runtime.
- **Cross-compilation**: The CLI builds for both Windows and Linux. Use `GOOS=linux go build ./cmd/k2s` to verify.
- Build via `BuildGoExe.ps1` (or `bgo.cmd` shortcut): `bgo -ProjectDir "path/to/cmd" -ExeOutDir "path/to/bin"`, or use `bgow` (all Windows) / `bgol` (all Linux).

## 7. Build & CI Workflows
See `.github/workflows/` for canonical pipelines:
- `build-k2s-cli*.yml` builds Go CLI.
- `build-k2s-artifacts.yml` assembles offline package.
- `build-docs-next.yml` builds MkDocs site.
- `ci-reuse-checks.yml` SPDX/license compliance.
- `ci-unit-tests.yml` runs test suites (PowerShell / Go where applicable).
- Naming: workflow files use a category prefix (`build-`, `ci-`, `release-`, `repo-` for repository housekeeping). Keep the `name:` field in sync (e.g. `CI - Commitlint`).
When modifying build steps, mirror variables & caching patterns used in existing workflows.

## 8. Testing Strategy
- PowerShell: unit-like tests live in module folders or `test/*.ps1` (see `addons.module.unit.tests.ps1`). Prefer parameterized helper functions for testability.
- Go: standard `*_test.go` files under related package directories.
- Avoid flaking Hyper-V dependent tests in CI—mock or guard with environment checks.

## 9. Security & Offline
- Never introduce code that silently pulls images or packages at runtime without explicit user action—offline reproducibility is a core promise.
- Large artifacts (VHDX, rootfs tarballs, MSI, WindowsNodeArtifacts.zip) are excluded from delta content; maintain the skip list in one place.
- Always sanitize zip extraction targets (already implemented—follow that pattern for any new archival logic).

## 10. Logging & Diagnostics
- Prefix category tags in logs: `[DebPkg]`, `[Expand]`, `[Hash]`, `[StageCleanup]`, etc. Follow existing style for new subsystems.
- On guest operations: gather diagnostics when expected artifacts are missing instead of failing silently.

## 11. Adding New Automation
When adding a new packaging / diff feature:
1. Put core logic in `New-...Methods.ps1` helper file.
2. Reference via dot-sourcing from orchestrator script.
3. Reuse phase timing & logging helpers.
4. Update or create manifest JSON with new metadata fields (keep camelCase keys consistent).

## 12. Style & Quality
- Preserve existing file headers & SPDX identifiers.
- Do not rename public functions consumed by scripts unless updating all call sites.
- PSScriptAnalyzer: avoid automatic variable assignment, prefer approved verbs; add suppressions only with justification in a comment.

## 13. Typical Commands (Local Dev)
- **After fresh clone (mandatory)**: `bgow` — Go-built binaries are not committed to git; this builds all 10 Windows executables to their expected locations. Use `bgol` for Linux cross-compilation.
- Build CLI (Go): `go build ./cmd/k2s` (respect existing Go module).
  - Or use build shortcuts: `bgow` (all Windows executables), `bgol` (all Linux executables), `bgo` (builds k2s.exe only), `bgo -ProjectDir "..." -ExeOutDir "..."`.
  - Cross-compile for Linux: `bgol` or `GOOS=linux go build -o k2s ./cmd/k2s`.
- Run delta packaging: `powershell -File lib/scripts/windows/host/system/package/New-K2sDeltaPackage.ps1 ...`.
- Serve docs locally: `mkdocs serve` (ensure python + mkdocs installed).
- Test PowerShell modules: Execute unit test files like `addons.module.unit.tests.ps1` with Pester.
- Run all tests: `powershell -File test/execute_all_tests.ps1`.

## 14. When Unsure
Prefer searching existing examples (addon scripts, helper functions) before inventing new patterns. Keep new code incremental and testable.

---
If a needed pattern isn’t described here, surface a question in PR or propose a minimal extension and document it in this file.
