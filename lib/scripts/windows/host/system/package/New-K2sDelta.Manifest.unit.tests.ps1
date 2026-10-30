# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    function Write-Log {}
    . "$PSScriptRoot\New-K2sDelta.Validation.ps1"
    . "$PSScriptRoot\New-K2sDelta.Manifest.ps1"
    Mock Write-Log {}
}

Describe 'Get-PackageKubernetesVersion' -Tag 'unit', 'ci', 'delta-package' {
    It 'reads the default Kubernetes version from an extracted package without importing it' {
        $moduleDir = Join-Path $TestDrive 'lib\modules\windows\infra\k2s.infra.module\config'
        New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null
        @"
function Get-DefaultK8sVersion {
    return 'v1.37.2'
}
"@ | Set-Content -LiteralPath (Join-Path $moduleDir 'config.module.psm1')

        Get-PackageKubernetesVersion -ExtractPath $TestDrive | Should -Be 'v1.37.2'
    }
}

Describe 'New-DeltaManifest' -Tag 'unit', 'ci', 'delta-package' {
    It 'records base and target Kubernetes versions' {
        $oldExtract = Join-Path $TestDrive 'old'
        $newExtract = Join-Path $TestDrive 'new'
        $stageDir = Join-Path $TestDrive 'stage'
        foreach ($extract in @($oldExtract, $newExtract, $stageDir)) {
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
        }

        Set-Content -LiteralPath (Join-Path $oldExtract 'VERSION') -Value '2.0.0'
        Set-Content -LiteralPath (Join-Path $newExtract 'VERSION') -Value '2.1.0'

        $relativeConfigPath = 'lib\modules\windows\infra\k2s.infra.module\config'
        $oldConfigDir = Join-Path $oldExtract $relativeConfigPath
        $newConfigDir = Join-Path $newExtract $relativeConfigPath
        New-Item -ItemType Directory -Path $oldConfigDir, $newConfigDir -Force | Out-Null
        "function Get-DefaultK8sVersion { return 'v1.36.4' }" |
            Set-Content -LiteralPath (Join-Path $oldConfigDir 'config.module.psm1')
        "function Get-DefaultK8sVersion { return 'v1.37.2' }" |
            Set-Content -LiteralPath (Join-Path $newConfigDir 'config.module.psm1')

        $context = @{
            InputPackageOne     = 'k2s-2.0.0.zip'
            InputPackageTwo     = 'k2s-2.1.0.zip'
            OldExtract          = $oldExtract
            NewExtract          = $newExtract
            StageDir            = $stageDir
            WholeDirsNormalized = @()
            SpecialSkippedFiles = @()
            Added               = @()
            Changed             = @()
            Removed             = @()
            DebianPackageDiff   = $null
            OfflineDebInfo      = $null
            ImageDiffResult     = $null
            GuestConfigDiff     = $null
        }

        $manifestPath = New-DeltaManifest -Context $context
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        $manifest.BaseKubernetesVersion | Should -Be 'v1.36.4'
        $manifest.TargetKubernetesVersion | Should -Be 'v1.37.2'
    }
}
