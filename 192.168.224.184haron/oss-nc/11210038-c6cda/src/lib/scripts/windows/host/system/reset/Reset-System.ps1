# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Resets system to the state before K2s installation

.DESCRIPTION
Resets system to the state before K2s installation

#>

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
Import-Module $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Output "Reset system"
& $PSScriptRoot\..\..\uninstall\Uninstall.ps1 | Out-Null
Write-Output "System reset successful!"
