<!--
SPDX-FileCopyrightText: © 2025 The K2s Authors
SPDX-License-Identifier: Apache-2.0
-->

## How to update the catalog file for *K2s*

Build all executables
``` 
del /Q c:\ws\k2s\build\catalog\k2s.cdf
del /Q c:\ws\k2s\build\catalog\k2s.cat
PackageInspector.exe scan C:\ws\k2s -out cat -cdfPath c:\ws\k2s\build\catalog\k2s.cdf -name c:\ws\k2s\build\catalog\k2s.cat -ca1 "K2s-Catalog"
```
