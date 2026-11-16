# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables the SMB share addon.
.DESCRIPTION
Enables the SMB share addon.
.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
.PARAMETER SmbHostType
Controls which host will expose the ContextFolder SMB share. Default: "windows".
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Controls which host will expose the ContextFolder SMB share. Default: "windows".')]
    [ValidateSet('windows', 'linux')]
    [string]$SmbHostType = 'windows',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$script = $MyInvocation.MyCommand.Name
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$smbShareModule = "$PSScriptRoot\module\Smb-share.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$validationModule = "$PSScriptRoot\..\storage-validation.module.psm1"

$addonName = 'storage'

Import-Module $infraModule, $smbShareModule, $addonsModule, $validationModule

Initialize-Logging -ShowLogs:$ShowLogs

# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

# Validate no conflicting storage implementation is enabled
$conflictError = Test-ConflictingStorageImplementation -RequestedImplementation 'smb'
if ($conflictError) {
    Write-Log "[$script] ERROR: $conflictError" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code 'storage-conflict' -Message $conflictError) }
        return
    }
    exit 1
}

if ($Config -ne $null -and $null -ne $Config.SmbHostType) {
    Write-Log "[$script] Using SMB host type '$($Config.SmbHostType)' from addon config" -Console
    $SmbHostType = $Config.SmbHostType
}
if ($Config -ne $null -and $null -ne $Config.Storage) {
    $configPath = Get-StorageConfigPath

    Write-Log "[$script] Applying storage configuration from global addon config and overwriting default storage config '$configPath'" -Console
    $json = ConvertTo-Json $Config.Storage -Depth 100 # no pipe to keep the array even for single storage config entry
    $json | Set-Content -Force $configPath -Confirm:$false
}

Write-Log "[$script] Enabling addon '$addonName' with SMB host type '$SmbHostType'.." -Console

$err = (Enable-SmbShare -SmbHostType $SmbHostType).Error

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