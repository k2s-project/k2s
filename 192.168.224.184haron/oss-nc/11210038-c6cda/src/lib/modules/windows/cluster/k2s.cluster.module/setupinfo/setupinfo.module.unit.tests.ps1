# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\setupinfo.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Confirm-SetupNameIsValid' -Tag 'unit', 'ci' {
    It 'validation error contains "<expected>" when setup name is "<name>"' -ForEach @(
        @{ Name = $null; Expected = 'system-not-installed' }
        @{ Name = ''; Expected = 'system-not-installed' }
        @{ Name = 'invalid-name'; Expected = "invalid:'invalid-name'" }
        @{ Name = 'k2s'; Expected = $null }
        @{ Name = 'BuildOnlyEnv'; Expected = $null }
    ) {
        InModuleScope $moduleName -Parameters @{Name = $Name; Expected = $Expected } {
            $result = Confirm-SetupNameIsValid -SetupName $Name

            if ($Expected -eq $null) {
                $result | Should -BeNullOrEmpty
            }
            else {
                $result | Should -Match $Expected
            }
        }
    }
}

Describe 'Get-SetupInfo' -Tag 'unit', 'ci' {
    Context 'setup name is valid' {
        Context "name is 'k2s'" {
            BeforeAll {
                Mock -ModuleName $moduleName Get-ConfigSetupType { return 'k2s' }
                Mock -ModuleName $moduleName Get-ConfigLinuxOnly { return $null }
                Mock -ModuleName $moduleName Confirm-SetupNameIsValid { return $null } -ParameterFilter { $SetupName -eq 'k2s' }
                Mock -ModuleName $moduleName Get-ProductVersion { return '1.2.3' }
            }

            It 'returns setup name without validation error' {
                $result = Get-SetupInfo
                $result.Name | Should -Be 'k2s'
                $result.Error | Should -BeNullOrEmpty
                $result.LinuxOnly | Should -BeFalse
                $result.Version | Should -Be 'v1.2.3'
            } 
        }
        
        Context 'Linux-only option set' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-ConfigSetupType { return 'k2s' }
                Mock -ModuleName $moduleName Get-ConfigLinuxOnly { return $true }
                Mock -ModuleName $moduleName Confirm-SetupNameIsValid { return $null } -ParameterFilter { $SetupName -eq 'k2s' }
                Mock -ModuleName $moduleName Get-ProductVersion { return '1.2.3' }
            }

            It 'returns setup name with Linux-only hint' {
                $result = Get-SetupInfo
                $result.Name | Should -Be 'k2s'
                $result.Error | Should -BeNullOrEmpty
                $result.LinuxOnly | Should -BeTrue
                $result.Version | Should -Be 'v1.2.3'
            } 
        }    
    }
    
    Context 'setup name is invalid' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-ConfigSetupType { return 'invalid' }
            Mock -ModuleName $moduleName Get-ConfigLinuxOnly { return $false }
            Mock -ModuleName $moduleName Confirm-SetupNameIsValid { return 'invalid-name' } -ParameterFilter { $SetupName -eq 'invalid' }
            Mock -ModuleName $moduleName Get-ProductVersion { return 'v1' }
        }

        It 'returns validation error only' {
            $result = Get-SetupInfo
            $result.Name | Should -BeNullOrEmpty
            $result.Error | Should -Be 'invalid-name'
            $result.LinuxOnly | Should -BeNullOrEmpty
            $result.Version | Should -BeNullOrEmpty
        }
    }
}
