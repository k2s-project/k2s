<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Getting K2s
*K2s* can be acquired in two different ways, depending on the intended use:

- [Option 1: Cloning Git Repository](#option-1-cloning-git-repository) for development of *K2s* or making use of the latest (potentially unstable) features. All dependencies get downloaded during the installation process.
- [Option 2: Downloading Official Release Package](#option-2-downloading-official-release-package) for e.g. use in development environments, test systems or production scenarios.

!!! note
    The target installation folder must fulfill the following requirements:

    - Folder name contains only:

          - Letters of the English alphabet (uppercase and lowercase)
          - Digits of the decimal system
          - Spaces
          - Special characters: `+`, `-`, `_` and `.`

    - No special folders (e.g. symbolic links) are allowed

!!! tip
    Due to legal/license considerations, *K2s* cannot provide a full offline installation package for e.g. air-gap scenarios out-of-the-box, but you can create one yourself locally, see [Creating an Offline Package](creating-offline-package.md).

## \[Option 1\] Cloning *Git* Repository
To clone the Git repository into a new folder of your choice, run:
```console
mkdir c:\myFolder; cd c:\myFolder
git clone https://github.com/k2s-project/k2s .
git checkout tags/v1.4.0
```

Go-built binaries (including `k2s.exe`) are **not committed** to the git repository. After cloning, you **must** build them before proceeding:

=== "Windows"
    ```console
    .\bin\bgow
    ```

=== "Linux"
    ```console
    ./bin/bgol
    ```

!!! warning
    Without this step, `k2s.exe` and supporting tools will be missing and *K2s* will not function.

Proceed with the installation, see [Installing *K2s*](installing-k2s.md).

## \[Option 2\] Downloading Official Release Package
Download the latest released and officially cleared *K2s* version from [*K2s* Releases](https://github.com/k2s-project/k2s/releases){target="_blank"}.
Please move the package to a folder on your drive from the windows downloads folder. 

!!! tip
    Please make sure to check *Unblock* in the file properties dialog before extracting the zip file (if this option is available):<br/>
    ![Unblock Zip Package](assets/UnblockZipPackage.png)

Extract the zip file to a target folder of your choice (e.g. `c:\target-dir`).
Remove the read-only attributes on the entire folder in an recursive way.
Proceed with the installation, see [Installing *K2s*](installing-k2s.md).

!!! warning
    It is recommended to install *K2s* to the *Windows* system drive (most likely `C:\`), because some 3rd-party components might assume that `C:\` is the *Windows* host's system drive, e.g. *Windows*-based containers running in *host mode*.

