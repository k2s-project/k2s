<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Licensing
K2s code and configuration are available under the Apache License, Version 2.0. New code contributions must be submitted under Apache-2.0 with a Developer Certificate of Origin sign-off. The complete requirements are defined in the [K2s Intellectual Property Policy](https://github.com/k2s-project/k2s/blob/main/IP_POLICY.md).

!!! warning
    **All files**, whether *own* code or 3rd-party code (i.e. *PowerShell*/*Go* snippets or configuration files like *yaml* manifests, etc.), have to be clearly marked with the respective license.

Third-party components under Apache-2.0 do not require additional license approval. Non-Apache-2.0 components must satisfy every CNCF allowlist requirement or receive an approved exception before inclusion. The currently supported/used 3rd-party licenses can be found in the [LICENSES](https://github.com/k2s-project/k2s/tree/main/LICENSES){target="_blank"} folder.

!!! warning
    **This repository follows the [REUSE Specification – Version 3.0](https://reuse.software/spec/){target="_blank"},** meaning that a valid license configuration must exist for every file, either **as comment or as separate \*.license file**.

The CI runs will check all files against the *REUSE* specification, but you can pre-check your local repo using the [reuse tool](https://github.com/fsfe/reuse-tool){target="_blank"}.