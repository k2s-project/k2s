# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables Prometheus/Grafana monitoring features for the k2s cluster.

.DESCRIPTION
The "monitoring" addons enables Prometheus/Grafana monitoring features for the k2s cluster.

#>
Param(
    [string] $InfraNodeSelector = '',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'Omit Grafana web UI; deploy only Prometheus, Alertmanager, and exporters')]
    [switch] $OmitGrafana,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$monitoringModule = "$PSScriptRoot\monitoring.module.psm1"
$dashboardModule = "$PSScriptRoot\..\dashboard\dashboard.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $monitoringModule

Initialize-Logging -ShowLogs:$ShowLogs

trap { if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $_.Exception.Message)}; return }; throw }
$ownerOptions = Get-AddonPlacementOwnerOptions -Name 'monitoring' -BoundParameters $PSBoundParameters -Defaults @{OmitGrafana = $OmitGrafana.IsPresent; Ingress = $Ingress}
$OmitGrafana = [switch]$ownerOptions.OmitGrafana
$Ingress = $ownerOptions.Ingress
$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector -Name 'monitoring' -Selector $InfraNodeSelector

if ($OmitGrafana) {
    Write-Log 'Enabling monitoring addon with --omitGrafana flag (Grafana web UI will not be deployed)' -Console
} else {
    Write-Log "K2s interacts with Grafana (AGPLv3) solely through its standard, public APIs; no AGPL-licensed code is incorporated or modified, and Grafana is deployed as a container. For this integration scenario, a copyleft assessment was performed with the conclusion that AGPLv3 copyleft obligations are not triggered for this specific scenario." -Console
    Write-Log "[Important] The AGPLv3 terms continue to apply to Grafana itself. Users must independently assess whether the AGPLv3 is appropriate for their use case." -Console
}

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'monitoring' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'monitoring' })) -eq $true) {
    $errMsg = "Addon 'monitoring' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ($InfraNodeSelector -and $Ingress -ne 'none') {
    throw 'Enable the requested ingress separately before enabling monitoring with infrastructure placement.'
}
if ($Ingress -ne 'none') {
        Enable-IngressAddon -Ingress:$Ingress
}

# Select kustomization based on OmitGrafana flag
if ($OmitGrafana) {
    $manifestsPath = "$PSScriptRoot\manifests\monitoring-no-grafana"
    Write-Log 'Installing Kube Prometheus Stack without Grafana (--omitGrafana)' -Console
} else {
    $manifestsPath = "$PSScriptRoot\manifests\monitoring"
    
    Write-Log 'Installing Kube Prometheus Stack' -Console
}

$crdsPath = "$PSScriptRoot\manifests\monitoring\crds"
$namespacePath = "$PSScriptRoot\manifests\monitoring\namespace.yaml"

$placement = $null
if ($InfraNodeSelector) {
    $placement = New-AddonPlacementInput -AddonName 'monitoring' -Path $manifestsPath -Selector $InfraNodeSelector -Kustomize
}

(Invoke-Kubectl -Params 'apply', '-f', $namespacePath).Output | Write-Log
# Use --server-side for CRDs to avoid oversized last-applied annotations on large CRDs
(Invoke-Kubectl -Params 'apply', '--server-side', '-f', $crdsPath).Output | Write-Log

# Wait for CRDs to be registered by the API server before clearing the discovery cache
Write-Log '[Monitoring] Waiting for Prometheus Operator CRDs to be fully established' -Console
$monCrdWait = Invoke-Kubectl -Params 'wait', '--for=condition=Established', 'crd/servicemonitors.monitoring.coreos.com', 'crd/prometheuses.monitoring.coreos.com', '--timeout=120s'
if ($monCrdWait.Success -ne $true) {
    Write-Log "[Monitoring] CRD wait output: $($monCrdWait.Output)" -Console
    Write-Log '[Monitoring] WARNING: Prometheus Operator CRDs may not be fully established' -Console
}

