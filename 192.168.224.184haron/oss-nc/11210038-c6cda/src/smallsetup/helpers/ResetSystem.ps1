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
Param(

)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1


Write-Output 'Reset system'
&"$global:KubernetesPath\lib\scripts\windows\host\uninstall\uninstall.ps1" | Out-Null
&"$global:KubernetesPath\lib\scripts\windows\linuxonly\uninstall\uninstall.ps1" | Out-Null
&"$global:KubernetesPath\lib\scripts\windows\buildonly\uninstall\uninstall.ps1" | Out-Null
Write-Output 'System reset successful!'
