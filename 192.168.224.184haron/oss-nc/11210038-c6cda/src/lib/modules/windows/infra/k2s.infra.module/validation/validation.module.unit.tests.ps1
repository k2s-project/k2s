# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\validation.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Get-ExceptionMessage' -Tag 'unit', 'ci', 'validation' {
    It 'extracts the message contained in an exception' {
        InModuleScope $moduleName {
            $expectedMessage = 'myExceptionMessage'
        
            Get-ExceptionMessage -Script { throw $expectedMessage } | Should -Be $expectedMessage
        }
    }
    It 'returns default message if no exception is thrown' {
        InModuleScope $moduleName {
            $expectedMessage = 'No exception thrown'
        
            Get-ExceptionMessage -Script { } | Should -Be $expectedMessage
        }
    }
}

Describe 'Assert-LegalCharactersInPath' -Tag 'unit', 'ci', 'validation' {
    It 'with path "<Path>" returns "<ExpectedOutput>"' -ForEach @(
        @{ Path = $null; ExpectedOutput = $false }
        @{ Path = ''; ExpectedOutput = $false }
        @{ Path = '  '; ExpectedOutput = $false }
        # @{ Path = 'Z:\myFol<<r'; ExpectedOutput = $false }         Reason: not working in the pipeline
        # @{ Path = 'Z:\myFolder\myFi<e'; ExpectedOutput = $false }  Reason: not working in the pipeline
        @{ Path = 'Z:\myFolder\myFile'; ExpectedOutput = $true }
    ) {
        InModuleScope $moduleName -Parameters @{Path = $Path; ExpectedOutput = $ExpectedOutput } {
            Assert-LegalCharactersInPath -Path $Path | Should -Be $ExpectedOutput
        }
    }
    It 'uses path value from pipeline by value' {
        InModuleScope $moduleName {
            $path = 'any valid path value'

            $output = $path | Assert-LegalCharactersInPath

            $output | Should -Be $true
        }
    }
}

Describe 'Assert-Pattern' -Tag 'unit', 'ci', 'validation' {
    It 'with missing arguments throws' {
        InModuleScope $moduleName {
            { Assert-Pattern -Pattern 'myPattern' } | Get-ExceptionMessage | Should -BeLike 'Argument missing: Path'
            { Assert-Pattern -Path 'myPath' } | Get-ExceptionMessage | Should -BeLike 'Argument missing: Pattern'
        }
    }
    It "with pattern '<Pattern>' returns '<ShallMatch>'" -ForEach @(
        @{ Pattern = 'path$'; ShallMatch = $true }
        @{ Pattern = 'path    $'; ShallMatch = $false }
        @{ Pattern = 'path'; ShallMatch = $true }
        @{ Pattern = '^path$'; ShallMatch = $false }
        @{ Pattern = '^.*path$'; ShallMatch = $true }
    ) {
        InModuleScope $moduleName -Parameters @{ Pattern = $Pattern; ShallMatch = $ShallMatch } {
            Assert-Pattern -Path 'my very long path' -Pattern $Pattern | Should -Be $ShallMatch
        }
    }
}

