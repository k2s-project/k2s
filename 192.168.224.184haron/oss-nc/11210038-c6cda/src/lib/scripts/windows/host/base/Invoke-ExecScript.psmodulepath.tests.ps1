# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $script:OriginalPSModulePath = $env:PSModulePath
    $script:InvokeExecScriptPath = Join-Path $PSScriptRoot 'Invoke-ExecScript.ps1'

    $parseErrors = $null
    $invokeExecScriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:InvokeExecScriptPath,
        [ref]$null,
        [ref]$parseErrors
    )

    if ($parseErrors) {
        throw "Failed to parse $script:InvokeExecScriptPath: $($parseErrors[0])"
    }

    $helperFunctionNames = @(
        'Get-WinPSCanonicalModulePath',
        'Test-NeedsWinPSModulePathNormalization',
        'Set-WinPSModulePathIfNeeded'
    )

    $helperFunctionAsts = foreach ($helperFunctionName in $helperFunctionNames) {
        $helperFunctionAst = $invokeExecScriptAst.FindAll({
            param($ast)
            $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $ast.Name -eq $helperFunctionName
        }, $true) | Select-Object -First 1

        if (-not $helperFunctionAst) {
            throw "Function '$helperFunctionName' not found in $script:InvokeExecScriptPath"
        }

        $helperFunctionAst
    }

    $helperFunctionSource = ($helperFunctionAsts |
        Sort-Object { $_.Extent.StartOffset } |
        ForEach-Object { $_.Extent.Text }) -join "`r`n`r`n"

    . ([ScriptBlock]::Create($helperFunctionSource))
}

AfterAll {
    $env:PSModulePath = $script:OriginalPSModulePath
    Remove-Item -Path Function:\Get-WinPSCanonicalModulePath -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Test-NeedsWinPSModulePathNormalization -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Set-WinPSModulePathIfNeeded -ErrorAction SilentlyContinue
}

Describe 'Invoke-ExecScript PSModulePath normalization' -Tag 'unit', 'ci', 'ps7-compat', 'k2s' {

    BeforeEach {
        $env:PSModulePath = $script:OriginalPSModulePath
    }

    Context 'when PSModulePath contains a PowerShell 7 path (pollution detected)' {

        It 'normalizes when Program Files\PowerShell\7\Modules pollution is present' {
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules;C:\Users\user\Documents\PowerShell\Modules'

            $wasChanged = Set-WinPSModulePathIfNeeded

            $wasChanged | Should -BeTrue
            $env:PSModulePath | Should -Not -Match 'PowerShell[/\\]7'
            $env:PSModulePath | Should -Be (Get-WinPSCanonicalModulePath)
        }

        It 'normalizes when Documents\PowerShell\Modules pollution is present' {
            $env:PSModulePath = 'C:\Users\user\Documents\PowerShell\Modules;C:\Windows\System32\WindowsPowerShell\v1.0\Modules'

            $wasChanged = Set-WinPSModulePathIfNeeded

            $wasChanged | Should -BeTrue
            $env:PSModulePath | Should -Be (Get-WinPSCanonicalModulePath)
        }

        It 'normalizes for a forward-slash variant of the pwsh 7 marker' {
            $env:PSModulePath = 'C:/Program Files/PowerShell/7/Modules;C:/Temp/Modules'

            $wasChanged = Set-WinPSModulePathIfNeeded

            $wasChanged | Should -BeTrue
            $env:PSModulePath | Should -Not -Match 'PowerShell[/\\]7'
            $env:PSModulePath | Should -Be (Get-WinPSCanonicalModulePath)
        }
    }

    Context 'when PSModulePath is already a clean WinPS 5.1 path (no pollution)' {

        It 'leaves PSModulePath unchanged for already canonical WinPS module paths' {
            $cleanPath = Get-WinPSCanonicalModulePath
            $env:PSModulePath = $cleanPath

            $wasChanged = Set-WinPSModulePathIfNeeded

            $wasChanged | Should -BeFalse
            $env:PSModulePath | Should -Be $cleanPath
        }

        It 'leaves PSModulePath unchanged when no 7-related segment is present' {
            $cleanPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules;C:\Custom\Modules'
            $env:PSModulePath = $cleanPath

            $wasChanged = Set-WinPSModulePathIfNeeded

            $wasChanged | Should -BeFalse
            $env:PSModulePath | Should -Be $cleanPath
        }
    }

    Context 'when PSModulePath is null or empty' {

        It 'returns false for null and empty input in Test-NeedsWinPSModulePathNormalization' {
            Test-NeedsWinPSModulePathNormalization -ModulePath $null | Should -BeFalse
            Test-NeedsWinPSModulePathNormalization -ModulePath '' | Should -BeFalse
        }

        It 'does not change PSModulePath when env var is null or empty in Set-WinPSModulePathIfNeeded' {
            $env:PSModulePath = $null
            $wasChangedForNull = Set-WinPSModulePathIfNeeded

            $wasChangedForNull | Should -BeFalse
            $env:PSModulePath | Should -BeNullOrEmpty

            $env:PSModulePath = ''
            $wasChangedForEmpty = Set-WinPSModulePathIfNeeded

            $wasChangedForEmpty | Should -BeFalse
            $env:PSModulePath | Should -BeNullOrEmpty
        }
    }
}
