# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    function Write-Log {}
    . "$PSScriptRoot\New-K2sDelta.HyperV.ps1"
    . "$PSScriptRoot\New-K2sDelta.ImageAcquisition.ps1"
    Mock Write-Log {}
}

Describe 'Get-K2sPackageBinPath' -Tag 'unit', 'ci', 'delta-package' {
    It 'resolves bin from the platform-first package script directory' {
        $packageDir = Join-Path $TestDrive 'root\lib\scripts\windows\host\system\package'
        New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

        Get-K2sPackageBinPath -ScriptDirectory $packageDir |
            Should -Be (Join-Path $TestDrive 'root\bin')
    }
}

Describe 'Export-ChangedImageLayers' -Tag 'unit', 'ci', 'delta-package' {
    It 'fails the operation when a required Linux image cannot be exported' {
        Mock Export-LinuxImageFromBuildah {
            @{ Success = $false; ErrorMessage = 'export timed out'; ImageInfo = $null; Size = 0 }
        }
        $image = [pscustomobject]@{
            FullName = 'registry.k8s.io/kube-apiserver:v1.37.2'
            Platform = 'linux'
        }
        $context = [pscustomobject]@{
            VmName = 'test-vm'; GuestIp = '192.0.2.10'; SwitchName = 'test-switch'
            NatName = 'test-nat'; HostSwitchIp = '192.0.2.1'
        }

        $result = Export-ChangedImageLayers -NewPackageRoot $TestDrive `
            -NewVhdxPath (Join-Path $TestDrive 'unused.vhdx') -ChangedImages @($image) `
            -StagingDir $TestDrive -ExistingVmContext $context

        $result.Success | Should -BeFalse
        $result.FailedImages | Should -Contain $image.FullName
        $result.ErrorMessage | Should -Match 'kube-apiserver'
    }
}
