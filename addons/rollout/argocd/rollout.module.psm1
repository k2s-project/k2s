# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
Import-Module $infraModule, $clusterModule, $addonsModule

$AddonName = 'rollout'
$rolloutNamespace = 'rollout'

$binPath = Get-KubeBinPath

<#
.SYNOPSIS
Contains common methods for installing and uninstalling the rollout addon
#>

<#
.DESCRIPTION
Gets the location of manifests to deploy ArgoCD
#>
function Get-RolloutConfig {
    return "$PSScriptRoot\manifests\rollout\overlay"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml to expose the ArgoCD dashboard
#>
function Get-RolloutDashboardNginxConfig {
    return "$PSScriptRoot\manifests\rollout-nginx-ingress.yaml"
    
}

<#
.DESCRIPTION
Gets the location of traefik ingress yaml to expose the ArgoCD dasboard
#>
function Get-RolloutDashboardTraefikConfig {
    return "$PSScriptRoot\manifests\rollout-traefik-ingress.yaml"
    
}

<#
.SYNOPSIS
Creates a backup of the rollout addon data

.DESCRIPTION
Creates a backup of the rollout addon data

.PARAMETER BackupDir
Back-up directory to write data to (gets created if not existing)
#>
function Backup-AddonData {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to (gets created if not existing).')]
        [string]$BackupDir = $(throw 'Please specify the back-up directory.')
    )
    $BackupDir = "$BackupDir\$AddonName"

    if ((Test-Path $BackupDir) -ne $true) {
        Write-Log "  '$AddonName' backup dir not existing, creating it.."
        New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    }

    Write-Log "  Exporting the addon data to '$BackupDir' .."

    $argoExe = "$(Get-ClusterInstalledFolder)\bin\argocd.exe"
    &$argoExe admin export -n $rolloutNamespace > "$BackupDir\rollout-backup.yaml"

    Write-Log "  Addon data exported to '$BackupDir'."
}

<#
.SYNOPSIS
Restores the backup of the rollout addon data

.DESCRIPTION
Restores the backup of the rollout addon data

