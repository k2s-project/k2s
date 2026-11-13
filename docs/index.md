<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Home
[![ci](https://github.com/k2s-project/k2s/actions/workflows/ci-reuse-checks.yml/badge.svg)](https://github.com/k2s-project/k2s/actions/workflows/ci-reuse-checks.yml){target="_blank"}
[![ci](https://github.com/k2s-project/k2s/actions/workflows/ci-unit-tests.yml/badge.svg)](https://github.com/k2s-project/k2s/actions/workflows/ci-unit-tests.yml){target="_blank"}
[![ci](https://github.com/k2s-project/k2s/actions/workflows/build-k2s-cli.yml/badge.svg)](https://github.com/k2s-project/k2s/actions/workflows/build-k2s-cli.yml){target="_blank"}
[![ci](https://github.com/k2s-project/k2s/actions/workflows/build-k2s-artifacts.yml/badge.svg)](https://github.com/k2s-project/k2s/actions/workflows/build-k2s-artifacts.yml){target="_blank"}
[![ci](https://github.com/k2s-project/k2s/actions/workflows/build-docs-next.yml/badge.svg)](https://github.com/k2s-project/k2s/actions/workflows/build-docs-next.yml){target="_blank"}

## What is *K2s*?
*K2s* is a *Kubernetes* distribution which packages different open-source components into one small and easy to use solution focusing on running mixed *Windows*-based & *Linux*-based workloads in *Kubernetes*. 

This solution is installable on *Windows* hosts.

The name *K2s* comes from the fact that we start with the default setting of 2 *Kubernetes* nodes (*Windows* & *Linux*) and it relates to *K8s* as synonym for *Kubernetes*.

## Why *K2s*?
The problems that *K2s* solves are the following:

- It provides the option to construct a *K8s* cluster by reusing the *Windows* host as a node. This eliminates the need for an extra *Windows* license in the case of a mixed *Windows* & *Linux* cluster.
- Offline support is available for all use cases, eliminating the requirement for an internet connection.
- It offers an easy path for migrating bare metal *Windows* applications to *K8s* workloads.
- It maintains a low footprint by utilizing a single virtual machine for *Linux* workloads (*Hyper-V* or WSL).
- It is built 100% on open-source technology, requiring no additional licenses.

## Who uses *K2s*?
*K2s* is an open source project for mixed Windows and Linux Kubernetes workloads. Organizations using K2s may request inclusion in the [adopters list](https://github.com/k2s-project/k2s/blob/main/ADOPTERS.md).

## Quick Start
Get started [here](quickstart/index.md).

## Features
*K2s* includes the following features:

- Support of mixed *Windows* and *Linux* *Kubernetes* workloads
- Support for multiple *Windows* versions (e.g. 10, 11 and Server OS versions, see [Supported OS Versions](op-manual/os-support.md))
- Multiple network cards support, including support for LAN and *WI-FI* network interfaces
- Offline support by being able to operate the *K8s* cluster and workloads without internet connectivity
- [Building a Container Image](user-guide/building-container-image.md) for building and testing *Windows* and *Linux* containers
 [Rich Set of Addons](https://github.com/k2s-project/k2s/blob/main/addons/README.md){target="_blank"} which can be used optionally for additional functionality
- *K2*s supports different [Hosting Variants](user-guide/hosting-variants.md)
- Template-based setup of the different variants through configuration files
- Main configuration through central configuration file
- HTTP proxy support in entire functionality
- Debugging helpers for analyzing network connectivity
- Status information on cluster availability
- Helpers for setting up the *K8s* cluster for on-premises bare metal nodes and in the cloud using *Azure Kubernetes Service*
- Improved overall DNS support and extension possibilities with custom DNS servers
- Overall HTTP(S) extension support for intranet resources or custom locations 
- Acceptance tests for ensuring full functionality of the cluster

## Security
### Reporting a Vulnerability
The *K2s* project treats security vulnerabilities seriously, so we strive to take action quickly when required.

The project requests that security issues be disclosed in a responsible manner to allow adequate time to respond. If a security issue or vulnerability has been found, please use the [private security advisory form](https://github.com/k2s-project/k2s/security/advisories/new).

Please include as much information as possible with the report. The
following details assist with analysis efforts:

  - Description of the vulnerability
  - Affected component (version, commit, branch, etc.)
  - Affected code (file path, line numbers, etc.)
  - Exploit code

### Security Team
The security team currently consists of the *K2s* maintainers.