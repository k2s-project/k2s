# SPDX-FileCopyrightText:  2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\BackupPersistentVolumes.psm1" -PassThru -Force).Name
}

Describe 'ConvertFrom-PVList' -Tag 'unit', 'ci', 'backup-pv' {
    It 'converts valid PV data correctly' {
        $pvListJson = @{
            items = @(@{
                metadata = @{ name = 'test-pv' }
                spec = @{
                    capacity = @{ storage = '10Gi' }
                    local = @{ path = '/data' }
                    claimRef = @{
                        namespace = 'default'
                        name = 'test-pvc'
                    }
                    persistentVolumeReclaimPolicy = 'Retain'
                }
                status = @{ phase = 'Bound' }
            })
        } | ConvertTo-Json -Depth 10 -Compress

        InModuleScope $moduleName -Parameters @{ pvListJson = $pvListJson } {
            param($pvListJson)
            $result = ConvertFrom-PVList -PVListJson $pvListJson
            
            $result | Should -Not -BeNullOrEmpty           
            $result.Name | Should -Be 'test-pv'
            $result.Type | Should -Be 'local'
            $result.Path | Should -Be '/data'
            $result.Capacity | Should -Be '10Gi'
            $result.ClaimNamespace | Should -Be 'default'
            $result.ClaimName | Should -Be 'test-pvc'
            $result.ReclaimPolicy | Should -Be 'Retain'
            $result.Status | Should -Be 'Bound'
        }
    }

    It 'throws error when required fields are missing' {
        $invalidItems = @(
            @{ metadata = @{ }; spec = @{ capacity = @{ storage = '10Gi' }; local = @{ path = '/data' } }; status = @{ phase = 'Bound' } },
            @{ metadata = @{ name = 'pv2' }; spec = @{ capacity = @{ }; local = @{ path = '/data' } }; status = @{ phase = 'Bound' } },
            @{ metadata = @{ name = 'pv3' }; spec = @{ capacity = @{ storage = '10Gi' }; local = @{ path = '/data' } }; status = @{ } },
            @{ metadata = @{ name = 'pv4' }; spec = @{ capacity = @{ storage = '10Gi' }; local = @{ } }; status = @{ phase = 'Bound' } },
            @{ metadata = @{ name = 'pv5' }; spec = @{ capacity = @{ storage = '10Gi' }; hostPath = @{ } }; status = @{ phase = 'Bound' } }
        )

        InModuleScope $moduleName -Parameters @{ invalidItems = $invalidItems } {
            param($invalidItems)
            
            # Test item 1 - missing metadata.name
            $json1 = (@{ items = @($invalidItems[0]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json1 } catch { $errorMsg1 = $_.Exception.Message }
            $errorMsg1 | Should -BeLike '*metadata.name*'
            
            # Test item 2 - missing spec.capacity.storage
            $json2 = (@{ items = @($invalidItems[1]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json2 } catch { $errorMsg2 = $_.Exception.Message }
            $errorMsg2 | Should -BeLike '*spec.capacity.storage*'
            
            # Test item 3 - missing status.phase
            $json3 = (@{ items = @($invalidItems[2]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json3 } catch { $errorMsg3 = $_.Exception.Message }
            $errorMsg3 | Should -BeLike '*status.phase*'
            
            # Test item 4 - missing spec.local.path
            $json4 = (@{ items = @($invalidItems[3]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json4 } catch { $errorMsg4 = $_.Exception.Message }
            $errorMsg4 | Should -BeLike '*spec.local.path*'
            
            # Test item 5 - missing spec.hostPath.path
            $json5 = (@{ items = @($invalidItems[4]) } | ConvertTo-Json -Depth 10 -Compress)
            try { ConvertFrom-PVList -PVListJson $json5 } catch { $errorMsg5 = $_.Exception.Message }
            $errorMsg5 | Should -BeLike '*spec.hostPath.path*'
        }
    }
}

Describe 'Get-BackupMetadata' -Tag 'unit', 'ci', 'backup-pv' {
    BeforeAll {
        $testDir = Join-Path $TestDrive "backup-metadata-tests"
        New-Item -Path $testDir -ItemType Directory -Force | Out-Null
        
        # Mock Write-Log to suppress error output during tests
        Mock -ModuleName $moduleName Write-Log {}
    }

    It 'loads valid backup metadata successfully' {
        
        $backupPath = Join-Path $testDir "test-pv-backup.tar.gz"
        $metadataPath = Join-Path $testDir "test-pv-backup-metadata.json"
        
       
        "mock backup data" | Set-Content -Path $backupPath -Encoding UTF8
        
        # Create metadata JSON
        $metadata = @{
            version = "1.0"
            backupType = "persistent-volume"
            pvName = "test-pv"
            volumeType = "local"
            volumePath = "/mnt/data"
            capacity = "10Gi"
            createdAt = "2024-12-15T10:00:00Z"
            sourceSize = "500MB"
            archiveSize = "250 MB"
            vmIpAddress = "172.19.1.100"
            backupFile = "test-pv-backup.tar.gz"
            claimNamespace = "default"
            claimName = "test-pvc"
            reclaimPolicy = "Retain"
        }
        $metadata | ConvertTo-Json -Depth 3 | Set-Content -Path $metadataPath -Encoding UTF8

        InModuleScope $moduleName -Parameters @{ backupPath = $backupPath } {
            param($backupPath)
            $result = Get-BackupMetadata -BackupPath $backupPath
            
            $result.Valid | Should -Be $true
            $result.Error | Should -BeNullOrEmpty
            $result.Metadata | Should -Not -BeNullOrEmpty
            $result.Metadata.pvName | Should -Be 'test-pv'
            $result.Metadata.volumeType | Should -Be 'local'
            $result.Metadata.volumePath | Should -Be '/mnt/data'
            $result.Metadata.capacity | Should -Be '10Gi'
            $result.Metadata.claimNamespace | Should -Be 'default'
            $result.Metadata.claimName | Should -Be 'test-pvc'
            $result.BackupFileSize | Should -BeGreaterThan 0
        }
    }

    It 'fails when backup file does not exist' {
        $nonExistentPath = Join-Path $testDir "nonexistent-backup.tar.gz"

        InModuleScope $moduleName -Parameters @{ nonExistentPath = $nonExistentPath } {
            param($nonExistentPath)
            $result = Get-BackupMetadata -BackupPath $nonExistentPath
            
            $result.Valid | Should -Be $false
            $result.Error | Should -BeLike '*not found*'
            $result.Metadata | Should -BeNullOrEmpty
        }
    }

    It 'fails when metadata file is missing' {
        # Create backup file without metadata
        $backupPath = Join-Path $testDir "orphaned-backup.tar.gz"
        "mock backup data" | Set-Content -Path $backupPath -Encoding UTF8

        InModuleScope $moduleName -Parameters @{ backupPath = $backupPath } {
            param($backupPath)
            $result = Get-BackupMetadata -BackupPath $backupPath
            
            $result.Valid | Should -Be $false
            $result.Error | Should -BeLike '*Metadata file not found*'
            $result.Metadata | Should -BeNullOrEmpty
        }
    }

    It 'fails when metadata JSON is invalid' {
        $backupPath = Join-Path $testDir "invalid-metadata-backup.tar.gz"
        $metadataPath = Join-Path $testDir "invalid-metadata-backup-metadata.json"
        
        "mock backup data" | Set-Content -Path $backupPath -Encoding UTF8
        "{ invalid json content" | Set-Content -Path $metadataPath -Encoding UTF8

        InModuleScope $moduleName -Parameters @{ backupPath = $backupPath } {
            param($backupPath)
            $result = Get-BackupMetadata -BackupPath $backupPath
            
            $result.Valid | Should -Be $false
            $result.Error | Should -BeLike '*Error loading metadata*'
            $result.Metadata | Should -BeNullOrEmpty
        }
    }

    It 'correctly reports backup file size' {
        $backupPath = Join-Path $testDir "size-test-backup.tar.gz"
        $metadataPath = Join-Path $testDir "size-test-backup-metadata.json"
        
        # Create larger dummy file (1KB)
        $dummyData = "x" * 1024
        $dummyData | Set-Content -Path $backupPath -Encoding ASCII -NoNewline
        
        $metadata = @{
            version = "1.0"
            pvName = "size-test-pv"
            volumePath = "/data"
        }
        $metadata | ConvertTo-Json | Set-Content -Path $metadataPath -Encoding ASCII

        InModuleScope $moduleName -Parameters @{ backupPath = $backupPath } {
            param($backupPath)
            $result = Get-BackupMetadata -BackupPath $backupPath
            
            $result.Valid | Should -Be $true
            $result.BackupFileSize | Should -Be 1024
        }
    }
}
