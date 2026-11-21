# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Manages kubelet certificate auto-rotation in the K2s cluster.
.DESCRIPTION
Enables, disables, or reports the current status of kubelet certificate auto-rotation.
When enabled, the kubelet automatically requests and picks up a new certificate before
the current one expires (at approximately 80% of its lifetime), without administrator
intervention.
.PARAMETER Enable
Enables kubelet certificate auto-rotation by setting rotateCertificates: true in the
kubelet configuration and restarting the kubelet service.
.PARAMETER Disable
Disables kubelet certificate auto-rotation by setting rotateCertificates: false in the
kubelet configuration and restarting the kubelet service.
.PARAMETER Status
Shows the current kubelet certificate auto-rotation configuration.
.EXAMPLE
PS> .\autorotation.ps1 -Enable
PS> .\autorotation.ps1 -Disable
PS> .\autorotation.ps1 -Status
#>

param (
    [parameter(Mandatory = $false, HelpMessage = 'Enables kubelet certificate auto-rotation.')]
    [switch] $Enable,

    [parameter(Mandatory = $false, HelpMessage = 'Disables kubelet certificate auto-rotation.')]
    [switch] $Disable,

    [parameter(Mandatory = $false, HelpMessage = 'Shows current kubelet certificate auto-rotation status.')]
    [switch] $Status,

    [Parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the logs are written into the console with more verbosity.')]
    [switch] $ShowLogs,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send the result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to true.')]
    [string] $MessageType
)

$infraModule =   "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$global:isControlPlaneStartedByMe = $false
$global:isControlPlaneSwitchCreatedByMe = $false
$global:isWsl = Get-ConfigWslFlag
$global:controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
$global:controlPlaneVMHostNameLower = $global:controlPlaneVMHostName.ToLower()
$global:controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName

$kubeletConfigPath = '/var/lib/kubelet/config.yaml'
$kubeletConfigBackupPath = '/var/lib/kubelet/config.yaml.autorotation.bak'

function Send-ErrorToCli {
    Param([string]$ErrorMessage)
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'certificate-autorotation-failure' -Message $ErrorMessage
        Send-ToCli -MessageType $MessageType -Message @{Error = $err}
        return
    }
    Write-Log $ErrorMessage -Error
}

function Start-ControlPlaneIfNotRunning {
    if ($global:isWsl) {
        if ((Get-IsWslRunning -Name $global:controlPlaneVMHostName) -ne $true) {
            Write-Log "Starting control plane WSL instance '$global:controlPlaneVMHostName'..."
            Start-WSL
            Wait-ForSSHConnectionToLinuxVMViaSshKey
            $global:isControlPlaneStartedByMe = $true
        }
    } else {
        if ((Get-IsVmRunning -Name $global:controlPlaneVMHostName) -ne $true) {
            Write-Log "Starting control plane VM '$global:controlPlaneVMHostName'..."
            $switchExists = Get-VMSwitch -Name "vEthernet($global:controlPlaneSwitchName)" -ErrorAction SilentlyContinue
            if (-not $switchExists) {
                Write-Log "vEthernet switch '$global:controlPlaneSwitchName' does not exist. Creating it..."
                New-KubeSwitch -Name $global:controlPlaneSwitchName
                Connect-KubeSwitch
                $global:isControlPlaneSwitchCreatedByMe = $true
            }
            Start-VM -Name $global:controlPlaneVMHostName
            Wait-ForSSHConnectionToLinuxVMViaSshKey
            $global:isControlPlaneStartedByMe = $true
        } else {
            Write-Log "Control plane VM '$global:controlPlaneVMHostName' is already running."
        }
    }
}

function Stop-ControlPlaneIfStartedByThisScript {
    if ($global:isWsl -and $global:isControlPlaneStartedByMe) {
        Write-Log "Stopping control plane WSL instance '$global:controlPlaneVMHostName' as it was started by the command..."
        wsl --shutdown
    }
    if ($global:isControlPlaneStartedByMe -and -not $global:isWsl) {
        Write-Log "Stopping control plane VM '$global:controlPlaneVMHostName' as it was started by the command..."
        Stop-VM -Name $global:controlPlaneVMHostName
    }
    if ($global:isControlPlaneSwitchCreatedByMe) {
        Write-Log "Removing vEthernet switch '$global:controlPlaneSwitchName' as it was created by the command..."
        Remove-KubeSwitch
    }
}

