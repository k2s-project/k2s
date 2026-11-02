# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot\common-setup.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
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

Describe 'Invoke-RemoteScript' -Tag 'unit', 'ci', 'provisioning' {
    BeforeEach {
        Mock Write-Log {} -ModuleName $moduleName
        Mock Test-Path { $true } -ModuleName $moduleName
        Mock Copy-ToRemoteComputerViaSshKey {} -ModuleName $moduleName
        Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } } -ModuleName $moduleName
    }

    It 'passes every argument as a single-quoted shell word' {
        InModuleScope $moduleName {
            Invoke-RemoteScript -LocalScriptPath 'C:\k\setproxy.sh' -UserName 'remote' -IpAddress '172.19.1.100' -Arguments @('http://proxy:8080', 'two words', '')

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq "chmod +x /tmp/setproxy.sh && /tmp/setproxy.sh 'http://proxy:8080' 'two words' ''"
            }
        }
    }

    It 'escapes single quotes so that an argument cannot inject shell commands' {
        InModuleScope $moduleName {
            Invoke-RemoteScript -LocalScriptPath 'C:\k\setproxy.sh' -UserName 'remote' -IpAddress '172.19.1.100' -Arguments @("http://x'; id; '")

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq "chmod +x /tmp/setproxy.sh && /tmp/setproxy.sh 'http://x'\''; id; '\'''"
            }
        }
    }

    It 'runs the script without arguments when none are given' {
        InModuleScope $moduleName {
            Invoke-RemoteScript -LocalScriptPath 'C:\k\setproxy.sh' -UserName 'remote' -IpAddress '172.19.1.100'

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly -ParameterFilter {
                $CmdToExecute -eq 'chmod +x /tmp/setproxy.sh && /tmp/setproxy.sh '
            }
        }
    }
}
