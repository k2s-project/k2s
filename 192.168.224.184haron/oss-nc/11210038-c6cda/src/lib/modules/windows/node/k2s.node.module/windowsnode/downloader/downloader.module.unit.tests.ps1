# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\downloader.module.psm1"
    Remove-Module downloader.module -Force -ErrorAction SilentlyContinue
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Invoke-PackageWindowsImageDownload' -Tag 'unit', 'ci', 'package' {
    BeforeEach {
        $script:operations = @()

        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Install-WinContainerd { $script:operations += 'install-containerd' }
        Mock -ModuleName $moduleName Set-DirectProxyForPackageContainerd { $script:operations += 'set-direct-proxy' }
        Mock -ModuleName $moduleName Invoke-DownloadWindowsImages { $script:operations += 'download-images' }
        Mock -ModuleName $moduleName Uninstall-WinContainerd { $script:operations += 'uninstall-containerd' }
    }

    It 'installs temporary containerd without transparent proxy and configures direct proxy when proxy is configured' {
        InModuleScope $moduleName {
            Invoke-PackageWindowsImageDownload -DownloadsBaseDirectory 'C:\downloads' -Proxy 'http://proxy.example.com:8080' -WindowsNodeArtifactsDirectory 'C:\windowsnode'
        }

        Should -Invoke Install-WinContainerd -ModuleName $moduleName -Exactly 1 -ParameterFilter {
            $Proxy -eq '' -and
            $SkipNetworkingSetup -eq $true -and
            $WindowsNodeArtifactsDirectory -eq 'C:\windowsnode'
        }
        Should -Invoke Set-DirectProxyForPackageContainerd -ModuleName $moduleName -Exactly 1 -ParameterFilter { $Proxy -eq 'http://proxy.example.com:8080' }
        $script:operations | Should -Be @('install-containerd', 'set-direct-proxy', 'download-images', 'uninstall-containerd')
    }

    It 'keeps temporary containerd without proxy when no proxy is configured' {
        InModuleScope $moduleName {
            Invoke-PackageWindowsImageDownload -DownloadsBaseDirectory 'C:\downloads' -Proxy '' -WindowsNodeArtifactsDirectory 'C:\windowsnode'
        }

        Should -Invoke Install-WinContainerd -ModuleName $moduleName -Exactly 1 -ParameterFilter {
            $Proxy -eq '' -and
            $SkipNetworkingSetup -eq $true -and
            $WindowsNodeArtifactsDirectory -eq 'C:\windowsnode'
        }
        Should -Invoke Set-DirectProxyForPackageContainerd -ModuleName $moduleName -Exactly 1 -ParameterFilter { $Proxy -eq '' }
        $script:operations | Should -Be @('install-containerd', 'set-direct-proxy', 'download-images', 'uninstall-containerd')
    }

    It 'cleans up containerd when image download fails' {
        Mock -ModuleName $moduleName Invoke-DownloadWindowsImages {
            $script:operations += 'download-images'
            throw 'image pull failed'
        }

        InModuleScope $moduleName {
            { Invoke-PackageWindowsImageDownload -DownloadsBaseDirectory 'C:\downloads' -Proxy 'http://proxy.example.com:8080' -WindowsNodeArtifactsDirectory 'C:\windowsnode' } | Should -Throw '*image pull failed*'
        }

        Should -Invoke Uninstall-WinContainerd -ModuleName $moduleName -Exactly 1 -ParameterFilter { $ShallowUninstallation -eq $true }
        $script:operations | Should -Be @('install-containerd', 'set-direct-proxy', 'download-images', 'uninstall-containerd')
    }
}
