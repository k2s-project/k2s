<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Overview
This folder holds *some* of K2s's domain logic: the rules and workflows that define *what* the system does, as opposed to *how* it talks to the outside world. Packages here orchestrate one or more [providers](../providers/README.md) and enforce business rules on top (validation, naming conventions, admission checks, config parsing).

Not all K2s domain logic lives here: this is not the single place to look for business rules; plenty of it is still scattered across other Go packages, PowerShell modules and scripts.

Most packages here follow IOSP (Integration Operation Segregation Principle): integration files wire together concrete [providers](../providers/README.md) directly and hold no logic of their own (and therefore no unit tests), while the actual rules sit in "leaf" operation functions/packages, which depend on narrow provider interfaces instead and are unit-tested.

## Folder structure
```
.
├── addons        --> addon manifest model, parsing and schema validation
├── clusterconfig --> cluster node configuration model
├── config        --> K2s setup/runtime configuration model
└── users         --> user access workflows for granting cluster access
```
