# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the rollout addon (Flux CD) in the cluster

.DESCRIPTION
The rollout addon utilizes Flux CD to provide GitOps continuous delivery for Kubernetes.
Flux automatically syncs applications from Git repositories to the cluster.

.EXAMPLE
Enable rollout with Flux in k2s
powershell <installation folder>\addons\rollout\fluxcd\Enable.ps1

Enable rollout addon with Flux and ingress nginx
powershell <installation folder>\addons\rollout\fluxcd\Enable.ps1 -Ingress "nginx"
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
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nodeModule = "$PSScriptRoot/../../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"
$dashboardModule = "$PSScriptRoot\..\..\dashboard\dashboard.module.psm1"

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

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$Proxy = "http://$($windowsHostIpAddress):8181"

Write-Log 'Check if Flux is already enabled'
if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd'})) -eq $true) {
    $errMsg = 'Addon rollout with Flux implementation is already enabled, nothing to do.'

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'argocd' })) -eq $true) {
    $errMsg = "Addon 'rollout argocd' is enabled. Disable it first to avoid conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$manifestPath = "$PSScriptRoot\..\addon.manifest.yaml"
$k2sRoot = "$PSScriptRoot\..\..\.."
Install-FluxCli -ManifestPath $manifestPath -K2sRoot $k2sRoot -Proxy $Proxy

Write-Log 'Creating rollout namespace' -Console
(Invoke-Kubectl -Params 'create', 'namespace', 'rollout').Output | Write-Log

Write-Log 'Installing Flux addon' -Console
$kustomizationDir = Get-FluxConfig
(Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir).Output | Write-Log

Write-Log 'Waiting for Flux controllers to be ready...' -Console
(Invoke-Kubectl -Params 'wait', '--for=condition=available', '--timeout=180s', 'deployment', '--all', '-n', 'rollout').Output | Write-Log

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

&"$PSScriptRoot\Update.ps1"

Write-Log 'Installation of rollout addon with Flux finished.' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after Flux enable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (Flux enable continues): $($_.Exception.Message)" -Console
        }
    }
}

# Deploy addon-sync infrastructure for GitOps addon delivery
if ($AddonSync) {
    Write-Log 'Deploying addon-sync infrastructure for FluxCD GitOps delivery' -Console
    $addonSyncFluxcdPath = Join-Path $PSScriptRoot '..\..\common\manifests\addon-sync\fluxcd'
    $addonSyncFluxcdPath = [System.IO.Path]::GetFullPath($addonSyncFluxcdPath)

    if (Test-Path $addonSyncFluxcdPath) {
        $kubectlCmd = Invoke-Kubectl -Params 'apply', '-k', $addonSyncFluxcdPath
        $kubectlCmd.Output | Write-Log
        if (-not $kubectlCmd.Success) {
            $errMsg = "Failed to deploy addon-sync FluxCD manifests from $addonSyncFluxcdPath"
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
        Write-Log "Addon-sync K2S_INSTALL_DIR set to $kubePath" -Console

        Write-Log 'Addon-sync infrastructure deployed successfully' -Console
        Write-Log 'When addons are pushed to the OCI registry, Flux will detect changes' -Console
        Write-Log 'and sync addon layers into the K2s addons directory automatically.' -Console
        Write-Log 'Synced addons will appear in `k2s addons ls` and can be enabled normally.' -Console
    } else {
        Write-Log "Warning: addon-sync FluxCD manifests not found at $addonSyncFluxcdPath" -Console
    }
} else {
    Write-Log 'Skipping addon-sync infrastructure deployment (--addon-sync=false)' -Console
}

Write-Log 'Flux CD is now installed in the rollout namespace' -Console
Write-Log 'To use Flux, configure GitRepository and Kustomization CRDs' -Console
Write-Log 'Example: kubectl apply -f <your-flux-resources>.yaml' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
