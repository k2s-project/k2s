# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    # windowsnode also contains a module named 'network.module', and other test files load both as
    # nested modules of k2s.node.module. InModuleScope/Mock -ModuleName resolve modules by name and
    # fail if the name is ambiguous, so run the test inside this exact module instance instead.
    $script:module = Import-Module "$PSScriptRoot/network.module.psm1" -PassThru -Force -DisableNameChecking
}

Describe 'Remove-KubeSwitch' -Tag 'unit', 'ci', 'network' {
    Context 'When removing KubeSwitch' {
        It 'clears stale routes via the control-plane IP from PersistentStore and ActiveStore' {
            & $script:module {
                function Get-VM { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Get-VMSwitch { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-VMSwitch { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NetIPAddress { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Get-NetRoute { [CmdletBinding()] param($AddressFamily, $PolicyStore) }
                function Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$InputObject, $PolicyStore) process {} }

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
                    $script:removedRoutes.Add("$PolicyStore`:$($InputObject.DestinationPrefix)->$($InputObject.NextHop)")
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
