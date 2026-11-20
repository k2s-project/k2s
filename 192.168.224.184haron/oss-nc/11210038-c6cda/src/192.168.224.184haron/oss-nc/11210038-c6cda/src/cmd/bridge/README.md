<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

### build the bridge
### Check latest common parts from: https://github.com/microsoft/windows-container-networking

#### build executable for windows 
### copy it to bin [Hardcoded c:\ws\k2s as an example]
bgo.cmd -ProjectDir "c:\ws\k2s\cmd\bridge" -ExeOutDir "c:\ws\k2s\bin\cni"

