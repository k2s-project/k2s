<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Overview
This folder contains *provider* packages: adapters (in the ports-and-adapters/hexagonal sense) that reach outside the system into its environment, e.g. the file system, OS users, SSH/SFTP connections, HTTP endpoints, `kubectl`/Kubernetes and kubeconfig files.

Each subfolder is one provider and should only contain the technical integration code needed to talk to that specific external dependency. Business/orchestration logic that uses a provider belongs elsewhere (e.g. `internal/core`), consuming providers through narrow interfaces rather than depending on their concrete types.

## Folder structure
```
.
├── acl         --> File ACL/permission handling
├── http        --> HTTP REST client functionality with TLS support
├── k8s         --> Kubernetes API access
├── kubeconfig  --> reading/writing kubeconfig files
├── kubectl     --> kubectl CLI invocation
├── osusers     --> OS user management
├── powershell  --> PowerShell execution bridge and script result handling
└── ssh         --> SSH connections and file copy/move over SFTP
...
```
