# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:modulePath = "$PSScriptRoot/worker-node.module.psm1"
    $script:moduleName = (Import-Module $script:modulePath -PassThru -Force -DisableNameChecking).Name
}

# The functions under test call commands defined in imported sub-modules
# (e.g. common-setup.module) that are not directly resolvable inside
# InModuleScope at test time. Each test injects lightweight function stubs
# into the module scope right before mocking them, so Pester's Mock can find
# and override the command. The stubs are never executed with real behavior -
# every one is replaced by a Mock in the same scope.

Describe 'Add-LinuxWorkerNode failure cleanup' -Tag 'unit', 'ci', 'worker-node' {
    Context 'When a step after Add-NodeConfig fails' {
        It 'preserves the node config entry (for upgrade/restore) and re-throws the original error' {
            InModuleScope $moduleName {
                function Add-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-Debian13NodeHardening { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Set-UpComputerBeforeProvisioning { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Repair-LinuxWorkerNodeRegistriesConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Clear-LinuxWorkerNodeRoutes { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Join-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-CmdOnVmViaSSHKey { param([Parameter(ValueFromRemainingArguments)]$Rest) }

                # Arrange: Add-NodeConfig succeeds, first provisioning step throws.
                Mock Write-Log {}
                Mock Add-NodeConfig {}
                Mock Invoke-Debian13NodeHardening {}
                Mock Set-UpComputerBeforeProvisioning { throw 'join failed' }
                Mock Remove-NodeConfig {}
                Mock Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer {}
                Mock Join-LinuxNode {}
                Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = '' } }

                # Act + Assert: original error is preserved (AC1)
                { Add-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100' -WindowsHostIpAddress '172.19.1.1' -installedDistributionOnRemoteComputer 'debian' } |
                    Should -Throw '*join failed*'

                Should -Invoke Add-NodeConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'scaleoutbox' }

                # Assert: config entry is NOT deleted - it must survive for a system
                # upgrade to restore the node; 'k2s node remove' cleans it up later (AC1)
                Should -Invoke Remove-NodeConfig -Times 0 -Exactly
            }
        }
    }
}

Describe 'Add-LinuxWorkerNode Debian13 hardening' -Tag 'unit', 'ci', 'worker-node' {
    BeforeEach {
        InModuleScope $moduleName {
            function script:Add-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function script:Invoke-Debian13NodeHardening { param($Stage, $InstalledDistribution, $UserName, $IpAddress, $UserPwd = '') }
            function script:Set-UpComputerBeforeProvisioning { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function script:Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function script:Join-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function script:Invoke-CmdOnVmViaSSHKey { param([Parameter(ValueFromRemainingArguments)]$Rest) }

            $script:hardeningEvents = [System.Collections.Generic.List[string]]::new()
            $script:failedHardeningStage = ''
            Mock Write-Log {}
            Mock Add-NodeConfig { $script:hardeningEvents.Add('config') }
            Mock Invoke-Debian13NodeHardening {
                $script:hardeningEvents.Add($Stage)
                if ($Stage -eq $script:failedHardeningStage) { throw 'Remote command failed: unsafe hardening refused' }
            }
            Mock Set-UpComputerBeforeProvisioning { $script:hardeningEvents.Add('provision') }
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = '' } }
            Mock Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer { $script:hardeningEvents.Add('packages') }
            Mock Repair-LinuxWorkerNodeRegistriesConfig { $script:hardeningEvents.Add('repair') }
            Mock Add-LinuxWorkerNodeRegistryMirrors { $script:hardeningEvents.Add('mirrors') }
            Mock Clear-LinuxWorkerNodeRoutes { $script:hardeningEvents.Add('routes') }
            Mock Join-LinuxNode { $script:hardeningEvents.Add('join') }
        }
    }

    It 'prepares before provisioning and cleans after packages before registry repair and join' {
        InModuleScope $moduleName {
            Add-LinuxWorkerNode -NodeName worker -UserName remote -IpAddress '172.19.1.101' -WindowsHostIpAddress '172.19.1.1' -installedDistributionOnRemoteComputer debian13 -NodeType VM-EXISTING

            ($script:hardeningEvents -join ',') | Should -Be 'config,prepare,provision,packages,cleanup,repair,mirrors,routes,join'
            Should -Invoke Invoke-Debian13NodeHardening -Times 2 -Exactly -ParameterFilter {
                $InstalledDistribution -eq 'debian13' -and $UserName -eq 'remote' -and $IpAddress -eq '172.19.1.101' -and
                [string]::IsNullOrWhiteSpace($UserPwd)
            }
            Should -Invoke Invoke-Debian13NodeHardening -Times 1 -Exactly -ParameterFilter { $Stage -eq 'prepare' }
            Should -Invoke Invoke-Debian13NodeHardening -Times 1 -Exactly -ParameterFilter { $Stage -eq 'cleanup' }
        }
    }

    It 'passes the detected distribution to the shared no-op guard for other workers' {
        InModuleScope $moduleName {
            Add-LinuxWorkerNode -NodeName worker -UserName remote -IpAddress '172.19.1.101' -WindowsHostIpAddress '172.19.1.1' -installedDistributionOnRemoteComputer debian12 -NodeType VM-EXISTING

            Should -Invoke Invoke-Debian13NodeHardening -Times 2 -Exactly -ParameterFilter { $InstalledDistribution -eq 'debian12' }
            Should -Invoke Join-LinuxNode -Times 1 -Exactly
        }
    }

    It 'does not repair registries or join after remote <Stage> failure' -ForEach @(
        @{ Stage = 'prepare'; Expected = 'config,prepare' }
        @{ Stage = 'cleanup'; Expected = 'config,prepare,provision,packages,cleanup' }
    ) {
        InModuleScope $moduleName -Parameters @{ Stage = $Stage; Expected = $Expected } {
            param($Stage, $Expected)
            $script:failedHardeningStage = $Stage

            { Add-LinuxWorkerNode -NodeName worker -UserName remote -IpAddress '172.19.1.101' -WindowsHostIpAddress '172.19.1.1' -installedDistributionOnRemoteComputer debian13 -NodeType VM-EXISTING } |
                Should -Throw '*unsafe hardening refused*'

            ($script:hardeningEvents -join ',') | Should -Be $Expected
            Should -Invoke Repair-LinuxWorkerNodeRegistriesConfig -Times 0 -Exactly
            Should -Invoke Join-LinuxNode -Times 0 -Exactly
            if ($Stage -eq 'prepare') {
                Should -Invoke Set-UpComputerBeforeProvisioning -Times 0 -Exactly
                Should -Invoke Install-LinuxPackagesAndAddContainerImagesIntoRemoteComputer -Times 0 -Exactly
            }
        }
    }
}

