<!--
SPDX-FileCopyrightText: © 2025 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# AI Coding Assistant Project Instructions (K2s)

These instructions make an AI agent immediately productive in this repository. Keep responses concise, apply these conventions automatically, and prefer concrete edits (not vague advice).

## 0. Required Reading (Sources of Truth)

Read the relevant document before changing architecture, layout, providers, or tooling. If code and documentation disagree, the code is authoritative — fix the documentation in the same change.

| Topic | Document |
|-------|----------|
| Overall architecture, provider pattern, bundled tools, module/script layout | [`docs/dev-guide/architecture.md`](../docs/dev-guide/architecture.md) |
| Go package layering under `internal/` | [`internal/README.md`](../internal/README.md) |
| Provider interfaces, Linux capability status | [`internal/provider/README.md`](../internal/provider/README.md) |
| Local builds (Windows and Linux) | [`docs/dev-guide/contributing/building-locally.md`](../docs/dev-guide/contributing/building-locally.md) |
| Tests, tags/labels | [`docs/dev-guide/contributing/automated-testing.md`](../docs/dev-guide/contributing/automated-testing.md), [`tags-labels.md`](../docs/dev-guide/contributing/tags-labels.md) |
| PowerShell development | [`docs/dev-guide/contributing/powershell-dev.md`](../docs/dev-guide/contributing/powershell-dev.md) |
| Linux host development | [`docs/dev-guide/contributing/linux-development/linux-development.md`](../docs/dev-guide/contributing/linux-development/linux-development.md) |
| Hosting variants and feature support | [`docs/dev-guide/hosting-variants-features-matrix.md`](../docs/dev-guide/hosting-variants-features-matrix.md) |
| Commits, PRs, licensing | [`docs/dev-guide/contributing/submitting-changes.md`](../docs/dev-guide/contributing/submitting-changes.md), [`licensing.md`](../docs/dev-guide/contributing/licensing.md) |

## 1. Big Picture

K2s is a dual-platform Kubernetes distribution supporting both Windows and Linux hosts, with strong offline support.

- **Windows host (default)**: bundles a Linux control-plane VM (Hyper-V or WSL 2, CRI-O) plus a Windows worker on the host (containerd). Setup variants: `k2s` (mixed OS), `--linux-only`, `--wsl`, and `buildonly`.
- **Linux host (experimental, Debian 13)**: runs the control plane natively (CRI-O) and optionally provisions a Windows worker VM via libvirt/KVM. The Linux provider registry prints an `[EXPERIMENTAL]` warning on every invocation — keep it until the feature is promoted.

The repository delivers:
- The `k2s` CLI (Go, Cobra) — the single user-facing entry point. Built as `k2s.exe` (Windows) and `k2s` (Linux) from the same sources via build tags.
- A provider layer (`internal/provider/`) that hides all platform-specific logic behind domain interfaces.
- Windows automation: PowerShell scripts and modules (`lib/scripts/windows/`, `lib/modules/windows/`, `smallsetup/`).
- Native Linux automation: Bash scripts and modules (`lib/scripts/linux/debian/`, `lib/modules/linux/`).
- An addon system (`addons/`), offline packaging (full and delta), and a MkDocs documentation site (`docs/`, `mkdocs.yml`).

## 2. Key Directories

All Go code is a single module (`github.com/k2s-project/k2s`, see `go.mod`) rooted at the repository root — there is no separate `k2s/` source folder.

