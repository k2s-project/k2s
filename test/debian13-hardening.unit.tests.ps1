# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

Describe 'Debian 13 hardening Bash safety checks' -Tag 'unit', 'ci' {
    BeforeAll {
        $gitDirectory = Split-Path (Get-Command git.exe -CommandType Application -ErrorAction Stop).Source -Parent
        $bashPath = $null
        while ($gitDirectory) {
            $candidate = Join-Path $gitDirectory 'bin\bash.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $bashPath = $candidate
                break
            }
            $gitDirectory = Split-Path $gitDirectory -Parent
        }
        if (-not $bashPath) {
            throw 'Git for Windows Bash is required to run Debian 13 hardening safety checks.'
        }
    }

    It 'passes package-safety and real isolated documentation-cleanup checks' {
        $output = & $bashPath "$PSScriptRoot\debian13-hardening.sh" | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 0 -Because $output
        $output | Should -Match '(?m)^Passed=[1-9][0-9]* Failed=0\b'
    }
}
