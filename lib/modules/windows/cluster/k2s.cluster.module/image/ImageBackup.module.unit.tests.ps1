# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -Modules Pester

BeforeAll {
    # Import required modules
    Import-Module "$PSScriptRoot\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1" -Force
    $modulePath = "$PSScriptRoot\ImageBackup.module.psm1"
    $script:moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe "ImageBackup Module Tests" -Tag 'unit', 'ci' {
    
    Describe "New-EmptyBackupResult" -Tag 'unit', 'ci' {
        Context 'default datetime' {
            It 'returns correct structure with default datetime' {
            $backupDir = "C:\Test\Backup"
            $result = New-EmptyBackupResult -BackupDirectory $backupDir

            $result.BackupDirectory | Should -Be $backupDir
            $result.Images.Count | Should -Be 0
            $result.Success | Should -Be $true
            $result.BackupTimestamp | Should -Match "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"
        }
        }
        
        Context 'custom datetime provider' {
            It 'uses custom datetime provider' {
            $testDate = "2024-01-01 12:00:00"
            $customProvider = { $testDate }
        
            $result = New-EmptyBackupResult -BackupDirectory "C:\Test" -DateTimeProvider $customProvider
            $result.BackupTimestamp | Should -Be $testDate
            }
        }
    }
    
    Describe "New-BackupDirectoryStructure" -Tag 'unit', 'ci' {
        BeforeEach {
            $testDir = "TestDrive:\backup"
            $imagesDir = "TestDrive:\backup\images"
        }
        
        Context 'main directory does not exist' {
            It 'creates main directory' {
            $mockProvider = @{
                TestPath = { param($path) $false }
                NewItem = { param($path, $type) 
                    New-Item -ItemType Directory -Path $path -Force | Out-Null 
                }
                JoinPath = { param($parent, $child) Join-Path $parent $child }
            }             
            { New-BackupDirectoryStructure -BackupDirectory $testDir -FileSystemProvider $mockProvider } | Should -Not -Throw
            }
        }
        
        Context 'images subdirectory requested' {
            It 'creates images subdirectory' {
            $testDir = "TestDrive:\backup"
            $imagesDir = "TestDrive:\backup\images"
            $createCalls = [System.Collections.ArrayList]::new()
            $mockProvider = @{
                TestPath = { param($path) $false }
                NewItem = { param($path, $type) 
                    $createCalls.Add($path) | Out-Null
                }
                JoinPath = { param($parent, $child) Join-Path $parent $child }
            }
            
            New-BackupDirectoryStructure -BackupDirectory $testDir -CreateImagesSubdir -FileSystemProvider $mockProvider
            
            $createCalls | Should -Contain $testDir
            $createCalls | Should -Contain $imagesDir
            }
        }
    }   
    
    Describe "Write-ProcessingProgress" -Tag 'unit', 'ci' {
        Context 'valid parameters' {
            It 'does not throw' {
            $mockImage = @{
                repository = "nginx"
                tag = "latest"
            }
            
            { Write-ProcessingProgress -Current 1 -Total 1 -Action "Testing" -Image $mockImage } | Should -Not -Throw
            }
        }
    }
    
    Describe "Test-ImageOperationParameters" -Tag 'unit', 'ci' {
        Context 'valid parameters' {
            It 'validates parameters successfully' {
            $images = @(
                @{ repository = "nginx"; tag = "latest"; imageid = "123" }
                @{ repository = "redis"; tag = "6"; imageid = "456" }
            )
            
            $result = Test-ImageOperationParameters -BackupDirectory "C:\Valid\Path" -Images $images -RequiredSpaceGB 10
            
            $result.IsValid | Should -Be $true
            $result.Errors.Count | Should -Be 0
            }
        }
        
        Context 'invalid parameters' {
            It 'detects invalid backup directory' {
            $result = Test-ImageOperationParameters -BackupDirectory ""
            
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "BackupDirectory cannot be empty or whitespace"
        }
        
            It 'detects invalid images' {
            $invalidImages = @(
                @{ repository = "nginx" }  # Missing tag and imageid
            )
            
            $result = Test-ImageOperationParameters -Images $invalidImages
            
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "Image at index 0 is missing required properties (repository, tag, imageid)"
        }
        
            It 'detects negative space requirement' {
                $result = Test-ImageOperationParameters -RequiredSpaceGB -5
                
                $result.IsValid | Should -Be $false
                $result.Errors | Should -Contain "RequiredSpaceGB must be a positive number"
            }
        }
    }
    
    Describe "New-ImageProcessingLog" -Tag 'unit', 'ci' {
        Context 'backup log creation' {
            It 'creates backup log with correct format' {
            $logPath = "TestDrive:\backup.log"
            $testResult = @{
                BackupTimestamp = "2024-01-01 12:00:00"
                Images = @(
                    @{ Repository = "nginx"; Tag = "latest"; ImageId = "123" }
                )
                FailedImages = @()
            }
            
            New-ImageProcessingLog -LogPath $logPath -LogType "Backup" -Result $testResult
            
            $logContent = Get-Content $logPath -Raw
            $logContent | Should -Match "K2s Image Backup Log"
            $logContent | Should -Match "Backup Date: 2024-01-01 12:00:00"
            $logContent | Should -Match "nginx:latest"
            }
        }
        
        Context 'restore log with failures' {
            It 'includes failed images in log' {
            $logPath = "TestDrive:\restore.log"
            $testResult = @{
                RestoreTimestamp = "2024-01-01 13:00:00"
                Images = @()
                FailedImages = @(
                    @{ Repository = "redis"; Tag = "6"; ImageId = "456"; Error = "Connection failed" }
                )
            }
            
            New-ImageProcessingLog -LogPath $logPath -LogType "Restore" -Result $testResult -OriginalTimestamp "2024-01-01 12:00:00"
            
            $logContent = Get-Content $logPath -Raw
            $logContent | Should -Match "Failed Images:"
            $logContent | Should -Match "redis:6.*Connection failed"
            $logContent | Should -Match "Original Backup Date: 2024-01-01 12:00:00"
            }
        }
    }

    Describe "Get-K2sImageList" -Tag 'unit', 'ci' {
        Context 'script not found' {
            It 'returns empty array when Get-Images.ps1 does not exist' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock Test-Path { $false }

                    $result = Get-K2sImageList -CrictlExePath 'C:\k\bin\crictl.exe' -CrictlConfigPath 'C:\k\bin\crictl.yaml'

                    $result.Count | Should -Be 0
                }
            }
        }

        Context 'resolves crictl paths from installed cluster folder' {
            It 'accepts explicit crictl paths and returns empty array when script not found' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock Test-Path { $false }

                    $result = Get-K2sImageList -CrictlExePath 'C:\k\bin\crictl.exe' -CrictlConfigPath 'C:\k\bin\crictl.yaml'

                    $result.Count | Should -Be 0
                }
            }

            It 'accepts a non-default install folder path' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock Test-Path { $false }

                    $result = Get-K2sImageList -CrictlExePath 'D:\custom-k2s\bin\crictl.exe' -CrictlConfigPath 'D:\custom-k2s\bin\crictl.yaml'

                    $result.Count | Should -Be 0
                }
            }
        }
    }

    Describe "Backup-K2sImages" -Tag 'unit', 'ci' {
        Context 'empty images list' {
            It 'returns empty backup result without invoking Export-Image.ps1' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock New-EmptyBackupResult { @{ BackupDirectory = 'C:\backup'; Images = @(); Success = $true } }

                    $result = Backup-K2sImages -BackupDirectory 'C:\backup' -Images @()

                    $result.Success | Should -Be $true
                    $result.Images.Count | Should -Be 0
                    Should -Invoke New-EmptyBackupResult -Exactly 1
                }
            }
        }

        Context 'explicit crictl paths bypass default resolution' {
            It 'does not call Get-CrictlExePath when CrictlExePath is supplied' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock New-BackupDirectoryStructure {
                        param($BackupDirectory)
                        New-Item -ItemType Directory -Path (Join-Path $BackupDirectory 'images') -Force | Out-Null
                    }
                    Mock Get-CrictlExePath { 'C:\default\bin\crictl.exe' }
                    Mock Get-KubeBinPath { 'C:\default\bin' }
                    Mock Invoke-Expression {}
                    Mock New-ImageProcessingLog {}
                    Mock Get-ConfiguredLogDirectory { 'TestDrive:\logs' }

                    $exportImageScriptPath = Join-Path $TestDrive 'Export-Image.ps1'
                    Set-Content -Path $exportImageScriptPath -Value @'
param(
    [string] $ExportPath
)
New-Item -ItemType File -Path $ExportPath -Force | Out-Null
'@

                    $images = @(@{ repository = 'nginx'; tag = 'latest'; imageid = 'abc123'; node = 'win'; size = '100MB' })

                    Backup-K2sImages `
                        -BackupDirectory 'TestDrive:\backup' `
                        -Images $images `
                        -CrictlExePath 'C:\old\bin\crictl.exe' `
                        -CrictlConfigPath 'C:\old\bin\crictl.yaml' `
                        -ExportImageScriptPath $exportImageScriptPath

                    Should -Invoke Get-CrictlExePath -Exactly 0
                }
            }
        }

        Context 'same image exists on Linux and Windows nodes (e.g. linkerd proxy)' {
            BeforeEach {
                # Simulates Export-Image.ps1: without a node filter, an image present on both OSes is
                # written as '<name-before-first-dot>_linux.tar' / '_windows.tar' instead of ExportPath
                $script:fakeExportImageScript = Join-Path $TestDrive 'Export-Image-dual.ps1'
                $script:exportCallLog = Join-Path $TestDrive 'export-calls.txt'
                Remove-Item $script:exportCallLog -ErrorAction SilentlyContinue
                Set-Content -Path $script:fakeExportImageScript -Value @"
param([string] `$Name, [string] `$ExportPath, [string] `$Nodes = '', [string] `$CrictlExePath, [string] `$CrictlConfigPath, [string] `$NerdctlExePath, [string] `$CtrExePath)
Add-Content -Path '$script:exportCallLog' -Value "`$Name|`$Nodes|`$ExportPath"
if ([string]::IsNullOrEmpty(`$Nodes)) {
    `$dir = Split-Path `$ExportPath
    `$base = ((Split-Path `$ExportPath -Leaf) -split '\.')[0]
    Set-Content -Path (Join-Path `$dir "`${base}_linux.tar") -Value 'linux'
    Set-Content -Path (Join-Path `$dir "`${base}_windows.tar") -Value 'windows'
} else {
    Set-Content -Path `$ExportPath -Value `$Nodes
}
"@
            }

            It 'backs up one tar per node at the path recorded in the manifest' {
                InModuleScope $script:moduleName -Parameters @{ ExportScript = $script:fakeExportImageScript; CallLog = $script:exportCallLog } {
                    param($ExportScript, $CallLog)
                    Mock Write-Log {}
                    Mock New-ImageProcessingLog {}
                    Mock Get-ConfiguredLogDirectory { 'TestDrive:\logs' }

                    $images = @(
                        @{ repository = 'shsk2s.azurecr.io/linkerd/proxy'; tag = 'edge-25.4.4'; imageid = 'f941e69465d6'; node = 'kubemaster'; size = '53.5MB' },
                        @{ repository = 'shsk2s.azurecr.io/linkerd/proxy-init'; tag = 'v2.4.2'; imageid = '2c6e24514307'; node = 'kubemaster'; size = '21.8MB' },
                        @{ repository = 'shsk2s.azurecr.io/linkerd/proxy'; tag = 'edge-25.4.4'; imageid = 'efb043ee1b09'; node = 'winhost'; size = '132MB' },
                        @{ repository = 'shsk2s.azurecr.io/linkerd/proxy-init'; tag = 'v2.4.2'; imageid = '0adc48dddff4'; node = 'winhost'; size = '121MB' }
                    )

                    $result = Backup-K2sImages -BackupDirectory 'TestDrive:\backup' -Images $images `
                        -CrictlExePath 'C:\old\bin\crictl.exe' -CrictlConfigPath 'C:\old\bin\crictl.yaml' -ExportImageScriptPath $ExportScript

                    $result.Success | Should -Be $true
                    $result.FailedImages.Count | Should -Be 0
                    $result.Images.Count | Should -Be 4

                    $tarFiles = @($result.Images | ForEach-Object { $_.TarFile })
                    ($tarFiles | Select-Object -Unique).Count | Should -Be 4
                    $tarFiles | Should -Contain 'images\images\shsk2s.azurecr.io_linkerd_proxy-edge-25.4.4.tar'
                    $tarFiles | Should -Contain 'images\images\shsk2s.azurecr.io_linkerd_proxy-edge-25.4.4-winhost.tar'

                    # Each tar holds the export of the node recorded for it, so restore imports the right OS variant
                    foreach ($entry in $result.Images) {
                        $file = Join-Path 'TestDrive:\backup\images' (Split-Path $entry.TarFile -Leaf)
                        (Get-Content $file) | Should -Be $entry.Node
                    }

                    $calls = @(Get-Content $CallLog)
                    $calls.Count | Should -Be 4
                    $calls | ForEach-Object { ($_ -split '\|')[1] | Should -Not -BeNullOrEmpty }
                    Test-Path 'TestDrive:\backup\images\shsk2s_linux.tar' | Should -Be $false
                }
            }

            It 'keeps the original file name and no node filter when the image has no node information' {
                InModuleScope $script:moduleName -Parameters @{ ExportScript = $script:fakeExportImageScript; CallLog = $script:exportCallLog } {
                    param($ExportScript, $CallLog)
                    Mock Write-Log {}
                    Mock New-ImageProcessingLog {}
                    Mock Get-ConfiguredLogDirectory { 'TestDrive:\logs' }

                    $images = @(@{ repository = 'docker.io/library/nginx'; tag = 'latest'; imageid = 'abc123'; node = ''; size = '100MB' })

                    $result = Backup-K2sImages -BackupDirectory 'TestDrive:\backup-nonode' -Images $images `
                        -CrictlExePath 'C:\old\bin\crictl.exe' -CrictlConfigPath 'C:\old\bin\crictl.yaml' -ExportImageScriptPath $ExportScript

                    # Without node info the legacy call is unchanged (no -Nodes); fake writes renamed files, so the image fails as before
                    (@(Get-Content $CallLog)[0] -split '\|')[1] | Should -BeNullOrEmpty
                    $result.FailedImages.Count | Should -Be 1
                    $result.FailedImages[0].Error | Should -Match 'did not produce .*docker.io_library_nginx-latest\.tar'
                }
            }

            It 'reports failure when export does not produce the expected tar for a node' {
                InModuleScope $script:moduleName -Parameters @{ CallLog = $script:exportCallLog } {
                    param($CallLog)
                    Mock Write-Log {}
                    Mock New-ImageProcessingLog {}
                    Mock Get-ConfiguredLogDirectory { 'TestDrive:\logs' }

                    $noOutputScript = Join-Path $TestDrive 'Export-Image-noop.ps1'
                    Set-Content -Path $noOutputScript -Value 'param([string] $ExportPath, [string] $Nodes)'

                    $images = @(@{ repository = 'shsk2s.azurecr.io/linkerd/proxy'; tag = 'edge-25.4.4'; imageid = 'f941e69465d6'; node = 'kubemaster'; size = '53.5MB' })

                    $result = Backup-K2sImages -BackupDirectory 'TestDrive:\backup-fail' -Images $images `
                        -CrictlExePath 'C:\old\bin\crictl.exe' -CrictlConfigPath 'C:\old\bin\crictl.yaml' -ExportImageScriptPath $noOutputScript

                    $result.Success | Should -Be $false
                    $result.Images.Count | Should -Be 0
                    $result.FailedImages.Count | Should -Be 1
                }
            }
        }
    }
}

AfterAll {
    Remove-Module $script:moduleName -Force -ErrorAction SilentlyContinue
}