- `cmd/k2s/` CLI: `main.go`, commands in `cmd/k2s/cmd/<command>/` (addons, image, install, node, start, status, stop, system, uninstall, version), shared command code in `cmd/k2s/cmd/common/`, logging in `cmd/k2s/utils/logging/`.
- `cmd/<tool>/` supporting executables (`httpproxy`, `vfprules`, `bridge`, `l4proxy`, `cplauncher`, `devgon`, `cloudinitisobuilder`, `yaml2json`, `zap`) and container-image components (`pause`, `login`, `clusterip-webhook`, `linkerdinit`, `linkerdproxyidentity`).
- `internal/` shared Go packages (see `internal/README.md`):
  - `provider/` platform-agnostic interfaces + build-tagged `*_windows.go` / `*_linux.go` implementations.
  - `core/`, `contracts/` domain logic and shared models; `providers/` adapters (`powershell`, `bash`, `kubectl`, `k8s`, `ssh`, `kubeconfig`, `http`, `acl`, `osusers`).
  - `linux/lifecycle/` dispatcher from the Linux cluster provider to Bash lifecycle scripts.
  - `setuporchestration/` Linux libvirt/KVM helpers (templates, VM management); lifecycle orchestration itself is Bash-owned.
  - `healthcheck/`, `effectiveconfig/`, `cli/` (exit codes), `output/`, `logging/`, `host/`, `os/`, `json/`, `yaml/`, `primitives/`, `version/`, `definitions/`, `windows/`, `containernetworking/`, `test/`.
- `lib/modules/windows/<ownership>/k2s.*.module/` PowerShell modules: `infra/k2s.infra.module`, `cluster/k2s.cluster.module`, `node/k2s.node.module`, `common/k2s.signing.module`.
- `lib/modules/linux/{common,infra,cluster,node,networking,services}/` Bash modules.
- `lib/scripts/windows/host/system/package/` full/delta packaging (`New-K2sPackage.ps1`, `New-K2sDeltaPackage.ps1`, `New-K2sNodePackage.ps1` plus dot-sourced helper files).
- `lib/scripts/control-plane/` control-plane Install/Start/Stop/Uninstall scripts; `lib/manifests/` cluster manifests.
- `addons/` addon definitions and shared addon modules (`addons.module.psm1`, …).
- `smallsetup/` Windows host bootstrap (loopback adapter, HNS, kubeadm flags) and `common/BuildGoExe.ps1`.
- `bin/` command shortcuts (`bgo.cmd`, `bgow.cmd`, `bgol.cmd`, `k.cmd`, …) and build output for Go tools (`bin/`, `bin/cni/`). Never modify or rewrite vendored third-party binaries.
- `cfg/` runtime configuration and templates (`config.json`, `containerd/`, `cni/`, `kubeadm/`, `libvirt/`, `applocker/`, `nodeextension/<os>/`).
- `build/` BOM and catalog metadata used for reproducibility and signing.
- `test/` test runner (`execute_all_tests.ps1`), e2e suites, layout checks.
- `docs/` MkDocs sources (user guide, operator manual, developer guide, security, troubleshooting).

### Platform-First Automation Layout

Treat the following locations as an enforced repository contract:

- Windows scripts: `lib/scripts/windows/{host,linuxonly,buildonly,worker}/`
- Windows modules: `lib/modules/windows/{common,infra,cluster,node}/`
- Native Debian 13 scripts: `lib/scripts/linux/debian/{host,linuxonly,worker}/` (`worker/bare-metal/Add.sh` joins Debian 13 amd64/arm64 worker nodes for `k2s node add`)
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

## 3. Go Code (CLI)

- Cobra framework (`github.com/spf13/cobra`); root command in `cmd/k2s/cmd/cmd.go`. Inspect existing commands before adding flags or subcommands.
- Structured logging via `log/slog` with the custom setup in `cmd/k2s/utils/logging`. Exit codes in `internal/cli` (`ExitCodeSuccess`, `ExitCodeFailure`).
- **Provider architecture** (details in `docs/dev-guide/architecture.md`):
  - `provider.NewRegistry(...)` is created in `PersistentPreRunE` and exposed through `CmdContext`. Command handlers call `context.Providers().<Domain>.<Method>(config)`.
  - Domains: `Cluster`, `Image`, `Node`, `System`, `Addon`. Interfaces live in `internal/provider/<domain>.go`.
  - **Never** use `runtime.GOOS` checks or build-tagged files in command handler code; put platform differences into `<domain>_windows.go` / `<domain>_linux.go`.
  - Windows implementations call PowerShell scripts via `powershell.ExecutePsWithStructuredResult` (`internal/providers/powershell`); scripts answer via `Send-ToCli`.
  - Linux lifecycle (install/start/stop/uninstall/reset) goes through `lifecycle.Execute` (`internal/linux/lifecycle`) to Bash scripts with a `0600` JSON `--operation-file`. Never put secrets into that file — scripts read credentials themselves. Status, addons, health checks, backup, and certificates are Go-native.
  - Unsupported operations return `provider.NotSupportedError(operation, reason)` (matches `provider.ErrNotSupported` via `errors.Is`).
  - Adding a domain or method: update the interface, both implementations, both `registry_*.go` factories, `internal/provider/README.md`, and `docs/dev-guide/architecture.md`.
