# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    foreach ($source in @('export.module.psm1', 'oci.module.psm1', 'Export.ps1', 'Import.ps1',
            'common\manifests\addon-sync\base\scripts\Sync-Addons.ps1')) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot $source), [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ($errors | Out-String) }
        foreach ($function in $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -in @('Copy-AddonSharedScripts', 'New-TarGzArchive', 'Expand-TarGzArchive', 'Expand-TarGz')
                }, $true)) {
            . ([scriptblock]::Create($function.Extent.Text))
        }
        if ($source -eq 'Export.ps1') {
            $block = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.IfStatementAst] -and
                    $node.Extent.Text.StartsWith('if (@(Get-ChildItem -LiteralPath $sharedScriptsStaging')
                }, $true)
            if ($null -eq $block) { throw 'Shared scripts export layer was not found.' }
            $script:exportSharedLayer = [scriptblock]::Create($block.Extent.Text)
            $ast.Extent.Text | Should -Match 'Copy-AddonSharedScripts -AddonPath \$manifest.dir.path -ImplementationPath \$dirPath -DestinationPath \$sharedScriptsStaging'
        }
        if ($source -eq 'Import.ps1' -or $source -like '*Sync-Addons.ps1') {
            $switch = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.SwitchStatementAst] -and
                    $node.Condition.Extent.Text -in @('$layerMediaType', '$layer.mediaType')
                }, $true)
            if ($null -eq $switch) { throw "Layer dispatch was not found in '$source'." }
            if ($source -eq 'Import.ps1') {
                $script:importLayer = [scriptblock]::Create($switch.Extent.Text)
            }
            else {
                $script:syncLayer = [scriptblock]::Create($switch.Extent.Text)
            }
        }
    }

    function Write-Log { param($Message, [switch]$Console) }
    function Write-SyncLog { param($Message) }
    function Add-ContentToBlobs { param($BlobsDir, $SourcePath, [switch]$Move) }
}

