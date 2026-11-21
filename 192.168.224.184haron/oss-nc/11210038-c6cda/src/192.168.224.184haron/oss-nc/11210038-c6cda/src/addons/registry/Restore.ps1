# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores the local container registry data

.DESCRIPTION
Restores the registry repository directory on the control plane VM from a tar.gz located in the staging folder.
The addon is enabled by the CLI before running this restore.

Restore is "overwrite" semantics: existing data in /registry/repository will be deleted before extraction.

.PARAMETER BackupDir
Directory containing backup.json and the referenced files.

.EXAMPLE
powershell <installation folder>\addons\registry\Restore.ps1 -BackupDir C:\Temp\registry-backup
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory containing backup.json and referenced files')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$manifestPath = Join-Path $BackupDir 'backup.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    $errMsg = "backup.json not found in '$BackupDir'"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json

Write-Log "[RegistryRestore] Restoring addon 'registry'" -Console

if (-not $manifest.files -or $manifest.files.Count -eq 0) {
    Write-Log "[RegistryRestore] backup.json contains no files; nothing to restore" -Console

    Write-Log "[RegistryRestore] Restore completed" -Console
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
    }
    return
}

$namespace = 'registry'
$statefulSetName = 'registry'

$tarFileName = 'registry-repository.tar.gz'
if (-not ($manifest.files -contains $tarFileName)) {
    $errMsg = "Backup does not contain required archive '$tarFileName'"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$localTarPath = Join-Path $BackupDir $tarFileName
if (-not (Test-Path -LiteralPath $localTarPath)) {
    $errMsg = "Backup archive not found in staging directory: $localTarPath"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$remoteRepoDir = '/registry/repository'
$remoteTarPath = '/tmp/registry-repository.tar.gz'

function Wait-ForNoRegistryPods {
    param(
        [Parameter(Mandatory = $false)]
        [int] $TimeoutSeconds = 120
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $pods = Invoke-Kubectl -Params 'get', 'pods', '-n', $namespace, '-l', 'app=registry', '-o', 'name'
        if (-not $pods.Success) {
            Start-Sleep -Seconds 2
            continue
        }

        $names = @($pods.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($names.Count -eq 0) {
            return $true
        }

        Start-Sleep -Seconds 2
    }

    return $false
}

try {
    if (-not (Get-Command -Name Copy-ToControlPlaneViaSSHKey -ErrorAction SilentlyContinue)) {
        throw 'Copy-ToControlPlaneViaSSHKey not available (vm module not imported)'
    }

    # Stop registry to avoid writing while restoring
    Write-Log "[RegistryRestore] Scaling registry StatefulSet to 0" -Console
    $scaleDown = Invoke-Kubectl -Params 'scale', 'statefulset', $statefulSetName, '-n', $namespace, '--replicas=0'
    if (-not $scaleDown.Success) {
        throw "Failed to scale down StatefulSet '$statefulSetName': $($scaleDown.Output)"
    }

    if ((Wait-ForNoRegistryPods -TimeoutSeconds 180) -ne $true) {
        Write-Log "[RegistryRestore] Warning: registry pods did not terminate in time; continuing restore" -Console
    }

    # Restore data on control plane
    Write-Log "[RegistryRestore] Copying archive to control plane" -Console
    Copy-ToControlPlaneViaSSHKey -Source $localTarPath -Target $remoteTarPath

    Write-Log "[RegistryRestore] Restoring registry repository on control plane" -Console
    $prepCmd = "sudo mkdir -p '$remoteRepoDir' && sudo find '$remoteRepoDir' -mindepth 1 -delete"
    $prepResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 60 -CmdToExecute $prepCmd -NoLog
    if (-not $prepResult.Success) {
        throw "Failed to prepare '$remoteRepoDir': $($prepResult.Output)"
    }

    $extractCmd = "sudo tar -xzf '$remoteTarPath' -C /registry"
    $extractResult = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 600 -CmdToExecute $extractCmd -NoLog
    if (-not $extractResult.Success) {
        throw "Failed to extract archive on control plane: $($extractResult.Output)"
    }

    # Optional: restore registry ConfigMap (best-effort; data restore must not fail because of this)
    $configCandidates = @('registry-config.json', 'registry-config.yaml')
    foreach ($configFile in $configCandidates) {
        if (-not ($manifest.files -contains $configFile)) {
            continue
        }

        $configPath = Join-Path $BackupDir $configFile
        if (-not (Test-Path -LiteralPath $configPath)) {
            continue
        }

        Write-Log "[RegistryRestore] Restoring ConfigMap 'registry-config'" -Console
        $apply = Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '--field-manager=k2s-addon-restore', '-f', $configPath
        if (-not $apply.Success) {
            Write-Log "[RegistryRestore] Warning: failed to apply '$configFile': $($apply.Output)" -Console
        }
        else {
            (Invoke-Kubectl -Params 'rollout', 'restart', 'statefulset', $statefulSetName, '-n', $namespace).Output | Write-Log
        }

        break
    }

    # Start registry again
    Write-Log "[RegistryRestore] Scaling registry StatefulSet to 1" -Console
    $scaleUp = Invoke-Kubectl -Params 'scale', 'statefulset', $statefulSetName, '-n', $namespace, '--replicas=1'
    if (-not $scaleUp.Success) {
        throw "Failed to scale up StatefulSet '$statefulSetName': $($scaleUp.Output)"
    }

    $rollout = Invoke-Kubectl -Params 'rollout', 'status', 'statefulset', $statefulSetName, '-n', $namespace, '--timeout=300s'
    Write-Log $rollout.Output
    if (-not $rollout.Success) {
        throw "Registry did not become ready in time: $($rollout.Output)"
    }
}
catch {
    $errMsg = "Restore of addon 'registry' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
finally {
    try {
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 5 -CmdToExecute "sudo rm -f '$remoteTarPath'" -NoLog | Out-Null
    }
    catch {
        # best-effort cleanup only
    }
}

Write-Log "[RegistryRestore] Restore completed" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
