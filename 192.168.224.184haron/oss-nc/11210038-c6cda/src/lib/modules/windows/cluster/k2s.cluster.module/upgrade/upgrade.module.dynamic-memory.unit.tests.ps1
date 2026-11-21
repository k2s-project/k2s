# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Unit tests for dynamic memory handling in upgrade module.

.DESCRIPTION
Tests the dynamic memory upgrade functionality, focusing on:
1. Command generation with dynamic memory configuration
2. Backward compatibility with static memory (string format)
3. Negative scenarios and error handling
#>

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\upgrade.module.psm1" -PassThru -Force).Name
}


Describe 'Invoke-ClusterInstall - Dynamic Memory Support' -Tag 'unit', 'ci', 'upgrade', 'dynamic-memory' {

    BeforeEach {
        # Mock dependencies
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Copy-Item { }
        Mock -ModuleName $moduleName Remove-Item { }
        Mock -ModuleName $moduleName Test-Path { return $true }
        Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
        Mock -ModuleName $moduleName Get-KubePath { return 'C:\K2s' }
    }

    Context 'Static Memory Configuration (Legacy - Most Common Upgrade Scenario)' {

        It 'generates correct command for static memory' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '6GB'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--master-memory 6GB' -and
                    $Arguments -notmatch '--master-memory-min' -and
                    $Arguments -notmatch '--master-memory-max'
                }
            }
        }

        It 'does not include dynamic memory flags for static memory' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '4GB'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -notmatch '--master-memory-min' -and
                    $Arguments -notmatch '--master-memory-max'
                }
            }
        }
    }

    Context 'Dynamic Memory Configuration (Future Upgrade Scenario)' {

        It 'generates correct command with all dynamic memory flags (auto-enables via min/max)' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '4GB' -EnableDynamicMemory -MasterVMMemoryMin '2GB' -MasterVMMemoryMax '8GB'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--master-memory 4GB' -and
                    $Arguments -match '--master-memory-min 2GB' -and
                    $Arguments -match '--master-memory-max 8GB' -and
                    $Arguments -notmatch '--master-dynamic-memory'
                }
            }
        }

        It 'includes min/max flags without explicit dynamic-memory flag (auto-enabled)' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '4GB' -EnableDynamicMemory -MasterVMMemoryMin '2GB' -MasterVMMemoryMax '8GB'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--master-memory 4GB' -and
                    $Arguments -match '--master-memory-min 2GB' -and
                    $Arguments -match '--master-memory-max 8GB'
                }
            }
        }

        It 'includes only minimum when maximum is not specified (auto-enables via min)' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '4GB' -EnableDynamicMemory -MasterVMMemoryMin '2GB'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--master-memory 4GB' -and
                    $Arguments -match '--master-memory-min 2GB' -and
                    $Arguments -notmatch '--master-memory-max'
                }
            }
        }

        It 'includes only maximum when minimum is not specified (auto-enables via max)' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '4GB' -EnableDynamicMemory -MasterVMMemoryMax '8GB'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--master-memory 4GB' -and
                    $Arguments -notmatch '--master-memory-min' -and
                    $Arguments -match '--master-memory-max 8GB'
                }
            }
        }

        It 'ignores min/max when EnableDynamicMemory is false' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '4GB' -MasterVMMemoryMin '2GB' -MasterVMMemoryMax '8GB'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--master-memory 4GB' -and
                    $Arguments -notmatch '--master-memory-min' -and
                    $Arguments -notmatch '--master-memory-max'
                }
            }
        }
    }

    Context 'Negative Scenarios and Edge Cases' {

        It 'handles null memory configuration gracefully' {
            InModuleScope -ModuleName $moduleName {
                { Invoke-ClusterInstall } | Should -Not -Throw

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -notmatch '--master-memory'
                }
            }
        }

        It 'handles empty string memory' {
            InModuleScope -ModuleName $moduleName {
                { Invoke-ClusterInstall -MasterVMMemory '' } | Should -Not -Throw

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -notmatch '--master-memory [0-9]'
                }
            }
        }

        It 'handles empty string min/max values' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '4GB' -EnableDynamicMemory -MasterVMMemoryMin '' -MasterVMMemoryMax ''

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--master-memory 4GB' -and
                    $Arguments -notmatch '--master-memory-min [0-9]' -and
                    $Arguments -notmatch '--master-memory-max [0-9]'
                }
            }
        }
    }

    Context 'Command String Format Validation' {

        It 'uses the long config flag and quotes paths with spaces' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -Config 'C:\Backup Dir\effective-install-config.previous.json'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--config "C:\\Backup Dir\\effective-install-config\.previous\.json"' -and
                    $Arguments -notmatch '(^|\s)-config(\s|$)'
                }
            }
        }

        It 'includes append-log flag in all cases' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall -MasterVMMemory '4GB'

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match '--append-log'
                }
            }
        }

        It 'constructs valid command string with all parameters (dynamic memory auto-enabled via min/max)' {
            InModuleScope -ModuleName $moduleName {
                Invoke-ClusterInstall `
                    -MasterVMMemory '4GB' `
                    -EnableDynamicMemory `
                    -MasterVMMemoryMin '2GB' `
                    -MasterVMMemoryMax '8GB' `
                    -MasterVMProcessorCount '4' `
                    -MasterDiskSize '100GB' `
                    -Proxy 'http://proxy.local:8080' `
                    -ShowLogs

                Should -Invoke Invoke-Cmd -ParameterFilter {
                    $Arguments -match 'install' -and
                    $Arguments -match '-o' -and
                    $Arguments -match '--proxy http://proxy.local:8080' -and
                    $Arguments -match '--master-cpus 4' -and
                    $Arguments -match '--master-memory 4GB' -and
                    $Arguments -match '--master-memory-min 2GB' -and
                    $Arguments -match '--master-memory-max 8GB' -and
                    $Arguments -match '--master-disk 100GB' -and
                    $Arguments -match '--append-log' -and
                    $Arguments -notmatch '--master-dynamic-memory'
                }
            }
        }
    }
}

AfterAll {
    Remove-Module $moduleName -Force -ErrorAction SilentlyContinue
}

