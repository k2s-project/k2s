<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Overview
This folder holds shared models used by both [`internal/core`](../core/README.md) and [`internal/providers`](../providers/README.md), e.g. config and user types. Putting them here lets `core` reference these types without depending on `providers` directly, avoiding an unwanted dependency (and import cycles) from domain logic onto concrete provider implementations.

## Folder structure
```
.
├── config --> K2s configuration model (host, control-plane, kubeconfig, SSH settings)
└── users  --> OS user model shared across user admission logic and providers
```
