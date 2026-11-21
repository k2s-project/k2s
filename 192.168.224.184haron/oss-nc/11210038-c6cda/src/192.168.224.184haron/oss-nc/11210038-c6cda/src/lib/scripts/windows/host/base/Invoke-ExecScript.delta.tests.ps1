# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Invoke-ExecScript.ps1'), [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw "Cannot parse execution wrapper: $parseErrors" }

    # Execute only module-path selection, never the privileged execution wrapper.
    $statements = @()
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
        $statements += $statement.Extent.Text
    }
    $script:bootstrap = [scriptblock]::Create(($statements -join "`n").Replace('$PSScriptRoot', '$ScriptRoot'))

    function Invoke-TestBootstrap {
        param([string] $ScriptRoot)
        . $script:bootstrap
        [pscustomobject]@{
            DeltaRoot = $possibleDeltaRoot
            IsDelta = $runningFromDelta
            InfraModule = [IO.Path]::GetFullPath($infraModule)
        }
    }
}

Describe 'Execution wrapper delta bootstrap' -Tag 'unit', 'ci', 'update' {
    BeforeEach {
        $script:originalSystemDrive = $env:SystemDrive
        $env:SystemDrive = Join-Path $TestDrive 'system'
        $script:packageRoot = Join-Path $TestDrive 'delta package'
        $script:installedRoot = Join-Path $TestDrive 'installed'
        $script:baseDir = Join-Path $packageRoot 'lib\scripts\windows\host\base'
        New-Item -ItemType Directory -Path $baseDir, $installedRoot -Force | Out-Null
        $setupDir = Join-Path $env:SystemDrive 'ProgramData\k2s'
        New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
        @{ InstallFolder = $installedRoot } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $setupDir 'setup.json')
    }

    AfterEach {
        $env:SystemDrive = $script:originalSystemDrive
    }

    It 'uses the active installation when the sparse delta has no cfg directory' {
        Set-Content -LiteralPath (Join-Path $packageRoot 'delta-manifest.json') -Value '{}'

        $result = Invoke-TestBootstrap -ScriptRoot $baseDir

        $result.DeltaRoot | Should -Be $packageRoot
        $result.IsDelta | Should -BeTrue
        $result.InfraModule | Should -Be (Join-Path $installedRoot 'lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1')
        Test-Path (Join-Path $packageRoot 'cfg') | Should -BeFalse
    }

    It 'keeps using the package infrastructure for a full package' {
        Remove-Item -LiteralPath (Join-Path $packageRoot 'delta-manifest.json') -ErrorAction SilentlyContinue

        $result = Invoke-TestBootstrap -ScriptRoot $baseDir

        $result.IsDelta | Should -BeFalse
        $result.InfraModule | Should -Be (Join-Path $packageRoot 'lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1')
    }
}
