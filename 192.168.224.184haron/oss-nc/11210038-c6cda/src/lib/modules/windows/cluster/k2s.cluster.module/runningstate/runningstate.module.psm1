# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$infraModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"

Import-Module $infraModule

function Get-IsWslRunning {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Name = $(throw 'Name not specified')
    )    

    Write-Log "detecting if WSL is running.."

    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $output = wsl -l --running
    [Console]::OutputEncoding = $prevEncoding

    foreach ($line in $output) {
        if ($line.Trim() -ne '' -and $line -match $Name) {
            Write-Log "WSL is running"
            return $true
        }
    }

    Write-Log "WSL not running"

    return $false
}

function Get-VmState {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = $(throw 'Name not specified')
    )
    return (Get-VM -Name $Name).State
}

function Get-IsVmRunning {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = $(throw 'Name not specified')
    )

    Write-Log "Checking if VM is running for Name='$Name'.."

    $vmState = Get-VmState -Name $Name

    Write-Log "Found VM state '$vmState'"

    return $vmState -eq [Microsoft.HyperV.PowerShell.VMState]::Running
}

function Get-RunningState {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SetupName = $(throw 'SetupName not specified')
    )
    if ($SetupName -ne 'k2s' -and $SetupName -ne 'BuildOnlyEnv') {
        throw "cannot get running state for invalid setup type '$SetupName'"
    }   

    Write-Log "Getting running state for SetupType='$SetupName'"

    $issues = [System.Collections.ArrayList]@()
    $allRunning = $true

    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
    $isWsl = Get-ConfigWslFlag

    if ($isWsl -eq $true) {
        Write-Log "WSL setup type"

        if ((Get-IsWslRunning -Name $controlPlaneNodeName) -ne $true) {
            $msg = "control-plane '$controlPlaneNodeName' not running (WSL)"
            Write-Log " $msg"
            $allRunning = $false
            $issues.Add($msg) | Out-Null
        }
        else {
            Write-Log "control-plane '$controlPlaneNodeName' running"
        }
    }
    else {
        Write-Log "not WSL setup type"

        if ((Get-IsVmRunning -Name $controlPlaneNodeName) -ne $true) {            
            $vmState = Get-VmState -Name $controlPlaneNodeName

            $msg = "control-plane '$controlPlaneNodeName' not running, state is '$vmState' (VM)"

            Write-Log "$msg"

            $allRunning = $false
            $issues.Add($msg) | Out-Null
        }
        else {
            Write-Log "control-plane '$controlPlaneNodeName' running"
        }
    }

    switch ($SetupName) {
        'k2s' {
            $linuxOnly = Get-ConfigLinuxOnly
            if ($linuxOnly) {
                Write-Log "Linux-only, no more checks needed"
                break
            }
            
            $servicesToCheck = 'flanneld', 'kubelet', 'kubeproxy'
            foreach ($service in $servicesToCheck) {
                Write-Log "checking '$service' service state.."

                if ((Get-Service -Name $service -ErrorAction SilentlyContinue).Status -ne 'Running') {
                    $msg = "'$service' not running (service)"

                    Write-Log "$msg"

                    $allRunning = $false
                    $issues.Add($msg) | Out-Null
                }
                else {
                    Write-Log "'$service' running"
                }
            }
        }
        Default { 
            Write-Log "no more state checks needed"
            break 
        }
    }

    Write-Log "returning with IsRunning='$allRunning' and Issues='$issues'"

    return @{IsRunning = $allRunning; Issues = $issues }
}

Export-ModuleMember -Function Get-RunningState, Get-IsVmRunning, Get-IsWslRunning