.PARAMETER BackupDir
Back-up directory to restore data from
#>
function Restore-AddonData {
    param (
        [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
        [string]$BackupDir = $(throw 'Please specify the back-up directory.')
    )
    $BackupDir = "$BackupDir\$AddonName"

    if ((Test-Path $BackupDir) -ne $true) {
        Write-Log "  '$AddonName' backup dir not existing, skipping."
        return
    }

    Write-Log "  Importing the addon data from '$BackupDir' .."
    $argoExe = "$binPath\argocd.exe"
    Get-Content -Raw "$BackupDir\rollout-backup.yaml" | &$argoExe admin import -n rollout -
    Write-Log "  Imported the addon data from '$BackupDir'."
    # Delete the backup since it contains the user credentials
    Remove-Item -Path "$BackupDir\rollout-backup.yaml" -Force -ErrorAction SilentlyContinue
}
function Write-UsageForUser {
    @"
                                        USAGE NOTES
 To open rollout dashboard, please use one of the options:
 
 Option 1: Access via ingress
 Please install either ingress nginx addon or ingress traefik addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable rollout
 k2s addons enable rollout
 The rollout dashboard will be accessible on the following URL: https://k2s.cluster.local/rollout

 Option 2: Port-forwading
 Use port-forwarding to the rollout dashboard using the command below:
 kubectl -n rollout port-forward svc/argocd-server 8080:443
 
 In this case, the rollout dashboard will be accessible on the following URL: https://localhost:8080/rollout
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

function Get-SafeJsonProperty {
    param(
        [Parameter(Mandatory = $false)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string] $PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Update-RolloutServiceMesh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $Namespace = 'rollout',

        [Parameter(Mandatory = $false)]
        [switch] $ForceRestart
    )

    $enhancedSecurityEnabled = Test-LinkerdServiceAvailability

    $currentInject = $null
    $currentSkipOutbound = $null
    $annotationsInspected = $false

    $nsAnnotations = $null
    $nsResult = Invoke-Kubectl -Params 'get', 'namespace', $Namespace, '-o', 'json'
    if ($nsResult.Success -and -not [string]::IsNullOrWhiteSpace(($nsResult.Output -join "`n"))) {
        try {
            $nsObj = ($nsResult.Output -join "`n") | ConvertFrom-Json
            $metadata = Get-SafeJsonProperty -Object $nsObj -PropertyName 'metadata'
            $nsAnnotations = Get-SafeJsonProperty -Object $metadata -PropertyName 'annotations'
            $currentInject = Get-SafeJsonProperty -Object $nsAnnotations -PropertyName 'linkerd.io/inject'
            $currentSkipOutbound = Get-SafeJsonProperty -Object $nsAnnotations -PropertyName 'config.linkerd.io/skip-outbound-ports'
            $annotationsInspected = $true
        }
        catch {
            Write-Log "[Rollout] Failed to parse namespace '$Namespace' JSON: $($_.Exception.Message)"
        }
    }

    # marker persisted on the namespace until all workload restarts succeeded, so a partially failed run is retried
    $restartPendingAnnotation = 'k2s.io/rollout-restart-pending'
    $restartPending = $null -ne (Get-SafeJsonProperty -Object $nsAnnotations -PropertyName $restartPendingAnnotation)

    $needsRestart = $ForceRestart.IsPresent -or -not $annotationsInspected -or $restartPending
    $argoServerPatched = $false

    # Inspect the actual pods so that a restart missed by a previous partially failed run is still performed.
    $podsMatchMeshState = $false
    $podsResult = Invoke-Kubectl -Params 'get', 'pods', '-n', $Namespace, '-o', 'json'
    if ($podsResult.Success -and -not [string]::IsNullOrWhiteSpace(($podsResult.Output -join "`n"))) {
        try {
            $podsObj = ($podsResult.Output -join "`n") | ConvertFrom-Json
            $podsMatchMeshState = $true
            foreach ($pod in @($podsObj.items)) {
                $podMeta = Get-SafeJsonProperty -Object $pod -PropertyName 'metadata'
                if ($null -ne (Get-SafeJsonProperty -Object $podMeta -PropertyName 'deletionTimestamp')) { continue }

                # only pods of Deployments/StatefulSets are restarted below, so other pods (e.g. Jobs) are not compared
                $ownerKinds = @(@(Get-SafeJsonProperty -Object $podMeta -PropertyName 'ownerReferences') | Where-Object { $null -ne $_ } | ForEach-Object { Get-SafeJsonProperty -Object $_ -PropertyName 'kind' })
                if ($ownerKinds -notcontains 'ReplicaSet' -and $ownerKinds -notcontains 'StatefulSet') { continue }

                $podStatus = Get-SafeJsonProperty -Object $pod -PropertyName 'status'
                $podPhase = Get-SafeJsonProperty -Object $podStatus -PropertyName 'phase'
                if ($podPhase -ne 'Running' -and $podPhase -ne 'Pending') { continue }
                $podAnnots = Get-SafeJsonProperty -Object $podMeta -PropertyName 'annotations'
                if ((Get-SafeJsonProperty -Object $podAnnots -PropertyName 'linkerd.io/inject') -eq 'disabled') { continue }
                $podSpec = Get-SafeJsonProperty -Object $pod -PropertyName 'spec'
                # linkerd-proxy runs in initContainers when native sidecar mode is enabled
                $podContainers = @(@(Get-SafeJsonProperty -Object $podSpec -PropertyName 'containers') + @(Get-SafeJsonProperty -Object $podSpec -PropertyName 'initContainers')) | Where-Object { $null -ne $_ }
                $hasProxy = $null -ne ($podContainers | Where-Object { (Get-SafeJsonProperty -Object $_ -PropertyName 'name') -eq 'linkerd-proxy' } | Select-Object -First 1)
                if ($hasProxy -ne $enhancedSecurityEnabled) {
                    $podsMatchMeshState = $false
                    break
                }
            }
        }
        catch {
            Write-Log "[Rollout] Failed to parse pods JSON in namespace '$Namespace': $($_.Exception.Message)"
            $podsMatchMeshState = $false
        }
    }
    if (-not $podsMatchMeshState) {
        $needsRestart = $true
    }

    if ($enhancedSecurityEnabled) {
        if (-not $annotationsInspected -or $currentInject -ne 'enabled' -or $currentSkipOutbound -ne '8181') {
            Write-Log '[Rollout] Updating rollout addon to be part of service mesh'
            $r1 = Invoke-Kubectl -Params 'annotate', 'namespace', $Namespace, 'linkerd.io/inject=enabled', '--overwrite'
            $r1.Output | Write-Log
            if (-not $r1.Success) { Write-Log "[Rollout] Warning: failed to set linkerd.io/inject annotation on namespace '$Namespace'" }

            $r2 = Invoke-Kubectl -Params 'annotate', 'namespace', $Namespace, 'config.linkerd.io/skip-outbound-ports=8181', '--overwrite'
            $r2.Output | Write-Log
            if (-not $r2.Success) { Write-Log "[Rollout] Warning: failed to set config.linkerd.io/skip-outbound-ports annotation on namespace '$Namespace'" }

            $needsRestart = $true
        }
        else {
            Write-Log "[Rollout] Namespace '$Namespace' is already part of service mesh; skipping workload restart"
        }

        if (Test-NginxGatewayAvailability) {
            $serverNeedsPatch = $true
            $serverResult = Invoke-Kubectl -Params 'get', 'deployment', 'argocd-server', '-n', $Namespace, '-o', 'json'
            if ($serverResult.Success -and -not [string]::IsNullOrWhiteSpace(($serverResult.Output -join "`n"))) {
                try {
                    $serverObj = ($serverResult.Output -join "`n") | ConvertFrom-Json
                    $spec = Get-SafeJsonProperty -Object $serverObj -PropertyName 'spec'
                    $template = Get-SafeJsonProperty -Object $spec -PropertyName 'template'
                    $templateMeta = Get-SafeJsonProperty -Object $template -PropertyName 'metadata'
                    $podAnnotations = Get-SafeJsonProperty -Object $templateMeta -PropertyName 'annotations'
                    $serverInject = Get-SafeJsonProperty -Object $podAnnotations -PropertyName 'linkerd.io/inject'
                    $serverSkipInbound = Get-SafeJsonProperty -Object $podAnnotations -PropertyName 'config.linkerd.io/skip-inbound-ports'
                    if ($serverInject -eq 'enabled' -and $serverSkipInbound -eq '8080') {
                        $serverNeedsPatch = $false
                    }
                }
                catch {
                    Write-Log "[Rollout] Failed to parse deployment 'argocd-server' JSON: $($_.Exception.Message)"
                }
            }

            if ($serverNeedsPatch) {
                Write-Log '[Rollout] Configuring Linkerd to skip inbound port 8080 for nginx-gw BackendTLSPolicy' -Console
                $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/skip-inbound-ports\":\"8080\"}}}}}'
                $patchRes = Invoke-Kubectl -Params 'patch', 'deployment', 'argocd-server', '-n', $Namespace, '-p', $annotations
                $patchRes.Output | Write-Log
                if (-not $patchRes.Success) { Write-Log "[Rollout] Warning: failed to patch deployment 'argocd-server' in namespace '$Namespace'" }
                $argoServerPatched = $true
            }
        }
    }
    else {
        if (-not $annotationsInspected -or $null -ne $currentInject -or $null -ne $currentSkipOutbound) {
            Write-Log '[Rollout] Updating rollout addon to not be part of service mesh'
            $r1 = Invoke-Kubectl -Params 'annotate', 'namespace', $Namespace, 'linkerd.io/inject-'
            $r1.Output | Write-Log
            if (-not $r1.Success) { Write-Log "[Rollout] Warning: failed to remove linkerd.io/inject annotation from namespace '$Namespace'" }

            $r2 = Invoke-Kubectl -Params 'annotate', 'namespace', $Namespace, 'config.linkerd.io/skip-outbound-ports-'
            $r2.Output | Write-Log
            if (-not $r2.Success) { Write-Log "[Rollout] Warning: failed to remove config.linkerd.io/skip-outbound-ports annotation from namespace '$Namespace'" }

            $needsRestart = $true
        }
        else {
            Write-Log "[Rollout] Namespace '$Namespace' is already excluded from service mesh; skipping workload restart"
        }

        $serverResult = Invoke-Kubectl -Params 'get', 'deployment', 'argocd-server', '-n', $Namespace, '-o', 'json'
        if (-not $serverResult.Success -or [string]::IsNullOrWhiteSpace(($serverResult.Output -join "`n"))) {
            throw "Failed to read deployment 'argocd-server' in namespace '$Namespace' to remove Linkerd annotations"
        }
        try {
            $serverObj = ($serverResult.Output -join "`n") | ConvertFrom-Json
            $spec = Get-SafeJsonProperty -Object $serverObj -PropertyName 'spec'
            $template = Get-SafeJsonProperty -Object $spec -PropertyName 'template'
            $templateMeta = Get-SafeJsonProperty -Object $template -PropertyName 'metadata'
            $podAnnotations = Get-SafeJsonProperty -Object $templateMeta -PropertyName 'annotations'
            $serverInject = Get-SafeJsonProperty -Object $podAnnotations -PropertyName 'linkerd.io/inject'
            $serverSkipInbound = Get-SafeJsonProperty -Object $podAnnotations -PropertyName 'config.linkerd.io/skip-inbound-ports'
        }
        catch {
            throw "Failed to parse deployment 'argocd-server' JSON: $($_.Exception.Message)"
        }

        # an explicit 'disabled' value is an operator opt-out and must be preserved
        $removeInject = ($null -ne $serverInject) -and ($serverInject -ne 'disabled')
        if ($removeInject -or $null -ne $serverSkipInbound) {
            Write-Log '[Rollout] Removing Linkerd pod annotations from deployment argocd-server'
            $annotationPatch = @()
            if ($removeInject) { $annotationPatch += '\"linkerd.io/inject\":null' }
            if ($null -ne $serverSkipInbound) { $annotationPatch += '\"config.linkerd.io/skip-inbound-ports\":null' }
            $clearAnnotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{' + ($annotationPatch -join ',') + '}}}}}'
            $patchRes = Invoke-Kubectl -Params 'patch', 'deployment', 'argocd-server', '-n', $Namespace, '-p', $clearAnnotations
            $patchRes.Output | Write-Log
            if (-not $patchRes.Success) { throw "Failed to remove Linkerd annotations from deployment 'argocd-server'" }
            $argoServerPatched = $true
        }
    }

    if ($needsRestart) {
        $markerSet = Invoke-Kubectl -Params 'annotate', 'namespace', $Namespace, "$restartPendingAnnotation=true", '--overwrite'
        if (-not $markerSet.Success) { Write-Log "[Rollout] Warning: failed to set restart-pending marker on namespace '$Namespace'" }

        $restartFailed = $false
        $rd = Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', '-n', $Namespace
        $rd.Output | Write-Log
        if (-not $rd.Success) {
            $restartFailed = $true
            Write-Log "[Rollout] Warning: failed to restart deployments in namespace '$Namespace'"
        }

        $rs = Invoke-Kubectl -Params 'rollout', 'restart', 'statefulset', '-n', $Namespace
        $rs.Output | Write-Log
        if (-not $rs.Success) {
            $restartFailed = $true
            Write-Log "[Rollout] Warning: failed to restart statefulsets in namespace '$Namespace'"
        }

        if ($restartFailed) {
            if ($ForceRestart.IsPresent) {
                throw "Failed to restart workloads in namespace '$Namespace'"
            }
        }
        else {
            $markerCleared = Invoke-Kubectl -Params 'annotate', 'namespace', $Namespace, "$restartPendingAnnotation-"
            if (-not $markerCleared.Success) { Write-Log "[Rollout] Warning: failed to remove restart-pending marker from namespace '$Namespace'" }
        }

        (Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', $Namespace, '--timeout', '60s').Output | Write-Log
        (Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', '-n', $Namespace, '--timeout', '60s').Output | Write-Log
    }
    elseif ($argoServerPatched) {
        (Invoke-Kubectl -Params 'rollout', 'status', 'deployment', 'argocd-server', '-n', $Namespace, '--timeout', '60s').Output | Write-Log
    }
}
