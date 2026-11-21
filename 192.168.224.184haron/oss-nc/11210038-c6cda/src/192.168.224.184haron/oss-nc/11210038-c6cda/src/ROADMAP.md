<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Roadmap

This roadmap describes the current direction for K2s. It is intentionally high level; detailed planning happens through GitHub issues, pull requests, and release milestones.

## Project Direction

K2s aims to make Kubernetes practical for mixed Windows and Linux workloads, with strong support for offline, air-gapped, on-premises, edge, and regulated environments.

The project focuses on:

- A small and repeatable Kubernetes distribution for Windows and Linux workloads.
- A consistent `k2s` CLI for install, lifecycle, diagnostics, packaging, addons, and node operations.
- Offline-first workflows for installation, upgrades, addon delivery, and node onboarding.
- Curated integrations with common cloud native ecosystem components.
- Clear platform abstractions so Windows and Linux host behavior can evolve without fragmenting the CLI.

## Near-Term Goals

- Continue improving the default Windows-host variant, where the Windows host is reused as a Kubernetes worker node and Linux workloads run through Hyper-V or WSL.
- Mature the experimental Linux-host variant, where the control plane runs natively on Linux and an optional Windows worker VM can be provisioned through libvirt/KVM.
- Improve the provider architecture in `internal/provider` so platform-specific behavior stays behind well-defined interfaces.
- Strengthen offline installation packages, addon export/import, node packages, GPU-enabled node packages, and delta packages.
- Harden lifecycle operations such as install, upgrade, backup, restore, status, diagnostics, reset, and uninstall.
- Keep the addon catalog practical and curated for ingress, registry, monitoring, logging, GitOps rollout, storage, security, GPU support, KubeVirt, and selected domain-specific workloads.
- Increase automated test coverage for CLI behavior, packaging workflows, addons, and cross-platform logic.
- Improve contributor-facing governance, security, maintainer, adopter, and roadmap documentation.

## Longer-Term Goals

- Broaden community participation beyond the initial contributor base.
- Improve release transparency and public planning through milestones and issues.
- Continue improving governance, security handling, and project metadata for the public open source project.
- Continue reducing implementation duplication between Windows-specific PowerShell orchestration and shared Go/provider-based logic where this improves maintainability.
- Expand validated scenarios for air-gapped and edge environments.

## How to Influence the Roadmap

The best way to influence the roadmap is to open or comment on a GitHub issue:

```text
https://github.com/k2s-project/k2s/issues
```

For substantial changes, please discuss the proposal with maintainers before investing in a large implementation.
