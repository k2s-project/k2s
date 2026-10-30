# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:modulePath = "$PSScriptRoot/control-plane-node.module.psm1"
    $script:moduleName = (Import-Module $script:modulePath -PassThru -Force -DisableNameChecking).Name
}

Describe 'Start-ControlPlaneNodeOnNewVM KubeSwitch ordering' -Tag 'unit', 'ci', 'control-plane' {
    Context 'When recreating KubeSwitch on Hyper-V' {
        It 'starts the control plane VM before waiting on Set-InterfacePrivate to avoid NLA gateway resolution deadlock' {
            InModuleScope $moduleName {
                function Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
                function Get-ConfigWslFlag { $false }
                function Get-ControlPlaneNodeDefaultSwitchName { 'KubeSwitch' }
                function Set-IndexForDefaultSwitch {}
                function Get-ConfigControlPlaneNodeHostname { 'kubemaster' }
                function Stop-VirtualMachine { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-KubeSwitch {}
                function New-KubeSwitch {}
                function Connect-KubeSwitch {}
                function Connect-WorkerNodesToKubeSwitch { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Start-VirtualMachine { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Set-InterfacePrivate { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Add-DnsServer { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Set-RoutesToKubemaster {}
                function Wait-ForSSHConnectionToLinuxVMViaSshKey {}
                function Get-LoopbackAdapterCIDR { '' }
                function Get-NetIPInterface { [pscustomobject]@{ InterfaceAlias = 'vEthernet (KubeSwitch)'; AddressFamily = 'IPv4'; ifIndex = 42 } }
                function Set-NetIPInterface { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-TimeSync {}
                function Set-RoutesToLinuxWorkloads {}
                function Get-VirtualSwitchName { param($Name) "vEthernet ($Name)" }
                function netsh { param([Parameter(ValueFromRemainingArguments)]$Rest) }

                $script:callOrder = [System.Collections.Generic.List[string]]::new()

                Mock Write-Log {}
                Mock Get-CimInstance { [pscustomobject]@{ NumberOfLogicalProcessors = 8 } }
                Mock CheckKubeSwitchInExpectedState { $false }
                Mock Stop-VirtualMachine { $script:callOrder.Add('Stop-VirtualMachine') }
                Mock Remove-KubeSwitch { $script:callOrder.Add('Remove-KubeSwitch') }
                Mock New-KubeSwitch { $script:callOrder.Add('New-KubeSwitch') }
                Mock Connect-KubeSwitch { $script:callOrder.Add('Connect-KubeSwitch') }
                Mock Connect-WorkerNodesToKubeSwitch { $script:callOrder.Add('Connect-WorkerNodesToKubeSwitch') }
                Mock Start-VirtualMachine { $script:callOrder.Add('Start-VirtualMachine') }
                Mock Set-InterfacePrivate { $script:callOrder.Add("Set-InterfacePrivate:$InterfaceAlias") }
                Mock Add-DnsServer {}
                Mock Set-RoutesToKubemaster {}
                Mock Wait-ForSSHConnectionToLinuxVMViaSshKey { $script:callOrder.Add('Wait-ForSSHConnectionToLinuxVMViaSshKey') }
                Mock Get-LoopbackAdapterCIDR { '' }
                Mock Set-NetIPInterface {}
                Mock Invoke-TimeSync {}
                Mock Set-RoutesToLinuxWorkloads { $script:callOrder.Add('Set-RoutesToLinuxWorkloads') }
                Mock Get-VirtualSwitchName { 'vEthernet (KubeSwitch)' }
                Mock netsh {}

                Start-ControlPlaneNodeOnNewVM -DnsServers '8.8.8.8' -SkipHeaderDisplay

                $startVmIndex = $script:callOrder.IndexOf('Start-VirtualMachine')
                $firstSetPrivateIndex = $script:callOrder.IndexOf('Set-InterfacePrivate:vEthernet (KubeSwitch)')

                $startVmIndex | Should -BeGreaterThan -1
                $firstSetPrivateIndex | Should -BeGreaterThan $startVmIndex
            }
        }
    }
}
