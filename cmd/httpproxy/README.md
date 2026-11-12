<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

### HTTP forward proxy to be used in small setup
#### build executable for windows [Hardcoded c:\ws\k2s as an example]
bgo.cmd -ProjectDir "c:\ws\k2s\cmd\httpproxy" -ExeOutDir "c:\ws\k2s\bin"

#### usage
At least one `--allowed-cidr` is required. Requests from source addresses outside these networks are rejected with `403 Forbidden` and logged; without any allowed network the proxy refuses to start.

```console
httpproxy.exe --allowed-cidr 172.20.0.0/16 --allowed-cidr 172.19.1.0/24 [--addr :8181] [--forwardproxy http://proxy.example:3128]
```
