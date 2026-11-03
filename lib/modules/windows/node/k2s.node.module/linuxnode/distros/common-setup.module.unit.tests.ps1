# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot\common-setup.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Invoke-Debian13NodeHardening' -Tag 'unit', 'ci' {
    BeforeEach {
        InModuleScope $moduleName {
            Mock Get-LinuxScriptPath { 'C:\k2s\cfg\nodeextension\debian13\scripts' }
            Mock Invoke-RemoteScript {}
        }
    }

    It 'passes <Stage> with password <Password> to the bundled script without retries' -ForEach @(
        @{ Stage = 'prepare'; Password = 'image-password' }
        @{ Stage = 'cleanup'; Password = 'image-password' }
        @{ Stage = 'prepare'; Password = '' }
        @{ Stage = 'cleanup'; Password = '' }
    ) {
        InModuleScope $moduleName -Parameters @{ Stage = $Stage; Password = $Password } {
            param($Stage, $Password)
            Invoke-Debian13NodeHardening -Stage $Stage -InstalledDistribution debian13 -UserName remote -IpAddress '172.19.1.101' -UserPwd $Password

            Should -Invoke Invoke-RemoteScript -Times 1 -Exactly -ParameterFilter {
                $LocalScriptPath -eq 'C:\k2s\cfg\nodeextension\debian13\scripts\harden-node.sh' -and
                $UserName -eq 'remote' -and $IpAddress -eq '172.19.1.101' -and $UserPwd -eq $Password -and
                $Arguments.Count -eq 1 -and $Arguments[0] -eq $Stage -and $Retries -eq 0 -and $CleanupAfterExecution
            }
        }
    }

    It 'skips <Distribution> at <Stage> without resolving or invoking a remote script' -ForEach @(
        @{ Distribution = 'debian12'; Stage = 'prepare' }
        @{ Distribution = 'debian12'; Stage = 'cleanup' }
        @{ Distribution = 'ubuntu24.04'; Stage = 'prepare' }
        @{ Distribution = 'ubuntu24.04'; Stage = 'cleanup' }
    ) {
        InModuleScope $moduleName -Parameters @{ Distribution = $Distribution; Stage = $Stage } {
            param($Distribution, $Stage)
            Invoke-Debian13NodeHardening -Stage $Stage -InstalledDistribution $Distribution -UserName remote -IpAddress '172.19.1.101'
            Should -Invoke Get-LinuxScriptPath -Times 0 -Exactly
            Should -Invoke Invoke-RemoteScript -Times 0 -Exactly
        }
    }

    It 'propagates remote script errors' {
        InModuleScope $moduleName {
            Mock Invoke-RemoteScript { throw 'unsafe cleanup refused' }
            { Invoke-Debian13NodeHardening -Stage cleanup -InstalledDistribution debian13 -UserName remote -IpAddress '172.19.1.101' } |
                Should -Throw '*unsafe cleanup refused*'
        }
    }
}

Describe 'Debian13 hardening remote execution' -Tag 'unit', 'ci' {
    BeforeEach {
        InModuleScope $moduleName {
            Mock Write-Log {}
            Mock Test-Path { $true }
            Mock Copy-ToRemoteComputerViaUserAndPwd {}
            Mock Copy-ToRemoteComputerViaSshKey {}
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd { [pscustomobject]@{ Success = $true; Output = '' } }
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } }
        }
    }

    It 'uses the selected transport and removes the script with password <Password>' -ForEach @(
        @{ Password = 'image-password' }
        @{ Password = '' }
    ) {
        InModuleScope $moduleName -Parameters @{ Password = $Password } {
            param($Password)
            Invoke-Debian13NodeHardening -Stage prepare -InstalledDistribution debian13 -UserName remote -IpAddress '172.19.1.101' -UserPwd $Password
            if ($Password) {
                Should -Invoke Copy-ToRemoteComputerViaUserAndPwd -Times 1 -Exactly -ParameterFilter { $UserPwd -eq $Password }
                Should -Invoke Copy-ToRemoteComputerViaSshKey -Times 0 -Exactly
                Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 0 -Exactly
                Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 1 -Exactly -ParameterFilter {
                    $CmdToExecute -eq "chmod +x /tmp/harden-node.sh && /tmp/harden-node.sh 'prepare'" -and $Retries -eq 0 -and $RemoteUserPwd -eq $Password
                }
                Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 1 -Exactly -ParameterFilter { $CmdToExecute -eq 'rm /tmp/harden-node.sh' }
            }
            else {
                Should -Invoke Copy-ToRemoteComputerViaSshKey -Times 1 -Exactly
                Should -Invoke Copy-ToRemoteComputerViaUserAndPwd -Times 0 -Exactly
                Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 0 -Exactly
                Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                    $CmdToExecute -eq "chmod +x /tmp/harden-node.sh && /tmp/harden-node.sh 'prepare'" -and $Retries -eq 0
                }
                Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter { $CmdToExecute -eq 'rm /tmp/harden-node.sh' }
            }
        }
    }

    It 'throws failed remote results with password <Password>' -ForEach @(
        @{ Password = 'image-password' }
        @{ Password = '' }
    ) {
        InModuleScope $moduleName -Parameters @{ Password = $Password } {
            param($Password)
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd { [pscustomobject]@{ Success = $false; Output = 'unsafe cleanup refused' } } -ParameterFilter { $CmdToExecute -like 'chmod *' }
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = 'unsafe cleanup refused' } } -ParameterFilter { $CmdToExecute -like 'chmod *' }

            { Invoke-Debian13NodeHardening -Stage cleanup -InstalledDistribution debian13 -UserName remote -IpAddress '172.19.1.101' -UserPwd $Password } |
                Should -Throw '*unsafe cleanup refused*'
        }
    }
}

