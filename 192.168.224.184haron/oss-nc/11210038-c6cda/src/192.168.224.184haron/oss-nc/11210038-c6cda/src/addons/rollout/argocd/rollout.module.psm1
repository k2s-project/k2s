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
