<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Governance

K2s is an open source project maintained by its contributor community. This document describes how the project is governed and how technical decisions are made.

## Project Scope

K2s is a Kubernetes distribution and lifecycle tool focused on mixed Windows and Linux workloads, offline operation, and practical Kubernetes usage in local, on-premises, edge, and regulated environments.

The project includes:

- The `k2s` CLI and related Go commands.
- Platform provider implementations for Windows and Linux hosts.
- PowerShell modules and scripts used for Windows host provisioning, lifecycle operations, addons, and packaging.
- Addon manifests, scripts, and Kubernetes resources.
- Offline packaging, addon export/import, node package, and delta package workflows.
- Documentation, tests, and release automation.

## Roles

### Contributors

Contributors are anyone who participates in the project through issues, pull requests, reviews, documentation, testing, design discussions, or user feedback.

### Maintainers

Maintainers have responsibility for reviewing contributions, making technical decisions, protecting project quality, and preparing releases. Current maintainers are listed in [MAINTAINERS.md](MAINTAINERS.md).

### Emeritus Maintainers

Emeritus maintainers are former active maintainers who are recognized for their contributions but are no longer expected to participate in day-to-day project work.

## Decision Making

K2s uses lazy consensus for most technical decisions:

1. A proposal is made through an issue, pull request, or maintainer discussion.
2. Maintainers and contributors have an opportunity to ask questions or raise concerns.
3. If no blocking objection is raised, the change may proceed after maintainer review.

For larger changes, maintainers may request a design discussion, prototype, test plan, documentation update, or staged implementation before accepting the change.

Blocking objections should be technical and should explain the risk, user impact, maintainability concern, security issue, or project-scope conflict.

## Contributions

Contributions follow the public GitHub pull request workflow documented in [docs/dev-guide/contributing/index.md](docs/dev-guide/contributing/index.md).

The project expects contributors to:

- Open or reference an issue for non-trivial changes.
- Keep changes focused and reviewable.
- Add or update tests when appropriate.
- Update documentation for user-visible behavior.
- Follow project licensing requirements and the REUSE specification.
- Respect the project [Code of Conduct](CODE_OF_CONDUCT.md).

## Releases

Releases are prepared by maintainers from the public repository. Release readiness is based on project state, CI results, documentation updates, packaging status, and maintainer judgment.

## Security

Security vulnerabilities should be reported according to [SECURITY.md](SECURITY.md). Security-sensitive issues may be handled privately until a fix or mitigation is available.

## Changes to Governance

Governance changes are made through pull requests and maintainer review. Significant governance changes should remain open long enough for maintainers and active contributors to review and comment.