Describe 'Debian13 shared image hardening order' -Tag 'unit', 'ci' {
    BeforeEach {
        InModuleScope $moduleName {
            $script:hardeningEvents = [System.Collections.Generic.List[string]]::new()
            $script:failedHardeningStage = ''
            Mock Write-Log {}
            Mock Get-VmIpForProvisioningKubeNode { '172.19.1.101' }
            Mock Get-DefaultUserNameKubeNode { 'remote' }
            Mock Get-DefaultUserPwdKubeNode { 'image-password' }
            Mock Get-IsValidIPv4Address { $true }
            Mock Test-Path { $true }
            Mock Get-LinuxScriptPath { 'C:\k2s\cfg\nodeextension\debian13\scripts' }
            Mock Copy-ToRemoteComputerViaUserAndPwd {}
            Mock Invoke-CmdOnVmViaSSHKey { throw 'image must use password authentication' }
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                if ($CmdToExecute -like 'chmod +x /tmp/harden-node.sh*') {
                    $stage = if ($CmdToExecute -like "*'prepare'") { 'prepare' } else { 'cleanup' }
                    $script:hardeningEvents.Add($stage)
                    if ($stage -eq $script:failedHardeningStage) {
                        return [pscustomobject]@{ Success = $false; Output = 'unsafe hardening refused' }
                    }
                }
                [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock New-KubenodeBaseImage {
                & $Hook
                $script:hardeningEvents.Add('seal')
            }
            Mock New-KubernetesNode { $script:hardeningEvents.Add('kubernetes') }
            Mock AddRegistryMirrors { $script:hardeningEvents.Add('mirrors') }
            Mock Get-KubernetesImages { $script:hardeningEvents.Add('images') }
            Mock Install-DnsServer { $script:hardeningEvents.Add('dns') }
            Mock Get-BuildahDebPackagesPath { '/tmp/buildah' }
            Mock Get-BuildahDebPackagesFromInternet {}
            Mock Install-BuildahDebPackages { $script:hardeningEvents.Add('buildah') }
            Mock Get-RegistryToken { 'test-token' }
            Mock Install-CliToolsOnKubeMaster { $script:hardeningEvents.Add('cli') }
            Mock Get-FlannelImages { $script:hardeningEvents.Add('flannel') }
            Mock Get-ClusterIPWebhookImages { $script:hardeningEvents.Add('webhook') }
            Mock Add-SupportForWSL { $script:hardeningEvents.Add('wsl') }
        }
    }

    It 'executes prepare before Kubernetes and cleanup after all additions before sealing' {
        InModuleScope $moduleName {
            New-VmImageForKubernetesNode -VmImageOutputPath 'C:\Temp\node.vhdx' -DnsIpAddresses '172.19.1.1'

            ($script:hardeningEvents -join ',') | Should -Be 'prepare,kubernetes,mirrors,images,dns,buildah,cli,flannel,webhook,wsl,cleanup,seal'
            Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 0 -Exactly -ParameterFilter { $CmdToExecute -match 'apt-get autoremove' }
            Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 2 -Exactly -ParameterFilter {
                $CmdToExecute -like 'chmod +x /tmp/harden-node.sh*' -and $RemoteUser -eq 'remote@172.19.1.101' -and
                $RemoteUserPwd -eq 'image-password' -and $Retries -eq 0
            }
        }
    }

    It 'does not seal when remote <Stage> fails' -ForEach @(
        @{ Stage = 'prepare' }
        @{ Stage = 'cleanup' }
    ) {
        InModuleScope $moduleName -Parameters @{ Stage = $Stage } {
            param($Stage)
            $script:failedHardeningStage = $Stage

            { New-VmImageForKubernetesNode -VmImageOutputPath 'C:\Temp\node.vhdx' -DnsIpAddresses '172.19.1.1' } |
                Should -Throw '*unsafe hardening refused*'

            $script:hardeningEvents | Should -Not -Contain 'seal'
            if ($Stage -eq 'prepare') {
                ($script:hardeningEvents -join ',') | Should -Be 'prepare'
                Should -Invoke New-KubernetesNode -Times 0 -Exactly
            }
            else {
                ($script:hardeningEvents -join ',') | Should -Be 'prepare,kubernetes,mirrors,images,dns,buildah,cli,flannel,webhook,wsl,cleanup'
            }
        }
    }
}

Describe 'Get-KubenodeNoProxy' -Tag 'unit', 'ci', 'proxy' {
    It 'derives K2s network entries from configured values' {
        InModuleScope $moduleName {
            Mock Get-ConfiguredIPControlPlane { '172.19.1.100' }
            Mock Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
            Mock Get-ConfiguredClusterCIDR { '10.20.0.0/16' }
            Mock Get-ConfiguredClusterCIDRServices { '10.21.0.0/16' }
            Mock Get-ConfiguredKubeDnsServiceIP { '10.21.0.10' }

            $entries = (Get-KubenodeNoProxy) -split ','

            $entries | Should -Contain '172.19.1.100'
            $entries | Should -Contain '172.19.1.1'
            $entries | Should -Contain '10.20.0.0/16'
            $entries | Should -Contain '10.21.0.0/16'
            $entries | Should -Contain '10.21.0.10'
            $entries | Should -Contain '.cluster.local'
            $entries | Should -Contain '.svc'
        }
    }
}

Describe 'Assert-GeneralComputerPrerequisites' -Tag 'unit', 'ci', 'provisioning' {
    BeforeEach {
        Mock Write-Log {} -ModuleName $moduleName
        Mock Get-IsValidIPv4Address { $true } -ModuleName $moduleName
    }

    It 'requests bounded retries only for the read-only hostname command' {
        InModuleScope $moduleName {
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                [pscustomobject]@{ Success = $true; Output = 'kubenode' }
            }

            { Assert-GeneralComputerPrerequisites -UserName 'remote' -UserPwd 'fixture' -IpAddress '172.18.12.22' } | Should -Not -Throw

            Should -Invoke Invoke-CmdOnControlPlaneViaUserAndPwd -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq 'hostname' -and $RemoteUser -eq 'remote@172.18.12.22' -and
                $RemoteUserPwd -eq 'fixture' -and $Retries -eq 3 -and $Timeout -eq 3 -and -not $IgnoreErrors
            }
        }
    }

    It 'reports exhausted SSH failures instead of validating their output as hostnames' {
        InModuleScope $moduleName {
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                [pscustomobject]@{ Success = $false; Output = 'FATAL ERROR: Network error: Software caused connection abort' }
            }

            { Assert-GeneralComputerPrerequisites -UserName 'remote' -UserPwd 'fixture' -IpAddress '172.18.12.22' } |
                Should -Throw "*SSH command 'hostname' failed after retrying*Software caused connection abort*"
        }
    }

    It 'does not accept valid-looking output from an unsuccessful command' {
        InModuleScope $moduleName {
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                [pscustomobject]@{ Success = $false; Output = 'kubenode' }
            }

            { Assert-GeneralComputerPrerequisites -UserName 'remote' -UserPwd 'fixture' -IpAddress '172.18.12.22' } |
                Should -Throw "*SSH command 'hostname' failed*"
        }
    }

    It 'retains empty and invalid hostname validation after successful SSH' -ForEach @(
        @{ Hostname = ''; Message = '*could not be retrieved*' },
        @{ Hostname = 'InvalidName'; Message = '*contains not allowed characters*' }
    ) {
        InModuleScope $moduleName -Parameters @{ Hostname = $Hostname; Message = $Message } {
            param($Hostname, $Message)
            Mock Invoke-CmdOnControlPlaneViaUserAndPwd {
                [pscustomobject]@{ Success = $true; Output = $Hostname }
            }

            { Assert-GeneralComputerPrerequisites -UserName 'remote' -UserPwd 'fixture' -IpAddress '172.18.12.22' } |
                Should -Throw $Message
        }
    }
}

Describe 'Get-GpuContainerImages' -Tag 'unit', 'ci', 'gpu' {
    It 'reads the GPU addon manifest from the package root' {
        InModuleScope $moduleName {
            Mock Test-Path { return $false }

            { Get-GpuContainerImages -UserName 'admin' -UserPwd 'password' -IpAddress '172.19.1.101' } |
                Should -Throw '*GPU addon manifest not found at:*addons\gpu-node\addon.manifest.yaml'
        }
    }
}