Describe 'Assert-Path' -Tag 'unit', 'ci', 'validation' {
    It 'with missing arguments throws' {
        InModuleScope $moduleName {
            { Assert-Path -PathType 'Leaf' -ShallExist $true } | Get-ExceptionMessage | Should -BeLike "Cannot bind argument to parameter 'Path' because it is an empty string."
            { Assert-Path -Path 'any path' -ShallExist $true } | Get-ExceptionMessage | Should -BeLike 'Argument missing: PathType'
            { Assert-Path -Path 'any path' -PathType 'Leaf' } | Get-ExceptionMessage | Should -BeLike 'Argument missing: ShallExist'
            { Assert-Path -Path 'any path' -PathType 'not valid value' -ShallExist $true } | Get-ExceptionMessage | Should -BeLike '*not valid value*Leaf,Container*'
        }
    }
    It 'with not met conditions throws (exist:<Exist>  shallExist:<ShallExist>  shallThrow:<ShallThrow>)' -ForEach @(
        @{ Exist = $true; ShallExist = $true; ShallThrow = $false }
        @{ Exist = $false; ShallExist = $true; ShallThrow = $true }
        @{ Exist = $true; ShallExist = $false; ShallThrow = $true }
        @{ Exist = $false; ShallExist = $false; ShallThrow = $false }
    ) {
        InModuleScope $moduleName -Parameters @{Exist = $Exist; ShallExist = $ShallExist; ShallThrow = $ShallThrow } {
            Mock Test-Path { return $Exist } 
            $path = 'any path'
            $pathType = 'Leaf'
            if ($ShallThrow) {
                $messageSuffix = 'exist'
                if (!$ShallExist) {
                    $messageSuffix = 'not ' + $messageSuffix
                }
                $message = "*The path '$path' shall $messageSuffix*"
                { Assert-Path -Path $path -PathType $pathType -ShallExist $ShallExist } | Get-ExceptionMessage | Should -BeLike $message
            }
            else {
                { Assert-Path -Path $path -PathType $pathType -ShallExist $ShallExist } | Should -Not -Throw
            }
        }
    }
    It 'accepts path from the pipeline and outputs same path value on success' {
        InModuleScope $moduleName {
            Mock Test-Path { return $true } 
            $path = 'any path'
            $anyPathType = 'Leaf'
            $path | Assert-Path -PathType $anyPathType -ShallExist $true | Should -Be $path
        }
    }
}

Describe 'Compare-Hashtables' -Tag 'unit', 'ci', 'validation' {
    It 'with missing arguments throws' {
        InModuleScope $moduleName {
            { Compare-Hashtables -Right @{} } | Get-ExceptionMessage | Should -BeLike 'Argument missing: Left'
            { Compare-Hashtables -Left @{} } | Get-ExceptionMessage | Should -BeLike 'Argument missing: Right'
        }
    }
    It 'with different amount of elements returns false' {
        InModuleScope $moduleName {
            Compare-Hashtables -Left @{'1' = 'one'; '2' = 'two' } -Right @{'1' = 'one' } | Should -Be $false
        }
    }
    It 'with different keys returns false' {
        InModuleScope $moduleName {
            Compare-Hashtables -Left @{'1' = 'one' } -Right @{'one' = '1' } | Should -Be $false
        }
    }
    It 'with different values for same key returns false' {
        InModuleScope $moduleName {
            Compare-Hashtables -Left @{'1' = 'one' } -Right @{'1' = 'other one' } | Should -Be $false
        }
    }
    It 'with same key value pairs returns true' {
        InModuleScope $moduleName {
            Compare-Hashtables -Left @{'1' = 'one'; '2' = 'two' } -Right @{'1' = 'one'; '2' = 'two' } | Should -Be $true
            Compare-Hashtables -Left @{'1' = 'one'; '2' = 'two' } -Right @{'2' = 'two'; '1' = 'one' } | Should -Be $true
        }
    }
}

Describe 'Get-IsValidIPv4Address' -Tag 'unit', 'ci', 'validation' {
    It 'with malformed IPv4 addresses returns "false"' {
        InModuleScope $moduleName {
            $wrongIPv4Values = @($null, '', '  ', 
                '256.100.100.100', '100.256.100.100', '100.100.256.100', '100.100.100.256',
                '100.101.102', 
                'a.101.102.103', '100.b.102.103', '100.101.c.103', '100.101.102.d',
                '-1.101.102.103', '100.-2.102.103', '100.101.-3.103', '100.101.102.-4') 
            foreach ($ipAddress in $wrongIPv4Values) {
                Get-IsValidIPv4Address($ipAddress) | Should -Be $false
            }
        }
    }
    It 'with wellformed IPv4 address returns "true"' {
        InModuleScope $moduleName {
            Get-IsValidIPv4Address('100.101.102.103') | Should -Be $true
        }
    }
}
