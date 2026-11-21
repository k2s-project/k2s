# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables the SMB share addon.
.DESCRIPTION
Disables the SMB share addon.
.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Skips user confirmation if set to true and delete all data')]
    [switch] $Force = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Keep data on volumes')]
    [switch] $Keep = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$smbShareModule = "$PSScriptRoot\module\Smb-share.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"

Import-Module $infraModule, $smbShareModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

if ($Force -and $Keep) {
    $errMsg = 'Disable storage smb failed: Cannot use both Force and Keep parameters at the same time.'
    if ($EncodeStructuredOutput) {
        $err = New-Error -Severity Error -Code (Get-ErrCodeInvalidParameter) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if (-not $Force -and -not $Keep) {
    $answer = Read-Host 'Do you want to DELETE ALL DATA of the shared SMB folders? Otherwise, all data will be kept. (y/N)'
    if ($answer -eq 'y') {
        Write-Log 'DATA DELETION CONFIRMED. All data on the shared SMB folders will be deleted.' -Console
    }
    else {
        $Keep = $true
        Write-Log 'DATA WILL BE KEPT. No data on the shared SMB folders will be deleted.' -Console
    }
}

Write-Log "Disabling addon '$addonName'.."

$config = Get-AddonConfig -Name $addonName
if ($null -eq $config) {
    Write-Log ' No addon config found in setup config, using default addon config for disabling.'
}
else {
    $configPath = Get-StorageConfigPath

    Write-Log "  Applying storage configuration from global addon config and overwriting default storage config '$configPath'"
    $json = ConvertTo-Json $config.Storage -Depth 100 # no pipe to keep the array even for single storage config entry
    $json | Set-Content -Force $configPath -Confirm:$false
}

$err = (Disable-SmbShare -Keep:$Keep).Error

if ($err) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $err.Message -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}

# adapt other addons when storage addon is called
Update-Addons -AddonName $addonName