function Invoke-PatchKubeletConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Value   # 'true' or 'false'
    )
    # Step 1: backup kubelet config - only if the file already exists
    $existsResult = Invoke-CmdOnControlPlaneViaSSHKey "test -f $kubeletConfigPath && echo 'exists' || echo 'missing'" -IgnoreErrors
    $configExists = ($existsResult.Output | Where-Object { $_ -match 'exists' })

    if ($configExists) {
        $backupResult = Invoke-CmdOnControlPlaneViaSSHKey "sudo cp $kubeletConfigPath $kubeletConfigBackupPath" -IgnoreErrors
        $backupResult.Output | Write-Log
        if (-not $backupResult.Success) {
            throw "[AutoRotation] Failed to back up kubelet config before patching."
        }
    } else {
        Write-Log "[AutoRotation] Kubelet config file does not exist yet - will create it with rotateCertificates: $Value" -Console
    }

    # Step 2: patch using sed — single-line bash (no heredoc, SSH-safe)
    # Update existing key if present, otherwise append it
    # Use extended regex to handle optional whitespace around the colon (e.g. 'rotateCertificates :  true')
    $patchCmd = "if sudo grep -q 'rotateCertificates' $kubeletConfigPath; then sudo sed -i -E 's/rotateCertificates\s*:.*/rotateCertificates: $Value/' $kubeletConfigPath; else echo 'rotateCertificates: $Value' | sudo tee -a $kubeletConfigPath > /dev/null; fi"
    $patchResult = Invoke-CmdOnControlPlaneViaSSHKey $patchCmd -IgnoreErrors
    $patchResult.Output | Write-Log
    if (-not $patchResult.Success) {
        Write-Log "[AutoRotation] Patch failed. Restoring backup..." -Console
        (Invoke-CmdOnControlPlaneViaSSHKey "sudo cp $kubeletConfigBackupPath $kubeletConfigPath" -IgnoreErrors).Output | Write-Log
        throw "[AutoRotation] Failed to patch kubelet config. Backup restored."
    }

    # Step 3: restart kubelet
    Write-Log "[AutoRotation] Restarting kubelet service to apply the change..." -Console
    $restartResult = Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart kubelet' -IgnoreErrors
    $restartResult.Output | Write-Log
    if (-not $restartResult.Success) {
        throw "[AutoRotation] Failed to restart kubelet after patching config."
    }
}

function Get-KubeletAutoRotationStatus {
    Write-Log "[AutoRotation] Reading kubelet config from control plane node..." -Console

    # Verify config file exists before reading
    $checkResult = Invoke-CmdOnControlPlaneViaSSHKey "test -f $kubeletConfigPath && echo 'exists' || echo 'missing'" -IgnoreErrors
    if (-not $checkResult.Success -and -not ($checkResult.Output | Where-Object { $_ -match 'exists|missing' })) {
        throw "[AutoRotation] SSH connection to control plane node failed. Cannot read kubelet config."
    }
    if (($checkResult.Output | Where-Object { $_ -match 'missing' })) {
        Write-Log "[AutoRotation] Kubelet config file not found at $kubeletConfigPath" -Console
        return 'unknown (config file missing)'
    }

    # Single-line bash: check for enabled/disabled/absent — SSH-safe, no heredoc
    # Use flexible grep patterns to handle optional whitespace around the colon (e.g. 'rotateCertificates : true')
    $statusCmd = "if sudo grep -qE 'rotateCertificates\s*:\s*true' $kubeletConfigPath; then echo 'enabled'; elif sudo grep -q 'rotateCertificates' $kubeletConfigPath; then echo 'disabled'; else echo 'disabled (key not present)'; fi"
    $result = Invoke-CmdOnControlPlaneViaSSHKey $statusCmd -IgnoreErrors
    if (-not $result.Success -and -not ($result.Output | Where-Object { $_ -match 'enabled|disabled' })) {
        throw "[AutoRotation] SSH connection to control plane node failed. Cannot determine auto-rotation status."
    }
    $statusValue = ($result.Output | Where-Object { $_ -match 'enabled|disabled|unknown' } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($statusValue)) {
        $statusValue = 'disabled (key not present)'
    }
    Write-Log "[AutoRotation] Kubelet certificate auto-rotation is: $statusValue" -Console
    return $statusValue
}

function Enable-KubeletAutoRotation {
    Write-Log "[AutoRotation] Enabling kubelet certificate auto-rotation on control plane node..." -Console
    Invoke-PatchKubeletConfig -Value 'true'
    Write-Log "[AutoRotation] Kubelet certificate auto-rotation has been enabled." -Console
}

function Disable-KubeletAutoRotation {
    Write-Log "[AutoRotation] Disabling kubelet certificate auto-rotation on control plane node..." -Console
    Invoke-PatchKubeletConfig -Value 'false'
    Write-Log "[AutoRotation] Kubelet certificate auto-rotation has been disabled." -Console
}

$noErrorsOccurred = $true

try {
    Start-ControlPlaneIfNotRunning

    if ($Enable) {
        Enable-KubeletAutoRotation
    } elseif ($Disable) {
        Disable-KubeletAutoRotation
    } else {
        # Default: show status (also handles explicit -Status flag)
        Get-KubeletAutoRotationStatus | Out-Null
    }

    if ($EncodeStructuredOutput -and $noErrorsOccurred) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }
} catch {
    $errMsg = "An error occurred during certificate auto-rotation management: $_"
    Write-Log $errMsg -Error
    $noErrorsOccurred = $false
    if ($EncodeStructuredOutput) {
        Send-ErrorToCli -ErrorMessage $_.ToString()
    }
} finally {
    Stop-ControlPlaneIfStartedByThisScript
}