Describe 'Shared addon scripts export and import' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $addonPath = Join-Path $caseRoot 'storage'
        $artifactPath = Join-Path $caseRoot 'artifact'
        $sharedScriptsStaging = Join-Path $artifactPath 'shared'
        New-Item -ItemType Directory -Path $addonPath, $sharedScriptsStaging -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $addonPath 'storage-validation.module.psm1') -Value 'shared validation'
        Set-Content -LiteralPath (Join-Path $addonPath 'storage-validation.module.psm1.license') -Value 'license'
        Set-Content -LiteralPath (Join-Path $addonPath 'README.md') -Value 'shared storage documentation'
        Set-Content -LiteralPath (Join-Path $addonPath 'README.md.license') -Value 'readme license'
        Mock Add-ContentToBlobs {
            @{ Digest = 'sha256:test'; Size = (Get-Item -LiteralPath $SourcePath).Length }
        }
    }

    It 'round-trips the shared module to the addon root for <Implementation>' -TestCases @(
        @{ Implementation = 'smb' }
        @{ Implementation = 'ceph' }
    ) {
        param($Implementation)

        $sourceImplementation = Join-Path $addonPath $Implementation
        New-Item -ItemType Directory -Path $sourceImplementation -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sourceImplementation 'Enable.ps1') -Value 'implementation only'
        Copy-AddonSharedScripts -AddonPath $addonPath -ImplementationPath $sourceImplementation -DestinationPath $sharedScriptsStaging

        Test-Path (Join-Path $sharedScriptsStaging 'Enable.ps1') | Should -BeFalse
        $ociMediaTypes = @{ SharedScripts = 'application/vnd.k2s.addon.shared-scripts.v1.tar+gzip' }
        $ociLayerDescriptors = @()
        $addonName = "storage $Implementation"
        $blobsDir = $artifactPath
        . $script:exportSharedLayer
        $ociLayerDescriptors.Count | Should -Be 1
        $ociLayerDescriptors[0].mediaType | Should -Be $ociMediaTypes.SharedScripts
        $blobPath = Join-Path $artifactPath 'shared-scripts.tar.gz'
        $layer = $ociLayerDescriptors[0]
        $layerMediaType = $layer.mediaType

        foreach ($consumer in @('import', 'sync')) {
            $destinationPath = Join-Path $caseRoot "$consumer\storage"
            $implementationPath = Join-Path $destinationPath $Implementation
            New-Item -ItemType Directory -Path $implementationPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $implementationPath 'README.md') -Value 'implementation documentation'
            if ($consumer -eq 'import') { . $script:importLayer }
            else { . $script:syncLayer }

            Get-Content -LiteralPath (Join-Path $destinationPath 'storage-validation.module.psm1') | Should -Be 'shared validation'
            Get-Content -LiteralPath (Join-Path $destinationPath 'storage-validation.module.psm1.license') | Should -Be 'license'
            Get-Content -LiteralPath (Join-Path $destinationPath 'README.md') | Should -Be 'shared storage documentation'
            Get-Content -LiteralPath (Join-Path $destinationPath 'README.md.license') | Should -Be 'readme license'
            Get-Content -LiteralPath (Join-Path $implementationPath 'README.md') | Should -Be 'implementation documentation'
            Test-Path (Join-Path $implementationPath 'storage-validation.module.psm1') | Should -BeFalse
        }
    }

    It 'fails export explicitly when the required storage validation module is missing' {
        Remove-Item -LiteralPath (Join-Path $addonPath 'storage-validation.module.psm1')
        { Copy-AddonSharedScripts -AddonPath $addonPath -ImplementationPath (Join-Path $addonPath 'smb') -DestinationPath $sharedScriptsStaging } |
            Should -Throw '*shared module*is missing*'
    }

    It 'does not duplicate scripts for a single-implementation addon' {
        Copy-AddonSharedScripts -AddonPath $addonPath -ImplementationPath $addonPath -DestinationPath $sharedScriptsStaging
        @(Get-ChildItem -LiteralPath $sharedScriptsStaging).Count | Should -Be 0
    }

    It 'does not create a shared layer for other multi-implementation addons' -TestCases @(
        @{ Addon = 'ingress'; Implementation = 'nginx-gw' }
        @{ Addon = 'rollout'; Implementation = 'argocd' }
    ) {
        param($Addon, $Implementation)

        $otherAddon = Join-Path $caseRoot $Addon
        New-Item -ItemType Directory -Path $otherAddon -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $otherAddon 'common.module.psm1') -Value 'unrelated helper'
        Set-Content -LiteralPath (Join-Path $otherAddon 'README.md') -Value 'unrelated documentation'
        Copy-AddonSharedScripts -AddonPath $otherAddon -ImplementationPath (Join-Path $otherAddon $Implementation) -DestinationPath $sharedScriptsStaging

        @(Get-ChildItem -LiteralPath $sharedScriptsStaging).Count | Should -Be 0
        $ociLayerDescriptors = @()
        . $script:exportSharedLayer
        $ociLayerDescriptors.Count | Should -Be 0
        Should -Invoke Add-ContentToBlobs -Times 0 -Exactly
    }

    It 'does not include unrelated storage-root scripts' {
        Set-Content -LiteralPath (Join-Path $addonPath 'unrelated.ps1') -Value 'unrelated script'
        Copy-AddonSharedScripts -AddonPath $addonPath -ImplementationPath (Join-Path $addonPath 'smb') -DestinationPath $sharedScriptsStaging

        @(Get-ChildItem -LiteralPath $sharedScriptsStaging).Count | Should -Be 4
        Test-Path (Join-Path $sharedScriptsStaging 'unrelated.ps1') | Should -BeFalse
    }

    It 'keeps unscoped script layers in the implementation directory' {
        $blobPath = Join-Path $artifactPath 'scripts.tar.gz'
        New-TarGzArchive -SourcePath $sharedScriptsStaging -DestinationPath $blobPath -ArchiveContents | Should -BeTrue
        $destinationPath = Join-Path $caseRoot 'legacy\storage'
        $implementationPath = Join-Path $destinationPath 'smb'
        $layerMediaType = 'application/vnd.k2s.addon.scripts.v1.tar+gzip'
        Mock Expand-TarGzArchive { } -Verifiable
        . $script:importLayer
        Should -Invoke Expand-TarGzArchive -Times 1 -Exactly -ParameterFilter { $DestinationPath -eq $implementationPath }
    }
}

