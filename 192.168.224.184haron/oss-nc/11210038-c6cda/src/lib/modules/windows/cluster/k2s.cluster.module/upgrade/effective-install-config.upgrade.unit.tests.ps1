# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $moduleName = (Import-Module "$PSScriptRoot\upgrade.module.psm1" -PassThru -Force).Name
}

Describe 'effective install configuration upgrade handling' -Tag 'unit', 'ci', 'upgrade' {
    It 'prefers an explicitly requested config for the forward install' {
        InModuleScope -ModuleName $moduleName {
            Resolve-UpgradeInstallConfig -RequestedConfig 'C:\new config.yaml' -PreviousConfig 'C:\backup\previous.json' | Should -Be 'C:\new config.yaml'
        }
    }

    It 'reuses the previous snapshot when no config is requested' {
        InModuleScope -ModuleName $moduleName {
            Resolve-UpgradeInstallConfig -PreviousConfig 'C:\backup\previous.json' | Should -Be 'C:\backup\previous.json'
        }
    }

    It 'always selects the previous snapshot for rollback' {
        InModuleScope -ModuleName $moduleName {
            Resolve-UpgradeInstallConfig -RequestedConfig 'C:\new config.yaml' -PreviousConfig 'C:\backup\previous.json' -Rollback | Should -Be 'C:\backup\previous.json'
        }
    }

    It 'atomically backs up the linked snapshot with its ACL applied at creation' {
        $configDir = Join-Path $TestDrive 'config'
        $backupDir = Join-Path $TestDrive 'backup'
        $sourcePath = Join-Path $configDir 'effective-install-config.json'
        $setupPath = Join-Path $configDir 'setup.json'
        $null = New-Item -ItemType Directory -Path $configDir
        [System.IO.File]::WriteAllText($sourcePath, '{"kind":"k2s","proxy":"secret"}')
        [System.IO.File]::WriteAllText($setupPath, ('{"EffectiveInstallConfigPath":' + (ConvertTo-Json $sourcePath -Compress) + '}'))

        InModuleScope -ModuleName $moduleName -Parameters @{ SetupPath = $setupPath; BackupDir = $backupDir; SourcePath = $sourcePath } {
            Mock Get-SetupConfigFilePath { $SetupPath }

            $result = Backup-EffectiveInstallConfig -BackupDir $BackupDir

            $result | Should -Be (Join-Path $BackupDir 'effective-install-config.previous.json')
            [System.IO.File]::ReadAllText($result) | Should -Be ([System.IO.File]::ReadAllText($SourcePath))
            $sourceAcl = Get-Acl -LiteralPath $SourcePath
            $resultAcl = Get-Acl -LiteralPath $result
            $resultAcl.Owner | Should -Be $sourceAcl.Owner
            $resultAcl.Group | Should -Be $sourceAcl.Group
            @($resultAcl.Access | ForEach-Object { $_.ToString() }) | Should -Be @($sourceAcl.Access | ForEach-Object { $_.ToString() })
            @(Get-ChildItem -LiteralPath $BackupDir -Filter '*.tmp').Count | Should -Be 0
        }
    }

    It 'returns no config for a legacy setup without a snapshot link' {
        InModuleScope -ModuleName $moduleName {
            Mock Get-SetupConfigFilePath { 'C:\config\setup.json' }
            Mock Test-Path { $true }
            Mock Get-Content { '{"SetupType":"k2s"}' }
            Mock Copy-Item { }

            Backup-EffectiveInstallConfig -BackupDir 'C:\backup' | Should -BeNullOrEmpty
            Should -Invoke Copy-Item -Exactly 0
        }
    }
}
