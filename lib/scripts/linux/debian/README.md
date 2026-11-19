<!--
SPDX-FileCopyrightText: © 2026 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

# Native Debian 13 Host Automation

`linuxonly/` contains the native Linux lifecycle entry points. They require root,
write lifecycle dispatch messages to `/var/log/k2s.log`, and invoke the installed
`k2s` CLI through `lib/modules/linux/cluster/lifecycle.sh`. `host/` delegates to
the same implementation to avoid a second native Linux lifecycle.

`ProvisionPackages.sh` is the native host boundary for version-pinned Debian
package provisioning. The Debian package assets remain under
`cfg/nodeextension/debian13/` because they are also consumed by Windows-host
Linux worker provisioning.

`worker/` is intentionally reserved for later native Linux worker automation.

`host/image/` and `host/addon/` contain the native counterparts of the Windows image and addon
scripts; the `k2s` CLI calls them for `k2s image ...` and `k2s addons export|import` on a Linux host.

For direct operational invocation, use the Linux-only entry points, for example:

```console
sudo ./lib/scripts/linux/debian/linuxonly/Install.sh --proxy http://proxy.example:8080
sudo ./lib/scripts/linux/debian/linuxonly/Stop.sh
sudo ./lib/scripts/linux/debian/linuxonly/Start.sh
sudo ./lib/scripts/linux/debian/linuxonly/Uninstall.sh
```
