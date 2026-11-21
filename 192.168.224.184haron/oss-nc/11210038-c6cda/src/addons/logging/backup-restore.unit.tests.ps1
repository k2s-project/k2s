# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Cluster-free unit tests for the logging addon Backup.ps1 / Restore.ps1 ConfigMap selection.
#
# Background (issue #2559): the Windows Fluent Bit ConfigMaps now embed the configured K2s log root
# (the __LOG_ROOT__ placeholder is substituted at addon enable time). Backing up the live, already
# substituted ConfigMap and restoring it verbatim on a host with a different log root would
# reintroduce stale, host-specific paths. These tests assert that the generated Fluent Bit
# ConfigMaps are NOT part of backup/restore, while the OpenSearch config still is.

BeforeAll {
    $script:backupPath = Join-Path $PSScriptRoot 'Backup.ps1'
    $script:restorePath = Join-Path $PSScriptRoot 'Restore.ps1'

    # The stateful ConfigMap that MUST remain in backup/restore.
    $script:retainedConfigMap = 'opensearch-cluster-master-config'

    # Parse Backup.ps1 with the PowerShell AST and collect the -Name argument of every
    # Try-ExportMinimalConfigMap invocation (i.e. every ConfigMap that is actually exported).
    function Get-BackedUpConfigMapNames {
        param([string] $Path)

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $calls = $ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Try-ExportMinimalConfigMap' }, $true)

        $names = @()
        foreach ($call in $calls) {
            $elements = $call.CommandElements
            for ($i = 0; $i -lt $elements.Count; $i++) {
                $el = $elements[$i]
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $el.ParameterName -eq 'Name' -and ($i + 1) -lt $elements.Count) {
                    $names += $elements[$i + 1].Value
                }
            }
        }
        return , $names
    }

    # Parse Restore.ps1 and return the leaf file names referenced inside the $filesToApply array.
    function Get-RestoredFileNames {
        param([string] $Path)

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $assignment = $ast.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$filesToApply' }, $true) | Select-Object -First 1

        $names = @()
        if ($assignment) {
            $strings = $assignment.Right.FindAll(
                { param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
            foreach ($s in $strings) {
                if ($s.Value -like '*.json') { $names += (Split-Path -Leaf $s.Value) }
            }
        }
        return , $names
    }
}

Describe 'logging Backup.ps1 ConfigMap selection' -Tag 'unit', 'ci', 'addon' {
    It 'exists' {
        Test-Path -LiteralPath $backupPath | Should -BeTrue
    }

    It 'backs up the OpenSearch config ConfigMap' {
        $names = Get-BackedUpConfigMapNames -Path $backupPath
        $names | Should -Contain $retainedConfigMap
    }

    It 'does NOT back up any generated Fluent Bit ConfigMap (<_>)' -ForEach @('fluent-bit', 'fluent-bit-win-parsers', 'fluent-bit-win-config') {
        $names = Get-BackedUpConfigMapNames -Path $backupPath
        $names | Should -Not -Contain $_
    }

    It 'exports exactly one ConfigMap' {
        $names = Get-BackedUpConfigMapNames -Path $backupPath
        $names.Count | Should -Be 1
    }
}

Describe 'logging Restore.ps1 ConfigMap selection' -Tag 'unit', 'ci', 'addon' {
    It 'exists' {
        Test-Path -LiteralPath $restorePath | Should -BeTrue
    }

    It 'restores the OpenSearch config file' {
        $names = Get-RestoredFileNames -Path $restorePath
        $names | Should -Contain 'opensearch-config.json'
    }

    It 'does NOT restore Fluent Bit config files' {
        $names = Get-RestoredFileNames -Path $restorePath
        $names | Should -Not -Contain 'fluent-bit-config.json'
        $names | Should -Not -Contain 'fluent-bit-win-parsers.json'
        $names | Should -Not -Contain 'fluent-bit-win-config.json'
    }

    It 'applies exactly one config file' {
        $names = Get-RestoredFileNames -Path $restorePath
        $names.Count | Should -Be 1
    }
}



