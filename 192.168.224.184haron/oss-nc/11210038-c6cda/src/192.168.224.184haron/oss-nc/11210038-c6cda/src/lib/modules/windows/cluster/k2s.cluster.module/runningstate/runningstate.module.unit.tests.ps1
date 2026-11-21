# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $moduleName = (Import-Module "$PSScriptRoot\runningstate.module.psm1" -PassThru -Force).Name
}

Describe 'Get-IsWslRunning' -Tag 'unit', 'ci' {
    Context 'Name not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-IsWslRunning } | Should -Throw -ExpectedMessage 'Name not specified'
            }
        }
    }
}

Describe 'Get-VmState' -Tag 'unit', 'ci' {
    Context 'Name not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-VmState } | Should -Throw -ExpectedMessage 'Name not specified'
            }
        }
    }
}

Describe 'Get-RunningState' -Tag 'unit', 'ci', 'running-state' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
        Mock -ModuleName $moduleName Get-ConfigControlPlaneNodeHostname { return 'control-plane-name' }
    }

    Context 'setup name not specified' {
        It 'throws' {
            { Get-RunningState } | Should -Throw
        }
    }

    Context 'invalid setup name' {
        It 'throws' {
            { Get-RunningState -SetupName 'invalid-name' } | Should -Throw
        }
    }

    Context 'k2s setup' {
        Context 'default setup' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-ConfigLinuxOnly { return $false }
            }

            Context 'control-plane on Linux VM' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-ConfigWslFlag { return $false }
                }
    
                Context 'everything is running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $true } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-VmState { return 'Running' } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    }
    
                    It 'returns all running without issues' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeTrue
                        $result.Issues | Should -BeNullOrEmpty
                    }
                }
    
                Context 'VM is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $false } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    }
    
                    It 'returns not all running with VM issue' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'control-plane-name'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'stopped'
                        $result.Issues[0] | Should -Match 'VM'
                    }
                }
    
                Context 'flanneld is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $true } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-VmState { return  'Running' } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'stopped' } } -ParameterFilter { $Name -eq 'flanneld' }
                    }
    
                    It 'returns not all running with flanneld issue' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'flanneld'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'service'
                    }
                }
    
                Context 'nothing is running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $false } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'stopped' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    }
    
                    It 'returns nothing running with all issues' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 4
                        $result.Issues[0] | Should -Match 'control-plane-name'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'stopped'
                        $result.Issues[0] | Should -Match 'VM'
                        $result.Issues[1] | Should -Match 'flanneld'
                        $result.Issues[1] | Should -Match 'not running'
                        $result.Issues[1] | Should -Match 'service'
                        $result.Issues[2] | Should -Match 'kubelet'
                        $result.Issues[2] | Should -Match 'not running'
                        $result.Issues[2] | Should -Match 'service'
                        $result.Issues[3] | Should -Match 'kubeproxy'
                        $result.Issues[3] | Should -Match 'not running'
                        $result.Issues[3] | Should -Match 'service'
                    }
                }
            }
    
            Context 'control-plane on WSL' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-ConfigWslFlag { return $true }
                }
    
                Context 'everything is running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $true } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    }
    
                    It 'returns all running without issues' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeTrue
                        $result.Issues | Should -BeNullOrEmpty
                    }
                }
    
                Context 'WSL is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $false } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    }
    
                    It 'returns not all running with WSL issue' {
                        InModuleScope $moduleName {
                            $result = Get-RunningState -SetupName 'k2s'
                            $result.IsRunning | Should -BeFalse
                            $result.Issues.Count | Should -Be 1
                            $result.Issues[0] | Should -Match 'control-plane-name'
                            $result.Issues[0] | Should -Match 'not running'
                            $result.Issues[0] | Should -Match 'WSL'
                        }
                    }
                }
    
                Context 'flanneld is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $true } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'Running' } } -ParameterFilter { $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'stopped' } } -ParameterFilter { $Name -eq 'flanneld' }
                    }
    
                    It 'returns not all running with flanneld issue' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'flanneld'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'service'
                    }
                }
    
                Context 'nothing is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsWslRunning { return $false } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-Service { return @{Status = 'stopped' } } -ParameterFilter { $Name -eq 'flanneld' -or $Name -eq 'kubelet' -or $Name -eq 'kubeproxy' }
                    }
    
                    It 'returns nothing running with all issues' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 4
                        $result.Issues[0] | Should -Match 'control-plane-name'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'WSL'
                        $result.Issues[1] | Should -Match 'flanneld'
                        $result.Issues[1] | Should -Match 'not running'
                        $result.Issues[1] | Should -Match 'service'
                        $result.Issues[2] | Should -Match 'kubelet'
                        $result.Issues[2] | Should -Match 'not running'
                        $result.Issues[2] | Should -Match 'service'
                        $result.Issues[3] | Should -Match 'kubeproxy'
                        $result.Issues[3] | Should -Match 'not running'
                        $result.Issues[3] | Should -Match 'service'
                    }
                }
            }
        }

        Context 'Linux-only setup' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-ConfigLinuxOnly { return $true }
            }

            Context 'control-plane on Linux VM' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-ConfigWslFlag { return $false }
                }

                Context 'everything is running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $true } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-VmState { return 'Running' } -ParameterFilter { $Name -eq 'control-plane-name' }
                    }

                    It 'returns all running without issues' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeTrue
                        $result.Issues | Should -BeNullOrEmpty
                    }
                }

                Context 'nothing is not running' {
                    BeforeAll {
                        Mock -ModuleName $moduleName Get-IsVmRunning { return $false } -ParameterFilter { $Name -eq 'control-plane-name' }
                        Mock -ModuleName $moduleName Get-VmState { return 'stopped' } -ParameterFilter { $Name -eq 'control-plane-name' }
                    }

                    It 'returns nothing running with all issues' {
                        $result = Get-RunningState -SetupName 'k2s'
                        $result.IsRunning | Should -BeFalse
                        $result.Issues.Count | Should -Be 1
                        $result.Issues[0] | Should -Match 'control-plane-name'
                        $result.Issues[0] | Should -Match 'not running'
                        $result.Issues[0] | Should -Match 'stopped'
                        $result.Issues[0] | Should -Match 'VM'
                    }
                }
            }
        }
    }
}
