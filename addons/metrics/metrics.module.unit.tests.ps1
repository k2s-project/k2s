# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $moduleName = (Import-Module "$PSScriptRoot\metrics.module.psm1" -PassThru -Force).Name

    function Invoke-Kubectl { param($Params) }
    function Write-Log { param([Parameter(ValueFromPipeline)]$Message, [switch]$Console) }

    $tokens = $null
    $parseErrors = $null
    $enableAst = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\Enable.ps1", [ref]$tokens, [ref]$parseErrors)
    $applyAssignment = $enableAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$apply'
    }, $true)
    $enableApply = $applyAssignment.Right.Expression.ScriptBlock.GetScriptBlock()
}

Describe 'Metrics enable apply' -Tag 'unit', 'ci', 'addon', 'metrics' {
    BeforeEach {
        Mock Write-Log { }
        Mock Invoke-Kubectl { [pscustomobject]@{ Success = $true; Output = '' } }
        $metricsManifest = Get-MetricsServerConfig
    }

    It 'applies the metrics-server manifest and then the full Windows Exporter bundle with -k' {
        (& $enableApply).Success | Should -BeTrue
        Should -Invoke Invoke-Kubectl -Times 1 -Exactly -ParameterFilter { $Params[0] -eq 'apply' -and $Params -contains $metricsManifest }
        Should -Invoke Invoke-Kubectl -Times 1 -Exactly -ParameterFilter { $Params[0] -eq 'apply' -and $Params[1] -eq '-k' -and $Params[2] -like '*\common\manifests\windows-exporter' }
    }

    It 'keeps a selected metrics-server manifest separate from node-local exporter resources' {
        $metricsManifest = 'TestDrive:\metrics-placement.yaml'
        (& $enableApply).Success | Should -BeTrue
        Should -Invoke Invoke-Kubectl -Times 1 -Exactly -ParameterFilter { $Params -contains 'TestDrive:\metrics-placement.yaml' }
        Should -Invoke Invoke-Kubectl -Times 0 -Exactly -ParameterFilter { $Params -contains '-k' -and $Params -contains 'TestDrive:\metrics-placement.yaml' }
    }

    It 'does not fail enable when the exporter step fails' {
        Mock Invoke-Kubectl { [pscustomobject]@{ Success = $false; Output = 'exporter denied' } } -ParameterFilter { $Params -contains '-k' }
        (& $enableApply).Success | Should -BeTrue
    }

    It 'stops before exporter deployment if the metrics-server apply fails' {
        Mock Invoke-Kubectl { [pscustomobject]@{ Success = $false; Output = 'metrics apply denied' } }
        (& $enableApply).Success | Should -BeFalse
        Should -Invoke Invoke-Kubectl -Times 1 -Exactly
    }
}

Describe 'Monitoring full exporter bundle compatibility' -Tag 'unit', 'ci', 'addon', 'metrics' {
    It 'keeps the existing full-bundle apply in monitoring <EntryPoint>' -TestCases @(
        @{ EntryPoint = 'Enable.ps1' }
        @{ EntryPoint = 'Update.ps1' }
    ) {
        param($EntryPoint)
        $tokens = $null
        $parseErrors = $null
        $monitoringAst = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\monitoring\$EntryPoint", [ref]$tokens, [ref]$parseErrors)
        $bundleApply = $monitoringAst.EndBlock.Statements | Where-Object { $_.Extent.Text -match 'Invoke-Kubectl -Params ''apply'', ''-k'', \$windowsExporter' }
        @($bundleApply).Count | Should -Be 1
        $windowsExporterPath = Get-WindowsExporterManifestDir
        $windowsExporterManifest = $windowsExporterPath
        Mock Write-Log { }
        Mock Invoke-Kubectl { [pscustomobject]@{ Success = $true; Output = 'full bundle configured' } }
        & ([scriptblock]::Create($bundleApply.Extent.Text))
        Should -Invoke Invoke-Kubectl -Times 1 -Exactly -ParameterFilter { $Params[0] -eq 'apply' -and $Params[1] -eq '-k' -and $Params[2] -eq $windowsExporterPath }
        Get-Content "$windowsExporterPath\kustomization.yaml" | Should -Contain '  - servicemonitor.yaml'
    }
}
