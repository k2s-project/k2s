# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"

Import-Module $infraModule, $nodeModule
Initialize-Logging

$logUseCase = 'Stop-System'
try {
    Write-Log "[$logUseCase] started"

    # --- Phase 1: Fast, critical operations (instant, no I/O risk) ---
    # These run first so that even if Windows kills us mid-cleanup, the most
    # important safeguards are already in place for the next boot.
    $kubeBinPath = Get-KubeBinPath
    if (Test-Path "$kubeBinPath\nssm.exe") {
        # Prevent flanneld from auto-starting on next boot. This is the single
        # most important operation: if flanneld starts before Start-System.ps1
        # it creates a transient cbr0 L2Bridge that causes a race condition.
        Write-Log "[$logUseCase] Setting flanneld to manual start to prevent auto-start on next boot"
        &"$kubeBinPath\nssm.exe" set flanneld Start SERVICE_DEMAND_START 2>&1 | Out-Null

        # Also prevent kubelet and kubeproxy from auto-starting into stale
        # network state. Start-System.ps1 will restore them to auto-start
        # after it has properly recreated the L2 bridge.
        Write-Log "[$logUseCase] Setting kubelet and kubeproxy to manual start"
        &"$kubeBinPath\nssm.exe" set kubelet Start SERVICE_DEMAND_START 2>&1 | Out-Null
        &"$kubeBinPath\nssm.exe" set kubeproxy Start SERVICE_DEMAND_START 2>&1 | Out-Null
    }

    # --- Phase 2: Stop networking services ---
    # Stop services before removing cbr0 to avoid them recreating it or holding
    # HNS resources that block removal.
    Write-Log "[$logUseCase] Stopping flanneld, kubeproxy and kubelet services"
    Stop-Service -Name 'flanneld' -Force -ErrorAction SilentlyContinue
    Stop-Service -Name 'kubeproxy' -Force -ErrorAction SilentlyContinue
    Stop-Service -Name 'kubelet' -Force -ErrorAction SilentlyContinue

    # --- Phase 3: HNS cleanup (slower, may fail under shutdown pressure) ---
    Write-Log "[$logUseCase] removing external switch with l2 bridge network"
    Write-Log "[$logUseCase] start hns in case it is not running"
    Start-Service -Name 'hns' -ErrorAction SilentlyContinue
    Write-Log "[$logUseCase] retrieving HNS networks"
    $hns = Get-HNSNetwork
    $hnsNames = $hns | Select-Object -ExpandProperty Name
    $logText = "[$logUseCase] HNS networks available: " + $hnsNames
    Write-Log $logText

    # Retry cbr0 removal up to 3 times — HNS can be transiently unavailable
    # during system shutdown.
    $cbr0Removed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $hnsToRemove = Get-HNSNetwork | Where-Object Name -Like '*cbr0*'
            if (-not $hnsToRemove) {
                Write-Log "[$logUseCase] no *cbr0* networks found (attempt $attempt)"
                $cbr0Removed = $true
                break
            }
            Write-Log "[$logUseCase] removing *cbr0* networks (attempt $attempt)"
            $hnsToRemove | Remove-HNSNetwork -ErrorAction SilentlyContinue
            $cbr0Removed = $true
            Write-Log "[$logUseCase] cbr0 network removed"
            break
        }
        catch {
            Write-Log "[$logUseCase] removing *cbr0* networks failed (attempt $attempt): $($_.Exception.Message)"
            if ($attempt -lt 3) {
                Start-Sleep -Seconds 1
            }
        }
    }
    if (-not $cbr0Removed) {
        Write-Log "[$logUseCase] WARNING: cbr0 removal failed after 3 attempts, Start-System.ps1 will handle cleanup on next boot"
    }

    # show the still existing HNS networks
    $hns = Get-HNSNetwork
    $hnsNames = $hns | Select-Object -ExpandProperty Name
    $logText = "[$logUseCase] HNS networks available: " + $hnsNames
    Write-Log $logText
    Write-Log "[$logUseCase] finished"
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
}
catch {
    Write-Log "[$logUseCase] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}
