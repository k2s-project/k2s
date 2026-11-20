# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Loop count')]
    [int] $Count,
    [parameter(Mandatory = $false, HelpMessage = 'Disable destruction of l2 bridge')]
    [switch] $CacheL2Bridge
)

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$infraModule = "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\lib\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
Import-Module $infraModule, $nodeModule
Initialize-Logging -ShowLogs:$true

# Create loopback adapter
Import-Module "$global:KubernetesPath\smallsetup\hns.v2.psm1" -WarningAction:SilentlyContinue -Force
New-LoopbackAdapter -Name $global:LoopbackAdapter -DevConExe $global:DevconExe | Out-Null

Start-Sleep 1

for ($i = 0; $i -lt $Count; $i++) {
    Write-Log "########################################################### $($i+1) ###########################################################"

    # create l2bridge
    Enable-NetAdapter -Name $global:LoopbackAdapter -Confirm:$false -ErrorAction SilentlyContinue
    Set-LoopbackAdapterProperties -Name $global:LoopbackAdapter -IPAddress $global:IP_LoopbackAdapter -Gateway $global:Gateway_LoopbackAdapter
    CreateExternalSwitch -adapterName $global:LoopbackAdapter

    $iteration = 10
    $loopbackAdapterFoundAfterL2BridgeCreation = $false
    while ($iteration -gt 0) {
        $iteration--
        Get-NetConnectionProfile -interfacealias "vEthernet ($global:LoopbackAdapter)" -ErrorAction SilentlyContinue
        if (!$?) {
            Write-Host "NetConnectionProfile 'vEthernet ($global:LoopbackAdapter)' not found! Retrying..."
            Start-Sleep 5
            continue
        } else {
            $loopbackAdapterFoundAfterL2BridgeCreation = $true
            Write-Host "NetConnectionProfile 'vEthernet ($global:LoopbackAdapter)' found !"
            break
        }
    }

    if ($iteration -eq 0 -and !$loopbackAdapterFoundAfterL2BridgeCreation) {
        throw "NetConnectionProfile 'vEthernet ($global:LoopbackAdapter)' not found after 5 minutes!"
    }

    # remove l2bridge
    if (!$CacheL2Bridge) {
        RemoveExternalSwitch
    }

    $hns = $(Get-HNSNetwork)
    if ($($hns | Measure-Object).Count -ge 2) {
        Write-Log 'Delete bridge, clear HNSNetwork (short disconnect expected)'

        if (!$CacheL2Bridge) {
            $hns | Where-Object Name -Like '*cbr0*' | Remove-HNSNetwork -ErrorAction SilentlyContinue
        }

        $hns | Where-Object Name -Like ('*' + $global:SwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
    }

    if (!$CacheL2Bridge) {
        Get-HnsPolicyList | Remove-HnsPolicyList -ErrorAction SilentlyContinue
    }
    Disable-NetAdapter -Name $global:LoopbackAdapter -Confirm:$false -ErrorAction SilentlyContinue
}

Remove-LoopbackAdapter -Name $global:LoopbackAdapter -DevConExe $global:DevconExe


