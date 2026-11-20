# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs KEDA

.DESCRIPTION
NA

.EXAMPLE
# Enable autoscaling in K2s
powershell <installation folder>\addons\autoscaling\Enable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dashboardModule = "$PSScriptRoot\..\dashboard\dashboard.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$kedaManifest = "$PSScriptRoot\manifests\keda.yaml"

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'autocaling' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([PSCustomObject]@{Name = 'autoscaling'})) -eq $true) {
    $errMsg = "Addon 'autoscaling' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing KEDA' -Console

$applyResult = (Invoke-Kubectl -Params 'apply', '--server-side', '-f', $kedaManifest)
if (-not $applyResult.Success) {
    $errMsg = "Failed to apply KEDA manifests: $($applyResult.Output)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$applyResult.Output | Write-Log

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app=keda-operator' -Namespace 'autoscaling' -TimeoutSeconds 300)
if ($allPodsAreUp -ne $true) {
    $errMsg = "All KEDA pods could not become ready. Please use kubectl describe for more details.`nInstallation of keda failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1  
}

&"$PSScriptRoot\Update.ps1"

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'autoscaling' })

# sync Headlamp plugins - KEDA is now running
if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after autoscaling enable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (autoscaling enable continues): $($_.Exception.Message)" -Console
        }
    }
}

Write-Log 'Installation of autoscaling addon finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}