- Reuse shared functionality under `internal/` before creating new helpers. Respect the layering `cmd` → `core` → `provider`/`providers`, with shared models in `contracts`; avoid import cycles (see `ps_result_windows.go`).
- Keep binaries buildable and runnable offline: no network fetches at runtime.
- **Cross-compilation is mandatory**: verify `GOOS=windows go build ./cmd/k2s` and `GOOS=linux go build ./cmd/k2s` when touching shared or provider code.
- New Go files start with the SPDX header:
  ```go
  // SPDX-FileCopyrightText: © <current year> The K2s Authors
  // SPDX-License-Identifier: Apache-2.0
  ```

## 4. PowerShell Conventions (Windows)

- All logging goes through `k2s.infra.module` (`Initialize-Logging`, `Write-Log`, `Write-ErrorMessage`). Don't use `Write-Host` directly in new code.
  - `Write-Log "message" -Console` logs to file + console; `Write-Log "message"` logs to file only.
  - Tag log messages with bracketed category prefixes: `Write-Log "[DebPkg] Processing packages"`.
- Scripts invoked by the CLI support `-EncodeStructuredOutput` / `-MessageType` and report results with `Send-ToCli`; create errors with `New-Error` and the `Get-ErrCode*` helpers from the `errors` submodule.
- Reusable logic goes into helper `.ps1` files or module functions; keep orchestration scripts thin.
- Long phases are wrapped with `Start-Phase` / `Stop-Phase` (see `New-K2sDelta.Phase.ps1`).
- Avoid assigning to automatic variables (`$args`, `$input`, …). Use explicit names (`$sshParams`, `$scpParams`).
- Hyper-V / guest interactions must clean up resources (switch, NAT, VM) even on error.
- Secrets: new code accepts `SecureString` or `PSCredential` (legacy plain strings exist — don't proliferate).
- Quote paths passed to external tools (e.g. `kubectl delete -f "$path"`).
- PSScriptAnalyzer: approved verbs, no automatic-variable assignment; suppressions only with a justification comment.

## 5. Bash Conventions (Native Linux)

- Entry scripts in `lib/scripts/linux/debian/` use `#!/usr/bin/env bash`, `set -euo pipefail`, resolve `K2S_INSTALL_DIR` relative to the script, then `source` the needed modules from `lib/modules/linux/`.
- Modules are include-guarded (`K2S_<NAME>_SH_LOADED`) and expose `k2s_`-prefixed functions. Reuse `common/logging.sh` (`k2s_log`, `k2s_log_command_failure`, …), `common/validation.sh` (`k2s_require_root`, `k2s_require_command`, …), `common/paths.sh`, and `common/command.sh` instead of ad-hoc code.
- Worker-node join (`k2s node add` on Linux) runs `worker/bare-metal/Add.sh` with `lib/modules/linux/node/worker-node.module.sh`; it mirrors the Windows `worker-node.module.psm1` flow and requires an offline node package.
- Lifecycle scripts are root-only and log to `/var/log/k2s.log` (`K2S_LOG_FILE`).
- `host/` lifecycle entry points delegate to `linuxonly/`; do not create a second lifecycle implementation.

## 6. Addon Pattern

Each addon folder (`addons/<name>/`, optionally with implementation subfolders) contains:
- `addon.manifest.yaml` conforming to `addons/addon.manifest.schema.json`.
- `Enable.ps1` / `Disable.ps1` applying manifests under `manifests/` via kubectl/helm.
  - Import standard modules: `$clusterModule`, `$infraModule`, `$addonsModule` (template: `addons/autoscaling/Enable.ps1`).
  - `Initialize-Logging -ShowLogs:$ShowLogs`; check the cluster with `Test-SystemAvailability -Structured`.
  - Check state with `Test-IsAddonEnabled -Addon ([PSCustomObject]@{Name = '<name>'})`.
  - Wait for readiness with `Wait-ForPodCondition -Condition Ready -Label 'app=...' -Namespace '...' -TimeoutSeconds 120`.
  - Report errors via `Send-ToCli` when `-EncodeStructuredOutput` is set.
- Optional: `Get-Status.ps1`, `Update.ps1`, `Backup.ps1`, `Restore.ps1`, `EnableForRestore.ps1`, `README.md`.
- New addon: copy a minimal existing one (e.g. `addons/autoscaling/`) and adjust manifest and scripts. On Linux hosts, addons are handled by the Go `linuxAddonProvider`; check its support before assuming parity.

## 7. Delta Packaging Pattern

- Orchestrator: `lib/scripts/windows/host/system/package/New-K2sDeltaPackage.ps1`, which dot-sources focused helpers `New-K2sDelta.<Area>.ps1` (`Phase`, `IO`, `Hash`, `Skip`, `Validation`, `Staging`, `Mandatory`, `Manifest`, `Signing`, `Debian`, `HyperV`, `Diff`, `ImageDiff`, `ImageAcquisition`, `GuestConfig`). Add new logic to the matching helper (or a new `New-K2sDelta.<Area>.ps1` registered in the orchestrator), not to the orchestrator.
- Extraction: `Expand-ZipWithProgress` (`k2s.infra.module/archive`) with path sanitization and traversal prevention.
- Hashing: `Get-FileMap` (`New-K2sDelta.Hash.ps1`) builds maps of `{ Hash; Size }` (lower-case SHA-256).
- Skip lists live in one place: `Get-DefaultSkipLists` in `New-K2sDelta.Skip.ps1` (large artifacts such as VHDX, MSI, archives, plus cluster-specific config). Extend it there.
- Debian diff: boot a temporary VM from the KubeMaster VHDX → SSH → `dpkg-query` → Added/Removed/Changed; offline acquisition via `Invoke-GuestDebAcquisition`.
- Staging output includes `delta-manifest.json` (camelCase keys) and optionally `debian-delta/*`.

## 8. Build & CI Workflows

See `.github/workflows/`. Naming uses a category prefix (`build-`, `ci-`, `release-`, `repo-`) and the `name:` field mirrors it (e.g. `CI - Commitlint`).
- `build-k2s-cli.yml`, `build-k2s-cli-pr.yml`, `build-vfprules-cli.yml` — Go builds.
- `build-k2s-artifacts.yml` — offline package; `build-docs-next.yml` — MkDocs site.
- `ci-unit-tests.yml` — unit tests; `ci-windows-cluster.yml`, `ci-linux-cluster.yml`, `ci-linux-cluster-node-arm64.yml`, `ci-arm64-*` — cluster/node integration.
- `ci-reuse-checks.yml` — SPDX/REUSE compliance; `ci-commitlint.yml` — conventional commits.
- `release-version.yml`, `repo-*` — release and repository housekeeping.
Mirror existing variables and caching patterns when modifying workflows.

## 9. Testing Strategy

- Run everything via `powershell -File test/execute_all_tests.ps1` (Pester via `Start-PesterTests`, Go via `Start-GinkgoTests`), filtered with `-Tags` / `-ExcludeTags` (e.g. `-Tags unit`).
- Go: Ginkgo/Gomega suites (`*_suite_test.go` with `RunSpecs(t, "...", Label("unit", "ci", ...))`) next to the code. Put helper functions after the `Describe` blocks (mock methods are exempt).
- PowerShell: Pester tests as `*.unit.tests.ps1` next to the module/script under test, tagged (`unit`, `ci`, …).
- Add only focused tests for new or fixed behaviour. Guard Hyper-V/VM/cluster-dependent tests with tags (e.g. `setup-required`) so CI does not flake.

## 10. Documentation

- Document at the **`k2s` CLI level** (e.g. `k2s system package`, `k2s addons enable`); PowerShell/Bash scripts are implementation details. Ensure the documented CLI command exists or is planned.
- Use `console` blocks for CLI examples; `powershell` / `bash` blocks only for shell-specific operations.
- New pages must be added to the `nav` in `mkdocs.yml`; keep relative links valid (MkDocs validation warns on broken links and anchors).
- Keep `docs/dev-guide/architecture.md`, `internal/provider/README.md`, and this file in sync with the code when changing providers, layout, bundled tools, or build tooling.

## 11. Security & Offline

- Never pull images or packages at runtime without explicit user action — offline reproducibility is a core promise.
- Large artifacts (VHDX, rootfs tarballs, MSI, WindowsNodeArtifacts.zip) are excluded from delta content; maintain the skip list only in `Get-DefaultSkipLists`.
- Always sanitize archive extraction targets (follow `Expand-ZipWithProgress`).
- Never log or persist credentials; on Linux, lifecycle operation files must remain non-secret.

## 12. Logging & Diagnostics

- Prefix log categories in brackets: `[DebPkg]`, `[Expand]`, `[Hash]`, `[StageCleanup]`, `[System]`, `[Node]`, etc. Follow existing style for new subsystems (Go `slog` messages included).
- On guest operations, gather diagnostics when expected artifacts are missing instead of failing silently.

## 13. Style, Commits & Pull Requests

- Preserve existing file headers and SPDX identifiers. New files need an SPDX header with the current year; files that cannot hold comments get a sibling `<file>.license`.
- Do not rename public functions consumed by scripts unless all call sites are updated.
- Commit messages and PR titles follow [Conventional Commits](https://www.conventionalcommits.org/) (enforced by commitlint), e.g. `docs: ...`, `fix(addons): ...`.
- Use the PR template (`.github/pull_request_template.md`): `Fixes #`, Motivation, Modifications, Verification. Open PRs as draft until builds are green.

## 14. Typical Commands (Local Dev)

- **After a fresh clone (mandatory)**: Go-built binaries are not committed.
  - Windows: `bgow` builds all 10 Windows executables (`k2s.exe` to the root, tools to `bin/` and `bin/cni/`).
  - Linux: `./build.sh` or `make build` builds `k2s` plus `cloudinitisobuilder`, `httpproxy`, `yaml2json` and a pinned `dnsproxy` into `bin/` — no PowerShell needed.
- Single build: `bgo` (k2s.exe only) or `bgo -ProjectDir "cmd\<tool>" -ExeOutDir "bin"`; cross-compile for Linux from Windows with `bgol`.
- Verify both targets: `GOOS=windows go build ./cmd/k2s` and `GOOS=linux go build ./cmd/k2s`.
- Go unit tests: `ginkgo --label-filter="unit" <dir>` or `go test ./internal/<pkg>/...`.
- All tests: `powershell -File test/execute_all_tests.ps1 -Tags unit`.
- Layout check (Bash): `bash test/native-linux-layout.sh`.
- Delta packaging: `k2s system package --delta-package ...` (see `docs/op-manual/delta-packages.md`).
- Docs: `mkdocs serve` (Python + MkDocs required).

## 15. When Unsure

Search existing examples (addon scripts, providers, helper modules) before inventing new patterns. Keep changes incremental and testable. If a needed pattern isn't described here, raise it in the PR and propose a minimal extension to this file.
