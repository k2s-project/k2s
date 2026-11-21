# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\formatting.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}

BeforeDiscovery {
    $ageStringTestCases = @(
        @{ Duration = [timespan]::FromTicks(5); Expected = '0s' }
        @{ Duration = [timespan]::FromMilliseconds(5); Expected = '0s' }
        @{ Duration = [timespan]::FromSeconds(5); Expected = '5s' }
        @{ Duration = [timespan]::FromMinutes(5); Expected = '5m' }
        @{ Duration = [timespan]::new(0, 5, 23); Expected = '5m23s' }
        @{ Duration = [timespan]::new(4, 55, 23); Expected = '4h55m23s' }
        @{ Duration = [timespan]::new(5, 0, 0); Expected = '5h' }
        @{ Duration = [timespan]::new(1, 0, 0, 0); Expected = '1d' }
        @{ Duration = [timespan]::new(1, 2, 5, 23); Expected = '1d2h' }
        @{ Duration = [timespan]::new(1, 23, 5, 23); Expected = '1d23h' }
    )
    $unixPathTestCases = @(
        @{ Path = $null; Expected = [string]::Empty }
        @{ Path = [string]::Empty; Expected = [string]::Empty }
        @{ Path = 'dir'; Expected = 'dir' }
        @{ Path = '/dir/to/some/resource'; Expected = '/dir/to/some/resource' }
        @{ Path = '\dir\to\some\resource'; Expected = '/dir/to/some/resource' }
        @{ Path = '\\dir\\to\\some\\resource'; Expected = '//dir//to//some//resource' }
        @{ Path = '\/dir\/to\/some\/resource'; Expected = '//dir//to//some//resource' }
    )
}

Describe 'Convert-ToAgeString' -Tag 'unit', 'ci' {
    It 'Returns <expected> when duration is <duration>' -ForEach $ageStringTestCases {
        InModuleScope $moduleName -Parameters @{Duration = $Duration; Expected = $Expected } {
            Convert-ToAgeString -Duration $Duration | Should -Be $Expected
        }
    }
}

Describe 'Convert-ToUnixPath' -Tag 'unit', 'ci' {
    Context 'path not specified' {
        It 'throws' {
            { Convert-ToUnixPath } | Should -Throw -ExpectedMessage 'path not specified'
        }
    }

    Context 'path specified' {
        It 'Returns <expected> when path is <path>' -ForEach $unixPathTestCases {
            InModuleScope $moduleName -Parameters @{Path = $Path; Expected = $Expected } {
                Convert-ToUnixPath -Path $Path | Should -Be $Expected
            }
        }
    }
}
