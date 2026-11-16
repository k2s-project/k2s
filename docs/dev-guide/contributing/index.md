<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Contributing
## Contribution Requirements

All new code contributions must be made under the Apache License, Version 2.0 and include a Developer Certificate of Origin sign-off on every commit. Create a signed-off commit with `git commit -s`; see [Submitting Changes](submitting-changes.md) for details.

Review the [K2s Intellectual Property Policy](https://github.com/k2s-project/k2s/blob/main/IP_POLICY.md) before adding third-party content. It defines the licensing and provenance requirements for dependencies, vendored files, generated assets, and documentation.

## Contributing with code
The code is mainly written in *Go* and *PowerShell*. See [*PowerShell* Development](powershell-dev.md) for more information.

The codebase structure looks like the following:

```{.text .no-copy title=""}
├── addons      --> Addon(s)-specific configuration and PowerShell scripts
├── bin         --> Binaries (either committed to this repo or dropped as build target)
├── build
├── cfg         --> Configuration files
├── docs        --> Main documentation
├── k2s         --> Go-based sources
├── lib         --> PowerShell scripts
├── LICENSES
├── smallsetup  --> [legacy] PowerShell scripts; to be migrated to "lib"
├── test        --> Main test script(s)
├── ...
├── README.md
├── k2s.exe
├── VERSION
└── ...
```

1. [Clone the *Git* Repository](../../op-manual/getting-k2s.md#option-1-cloning-git-repository)
2. Make your changes locally, adhering to the [Licensing Obligations](licensing.md) and the K2s Intellectual Property Policy
3. [Build Locally](building-locally.md)
4. Create [Automated Tests](automated-testing.md) and execute them successfully
5. [Update the Documentation](updating-documentation.md)
6. [Submit your Changes](submitting-changes.md)