<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Windows Support Module
This module contains the currently supported Windows version from the [Supported OS Versions](../../../README.md#supported-os-versions) section in a machine-readable way for Windows-based image creation.

**K2s supports more Windows versions than K8s** (see [K2s: Supported OS Versions](../../../README.md#supported-os-versions) and [K8s: Windows OS version compatibility](https://kubernetes.io/docs/concepts/windows/intro/#windows-os-version-support)).

In order to keep that level of compatibility, the K2s registry provides the Windows-based images for 3rd-party tooling that does not provide the required Windows images officially.

> Additional reference: [List of Microsoft Windows versions](https://en.wikipedia.org/wiki/List_of_Microsoft_Windows_versions)

## Windows-based Images
To publish the images for 3rd-party tooling, the script [Build_Windows_Images.ps1](./Build_Windows_Images.ps1) can be used.

> See the script documentation for more options, especially when pushing to a local registry or other insecure instances.
> This script assumes that all necessary tools like Docker or nssm have been installed and configured correctly (e.g. via K2s installation).

<span style="color:orange;font-size:medium">**⚠**</span> The Windows host running this script must support the versions listed in [Windows-based Images](../../../smallsetup/ps-modules/windows-support/README.md#windows-based-images), otherwise Docker will not be able to pull all the Windows base images.

To apply new versions of the 3rd-party tooling, run the [Build_Windows_Images.ps1](./Build_Windows_Images.ps1) script with the newer versions and adapt the consuming manifest files accordingly.

<span style="color:orange;font-size:medium">**⚠**</span> **When retrying** the image and manifest creation for the same versions (i.e. tags) due to e.g. an error while running the [Build_Windows_Images.ps1](./Build_Windows_Images.ps1) script, **delete the local Docker images** (e.g. `docker rmi <image>`) **and the associated manifests** under `~\.docker\manifests` first.
