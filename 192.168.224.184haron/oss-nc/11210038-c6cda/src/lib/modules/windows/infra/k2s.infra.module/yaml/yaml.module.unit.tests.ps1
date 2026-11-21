# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\yaml.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Get-FromYamlFile' -Tag 'unit', 'ci', 'yaml', 'infra', 'module', 'k2s' {
    Context 'Path is not specified' {
        It 'throws' {
            { Get-FromYamlFile } | Should -Throw -ExpectedMessage 'Path not specified'
        }
    }
    
    Context 'Path does not exist' {
        It 'throws' {
            { Get-FromYamlFile -Path 'non-existent' } | Should -Throw -ExpectedMessage "path 'non-existent' does not exist"
        }
    }
    
    Context 'yaml2json.exe execution failed' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'yaml-path' }
            Mock -ModuleName $moduleName Get-KubeBinPath { return 'bin-path' }
            Mock -ModuleName $moduleName New-K2sTempFile { return 'temp-file' }
            Mock -ModuleName $moduleName Invoke-Expression {}
            Mock -ModuleName $moduleName Test-LastExecutionForSuccess { return $false }
            Mock -ModuleName $moduleName Remove-Item {}
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-FromYamlFile -Path 'yaml-path' } | Should -Throw -ExpectedMessage "yaml2json conversion failed for 'yaml-path'. See log output above for details."

                Should -Invoke Invoke-Expression -Times 1 -Scope Context -ParameterFilter { $Command -match '&"bin-path\\yaml2json.exe" -input "yaml-path" -output "temp-file"' }
            }
        }
        
        It 'removes the temp file' {
            InModuleScope -ModuleName $moduleName {
                { Get-FromYamlFile -Path 'yaml-path' } | Should -Throw

                Should -Invoke Remove-Item -Times 1 -Scope Context -ParameterFilter { $Path -eq 'temp-file' }
            }
        }
    }
    
    Context 'yaml2json.exe execution succeeded' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'yaml-path' }
            Mock -ModuleName $moduleName Get-KubeBinPath { return 'bin-path' }
            Mock -ModuleName $moduleName New-K2sTempFile { return 'temp-file' }
            Mock -ModuleName $moduleName Invoke-Expression {}
            Mock -ModuleName $moduleName Test-LastExecutionForSuccess { return $true }
            Mock -ModuleName $moduleName Get-Content { return 'content' }
            Mock -ModuleName $moduleName Out-String { return 'string' } -ParameterFilter { $InputObject -eq 'content' }
            Mock -ModuleName $moduleName ConvertFrom-Json { return 'json' } -ParameterFilter { $InputObject -eq 'string' }
            Mock -ModuleName $moduleName Remove-Item {}
        }

        It 'removes the temp file' {
            InModuleScope -ModuleName $moduleName {
                Get-FromYamlFile -Path 'yaml-path'

                Should -Invoke Remove-Item -Times 1 -Scope Context -ParameterFilter { $Path -eq 'temp-file' }
            }
        }

        It 'returns the result' {
            InModuleScope -ModuleName $moduleName {
                $result = Get-FromYamlFile -Path 'yaml-path'

                $result | Should -Be 'json'

                Should -Invoke Invoke-Expression -Times 1 -Scope Context -ParameterFilter { $Command -match '&"bin-path\\yaml2json.exe" -input "yaml-path" -output "temp-file"' }
            }
        }
    }
}