# Clear stale kubectl discovery cache and verify ServiceMonitor type is visible
Clear-KubectlDiscoveryCache
Write-Log '[Monitoring] Waiting for kubectl discovery cache to include Prometheus Operator CRDs' -Console
$monDiscoveryReady = $false
for ($d = 1; $d -le 30; $d++) {
    $probe = Invoke-Kubectl -Params 'get', 'servicemonitors', '--no-headers', '--ignore-not-found', '-A'
    if ($probe.Success -eq $true) {
        Write-Log '[Monitoring] kubectl discovery cache is up-to-date' -Console
        $monDiscoveryReady = $true
        break
    }
    Write-Log "[Monitoring] Discovery probe attempt $d/30 failed, retrying in 2s..." -Console
    Start-Sleep -Seconds 2
}
if (-not $monDiscoveryReady) {
    Write-Log '[Monitoring] WARNING: kubectl discovery cache did not refresh within 60s' -Console
}

if ($placement) {
    try {
        $addon = [pscustomobject]@{ Name = 'monitoring'; OmitGrafana = $OmitGrafana.IsPresent; Ingress = $Ingress; InfraNodeSelector = $InfraNodeSelector }
        Invoke-AddonEnableTransaction -Addon $addon -Selector $InfraNodeSelector -HasMatchingNodes $placement.HasMatchingNodes -Apply {
            Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-f', $placement.Path
        } -Wait {
            $controllers = Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'monitoring', '--timeout=600s'
            $prometheus = Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=prometheus' -Namespace 'monitoring' -TimeoutSeconds 600
            $alertmanager = Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=alertmanager' -Namespace 'monitoring' -TimeoutSeconds 600
            return ($controllers.Success -and $prometheus -and $alertmanager)
        } -Update { & "$PSScriptRoot\Update.ps1" -OmitGrafana:$OmitGrafana } -Rollback { [pscustomobject]@{ Success = $false; Output = 'Operator resources may remain; retry with the saved selector or disable monitoring.' } }
        (Invoke-Kubectl -Params 'apply', '-k', "$PSScriptRoot\..\common\manifests\windows-exporter").Output | Write-Log
        if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{Error = $null} }
        return
    }
    finally { Remove-Item -LiteralPath $placement.Path -Force -ErrorAction SilentlyContinue }
}
(Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-k', $manifestsPath).Output | Write-Log

Write-Log 'Deploying Windows Exporter for Windows node metrics' -Console
$windowsExporterPath = "$PSScriptRoot\..\common\manifests\windows-exporter"
(Invoke-Kubectl -Params 'apply', '-k', $windowsExporterPath).Output | Write-Log

Write-Log 'Waiting for Pods..'
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'monitoring', '--timeout=600s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Kube Prometheus Stack could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'monitoring', '--timeout=600s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Kube Prometheus Stack could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=alertmanager' -Namespace 'monitoring' -TimeoutSeconds 600)
if ($allPodsAreUp -ne $true) {
    $errMsg = "Alertmanager could not be deployed!"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1  
}

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/name=prometheus' -Namespace 'monitoring' -TimeoutSeconds 600)
if ($allPodsAreUp -ne $true) {
    $errMsg = "Prometheus could not be deployed!"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1  
}

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'monitoring', '--timeout=600s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Kube Prometheus Stack could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

&"$PSScriptRoot\Update.ps1" -OmitGrafana:$OmitGrafana

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'monitoring'; OmitGrafana = $OmitGrafana.IsPresent })

if (Test-Path $dashboardModule) {
    Import-Module $dashboardModule -Force
    if (Get-Command Sync-HeadlampPlugins -ErrorAction SilentlyContinue) {
        Write-Log '[Dashboard][Plugin] Syncing Headlamp plugins after monitoring enable' -Console
        try {
            Sync-HeadlampPlugins
        }
        catch {
            # Plugin sync is best-effort: a failure here must not fail the primary addon operation.
            Write-Log "[Dashboard][Plugin] Headlamp plugin sync failed (monitoring enable continues): $($_.Exception.Message)" -Console
        }
    }
}

if ($OmitGrafana) {
    Write-Log 'Kube Prometheus Stack installed successfully (without Grafana)'
} else {
    Write-Log 'Kube Prometheus Stack installed successfully'
    Write-UsageForUser
    Write-BrowserWarningForUser
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