Describe 'Addon export in a Linux-only setup' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $script:exportAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'Export.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ($errors | Out-String) }
        $block = $script:exportAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text.StartsWith('if (-not $exportWindowsImages)')
            }, $true)
        if ($null -eq $block) { throw 'Windows image skipping was not found in Export.ps1.' }
        $script:skipWindowsImages = [scriptblock]::Create($block.Extent.Text)
    }

    It 'no longer rejects a Linux-only setup' {
        $script:exportAst.Extent.Text | Should -Not -Match 'Cannot export addons in Linux-only setup'
        $script:exportAst.Extent.Text | Should -Match '\$exportWindowsImages = \$setupInfo\.LinuxOnly -ne \$true'
    }

    It 'does not query the Windows node of a Linux-only setup' {
        $script:exportAst.Extent.Text | Should -Match 'if \(\$exportWindowsImages\) \{ Get-ContainerImagesOnWindowsNode'
    }

    It 'skips the Windows images when there is no Windows node' {
        Mock Write-Log { }
        $exportWindowsImages = $false
        $addonName = 'security'
        $windowsImages = @('mcr.microsoft.com/windows/nanoserver:ltsc2022', 'mcr.microsoft.com/windows/servercore:ltsc2022')

        . $script:skipWindowsImages

        @($windowsImages).Count | Should -Be 0
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'Skipping 2 Windows image(s) of addon security*' }
    }

    It 'keeps the Windows images when the setup has a Windows node' {
        $exportWindowsImages = $true
        $windowsImages = @('mcr.microsoft.com/windows/nanoserver:ltsc2022')

        . $script:skipWindowsImages

        $windowsImages | Should -Be @('mcr.microsoft.com/windows/nanoserver:ltsc2022')
    }

    It 'does not report anything when there are no Windows images' {
        Mock Write-Log { }
        $exportWindowsImages = $false
        $addonName = 'registry'
        $windowsImages = $null

        . $script:skipWindowsImages

        @($windowsImages).Count | Should -Be 0
        Should -Invoke Write-Log -Times 0
    }

    It 'skips the Windows packages of a Linux-only setup as well' {
        $script:exportAst.Extent.Text | Should -Match '\$exportWindowsPackages = \$exportWindowsImages'
        $block = $script:exportAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text.StartsWith('if (-not $exportWindowsPackages')
            }, $true)
        $block | Should -Not -BeNullOrEmpty
        Mock Write-Log { }
        $exportWindowsPackages = $false
        $addonName = 'security'
        $windowsCurlPackages = @(@{ url = 'https://example.com/cmctl.exe' }, @{ url = 'https://example.com/kyverno.zip' })

        . ([scriptblock]::Create($block.Extent.Text))

        $windowsCurlPackages.Count | Should -Be 0
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter { $Message -like 'Skipping 2 Windows package(s) of addon security*' }
    }
}

Describe 'Addon export failures' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot 'Export.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw ($errors | Out-String) }
        $script:exportTry = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.TryStatementAst] -and
                $null -ne $node.Finally -and $node.Finally.Extent.Text -match 'http_proxy'
            }, $true)
        if ($null -eq $script:exportTry) { throw 'The export try statement was not found in Export.ps1.' }
    }

    It 'turns an error that ends the export into a failure instead of an artifact without addons' {
        $script:exportTry.CatchClauses.Count | Should -Be 1
    }

    It 'removes the staging directory and reports the error' {
        function New-Error { param($Code, $Message) @{ Code = $Code; Message = $Message } }
        function Send-ToCli { param($MessageType, $Message) $script:sentError = $Message.Error }
        $tmpExportDir = Join-Path $TestDrive 'tmp-exported-addons'
        New-Item -ItemType Directory -Path (Join-Path $tmpExportDir 'artifacts') -Force | Out-Null
        $EncodeStructuredOutput = $true
        $MessageType = 'CmdResult'
        $body = $script:exportTry.CatchClauses[0].Body.Extent.Text
        $catchBody = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
        $failure = [System.Management.Automation.ErrorRecord]::new(
            [System.Management.Automation.CommandNotFoundException]::new("The term 'crictl.exe' is not recognized"),
            'CommandNotFoundException', 'ObjectNotFound', $null)

        $failure | ForEach-Object { . $catchBody }

        Test-Path $tmpExportDir | Should -BeFalse
        $script:sentError.Code | Should -Be 'addon-export-failed'
        $script:sentError.Message | Should -Be "Exporting the addons failed: The term 'crictl.exe' is not recognized"
    }
}
