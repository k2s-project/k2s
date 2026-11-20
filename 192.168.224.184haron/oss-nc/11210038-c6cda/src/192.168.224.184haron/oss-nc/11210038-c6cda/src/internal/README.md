<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Overview
This folder contains all re-usable *Go* packages that cannot be referenced from outside this repo.

Even though they have interdependencies, the aim is to keep their coupling as low as possible.

Packages follow a layered architecture: `core` orchestrates domain logic using `contracts` and calls into `providers` through the `provider` interface abstraction. Platform-specific implementations live in build-tagged files (Windows/Linux) and provider adapters, while utility packages provide shared functionality across layers.

## Core & Architecture Packages

| Package      | Purpose                                                                                                                                                                                    |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `core/`      | Domain logic and workflows: cluster lifecycle, addons, config parsing, user management, admission rules — see [core/README.md](core/README.md)                                             |
| `contracts/` | Shared models (config, users) referenced by both `core` and `providers`, avoiding unwanted dependencies and import cycles — see [contracts/README.md](contracts/README.md)                 |
| `provider/`  | **Platform-agnostic provider interfaces** and build-tagged implementations for Windows and Linux. Commands use these interfaces exclusively — see [provider/README.md](provider/README.md) |
| `providers/` | Concrete adapter packages: Kubernetes, SSH, kubectl, kubeconfig utilities — see [providers/README.md](providers/README.md)                                                                 |

## Platform-Specific Packages

| Package                | Purpose                                                       |
| ---------------------- | ------------------------------------------------------------- |
| `setuporchestration/`  | Linux-native cluster provisioning (kubeadm, libvirt/KVM, SSH) |
| `windows/`             | Windows-specific utilities and native Go operations           |
| `linux/`               | Linux-specific utilities and native Go operations             |
| `containernetworking/` | Windows CNI bridge plugin logic                               |

## Utility & Support Packages

| Package        | Purpose                                                        |
| -------------- | -------------------------------------------------------------- |
| `cli/`         | Exit codes, structured result types, command execution helpers |
| `host/`        | Host OS detection and platform abstraction                     |
| `os/`          | OS-level utilities, file I/O, `StdWriter` interface            |
| `output/`      | Formatted output and display helpers                           |
| `terminal/`    | Terminal/console interaction utilities                         |
| `logging/`     | Centralized logging primitives                                 |
| `json/`        | JSON serialization/deserialization helpers                     |
| `yaml/`        | YAML parsing and generation utilities                          |
| `primitives/`  | Low-level data structure helpers                               |
| `version/`     | Version management and comparison                              |
| `definitions/` | Shared constant definitions and enums                          |

## Testing

| Package | Purpose                               |
| ------- | ------------------------------------- |
| `test/` | Shared testing utilities and fixtures |

## Dependency Analysis

The dependencies can be analyzed with *Go* tooling, e.g.:

- Install [*Goda*](https://github.com/loov/goda):
    ```sh
    go install github.com/loov/goda@latest
    ```
- Install [*Graphviz*](https://graphviz.org/download/#windows)
- Generate graph:
    ```sh
    goda graph github.com/k2s-project/k2s/internal/... | dot -Tsvg -o graph-internal.svg
    ```
