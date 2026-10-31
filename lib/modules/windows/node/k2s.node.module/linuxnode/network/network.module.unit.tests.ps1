# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:modulePath = "$PSScriptRoot/network.module.psm1"
    $script:moduleName = (Import-Module $script:modulePath -PassThru -Force -DisableNameChecking).Name
}

Describe 'Remove-KubeSwitch' -Tag 'unit', 'ci', 'network' {
    Context 'When removing KubeSwitch' {
        It 'clears stale routes via the control-plane IP from PersistentStore and ActiveStore' {
            InModuleScope $moduleName {
                function Get-VM { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Get-VMSwitch { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-VMSwitch { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NetIPAddress { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Get-NetRoute { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NetRoute { param([Parameter(ValueFromRemainingArguments)]$Rest) }

                $script:ipControlPlane = '172.19.1.100'
                $script:queriedStores = [System.Collections.Generic.List[string]]::new()
                $script:removedRoutes = [System.Collections.Generic.List[string]]::new()

                Mock Write-Log {}
                Mock Get-VM { @() }
                Mock Get-VMSwitch { $null }
                Mock Remove-NetIPAddress {}
                Mock Get-NetRoute {
                    $script:queriedStores.Add($PolicyStore)
                    @(
                        [pscustomobject]@{ DestinationPrefix = '172.20.0.0/24'; NextHop = '172.19.1.100' },
                        [pscustomobject]@{ DestinationPrefix = '172.21.0.0/24'; NextHop = '172.19.1.100' },
                        [pscustomobject]@{ DestinationPrefix = '10.0.0.0/8'; NextHop = '10.0.0.1' }
                    )
                }
                Mock Remove-NetRoute {
                    process {
                        $script:removedRoutes.Add("$PolicyStore`:$($_.DestinationPrefix)->$($_.NextHop)")
                    }
                }

                Remove-KubeSwitch

                ($script:queriedStores -join ',') | Should -Be 'PersistentStore,ActiveStore'
                $script:removedRoutes.Count | Should -Be 4
                $script:removedRoutes | Should -Contain 'PersistentStore:172.20.0.0/24->172.19.1.100'
                $script:removedRoutes | Should -Contain 'PersistentStore:172.21.0.0/24->172.19.1.100'
                $script:removedRoutes | Should -Contain 'ActiveStore:172.20.0.0/24->172.19.1.100'
                $script:removedRoutes | Should -Contain 'ActiveStore:172.21.0.0/24->172.19.1.100'
            }
        }
    }
}