Describe 'Remove-LinuxWorkerNode robustness' -Tag 'unit', 'ci', 'worker-node' {
    Context 'When the node is not part of the cluster (orphaned entry)' {
        It 'still removes the node config entry' {
            InModuleScope $moduleName {
                function Get-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-Kubectl { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-KubernetesArtifacts { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }

                # Arrange: node absent from kubectl, remote cleanup would fail.
                Mock Write-Log {}
                Mock Get-NodeConfig { $null }
                Mock Invoke-Kubectl { [pscustomobject]@{ Output = 'controlplane   Ready   control-plane' } }
                Mock Remove-LinuxNode { throw 'should not be called for absent node' }
                Mock Remove-KubernetesArtifacts { throw 'node unreachable' }
                Mock Remove-NodeConfig {}

                # Act
                Remove-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100'

                # Assert: config entry removed despite cluster/remote failures (AC3)
                Should -Invoke Remove-NodeConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'scaleoutbox' }
                Should -Invoke Remove-LinuxNode -Times 0 -Exactly
            }
        }
    }

    Context 'When the node is part of the cluster (normal removal)' {
        It 'removes it from the cluster and clears the config entry' {
            InModuleScope $moduleName {
                function Get-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-Kubectl { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-KubernetesArtifacts { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }

                # Arrange: node present in kubectl.
                Mock Write-Log {}
                Mock Get-NodeConfig { $null }
                Mock Invoke-Kubectl { [pscustomobject]@{ Output = "controlplane   Ready`nscaleoutbox   Ready   worker" } }
                Mock Remove-LinuxNode {}
                Mock Remove-KubernetesArtifacts {}
                Mock Remove-NodeConfig {}

                # Act
                Remove-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100'

                # Assert: normal path unchanged (AC4)
                Should -Invoke Remove-LinuxNode -Times 1 -Exactly
                Should -Invoke Remove-NodeConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'scaleoutbox' }
            }
        }
    }

    Context 'When cluster removal fails for a registered node' {
        It 'preserves the node config and re-throws the removal error' {
            InModuleScope $moduleName {
                function Get-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-Kubectl { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-KubernetesArtifacts { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }

                Mock Write-Log {}
                Mock Get-NodeConfig { $null }
                Mock Invoke-Kubectl { [pscustomobject]@{ Output = "controlplane   Ready`nscaleoutbox   Ready   worker" } }
                Mock Remove-LinuxNode { throw 'cluster removal failed' }
                Mock Remove-KubernetesArtifacts {}
                Mock Remove-NodeConfig {}

                { Remove-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100' } |
                    Should -Throw '*cluster removal failed*'

                Should -Invoke Remove-NodeConfig -Times 0 -Exactly
                Should -Invoke Remove-KubernetesArtifacts -Times 0 -Exactly
            }
        }
    }

    Context 'When the VM link is broken (-SkipRemoteCleanup)' {
        It 'skips all remote/cluster steps but still clears the config entry' {
            InModuleScope $moduleName {
                function Get-NodeConfig { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Invoke-Kubectl { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-LinuxNode { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-KubernetesArtifacts { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-PersistentLinuxWorkerNodeRoutes { param([Parameter(ValueFromRemainingArguments)]$Rest) }
                function Remove-NodeConfig { param([string]$Name, [Parameter(ValueFromRemainingArguments)]$Rest) }

                # Arrange: node is a HOST node but unreachable; any remote call would fail.
                Mock Write-Log {}
                Mock Get-NodeConfig { [pscustomobject]@{ NodeType = 'HOST' } }
                Mock Invoke-Kubectl { throw 'kubectl unreachable' }
                Mock Remove-LinuxNode { throw 'should not be called' }
                Mock Remove-KubernetesArtifacts { throw 'should not be called' }
                Mock Remove-PersistentLinuxWorkerNodeRoutes { throw 'should not be called' }
                Mock Remove-NodeConfig {}

                # Act: caller knows the VM link is broken (matches PR #2781 Remove.ps1)
                Remove-LinuxWorkerNode -NodeName 'scaleoutbox' -UserName 'remote' -IpAddress '172.19.1.100' -SkipRemoteCleanup

                # Assert: no remote/cluster work attempted, but config entry cleared (AC3)
                Should -Invoke Invoke-Kubectl -Times 0 -Exactly
                Should -Invoke Remove-LinuxNode -Times 0 -Exactly
                Should -Invoke Remove-KubernetesArtifacts -Times 0 -Exactly
                Should -Invoke Remove-PersistentLinuxWorkerNodeRoutes -Times 0 -Exactly
                Should -Invoke Remove-NodeConfig -Times 1 -Exactly -ParameterFilter { $Name -eq 'scaleoutbox' }
            }
        }
    }
}
