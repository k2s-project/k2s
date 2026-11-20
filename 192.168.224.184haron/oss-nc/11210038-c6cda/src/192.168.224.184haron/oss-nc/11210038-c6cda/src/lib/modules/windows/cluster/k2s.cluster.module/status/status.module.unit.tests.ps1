# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\Status.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Get-Status' -Tag 'unit', 'ci' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }
    
    Context 'progress display disabled' {
        Context 'setup name is invalid' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{ Error = 'invalid-name' } }
            }
            
            It 'returns status with error immediately without gathering additional data' {
                InModuleScope -ModuleName $moduleName {
                    $result = Get-Status
                    $result.Error.Code | Should -Be 'invalid-name'
                }
            }
        }
        
        Context 'system is not running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $false } }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns status immediately without gathering additional data' {
                InModuleScope -ModuleName $moduleName {
                    $result.RunningState.IsRunning | Should -BeFalse
                }
            }
        }
        
        Context 'system is running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $true } }
                Mock -ModuleName $moduleName Get-Nodes { return @{Name = 'n1' }, @{Name = 'n2' } }
                Mock -ModuleName $moduleName Get-SystemPods { return @{Name = 'p1' }, @{Name = 'p2' } }
                Mock -ModuleName $moduleName Get-K8sVersionInfo { return @{K8sServerVersion = '123'; K8sClientVersion = '321' } }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns is running state' {
                InModuleScope -ModuleName $moduleName {
                    $result.RunningState.IsRunning | Should -BeTrue
                }
            }

            It 'returns K8s version info' {
                InModuleScope -ModuleName $moduleName {
                    $result.K8sVersionInfo.K8sClientVersion | Should -Be '321'
                    $result.K8sVersionInfo.K8sServerVersion | Should -Be '123'
                }
            }
            
            It 'returns nodes' {
                InModuleScope -ModuleName $moduleName {
                    $result.Nodes.Count | Should -Be 2
                    $result.Nodes[0].Name | Should -Be 'n1'
                    $result.Nodes[1].Name | Should -Be 'n2'
                }
            }
            
            It 'returns system pods' {
                InModuleScope -ModuleName $moduleName {
                    $result.Pods.Count | Should -Be 2
                    $result.Pods[0].Name | Should -Be 'p1'
                    $result.Pods[1].Name | Should -Be 'p2'
                }
            }
        }
    }

    Context 'progress display enabled' {
        Context 'setup name is invalid' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'invalid'; Error = 'invalid type' } }
                Mock -ModuleName $moduleName Write-Progress {}

                InModuleScope -ModuleName $moduleName {
                    Get-Status -ShowProgress $true
                }
            }
            
            It 'displays initial progress info' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '0/4' } -Scope Context
                }
            }

            It 'completes progress immediately' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Completed -eq $true } -Scope Context
                    Should -Invoke Write-Progress -Times 2 -Scope Context
                }
            }
        }
       
        Context 'system is not running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Write-Progress {}
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $false } }

                InModuleScope -ModuleName $moduleName {
                    Get-Status -ShowProgress $true
                }
            }
            
            It 'displays progress until system running state' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '0/4' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '1/4' } -Scope Context
                }
            }

            It 'completes progress immediately after running state' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Completed -eq $true } -Scope Context
                    Should -Invoke Write-Progress -Times 3 -Scope Context
                }
            }
        }
        
        Context 'system is running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'valid' } }
                Mock -ModuleName $moduleName Write-Progress {}
                Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $true } }
                Mock -ModuleName $moduleName Get-Nodes {}
                Mock -ModuleName $moduleName Get-SystemPods {}
                Mock -ModuleName $moduleName Get-K8sVersionInfo {}

                InModuleScope -ModuleName $moduleName {
                    Get-Status -ShowProgress $true
                }
            }
            
            It 'displays progress until completion' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '0/4' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '1/4' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '2/4' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '3/4' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '4/4' } -Scope Context
                    Should -Invoke Write-Progress -Times 1 -ParameterFilter { $Id -eq 1 -and $Status -eq '4/4' -and $PercentComplete -eq 100 } -Scope Context
                    Should -Invoke Write-Progress -Times 7 -Scope Context
                }
            }
        }
    }
}

Describe 'Test-SystemAvailability' -Tag 'unit', 'ci' {
    Context 'setup info has errors' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return @{Error = 'invalid-error' } }
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                Test-SystemAvailability | Should -Be 'invalid-error'
            } 
        }
    }
    
    Context 'state is system-not-running' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'my-setup'; Error = $null } }
            Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $false } } -ParameterFilter { $SetupName -eq 'my-setup' }
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                Test-SystemAvailability | Should -Be 'system-not-running'
            } 
        }
    }
    
    Context 'state is running' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'my-setup'; Error = $null } }
            Mock -ModuleName $moduleName Get-RunningState { return @{IsRunning = $true } } -ParameterFilter { $SetupName -eq 'my-setup' }
        }

        It 'returns null' {
            InModuleScope -ModuleName $moduleName {
                Test-SystemAvailability | Should -BeNullOrEmpty
            } 
        }
    }
}

Describe 'Test-ClusterAvailability' -Tag 'unit', 'ci' -Skip { 
    It 'test-not-implemented' {
        
    }
}

Describe 'Get-KubernetesServiceAreRunning' -Tag 'unit', 'ci' -Skip { 
    It 'test-not-implemented' {
        
    }
}
