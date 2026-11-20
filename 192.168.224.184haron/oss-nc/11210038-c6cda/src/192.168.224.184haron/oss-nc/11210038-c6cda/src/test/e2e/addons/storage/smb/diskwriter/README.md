<!--
SPDX-FileCopyrightText: © 2024 The K2s Authors

SPDX-License-Identifier: Apache-2.0
-->

# Build the app
```sh
PS> .\build_app.ps1
```
The executable will be dropped to *.\dist* folder

# Test the app
| param    | default  |
| -------- | -------- |
| outfile  | out.file |
| interval | 1000     |

```sh
diskwriter.exe -outfile <out-file-path> -interval <interval-in-ms>
```
e.g.:
```sh
diskwriter.exe -outfile "test.file" -interval 2000
```

# Build the images
## Local Registry
```PowerShell
PS> C:\ws\k2s\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "diskwriter" -Tag "v0.1.0" -Registry "k2s.registry.local" -Dockerfile "C:\ws\k2s\test\e2e\addons\storage\smb\diskwriter\Dockerfile" -WorkDir "C:\ws\k2s\test\e2e\addons\storage\smb\diskwriter" -RegUser test -RegPw test -AllowInsecureRegistries
```

## PreDev Registry
```PowerShell
PS> C:\ws\k2s\smallsetup\ps-modules\windows-support\Build_Windows_Images.ps1 -Name "diskwriter" -Tag "v1.0.0" -Registry "shsk2s.azurecr.io" -Dockerfile "C:\ws\k2s\test\e2e\addons\storage\smb\diskwriter\Dockerfile" -WorkDir "C:\ws\k2s\test\e2e\addons\storage\smb\diskwriter" -RegUser <user> -RegPw <pw>
```
