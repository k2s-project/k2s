<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Quick Start
1. [Get *K2s*](../op-manual/getting-k2s.md)
2. Verify that the [Prerequisites](../op-manual/installing-k2s.md#prerequisites) are fulfilled
3. If you cloned the *Git* repository, build the Go binaries first (they are not committed to git):
    ```console
    .\bin\bgow
    ```
4. Run as administrator in the installation/repository folder:
    ```console
    k2s.exe install
    ```
5. Check *K2s* cluster health:
    ```console
    k2s.exe status
    ```
6. Deploy your workloads :rocket:

See [*k2s* CLI](../user-guide/k2s-cli.md) and [CLI Shortcuts](../user-guide/cli-shortcuts.md) for more means to interact with the *K2s* cluster.

Optionally, install one or more [*K2s* Addons](https://github.com/k2s-project/k2s/blob/main/addons/README.md){target="_blank"} for additional functionality.

To create an offline installer first, check out [Creating Offline Package](../op-manual/creating-offline-package.md).