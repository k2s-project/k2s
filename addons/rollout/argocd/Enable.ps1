# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the rollout addons (ArgoCD) in the cluster

.DESCRIPTION
The rollout addons utilizes ArgoCD to provide the user with the possibility 
to automate the deployment of application based on Git repositories. The addon can 
either be used by directly accessing the argocd cli or using the exposed web interface.

.EXAMPLE
Enable rollout in k2s
powershell <installation folder>\addons\rollout\argocd\Enable.ps1

Enable rollout addon in k2s with ingress nginx addon
powershell <installation folder>\addons\rollout\argocd\Enable.ps1 -Ingress "nginx"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable Ingress-Nginx Addon')]
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'Deploy addon-sync infrastructure for GitOps addon delivery')]
    [switch] $AddonSync = $true,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nodeModule = "$PSScriptRoot/../../../lib\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $nodeModule, $rolloutModule

Initialize-Logging -ShowLogs:$ShowLogs
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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'rollout' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([PSCustomObject]@{Name = 'rollout'; Implementation = 'argocd'})) -eq $true) {
    $errMsg = "Addon 'rollout' with ArgoCD implementation is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })) -eq $true) {
    $errMsg = "Addon 'rollout fluxcd' is enabled. Disable it first to avoid conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$rolloutNamespace = 'rollout'

$VERSION_ARGOCD = 'v3.5.6'

Write-Log 'Creating rollout namespace'
(Invoke-Kubectl -Params 'create', 'namespace', $rolloutNamespace).Output | Write-Log

Write-Log 'Installing rollout addon' -Console
$rolloutConfig = Get-RolloutConfig
# Use --server-side to avoid the 256KB annotation size limit that client-side
# apply hits on large CRDs (e.g. applicationsets.argoproj.io).
(Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-n', $rolloutNamespace, '-k', $rolloutConfig).Output | Write-Log

Write-Log 'Waiting for pods being ready...' -Console

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', $rolloutNamespace, '--timeout=600s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'rollout addon could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', $rolloutNamespace, '--timeout=600s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'rollout addon (ArgoCD application controller) could not be deployed successfully'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

&"$PSScriptRoot\Update.ps1"

Write-Log 'Installation of rollout addon finished.' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'argocd' })

# Deploy addon-sync infrastructure for GitOps addon delivery (ArgoCD variant)
if ($AddonSync) {
    Write-Log 'Deploying addon-sync infrastructure for ArgoCD GitOps delivery' -Console
    $addonSyncArgocdPath = Join-Path $PSScriptRoot '..\..\common\manifests\addon-sync\argocd'
    $addonSyncArgocdPath = [System.IO.Path]::GetFullPath($addonSyncArgocdPath)

    if (Test-Path $addonSyncArgocdPath) {
        $kubectlCmd = Invoke-Kubectl -Params 'apply', '-k', $addonSyncArgocdPath
        $kubectlCmd.Output | Write-Log
        if (-not $kubectlCmd.Success) {
            $errMsg = "Failed to deploy addon-sync ArgoCD manifests from $addonSyncArgocdPath"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $errMsg -Error
            exit 1
        }

        # Patch K2S_INSTALL_DIR to the actual installation path using Get-KubePath.
        $kubePath = Get-KubePath
        $patchFile = Join-Path ([System.IO.Path]::GetTempPath()) 'addon-sync-installdir-patch.yaml'
        $patchContent = "data:`n  K2S_INSTALL_DIR: '$kubePath'"
        Set-Content -Path $patchFile -Value $patchContent -Encoding UTF8
        $kubectlCmd = Invoke-Kubectl -Params 'patch', 'configmap', 'addon-sync-config', '-n', 'k2s-addon-sync', '--type', 'merge', "--patch-file=$patchFile"
        $kubectlCmd.Output | Write-Log
        Remove-Item $patchFile -Force -ErrorAction SilentlyContinue
        if (-not $kubectlCmd.Success) {
            $errMsg = 'Failed to patch addon-sync-config with K2S_INSTALL_DIR'
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $errMsg -Error
            exit 1
        }
        Write-Log "K2S_INSTALL_DIR set to $kubePath" -Console
        Write-Log 'addon-sync-poller CronJob deployed — it will poll the registry every 5 minutes for new addon artifacts.' -Console
        Write-Log 'Infrastructure deployed successfully' -Console
        Write-Log 'Push an addon OCI artifact to the registry; the poller will detect it within 5 minutes and sync it to the K2s addons directory.' -Console
        Write-Log 'After the sync Job completes, run: k2s addons enable <name>' -Console
    } else {
        Write-Log "Warning: addon-sync ArgoCD manifests not found at $addonSyncArgocdPath" -Console
    }
} else {
    Write-Log 'Skipping addon-sync infrastructure deployment (--addon-sync=false)' -Console
}

Write-UsageForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
