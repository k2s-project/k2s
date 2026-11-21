<!--
SPDX-FileCopyrightText: © 2025 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# login servive providing login UI 
`login.exe` and `hydra.exe` are not tracked in Git. Create both in this folder before building the container image.

### build it
bgo.cmd -ProjectDir "c:\ws\k2s\cmd\login" -ExeOutDir "c:\ws\k2s\cmd\login"
### download hydra
.\DownloadandExtractHydra.ps1
### build container with k2s
k2s image build --windows --input-folder . --image-tag 1.0.0 -p
