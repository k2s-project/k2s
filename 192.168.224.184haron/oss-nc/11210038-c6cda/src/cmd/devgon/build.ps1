# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

&$PSScriptRoot\..\..\..\smallsetup\common\GlobalVariables.ps1

&$global:KubernetesPath\smallsetup\common\BuildGoExe.ps1 -ProjectDir "$global:KubernetesPath\cmd\devgon" -ExeOutDir "$global:KubernetesPath\bin"
