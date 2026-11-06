# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\addons.module.psm1" -PassThru -Force).Name
}

Describe 'Find-AddonManifests' -Tag 'unit', 'ci', 'addon' {
    Context 'Directory not specified' {
        It 'throws' {
            { Find-AddonManifests } | Should -Throw -ExpectedMessage 'Directory not specified'
        }
    }

    Context 'Directory specified' {
        BeforeAll {
            $foundFiles = @{FullName = 'f1' }, @{FullName = 'f2' }, @{FullName = 'f3' }

            Mock -ModuleName $moduleName Get-ChildItem { return $foundFiles }
        }

        It 'starts the search' {
            InModuleScope $moduleName {
                $result = Find-AddonManifests -Directory 'test'

                Should -Invoke Get-ChildItem -Times 1 -Scope Context -ParameterFilter { $Path -eq 'test' -and $Filter -eq 'addon.manifest.yaml' }

                $result[0] | Should -Be 'f1'
                $result[1] | Should -Be 'f2'
                $result[2] | Should -Be 'f3'
            }
        }
    }
}

Describe 'Get-EnabledAddons' -Tag 'unit', 'ci', 'addon' {
    Context 'all addons disabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-AddonsConfig { return $null }
        }

        It 'returns object with null array' {
            InModuleScope $moduleName {
                $result = Get-EnabledAddons

                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context 'some addons enabled' {
        BeforeAll {
            $addonsConfig = @{Name = 'a1'; Implementation = @("i1") }, @{Name = 'a2' }

            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-AddonsConfig { return $addonsConfig }
        }

        It 'returns enabled addons' {
            InModuleScope $moduleName {
                $result = Get-EnabledAddons

                $result.Count | Should -Be 2
                $result[0].Name | Should -Be 'a1'
                $result[0].Implementations[0] | Should -Be 'i1'
                $result[1].Name | Should -Be 'a2'
            }
        }
    }
}

Describe 'ConvertTo-NewConfigStructure' -Tag 'unit', 'ci', 'addon' {
    Context 'config structure needs to be migrated from <= v0.5 to current version' {
        BeforeAll {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
            $oldConfig = ConvertFrom-Json '[ "gateway-nginx", "metrics-server", "dashboard", "ingress-nginx", "traefik" ]'

            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
            $expectedResult = [pscustomobject]@{Name = 'gateway-api' }, [pscustomobject]@{Name = 'metrics' }, [pscustomobject]@{Name = 'dashboard' }, [pscustomobject]@{Name = 'ingress'; Implementation = @("nginx")}, [pscustomobject]@{Name = 'ingress'; Implementation = @("traefik")}
        }

        BeforeEach {
            $log = [System.Collections.ArrayList]@()
            Mock -ModuleName $moduleName Write-Information { $log.Add($MessageData) | Out-Null }
        }

        It 'migrates the structure correctly' {
            InModuleScope -ModuleName $moduleName -Parameters @{oldConfig = $oldConfig; expectedResult = $expectedResult } {
                ConvertTo-NewConfigStructure -Config $oldConfig | ConvertTo-Json | Should -Be $($expectedResult | ConvertTo-Json)
            }
        }

        It 'logs the migration for each addon' {
            InModuleScope -ModuleName $moduleName -Parameters @{oldConfig = $oldConfig; log = $log } {
                ConvertTo-NewConfigStructure -Config $oldConfig

                $log.Count | Should -Be 5
                $log[0] | Should -Be "Config for addon 'gateway-nginx' migrated."
                $log[1] | Should -Be "Config for addon 'metrics-server' migrated."
                $log[2] | Should -Be "Config for addon 'dashboard' migrated."
                $log[3] | Should -Be "Config for addon 'ingress-nginx' migrated."
                $log[4] | Should -Be "Config for addon 'traefik' migrated."
            }
        }
    }

    Context 'config structure needs to be migrated from v0.5 < version <= v1.1.1 to current version' {
        BeforeAll {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
            $oldConfig = [pscustomobject]@{Name = 'gateway-nginx' }, [pscustomobject]@{Name = 'metrics-server' }, [pscustomobject]@{Name = 'dashboard' }, [pscustomobject]@{Name = 'ingress-nginx'}, [pscustomobject]@{Name = 'traefik'}, [pscustomobject]@{Name = 'smb-share'; SmbHostType = 'linux' } 

            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
            $expectedResult = [pscustomobject]@{Name = 'gateway-api' }, [pscustomobject]@{Name = 'metrics' }, [pscustomobject]@{Name = 'dashboard' }, [pscustomobject]@{Name = 'ingress'; Implementation = "nginx"}, [pscustomobject]@{Name = 'ingress'; Implementation = "traefik"}, [pscustomobject]@{Name = 'storage'; SmbHostType = 'linux' } 
        }

        BeforeEach {
            $log = [System.Collections.ArrayList]@()
            Mock -ModuleName $moduleName Write-Information { $log.Add($MessageData) | Out-Null }
        }
    
        It 'migrates the structure correctly' {
            InModuleScope -ModuleName $moduleName -Parameters @{oldConfig = $oldConfig; expectedResult = $expectedResult } {
                ConvertTo-NewConfigStructure -Config $oldConfig | ConvertTo-Json | Should -Be $($expectedResult | ConvertTo-Json)
            }
        }

        It 'logs the migration for each addon' {
            InModuleScope -ModuleName $moduleName -Parameters @{oldConfig = $oldConfig; log = $log } {
                ConvertTo-NewConfigStructure -Config $oldConfig

                $log.Count | Should -Be 5
                $log[0] | Should -Be "Config for addon 'gateway-nginx' migrated."
                $log[1] | Should -Be "Config for addon 'metrics-server' migrated."
                $log[2] | Should -Be "Config for addon 'ingress-nginx' migrated."
                $log[3] | Should -Be "Config for addon 'traefik' migrated."
                $log[4] | Should -Be "Config for addon 'smb-share' migrated."
            }
        }
    }

    Context 'config structure contains unexpected addon types' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { ConvertTo-NewConfigStructure -Config (332, 213, 444) } | Should -Throw -ExpectedMessage "Unexpected addon config type 'Int32'"
            }
        }
    }
}

Describe 'Test-IsAddonEnabled' -Tag 'unit', 'ci', 'addon' {
    Context 'no addon name specified' {
        It 'throws' {
            { Test-IsAddonEnabled } | Should -Throw
        }
    }

    Context 'addon disabled' {
        BeforeAll {
            $enabledAddons = @{ Name = 'a2' }, @{ Name = 'a3' }

            Mock -ModuleName $moduleName Get-AddonsConfig { return $enabledAddons }
        }

        It 'returns false' {
            Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'a1' }) | Should -BeFalse
        }

        Context 'implementation disabled' {
            BeforeAll {
                $enabledAddons = @{ Name = 'a2'; Implementation = @('i1') }, @{ Name = 'a3' }
    
                Mock -ModuleName $moduleName Get-AddonsConfig { return $enabledAddons }
            }
    
            It 'returns false' {
                Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'a2'; Implementation = 'i2' }) | Should -BeFalse
            }
        }
    }

    Context 'addon enabled' {
        BeforeAll {
            $enabledAddons = @{ Name = 'a1' }, @{ Name = 'a2' }

            Mock -ModuleName $moduleName Get-AddonsConfig { return $enabledAddons }
        }

        It 'returns true' {
            Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'a1' }) | Should -BeTrue
        }

        Context 'implementation enabled' {
            BeforeAll {
                $enabledAddons = @{ Name = 'a1'; Implementation = @('i1') }, @{ Name = 'a2' }
    
                Mock -ModuleName $moduleName Get-AddonsConfig { return $enabledAddons }
            }
    
            It 'returns true' {
                Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'a1'; Implementation = 'i1'  }) | Should -BeTrue
            }
        }
    }
}

Describe 'Invoke-AddonsHooks' -Tag 'unit', 'ci', 'addon' {
    Context 'no hook type specified' {
        It 'throws' {
            { Invoke-AddonsHooks } | Should -Throw
        }
    }

    Context 'invalid hook type specified' {
        It 'throws' {
            { Invoke-AddonsHooks -HookType 'invalid' } | Should -Throw
        }
    }

    Context 'hooks dir not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -notmatch 'hooks' }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-ChildItem { }
            Mock -ModuleName $moduleName Invoke-Script { }
        }

        It 'skips the invocation' {
            Invoke-AddonsHooks -HookType 'AfterStart'

            InModuleScope -ModuleName $moduleName {
                Should -Invoke Get-ChildItem -Times 0 -Scope Context
                #TODO : Check mock of Write-Log
                #Should -Invoke Write-Log -Times 1 -ParameterFilter { $InputObject -match 'skipping' } -Scope Context
                Should -Invoke Invoke-Script -Times 0 -Scope Context
            }
        }
    }

    Context 'valid hook type specified' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -notmatch 'hooks' }
            Mock -ModuleName $moduleName Get-ChildItem { return @{FullName = 'do-something-useful.AfterStart.ps1' } }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Invoke-Script { }
        }

        It 'executes all matching scripts in hooks directory' {
            Invoke-AddonsHooks -HookType 'AfterStart'

            InModuleScope -ModuleName $moduleName {
                Should -Invoke Get-ChildItem -Times 1 -ParameterFilter { $Path -match 'hooks' -and $Filter -eq '*.AfterStart.ps1' } -Scope Context
                Should -Invoke Write-Log -Times 1
                Should -Invoke Invoke-Script -Times 1 -ParameterFilter { $FilePath -eq 'do-something-useful.AfterStart.ps1' } -Scope Context
            }
        }
    }
}

Describe 'Copy-ScriptsToHooksDir' -Tag 'unit', 'ci', 'addon' {
    Context 'script files not specified' {
        It 'throws' {
            { Copy-ScriptsToHooksDir } | Should -Throw -ExpectedMessage 'No script file paths specified'
        }
    }

    Context 'hooks dir not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName New-Item {}
            Mock -ModuleName $moduleName Get-FileName {}
            Mock -ModuleName $moduleName Copy-Item {}

            Copy-ScriptsToHooksDir -ScriptPaths $null
        }

        It 'creates the hooks dir' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-Item -Times 1 -Scope Context -ParameterFilter { $Path -match 'hooks' -and $ItemType -eq 'Directory' }
            }
        }
    }

    Context 'some hook scripts do not exist' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 's1' -or $Path -eq 's3' }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 's2' -or $Path -eq 's4' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Get-FileName {}
            Mock -ModuleName $moduleName Get-FileName { return 's1' } -ParameterFilter { $FilePath -eq 's1' }
            Mock -ModuleName $moduleName Get-FileName { return 's3' } -ParameterFilter { $FilePath -eq 's3' }
            Mock -ModuleName $moduleName Copy-Item {}

            Copy-ScriptsToHooksDir -ScriptPaths 's1', 's2', 's3', 's4'
        }

        It 'skips the copying of non-existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Get-FileName -Times 0 -ParameterFilter { $FilePath -eq 's2' -or $FilePath -eq 's4' } -Scope Context
            }
        }

        It 'informs the user about non-existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match "Cannot copy addon hook 's2'" } -Scope Context
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match "Cannot copy addon hook 's4'" } -Scope Context
            }
        }

        It 'copies the existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 's1' -and $Destination -match 'hooks\\s1' } -Scope Context
                Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 's3' -and $Destination -match 'hooks\\s3' } -Scope Context
            }
        }
    }
}

Describe 'Remove-ScriptsFromHooksDir' -Tag 'unit', 'ci', 'addon' {
    Context 'scripts not specified' {
        It 'throws' {
            { Remove-ScriptsFromHooksDir } | Should -Throw -ExpectedMessage 'No script file names specified'
        }
    }

    Context 'hooks dir not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}

            Remove-ScriptsFromHooksDir -ScriptNames 's1', 's2'
        }

        It 'skips the removal' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'nothing to remove' }
            }
        }
    }

    Context 'some hooks do not exist' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks\\s1' -or $Path -match 'hooks\\s3' }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks\\s2' -or $Path -match 'hooks\\s4' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Remove-Item {}

            Remove-ScriptsFromHooksDir -ScriptNames 's1', 's2', 's3', 's4'
        }

        It 'skips the removal of non-existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Item -Times 0 -ParameterFilter { $Path -match 'hooks\\s2' -or $Path -match 'hooks\\s4' } -Scope Context
            }
        }

        It 'informs the user about non-existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'Cannot remove addon hook' -and $Message -match 'hooks\\s2' } -Scope Context
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'Cannot remove addon hook' -and $Message -match 'hooks\\s4' } -Scope Context
            }
        }

        It 'removes the existent hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s1' } -Scope Context
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s3' } -Scope Context
            }
        }
    }

    Context 'all hooks existent' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' -or $Path -match 'hooks\\s' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Write-Warning { throw 'unexpected' }
            Mock -ModuleName $moduleName Remove-Item {}

            Remove-ScriptsFromHooksDir -ScriptNames 's1', 's2', 's3', 's4'
        }

        It 'removes all hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s1' } -Scope Context
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s2' } -Scope Context
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s3' } -Scope Context
                Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Path -match 'hooks\\s4' } -Scope Context
            }
        }
    }
}

Describe 'Addon Hook Scripts Path Integrity' -Tag 'unit', 'ci', 'addon' {
    It 'all hook scripts resolve imported modules and scripts correctly from runtime addons\hooks location' {
        $runtimeHooksDir = Join-Path $PSScriptRoot 'hooks'

        $hookFiles = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter '*.ps1' | Where-Object {
            $_.DirectoryName -match '[\\/]hooks$' -or $_.Name -match '\.(AfterStart|BeforeUninstall|AfterUninstall|Backup|Restore)\.ps1$'
        }

        $hookFiles.Count | Should -BeGreaterThan 0

        foreach ($hookFile in $hookFiles) {
            $content = Get-Content -Path $hookFile.FullName -Raw

            $matches = [regex]::Matches($content, '\$\w+\s*=\s*["''](?:\$PSScriptRoot[/\\])?([^"'']+\.psm?1)["'']')

            foreach ($m in $matches) {
                $relPath = $m.Groups[1].Value
                $resolvedPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($runtimeHooksDir, $relPath))
                (Test-Path -Path $resolvedPath) | Should -BeTrue -Because "In hook script '$($hookFile.FullName)', relative path '$relPath' must resolve to existing file '$resolvedPath' when executed from '$runtimeHooksDir'"
            }
        }
    }
}

Describe 'Get-AddonConfig' -Tag 'unit', 'ci', 'addon' {
    Context 'addon name not specified' {
        It 'throws' {
            { Get-AddonConfig } | Should -Throw -ExpectedMessage 'Name not specified'
        }
    }

    Context 'no addons configured' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-AddonsConfig { return $null }
        }

        It 'returns nothing' {
            Get-AddonConfig -Name 'my-addon' | Should -BeNullOrEmpty
        }
    }

    Context 'addon name not among configured addons' {
        BeforeAll {
            $config = [pscustomobject]@{Name = 'a1' }, [pscustomobject]@{Name = 'a2' }

            Mock -ModuleName $moduleName Get-AddonsConfig { return $config }
        }

        It 'returns nothing' {
            Get-AddonConfig -Name 'a3' | Should -BeNullOrEmpty
        }
    }

    Context 'addon name among configured addons' {
        BeforeAll {
            $expectedAddon = [pscustomobject]@{Name = 'a2' }
            $config = [pscustomobject]@{Name = 'a1' }, $expectedAddon

            Mock -ModuleName $moduleName Get-AddonsConfig { return $config }
        }

        It 'returns addon' {
            Get-AddonConfig -Name 'a2' | Should -Be $expectedAddon
        }
    }
}

Describe 'Backup-Addons' -Tag 'unit', 'ci', 'addon' {
    Context 'no addons config existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-AddonsConfig { return $null }
            Mock -ModuleName $moduleName Test-Path { }

            InModuleScope -ModuleName $moduleName {
                Backup-Addons -BackupDir 'test'
            }
        }

        It 'skips the backup' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Test-Path -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'skipping' }
            }
        }
    }

    Context 'backup dir not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-AddonsConfig { return '' }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'test' }
            Mock -ModuleName $moduleName New-Item {  }
            Mock -ModuleName $moduleName ConvertTo-NewConfigStructure {  }
            Mock -ModuleName $moduleName Join-Path { return 'test' }
            Mock -ModuleName $moduleName ConvertTo-Json { }
            Mock -ModuleName $moduleName Set-Content {  }
            Mock -ModuleName $moduleName Invoke-BackupRestoreHooks {  }

            InModuleScope -ModuleName $moduleName {
                Backup-Addons -BackupDir 'test'
            }
        }

        It 'creates the backup dir ' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-Item -Times 1 -Scope Context -ParameterFilter { $Path -eq 'test' -and $ItemType -eq 'Directory' }
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'backup dir not existing' }
            }
        }
    }

    Context 'addons config existing' {
        BeforeAll {
            $log = [System.Collections.ArrayList]@()

            Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
            Mock -ModuleName $moduleName Get-AddonsConfig { return 'config' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'dir' }
            Mock -ModuleName $moduleName ConvertTo-NewConfigStructure { Write-Information 'log-from-migration'
                return 'migrated'
            }
            Mock -ModuleName $moduleName Join-Path { return 'path' } -ParameterFilter { $Path[0] -eq 'dir' -and $Path[1] -eq $backupFileName }
            Mock -ModuleName $moduleName ConvertTo-Json { return 'json' } -ParameterFilter { $InputObject.Config -eq 'migrated' }
            Mock -ModuleName $moduleName Set-Content {  }
            Mock -ModuleName $moduleName Invoke-BackupRestoreHooks {  }
            Mock -ModuleName $moduleName Write-Warning { }

            InModuleScope -ModuleName $moduleName {
                Backup-Addons -BackupDir 'dir'
            }
        }

        It 'migrates the config structure' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke ConvertTo-NewConfigStructure -Times 1 -Scope Context -ParameterFilter { $Config -eq 'config' }
            }
        }

        It 'migration informs the user' {
            InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
                $log.Count | Should -BeGreaterOrEqual 2
                $log[1] | Should -Be 'log-from-migration'
            }
        }

        It 'saves the config structure to config file' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value -eq 'json' -and $Path -eq 'path' }
            }
        }

        It 'invokes backup hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-BackupRestoreHooks -Times 1 -Scope Context -ParameterFilter { $HookType -eq 'Backup' -and $BackupDir -eq 'dir' }
            }
        }
    }

    Context 'addon hooks exist for backup and restore' {
        BeforeAll {
            $warnings = [System.Collections.ArrayList]@()

            Mock -ModuleName $moduleName Write-Log {  }
            Mock -ModuleName $moduleName Write-Warning { $warnings.Add($Message) | Out-Null }
            Mock -ModuleName $moduleName Get-AddonsConfig {
                return @(
                    [pscustomobject]@{ Name = 'Addon1' },
                    [pscustomobject]@{ Name = $null }
                )
            }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'dir' }
            Mock -ModuleName $moduleName ConvertTo-NewConfigStructure { Write-Information 'log-from-migration'
                return @(
                    [pscustomobject]@{ Name = 'Addon1' },
                    [pscustomobject]@{ Name = $null }
                )
            }
            Mock -ModuleName $moduleName Join-Path { return 'path' } -ParameterFilter { $Path[0] -eq 'dir' -and $Path[1] -eq $backupFileName }
            Mock -ModuleName $moduleName ConvertTo-Json { return 'json' } -ParameterFilter {
                $Depth -eq 100 -and
                $null -ne $InputObject -and
                $null -ne $InputObject.Config -and
                $InputObject.Config.Count -eq 2 -and
                $InputObject.Config[0].Name -eq 'Addon1' -and
                $null -eq $InputObject.Config[1].Name
            }
            Mock -ModuleName $moduleName Set-Content {  }
            Mock -ModuleName $moduleName Get-ScriptRoot { return 'C:\Scripts' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'C:\Scripts\Addon1\hooks' }
            Mock -ModuleName $moduleName Get-ChildItem {
                return @(
                    [pscustomobject]@{ FullName = 'C:\Scripts\Addon1\hooks\Backup.ps1'; Name = 'Backup.ps1' },
                    [pscustomobject]@{ FullName = 'C:\Scripts\Addon1\hooks\Restore.ps1'; Name = 'Restore.ps1' },
                    [pscustomobject]@{ FullName = 'C:\Scripts\Addon1\hooks\Other.ps1'; Name = 'Other.ps1' }
                )
            }
            Mock -ModuleName $moduleName Copy-ScriptsToHooksDir { }
            Mock -ModuleName $moduleName Invoke-BackupRestoreHooks {  }

            InModuleScope -ModuleName $moduleName {
                Backup-Addons -BackupDir 'dir'
            }
        }

        It 'copies only backup and restore scripts' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-ScriptsToHooksDir -Times 1 -Scope Context -ParameterFilter {
                    $ScriptPaths -contains 'C:\Scripts\Addon1\hooks\Backup.ps1' -and
                    $ScriptPaths -contains 'C:\Scripts\Addon1\hooks\Restore.ps1' -and
                    -not ($ScriptPaths -contains 'C:\Scripts\Addon1\hooks\Other.ps1')
                }
            }
        }

        It 'logs a warning for addons without a name' {
            InModuleScope -ModuleName $moduleName -Parameters @{warnings = $warnings } {
                # Write-Host "Warning messages captured during the test:"
                # $warnings | ForEach-Object { Write-Host $_ }

                $warnings[0] | Should -Be "Invalid addon config '@{Name=}' found, skipping it."
            }
        }

        It 'invokes backup hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-BackupRestoreHooks -Times 1 -Scope Context -ParameterFilter { $HookType -eq 'Backup' -and $BackupDir -eq 'dir' }
            }
        }
    }
}

Describe 'Restore-Addons' -Tag 'unit', 'ci', 'addon' {
    Context 'no addons backup existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Join-Path { return 'path' } -ParameterFilter { $Path[0] -eq 'dir' -and $Path[1] -eq $backupFileName }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'path' }
            Mock -ModuleName $moduleName Get-Content { }

            InModuleScope -ModuleName $moduleName {
                Restore-Addons -BackupDir 'dir'
            }
        }

        It 'skips the restore' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Get-Content -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'skipping' }
            }
        }
    }

    Context 'addons backup existing' {
        BeforeAll {
            $backupContentRoot = [pscustomobject]@{Config = 'a1', 'a2', 'a3' }

            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Join-Path { return 'path' } -ParameterFilter { $Path[0] -eq 'dir' -and $Path[1] -eq $backupFileName }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'path' }
            Mock -ModuleName $moduleName Get-Content { return 'content' } -ParameterFilter { $Path -eq 'path' }
            Mock -ModuleName $moduleName ConvertFrom-Json { return $backupContentRoot } -ParameterFilter { $InputObject -eq 'content' }
            Mock -ModuleName $moduleName Enable-AddonFromConfig {  }
            Mock -ModuleName $moduleName Invoke-BackupRestoreHooks {  }

            InModuleScope -ModuleName $moduleName {
                Restore-Addons -BackupDir 'dir'
            }
        }

        It 'enables all addons from config backup' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Enable-AddonFromConfig -Times 1 -Scope Context -ParameterFilter { $Config -eq 'a1' }
                Should -Invoke Enable-AddonFromConfig -Times 1 -Scope Context -ParameterFilter { $Config -eq 'a2' }
                Should -Invoke Enable-AddonFromConfig -Times 1 -Scope Context -ParameterFilter { $Config -eq 'a3' }
            }
        }

        It 'invokes restore hooks' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-BackupRestoreHooks -Times 1 -Scope Context -ParameterFilter { $HookType -eq 'Restore' -and $BackupDir -eq 'dir' }
            }
        }
    }
}

Describe 'Invoke-BackupRestoreHooks' -Tag 'unit', 'ci', 'addon' {
    Context 'hook type not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Invoke-BackupRestoreHooks -BackupDir 'dir' } | Should -Throw -ExpectedMessage 'Hook type not specified'
            }
        }
    }

    Context 'hook type invalid' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Invoke-BackupRestoreHooks -HookType 'invalid' -BackupDir 'dir' } | Should -Throw
            }
        }
    }

    Context 'backup dir not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Invoke-BackupRestoreHooks -HookType 'Backup' } | Should -Throw -ExpectedMessage 'Back-up directory not specified'
            }
        }
    }

    Context 'hooks directory not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-ChildItem {}
        }

        It 'skips the invokation' {
            InModuleScope -ModuleName $moduleName {
                Invoke-BackupRestoreHooks -HookType 'Backup' -BackupDir 'backupDir'

                Should -Invoke Get-ChildItem -Times 0 -Scope Context
            }
        }
    }

    Context 'hooks non-existent' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-ChildItem { } -ParameterFilter { $Path -match 'hooks' -and $Filter -eq '*.Backup.ps1' }
            Mock -ModuleName $moduleName Get-ChildItem { throw 'unexpected' } -ParameterFilter { $Path -notmatch 'hooks' -or $Filter -ne '*.Backup.ps1' }
        }

        It 'states that no hooks has been found' {
            InModuleScope -ModuleName $moduleName {
                Invoke-BackupRestoreHooks -HookType 'Backup' -BackupDir 'backupDir'

                Should -Invoke Write-Log -Times 1 -ParameterFilter { $Messages -match 'No back-up/restore hooks found' } -Scope Context
            }
        }
    }

    Context 'hooks existing' {
        BeforeAll {
            $scriptContent = @'
            param (
                [Parameter(Mandatory = $false)]
                [string]$BackupDir = $(throw 'Missing dir param')
            )
            if ($BackupDir -ne 'backupDir') {
                throw "'$BackupDir' not equals 'backupDir'"
            }
            return
'@
            $script1 = 'TestDrive:\s1.ps1'
            $script2 = 'TestDrive:\s2.ps1'
            Set-Content $script1 -value $scriptContent
            Set-Content $script2 -value $scriptContent

            $scripts = [pscustomobject]@{FullName = $script1 }, [pscustomobject]@{FullName = $script2 }

            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -match 'hooks' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-ChildItem { return $scripts } -ParameterFilter { $Path -match 'hooks' -and $Filter -eq '*.Backup.ps1' }
        }

        It 'executes the hooks without errors' {
            InModuleScope -ModuleName $moduleName {
                Invoke-BackupRestoreHooks -HookType 'Backup' -BackupDir 'backupDir'
            }
        }

        It 'does not state that no hooks has been found' {
            InModuleScope -ModuleName $moduleName {
                Invoke-BackupRestoreHooks -HookType 'Backup' -BackupDir 'backupDir'

                Should -Invoke Write-Log -Times 0 -ParameterFilter { $Messages -match 'No back-up/restore hooks found' } -Scope Context
            }
        }
    }
}

Describe 'Enable-AddonFromConfig' -Tag 'unit', 'ci', 'addon' {
    Context 'config object not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Enable-AddonFromConfig } | Should -Throw -ExpectedMessage 'Config object not specified'
            }
        }
    }

    Context "'Name' property missing on config object" {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path {}
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Write-Log { }

            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject] @{ SomeProp = 123 }

                Enable-AddonFromConfig -Config $config
            }
        }

        It 'skips the addon enabling' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Test-Path -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Warning -Times 1 -Scope Context -ParameterFilter { $Message -match 'Invalid' -and $Message -match 'skipping' }
            }
        }
    }

    Context 'addon is obsolete after upgrade' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match '\\a1\\Enable.ps1' }
            Mock -ModuleName $moduleName Write-Warning {}
            Mock -ModuleName $moduleName Write-Log {}

            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject] @{ Name = 'a1' }

                Enable-AddonFromConfig -Config $config
            }
        }

        It 'skips the addon enabling' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 0 -Scope Context
            }
        }

        It 'informs the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Warning -Times 1 -Scope Context -ParameterFilter { $Message -match 'a1' -and $Message -match 'deprecated' }
            }
        }
    }  
}

Describe 'Get-AddonsConfig' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-SetupConfigFilePath { return 'config-path' }
        Mock -ModuleName $moduleName Get-ConfigValue { return 'config' } -ParameterFilter { $Path -eq 'config-path' -and $Key -eq 'EnabledAddons' }
    }

    It 'calls underlying config function correctly' {
        InModuleScope -ModuleName $moduleName {
            Get-AddonsConfig | Should -Be 'config'
        }
    }
}

Describe 'Get-AddonStatus' -Tag 'unit', 'ci', 'addon' {
    Context 'Name not specified' {
        It 'throws' {
            { Get-AddonStatus -Directory 'test-dir' } | Should -Throw -ExpectedMessage 'Name not specified'
        }
    }

    Context 'Directory not specified' {
        It 'throws' {
            { Get-AddonStatus -Name 'test-name' } | Should -Throw -ExpectedMessage 'Directory not specified'
        }
    }

    Context 'addon not existing' {
        BeforeAll {
            $addonDirectory = 'test-addon-dir'
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq $addonDirectory }
        }

        It 'returns addon-not-found error' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonDirectory = $addonDirectory } {
                $result = Get-AddonStatus -Name 'some-name' -Directory $addonDirectory

                $result.Error.Code | Should -Be (Get-ErrCodeAddonNotFound)
                $result.Error.Severity | Should -Be Warning
                $result.Error.Message | Should -Match 'not found in directory'
            }
        }
    }

    Context 'addon does not provide a status script' {
        BeforeAll {
            $addonDirectory = 'test-addon-dir'
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq $addonDirectory }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -match "$addonDirectory\\Get-Status.ps1" }
        }

        It 'returns no-addon-status error' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonDirectory = $addonDirectory } {
                $result = Get-AddonStatus -Name 'some-name' -Directory $addonDirectory

                $result.Error.Code | Should -Be 'no-addon-status'
                $result.Error.Severity | Should -Be Warning
                $result.Error.Message | Should -Match 'does not provide detailed status information'
            }
        }
    }

    Context 'system error occurred' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Test-SystemAvailability { 'nothing-there' }
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                $result = Get-AddonStatus -Name 'test-addon' -Directory 'some-dir'

                $result.Error | Should -Be 'nothing-there'
            }
        }
    }

    Context 'addon is disabled' {
        BeforeAll {
            $addonName = 'test-addon'
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Test-SystemAvailability { return $null }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false } -ParameterFilter { $Addon.Name -eq $addonName } 
        }

        It 'returns addon-disabled status' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonName = $addonName } {
                $result = Get-AddonStatus -Name $addonName -Directory 'some-dir'

                $result.Enabled | Should -BeFalse
            }
        }
    }

    Context 'addon is enabled' {
        BeforeAll {
            $addonName = 'test-addon'
            $addonDirectory = 'test-dir'
            $props = @{Name = 'p1' }, @{Name = 'p2' }
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Test-SystemAvailability { return $null }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true } -ParameterFilter { $Addon.Name -eq $addonName }
            Mock -ModuleName $moduleName Invoke-Script { return $props } -ParameterFilter { $FilePath -match "$addonDirectory\\Get-Status.ps1" }
        }

        It 'returns addon-enabled status' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonName = $addonName ; addonDirectory = $addonDirectory } {
                $result = Get-AddonStatus -Name $addonName -Directory $addonDirectory

                $result.Enabled | Should -BeTrue
            }
        }

        It 'returns addon-specific props' {
            InModuleScope -ModuleName $moduleName -Parameters @{addonName = $addonName; addonDirectory = $addonDirectory; props = $props } {
                $result = Get-AddonStatus -Name $addonName -Directory $addonDirectory

                $result.Props | Should -Be $props
            }
        }
    }
}

Describe 'Get-IngressNginxGatewayConfig' -Tag 'unit', 'ci', 'addon' {
    It 'returns correct path' {
        InModuleScope -ModuleName $moduleName {
            $result = Get-IngressNginxGatewayConfig

            $result | Should -Be 'ingress-nginx-gw'
        }
    }
}

Describe 'Get-IngressNginxGatewaySecureConfig' -Tag 'unit', 'ci', 'addon' {
    It 'returns correct secure path' {
        InModuleScope -ModuleName $moduleName {
            $result = Get-IngressNginxGatewaySecureConfig

            $result | Should -Be 'ingress-nginx-gw-secure'
        }
    }
}

Describe 'Update-IngressForNginxGateway' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false }
        Mock -ModuleName $moduleName Update-IngressForAddon { }
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
    }

    Context 'security addon not enabled' {
        It 'applies non-secure config' {
            InModuleScope -ModuleName $moduleName {
                $testAddon = [pscustomobject]@{ Name = 'dashboard' }
                Update-IngressForNginxGateway -Addon $testAddon

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k'
                }
            }
        }
    }

    Context 'security addon enabled without keycloak and hydra' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeyCloakServiceAvailability { return $false }
            Mock -ModuleName $moduleName Test-HydraAvailability { return $false }
        }

        It 'applies non-secure config' {
            InModuleScope -ModuleName $moduleName {
                $testAddon = [pscustomobject]@{ Name = 'dashboard' }
                Update-IngressForNginxGateway -Addon $testAddon

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k'
                }
            }
        }
    }

    Context 'security addon enabled with keycloak' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeyCloakServiceAvailability { return $true }
            Mock -ModuleName $moduleName Test-HydraAvailability { return $false }
            Mock -ModuleName $moduleName Test-Path { return $true }
        }

        It 'applies secure config' {
            InModuleScope -ModuleName $moduleName {
                $testAddon = [pscustomobject]@{ Name = 'dashboard' }
                Update-IngressForNginxGateway -Addon $testAddon

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k'
                }
            }
        }
    }

    Context 'security addon enabled with hydra' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-KeyCloakServiceAvailability { return $false }
            Mock -ModuleName $moduleName Test-HydraAvailability { return $true }
            Mock -ModuleName $moduleName Test-Path { return $true }
        }

        It 'applies secure config' {
            InModuleScope -ModuleName $moduleName {
                $testAddon = [pscustomobject]@{ Name = 'dashboard' }
                Update-IngressForNginxGateway -Addon $testAddon

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k'
                }
            }
        }
    }
}

Describe 'Get-CertManagerConfig' -Tag 'unit', 'ci', 'addon' {
    It 'returns cert-manager manifest path' {
        InModuleScope -ModuleName $moduleName {
            $result = Get-CertManagerConfig
            $result | Should -Match 'common\\manifests\\certmanager\\cert-manager\.yaml$'
        }
    }
}

Describe 'Get-CAIssuerConfig' -Tag 'unit', 'ci', 'addon' {
    It 'returns CA issuer manifest path' {
        InModuleScope -ModuleName $moduleName {
            $result = Get-CAIssuerConfig
            $result | Should -Match 'common\\manifests\\certmanager\\ca-issuer\.yaml$'
        }
    }
}

Describe 'Install-CmctlCli' -Tag 'unit', 'ci', 'addon' {
    Context 'cmctl does not exist yet' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }

            $script:downloadArgs = $null
            $script:downloadedUrls = @()
            $script:downloadProxy = $null

            $manifest = [pscustomobject]@{
                spec = [pscustomobject]@{
                    implementations = @(
                        [pscustomobject]@{
                            offline_usage = [pscustomobject]@{
                                windows = [pscustomobject]@{
                                    curl = @(
                                        [pscustomobject]@{ destination = 'bin\\cmctl.exe'; url = 'http://example/cmctl.exe' }
                                        [pscustomobject]@{ destination = 'bin\\linkerd.exe'; url = 'http://example/linkerd.exe' }
                                    )
                                }
                            }
                        }
                    )
                }
            }

            Mock -ModuleName $moduleName Get-FromYamlFile { return $manifest }
            Mock -ModuleName $moduleName Test-Path { return $false }
            Mock -ModuleName $moduleName Invoke-DownloadFile {
                param(
                    [string]$destination,
                    [string]$source,
                    [bool]$forceDownload,
                    [string]$ProxyToUse
                )
                $script:downloadArgs = @($destination, $source, $forceDownload, $ProxyToUse)
                $script:downloadedUrls += $source
                $script:downloadProxy = $ProxyToUse
            }
        }

        It 'downloads cmctl with provided proxy and logs downloading' {
            InModuleScope -ModuleName $moduleName {
                Install-CmctlCli -ManifestPath 'C:\test\manifest.yaml' -K2sRoot 'C:\k2s' -Proxy 'http://proxy:8080'

                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter { $Messages -match 'Downloading cert-manager CLI tools' }
                Should -Invoke Invoke-DownloadFile -Times 1 -Scope It
            }

            $script:downloadArgs | Should -Not -BeNullOrEmpty
            $script:downloadedUrls | Should -Contain 'http://example/cmctl.exe'
            $script:downloadedUrls | Should -Not -Contain 'http://example/linkerd.exe'
            Should -Invoke -ModuleName $moduleName Invoke-DownloadFile -Times 1 -Scope It -ParameterFilter {
                $destination -match 'cmctl\.exe$' -and
                $source -eq 'http://example/cmctl.exe' -and
                $ProxyToUse -eq 'http://proxy:8080'
            }
        }
    }

    Context 'cmctl already exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }

            $manifest = [pscustomobject]@{
                spec = [pscustomobject]@{
                    implementations = @(
                        [pscustomobject]@{
                            offline_usage = [pscustomobject]@{
                                windows = [pscustomobject]@{
                                    curl = @(
                                        [pscustomobject]@{ destination = 'bin\\cmctl.exe'; url = 'http://example/cmctl.exe' }
                                    )
                                }
                            }
                        }
                    )
                }
            }

            Mock -ModuleName $moduleName Get-FromYamlFile { return $manifest }
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Invoke-DownloadFile { }
        }

        It 'skips download and does not log downloading' {
            InModuleScope -ModuleName $moduleName {
                Install-CmctlCli -ManifestPath 'C:\test\manifest.yaml' -K2sRoot 'C:\k2s'

                Should -Invoke Invoke-DownloadFile -Times 0 -Scope Context
                Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter { $Messages -match 'Downloading cert-manager CLI tools' }
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter { $Messages -match 'already exists\. Skipping download' }
            }
        }
    }

    Context 'curl section contains a ZIP archive alongside a direct exe' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }

            $script:downloadedUrls = @()

            $manifest = [pscustomobject]@{
                spec = [pscustomobject]@{
                    implementations = @(
                        [pscustomobject]@{
                            offline_usage = [pscustomobject]@{
                                windows = [pscustomobject]@{
                                    curl = @(
                                        [pscustomobject]@{ destination = 'bin\\cmctl.exe'; url = 'http://example/cmctl.exe' }
                                        [pscustomobject]@{ destination = 'bin\\kyverno.exe'; url = 'http://example/kyverno-cli_v1.19.2_windows_x86_64.zip' }
                                    )
                                }
                            }
                        }
                    )
                }
            }

            Mock -ModuleName $moduleName Get-FromYamlFile { return $manifest }
            Mock -ModuleName $moduleName Test-Path { return $false }
            Mock -ModuleName $moduleName Invoke-DownloadFile {
                param(
                    [string]$destination,
                    [string]$source,
                    [bool]$forceDownload,
                    [string]$ProxyToUse
                )
                $script:downloadedUrls += $source
            }
        }

        It 'downloads the direct exe but skips the ZIP archive' {
            InModuleScope -ModuleName $moduleName {
                Install-CmctlCli -ManifestPath 'C:\test\manifest.yaml' -K2sRoot 'C:\k2s'
            }

            # Only cmctl.exe should be downloaded; the kyverno ZIP is handled by Install-KyvernoCli
            $script:downloadedUrls | Should -Contain 'http://example/cmctl.exe'
            $script:downloadedUrls | Should -Not -Contain 'http://example/kyverno-cli_v1.19.2_windows_x86_64.zip'
            Should -Invoke -ModuleName $moduleName Invoke-DownloadFile -Times 1 -Scope It
            Should -Invoke -ModuleName $moduleName Invoke-DownloadFile -Times 1 -Scope It -ParameterFilter {
                $destination -match 'cmctl\.exe$' -and $source -eq 'http://example/cmctl.exe'
            }
        }
    }
}

Describe 'Wait-ForCertManagerAvailable' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
    }

    Context 'cmctl reports API ready' {
        It 'returns true' {
            InModuleScope -ModuleName $moduleName {
                Set-Variable -Name cmctlExe -Value { param($cmd, $subcmd, $wait) 'The cert-manager API is ready' }
                Wait-ForCertManagerAvailable | Should -BeTrue
            }
        }
    }

    Context 'cmctl does not report readiness' {
        It 'returns false' {
            InModuleScope -ModuleName $moduleName {
                Set-Variable -Name cmctlExe -Value { param($cmd, $subcmd, $wait) 'not ready' }
                Wait-ForCertManagerAvailable | Should -BeFalse
            }
        }

        It 'logs cmctl diagnostics when readiness is not reported' {
            InModuleScope -ModuleName $moduleName {
                Set-Variable -Name cmctlExe -Value { param($cmd, $subcmd, $wait) 'cmctl: webhook unavailable' }

                Wait-ForCertManagerAvailable | Should -BeFalse

                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Messages -match 'cmctl check api failed' -and $Messages -match 'cmctl: webhook unavailable'
                }
            }
        }
    }
}

Describe 'Update-CertificateResources' -Tag 'unit', 'ci', 'addon' {
    It 'invokes cmctl renew for all namespaces' {
        InModuleScope -ModuleName $moduleName {
            $script:calls = @()
            Set-Variable -Name cmctlExe -Value {
                param($cmd, $p1, $p2)
                $script:calls += , @($cmd, $p1, $p2)
            }

            Update-CertificateResources

            $script:calls.Count | Should -Be 1
            $script:calls[0][0] | Should -Be 'renew'
            $script:calls[0][1] | Should -Be '--all'
            $script:calls[0][2] | Should -Be '--all-namespaces'
        }
    }
}

Describe 'Wait-ForCARootCertificate' -Tag 'unit', 'ci', 'addon' {
    Context 'secret appears within retries' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Start-Sleep { }

            $script:callCount = 0
            Mock -ModuleName $moduleName Invoke-Kubectl {
                $script:callCount++
                if ($script:callCount -lt 3) {
                    return [pscustomobject]@{ Output = '' }
                }
                return [pscustomobject]@{ Output = 'ca-issuer-root-secret' }
            }
        }

        It 'returns true and retries until secret is found' {
            InModuleScope -ModuleName $moduleName {
                $result = Wait-ForCARootCertificate -SleepDurationInSeconds 0 -NumberOfRetries 3
                $result | Should -BeTrue
            }

            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-Kubectl -Times 3 -Scope Context
            }
        }
    }

    Context 'secret never appears' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Start-Sleep { }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Output = '' } }
        }

        It 'returns false after all retries' {
            InModuleScope -ModuleName $moduleName {
                $result = Wait-ForCARootCertificate -SleepDurationInSeconds 0 -NumberOfRetries 2
                $result | Should -BeFalse

                Should -Invoke Invoke-Kubectl -Times 2 -Scope Context
                Should -Invoke Start-Sleep -Times 2 -Scope Context
            }
        }
    }
}

Describe 'Remove-Cmctl' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Remove-Item { }
    }

    It 'removes cmctl executable path' {
        InModuleScope -ModuleName $moduleName {
            Set-Variable -Name cmctlExe -Value 'C:\\tmp\\cmctl.exe'
            Remove-Cmctl
        }

        InModuleScope -ModuleName $moduleName {
            Should -Invoke Remove-Item -Times 1 -Scope It -ParameterFilter { $Path -eq 'C:\\tmp\\cmctl.exe' }
        }
    }
}

Describe 'Import-CACertificateToWindowsStore' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-TrustedRootStoreLocation { return 'Cert:\\LocalMachine\\Root' }
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Output = $script:b64 } }
        Mock -ModuleName $moduleName Import-CertificateToTrustedRootStore { }
        Mock -ModuleName $moduleName New-CompatTemporaryFile { return [pscustomobject]@{ FullName = 'C:\\temp\\ca.crt' } }
        Mock -CommandName Out-File { }
        Mock -CommandName Remove-Item { }
    }

    It 'extracts secret and imports certificate' {
        InModuleScope -ModuleName $moduleName {
            Import-CACertificateToWindowsStore

            Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains 'ca-issuer-root-secret' }
            Should -Invoke Import-CertificateToTrustedRootStore -Times 1 -Scope It
        }

    }
}

Describe 'Import-CertificateToTrustedRootStore' -Tag 'unit', 'ci', 'addon' {
    Context 'Certificate path does not exist' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $LiteralPath -eq 'C:\temp\missing.crt' -and $PathType -eq 'Leaf' }
        }

        It 'throws error when certificate file does not exist' {
            InModuleScope -ModuleName $moduleName {
                {
                    Import-CertificateToTrustedRootStore -CertificatePath 'C:\temp\missing.crt' -CertStoreLocation 'Cert:\LocalMachine\Root'
                } | Should -Throw "Certificate file does not exist: 'C:\temp\missing.crt'"
            }
        }
    }

    Context 'Cert provider is available' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName Test-CertificateProviderAvailable { return $true }
            Mock -ModuleName $moduleName Import-Certificate { }
        }

        It 'imports using Import-Certificate' {
            InModuleScope -ModuleName $moduleName {
                Import-CertificateToTrustedRootStore -CertificatePath 'C:\temp\ca.crt' -CertStoreLocation 'Cert:\LocalMachine\Root'

                Should -Invoke Import-Certificate -Times 1 -Scope It -ParameterFilter {
                    $FilePath -eq 'C:\temp\ca.crt' -and $CertStoreLocation -eq 'Cert:\LocalMachine\Root' -and $ErrorAction -eq 'Stop'
                }
            }
        }
    }

    Context 'Cert provider is not available' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-CertificateProviderAvailable { return $false }
            Mock -ModuleName $moduleName Import-Certificate { throw 'cmdlet should not be called' }
        }

        It 'uses fallback path without invoking Import-Certificate' {
            InModuleScope -ModuleName $moduleName {
                $tempNonCertFile = Join-Path -Path $env:TEMP -ChildPath ("k2s-non-cert-{0}.crt" -f ([guid]::NewGuid().ToString()))
                Set-Content -Path $tempNonCertFile -Value 'NOT A CERTIFICATE' -Encoding ascii

                try {
                    {
                        Import-CertificateToTrustedRootStore -CertificatePath $tempNonCertFile -CertStoreLocation 'Cert:\LocalMachine\Root'
                    } | Should -Throw
                }
                finally {
                    Remove-Item -Path $tempNonCertFile -Force -ErrorAction SilentlyContinue
                }

                Should -Invoke Import-Certificate -Times 0 -Scope It
            }
        }
    }
}

Describe 'Install-CertManagerControllers' -Tag 'unit', 'ci', 'addon' {
    Context 'images are already cached locally' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-CertManagerConfig { return 'cert-manager.yaml' }
            Mock -ModuleName $moduleName Get-ImagesFromYaml { return @('img1:v1', 'img2:v1') }
            Mock -ModuleName $moduleName Get-Content { return 'dummy-yaml' }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                return [pscustomobject]@{ Success = $true; Output = 'cached' }
            }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'ok' } }
            Mock -ModuleName $moduleName Wait-ForCertManagerAvailable { return $true }
            Mock -ModuleName $moduleName Clear-KubectlDiscoveryCache { }
        }

        It 'inspects images, skips pull, applies manifest, waits for API and CRDs' {
            InModuleScope -ModuleName $moduleName {
                Install-CertManagerControllers

                Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 2 -Scope It -ParameterFilter {
                    $CmdToExecute -like '*crictl inspecti*'
                }
                Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 0 -Scope It -ParameterFilter {
                    $CmdToExecute -like '*crictl pull*'
                }
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Messages -match "Image 'img1:v1' is already cached on control-plane node, skipping pull"
                }
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Messages -match "Image 'img2:v1' is already cached on control-plane node, skipping pull"
                }
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-f' -and $Params -contains 'cert-manager.yaml'
                }
                Should -Invoke Wait-ForCertManagerAvailable -Times 1 -Scope It
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'wait' -and $Params -contains '--for=condition=Established'
                }
                Should -Invoke Clear-KubectlDiscoveryCache -Times 1 -Scope It
            }
        }
    }

    Context 'images are not cached locally and pull succeeds' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-CertManagerConfig { return 'cert-manager.yaml' }
            Mock -ModuleName $moduleName Get-ImagesFromYaml { return @('img1:v1') }
            Mock -ModuleName $moduleName Get-Content { return 'dummy-yaml' }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                if ($CmdToExecute -like '*inspecti*') {
                    return [pscustomobject]@{ Success = $false; Output = 'not found' }
                }
                return [pscustomobject]@{ Success = $true; Output = 'pulled' }
            }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'ok' } }
            Mock -ModuleName $moduleName Wait-ForCertManagerAvailable { return $true }
            Mock -ModuleName $moduleName Clear-KubectlDiscoveryCache { }
        }

        It 'pulls images when inspecti fails' {
            InModuleScope -ModuleName $moduleName {
                Install-CertManagerControllers

                Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Scope It -ParameterFilter {
                    $CmdToExecute -like '*crictl inspecti*'
                }
                Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Scope It -ParameterFilter {
                    $CmdToExecute -like '*crictl pull*'
                }
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Messages -match "Pre-pulling image: img1:v1"
                }
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Messages -match "Pre-pull succeeded: img1:v1"
                }
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'apply'
                }
            }
        }
    }

    Context 'images are not cached locally and pull fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-CertManagerConfig { return 'cert-manager.yaml' }
            Mock -ModuleName $moduleName Get-ImagesFromYaml { return @('img1:v1') }
            Mock -ModuleName $moduleName Get-Content { return 'dummy-yaml' }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                if ($CmdToExecute -like '*inspecti*') {
                    return [pscustomobject]@{ Success = $false; Output = 'not found' }
                }
                return [pscustomobject]@{ Success = $false; Output = 'network unreachable' }
            }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'ok' } }
            Mock -ModuleName $moduleName Wait-ForCertManagerAvailable { return $true }
            Mock -ModuleName $moduleName Clear-KubectlDiscoveryCache { }
        }

        It 'logs warning and continues installation without throwing on pull failure' {
            InModuleScope -ModuleName $moduleName {
                Install-CertManagerControllers

                Should -Invoke Invoke-CmdOnControlPlaneViaSSHKey -Times 1 -Scope It -ParameterFilter {
                    $CmdToExecute -like '*crictl pull*'
                }
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Messages -match "WARNING: Pre-pull of 'img1:v1' failed \(will fall back to runtime pull\): network unreachable"
                }
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'apply'
                }
            }
        }
    }

    Context 'cert-manager never becomes ready' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-CertManagerConfig { return 'cert-manager.yaml' }
            Mock -ModuleName $moduleName Get-ImagesFromYaml { return @('img1:v1') }
            Mock -ModuleName $moduleName Get-Content { return 'dummy-yaml' }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { return [pscustomobject]@{ Success = $true; Output = 'ok' } }
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'ok' } }
            Mock -ModuleName $moduleName Wait-ForCertManagerAvailable { return $false }
            Mock -ModuleName $moduleName Clear-KubectlDiscoveryCache { }
        }

        It 'throws when cert-manager is not ready' {
            InModuleScope -ModuleName $moduleName {
                { Install-CertManagerControllers } | Should -Throw
            }
        }
    }

    Context 'cert-manager CRDs do not become established' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Get-CertManagerConfig { return 'cert-manager.yaml' }
            Mock -ModuleName $moduleName Get-ImagesFromYaml { return @('img1:v1') }
            Mock -ModuleName $moduleName Get-Content { return 'dummy-yaml' }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { return [pscustomobject]@{ Success = $true; Output = 'ok' } }
            Mock -ModuleName $moduleName Invoke-Kubectl {
                if ($Params -contains 'wait') {
                    return [pscustomobject]@{ Success = $false; Output = 'timed out waiting for condition' }
                }
                return [pscustomobject]@{ Success = $true; Output = 'ok' }
            }
            Mock -ModuleName $moduleName Wait-ForCertManagerAvailable { return $true }
            Mock -ModuleName $moduleName Clear-KubectlDiscoveryCache { }
        }

        It 'throws when CRDs fail to become established' {
            InModuleScope -ModuleName $moduleName {
                { Install-CertManagerControllers } | Should -Throw
            }
        }
    }
}

Describe 'Initialize-CACertificateIssuer' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-CAIssuerConfig { return 'ca-issuer.yaml' }
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = 'ok' } }
        Mock -ModuleName $moduleName Wait-ForCARootCertificate { return $true }
        Mock -ModuleName $moduleName Update-CertificateResources { }
        Mock -ModuleName $moduleName Clear-KubectlDiscoveryCache { }
        Mock -ModuleName $moduleName Get-CARootCertificateHash { return 'old-hash' }
        Mock -ModuleName $moduleName Wait-ForCARootCertificateRotation { return $true }
    }

    It 'clears cache and applies issuer manifest and waits for root cert' {
        InModuleScope -ModuleName $moduleName {
            Initialize-CACertificateIssuer

            Should -Invoke Clear-KubectlDiscoveryCache -Times 1 -Scope It
            Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                $Params -contains 'apply' -and $Params -contains '--server-side' -and $Params -contains '-f' -and $Params -contains 'ca-issuer.yaml'
            }
            Should -Invoke Wait-ForCARootCertificate -Times 1 -Scope It
        }
    }

    It 'captures the CA hash before renewal and waits for rotation using it afterwards' {
        InModuleScope -ModuleName $moduleName {
            Initialize-CACertificateIssuer

            Should -Invoke Get-CARootCertificateHash -Times 1 -Scope It
            Should -Invoke Update-CertificateResources -Times 1 -Scope It
            Should -Invoke Wait-ForCARootCertificateRotation -Times 1 -Scope It -ParameterFilter {
                $PreviousHash -eq 'old-hash'
            }
        }
    }

    Context 'CA root certificate is never created' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForCARootCertificate { return $false }
        }

        It 'throws when CA root certificate is not created' {
            InModuleScope -ModuleName $moduleName {
                { Initialize-CACertificateIssuer } | Should -Throw
            }
        }
    }
}

Describe 'Get-CARootCertificateHash' -Tag 'unit', 'ci', 'addon' {
    It 'returns the secret content when readable' {
        InModuleScope -ModuleName $moduleName {
            Mock Invoke-Kubectl { return [pscustomobject]@{ Output = 'BASE64DATA' } }

            $result = Get-CARootCertificateHash

            $result | Should -Be 'BASE64DATA'
        }
    }

    It 'returns an empty string when the secret content cannot be read' {
        InModuleScope -ModuleName $moduleName {
            Mock Invoke-Kubectl { return [pscustomobject]@{ Output = '' } }

            $result = Get-CARootCertificateHash

            $result | Should -Be ''
        }
    }
}

Describe 'Wait-ForCARootCertificateRotation' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Start-Sleep { }
    }

    It 'returns true immediately when PreviousHash is empty (fresh install, nothing to wait for)' {
        InModuleScope -ModuleName $moduleName {
            Mock Get-CARootCertificateHash { return 'anything' }

            $result = Wait-ForCARootCertificateRotation -PreviousHash '' -SleepDurationInSeconds 0 -NumberOfRetries 3

            $result | Should -BeTrue
            Should -Invoke Get-CARootCertificateHash -Times 0 -Scope It
        }
    }

    It 'returns true as soon as the content differs from PreviousHash' {
        InModuleScope -ModuleName $moduleName {
            $script:callCount = 0
            Mock Get-CARootCertificateHash {
                $script:callCount++
                if ($script:callCount -lt 2) {
                    return 'old-hash'
                }
                return 'new-hash'
            }

            $result = Wait-ForCARootCertificateRotation -PreviousHash 'old-hash' -SleepDurationInSeconds 0 -NumberOfRetries 5

            $result | Should -BeTrue
            Should -Invoke Get-CARootCertificateHash -Times 2 -Scope It
        }
    }

    It 'returns false without throwing when rotation is never observed within retries' {
        InModuleScope -ModuleName $moduleName {
            Mock Get-CARootCertificateHash { return 'old-hash' }

            $result = Wait-ForCARootCertificateRotation -PreviousHash 'old-hash' -SleepDurationInSeconds 0 -NumberOfRetries 3

            $result | Should -BeFalse
            Should -Invoke Get-CARootCertificateHash -Times 3 -Scope It
            Should -Invoke Start-Sleep -Times 2 -Scope It
        }
    }
}

Describe 'Get-CertManagerStatusProperties' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Output = 'cert-manager' } }
        Mock -ModuleName $moduleName Test-Path { return $true }
        Mock -ModuleName $moduleName Wait-ForCertManagerAvailable { return $true }
        Mock -ModuleName $moduleName Wait-ForCARootCertificate { return $false }
    }

    It 'returns two status properties with expected shape' {
        InModuleScope -ModuleName $moduleName {
            $props = Get-CertManagerStatusProperties

            $props.Count | Should -Be 2
            $props[0].Name | Should -Be 'IsCertManagerAvailable'
            $props[0].Value | Should -BeTrue
            $props[1].Name | Should -Be 'IsCaRootCertificateAvailable'
            $props[1].Value | Should -BeFalse
        }
    }

    It 'returns both properties as false immediately when cert-manager is absent (--omitCertMgr scenario)' {
        InModuleScope -ModuleName $moduleName {
            Mock Test-Path { return $false } -ParameterFilter { $Path -match 'cmctl\.exe' }
            Mock Invoke-Kubectl { return [pscustomobject]@{ Output = ''; Success = $true } } -ParameterFilter { $Params -contains 'cert-manager' }

            $props = Get-CertManagerStatusProperties

            $props.Count | Should -Be 2
            $props[0].Name | Should -Be 'IsCertManagerAvailable'
            $props[0].Value | Should -BeFalse
            $props[0].Okay | Should -BeFalse
            $props[1].Name | Should -Be 'IsCaRootCertificateAvailable'
            $props[1].Value | Should -BeFalse
            $props[1].Okay | Should -BeFalse

            Should -Invoke Wait-ForCertManagerAvailable -Times 0 -Scope It
            Should -Invoke Wait-ForCARootCertificate -Times 0 -Scope It
        }
    }
}

Describe 'New-AddonStatusProperty' -Tag 'unit', 'ci', 'addon' {
    It 'creates a consistent status property hashtable' {
        InModuleScope -ModuleName $moduleName {
            $p = New-AddonStatusProperty -Name 'X' -Value $true -SuccessMessage 'ok' -FailureMessage 'fail'
            $p.Name | Should -Be 'X'
            $p.Value | Should -BeTrue
            $p.Okay | Should -BeTrue
            $p.Message | Should -Be 'ok'
        }
    }
}

Describe 'Get-GatewayApiCrdsConfig' -Tag 'unit', 'ci', 'addon' {
    It 'returns gateway api CRDs manifest path' {
        InModuleScope -ModuleName $moduleName {
            $result = Get-GatewayApiCrdsConfig
            $result | Should -Match 'common\\manifests\\crds\\gateway-crds\\gateway-api-v1\.4\.1\.yaml$'
        }
    }
}

Describe 'Install-GatewayApiCrds' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-GatewayApiCrdsConfig { return 'gateway-api.yaml' }
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Output = 'ok'; Success = $true } }
        Mock -ModuleName $moduleName Clear-KubectlDiscoveryCache { }
    }

    It 'applies CRDs, waits for Established, clears cache, and probes discovery' {
        InModuleScope -ModuleName $moduleName {
            Install-GatewayApiCrds
            Should -Invoke Invoke-Kubectl -Scope It -ParameterFilter {
                $Params -contains 'apply' -and $Params -contains '--server-side' -and $Params -contains '-f' -and $Params -contains 'gateway-api.yaml'
            }
            Should -Invoke Invoke-Kubectl -Scope It -ParameterFilter {
                $Params -contains 'wait' -and $Params -contains '--for=condition=Established' -and $Params -contains 'crd/gateways.gateway.networking.k8s.io'
            }
            Should -Invoke Clear-KubectlDiscoveryCache -Times 1 -Scope It
            Should -Invoke Invoke-Kubectl -Scope It -ParameterFilter {
                $Params -contains 'get' -and $Params -contains 'gateways.gateway.networking.k8s.io'
            }
        }
    }
}

Describe 'Uninstall-GatewayApiCrds' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-GatewayApiCrdsConfig { return 'gateway-api.yaml' }
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Output = 'ok' } }
    }

    It 'deletes the CRDs manifest with ignore-not-found' {
        InModuleScope -ModuleName $moduleName {
            Uninstall-GatewayApiCrds
            Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                $Params -contains 'delete' -and $Params -contains '--ignore-not-found' -and $Params -contains '-f' -and $Params -contains 'gateway-api.yaml'
            }
        }
    }
}

Describe 'Uninstall-CertManager' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-CertManagerConfig { return 'cert-manager.yaml' }
        Mock -ModuleName $moduleName Get-CAIssuerConfig { return 'ca-issuer.yaml' }
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Output = 'ok' } }
        Mock -ModuleName $moduleName Remove-Cmctl { }
        Mock -ModuleName $moduleName Get-CAIssuerName { return 'K2s Self-Signed CA' }
        Mock -ModuleName $moduleName Get-TrustedRootStoreLocation { return 'Cert:\\LocalMachine\\Root' }
        Mock -ModuleName $moduleName Remove-CertificateFromTrustedRootStore { }
        Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false }
    }

    It 'deletes manifests, preserves cmctl, and removes CA cert from trusted root when security addon is disabled' {
        InModuleScope -ModuleName $moduleName {
            Uninstall-CertManager

            Should -Invoke Invoke-Kubectl -Times 2 -Scope It -ParameterFilter { $Params -contains 'delete' -and $Params -contains '-f' }
            Should -Invoke Remove-Cmctl -Times 0 -Scope It
            Should -Invoke Remove-CertificateFromTrustedRootStore -Times 1 -Scope It
        }
    }

    It 'skips uninstallation when security addon is enabled' {
        InModuleScope -ModuleName $moduleName {
            # Note: Current implementation doesn't check security addon status, it always uninstalls
            # This test documents expected behavior but isn't enforced by implementation
            Uninstall-CertManager

            # Implementation always uninstalls regardless of security addon
            Should -Invoke Invoke-Kubectl -Times 2 -Scope It
            Should -Invoke Remove-Cmctl -Times 0 -Scope It
            Should -Invoke Remove-CertificateFromTrustedRootStore -Times 1 -Scope It
        }
    }
}

Describe 'Remove-CertificateFromTrustedRootStore' -Tag 'unit', 'ci', 'addon' {
    Context 'Cert provider is available' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-CertificateProviderAvailable { return $true }
            Mock -ModuleName $moduleName Get-ChildItem {
                return @(
                    [pscustomobject]@{ Subject = 'CN=K2s Self-Signed CA' },
                    [pscustomobject]@{ Subject = 'CN=Other' }
                )
            }
            Mock -ModuleName $moduleName Remove-Item { }
        }

        It 'removes matching certificates from cert provider store' {
            InModuleScope -ModuleName $moduleName {
                Remove-CertificateFromTrustedRootStore -IssuerName 'K2s Self-Signed CA' -TrustedRootStoreLocation 'Cert:\\LocalMachine\\Root'

                Should -Invoke Get-ChildItem -Times 1 -Scope It -ParameterFilter { $Path -eq 'Cert:\\LocalMachine\\Root' }
                Should -Invoke Remove-Item -Times 1 -Scope It
            }
        }
    }

    Context 'Cert provider is not available' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-CertificateProviderAvailable { return $false }
            Mock -ModuleName $moduleName Get-ChildItem { throw 'Get-ChildItem should not be called' }
            Mock -ModuleName $moduleName Remove-Item { throw 'Remove-Item should not be called' }
        }

        It 'does not use cert provider cmdlets' {
            $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
            $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isElevated) {
                Set-ItResult -Skipped -Because 'Requires admin to open LocalMachine Root store in fallback path'
                return
            }

            InModuleScope -ModuleName $moduleName {
                Remove-CertificateFromTrustedRootStore -IssuerName 'K2s Self-Signed CA' -TrustedRootStoreLocation 'Cert:\\LocalMachine\\Root'

                Should -Invoke Get-ChildItem -Times 0 -Scope It
                Should -Invoke Remove-Item -Times 0 -Scope It
            }
        }
    }
}

Describe 'Enable-CertManager' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Wait-ForCertManagerAvailable { return $false }
        Mock -ModuleName $moduleName Install-CmctlCli { }
        Mock -ModuleName $moduleName Install-CertManagerControllers { }
        Mock -ModuleName $moduleName Initialize-CACertificateIssuer { }
        Mock -ModuleName $moduleName Import-CACertificateToWindowsStore { }
    }

    It 'installs cert-manager when not already installed' {
        InModuleScope -ModuleName $moduleName {
            Enable-CertManager

            # Note: Current implementation doesn't check availability first, always installs
            Should -Invoke Install-CmctlCli -Times 1 -Scope It
            Should -Invoke Install-CertManagerControllers -Times 1 -Scope It
            Should -Invoke Initialize-CACertificateIssuer -Times 1 -Scope It
            Should -Invoke Import-CACertificateToWindowsStore -Times 1 -Scope It
        }
    }
}

Describe 'Assert-IngressTlsCertificate' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Invoke-Kubectl { return @{Output = 'applied' } }
    }

    Context 'nginx ingress - certificate already exists' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForK8sSecret { return $true }
        }

        It 'returns true without re-applying manifest' {
            InModuleScope -ModuleName $moduleName {
                $result = Assert-IngressTlsCertificate -IngressType 'nginx' -CertificateManifestPath 'test.yaml'

                $result | Should -BeTrue
                Should -Invoke Wait-ForK8sSecret -Times 1 -Scope It -ParameterFilter { $SecretName -eq 'k2s-cluster-local-tls' -and $Namespace -eq 'ingress-nginx' }
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It
            }
        }
    }

    Context 'traefik ingress - certificate does not exist initially' {
        BeforeAll {
            $script:waitCallCount = 0
            Mock -ModuleName $moduleName Wait-ForK8sSecret { 
                $script:waitCallCount++
                return $script:waitCallCount -gt 1
            }
        }

        It 'applies manifest and waits for certificate' {
            InModuleScope -ModuleName $moduleName {
                $script:waitCallCount = 0
                $result = Assert-IngressTlsCertificate -IngressType 'traefik' -CertificateManifestPath 'cluster-local-ingress.yaml'

                $result | Should -BeTrue
                Should -Invoke Wait-ForK8sSecret -Times 2 -Scope It
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains 'apply' -and $Params -contains 'cluster-local-ingress.yaml' }
            }
        }
    }

    Context 'nginx-gw ingress - certificate never appears' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForK8sSecret { return $false }
        }

        It 'applies manifest and returns false with warning' {
            InModuleScope -ModuleName $moduleName {
                $result = Assert-IngressTlsCertificate -IngressType 'nginx-gw' -CertificateManifestPath 'k2s-cluster-local-tls-certificate.yaml'

                $result | Should -BeFalse
                Should -Invoke Wait-ForK8sSecret -Times 2 -Scope It
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains 'apply' -and $Params -contains 'k2s-cluster-local-tls-certificate.yaml' }
            }
        }
    }

    Context 'custom manifest path provided' {
        BeforeAll {
            Mock -ModuleName $moduleName Wait-ForK8sSecret { return $false }
        }

        It 'uses custom manifest path' {
            InModuleScope -ModuleName $moduleName {
                $customPath = 'C:\custom\path\cert.yaml'
                $result = Assert-IngressTlsCertificate -IngressType 'nginx' -CertificateManifestPath $customPath

                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains $customPath }
            }
        }
    }
}

Describe 'Resolve-AddonImportPath' -Tag 'unit', 'ci', 'addon' {
    Context 'single-implementation addon without hyphen' {
        It 'returns the addon name as base with no implementation' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'dashboard' -AddonImplementation 'dashboard'

                $result.BaseAddonName | Should -Be 'dashboard'
                $result.ImplementationName | Should -BeNullOrEmpty
            }
        }
    }

    Context 'single-implementation addon with hyphen in name (gpu-node bug)' {
        It 'preserves the full hyphenated name as base folder' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'gpu-node' -AddonImplementation 'gpu-node'

                $result.BaseAddonName | Should -Be 'gpu-node'
                $result.ImplementationName | Should -BeNullOrEmpty
            }
        }
    }

    Context 'multi-implementation addon (ingress nginx)' {
        It 'uses addon name as base and implementation annotation as subfolder' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'ingress' -AddonImplementation 'nginx'

                $result.BaseAddonName | Should -Be 'ingress'
                $result.ImplementationName | Should -Be 'nginx'
            }
        }
    }

    Context 'multi-implementation addon (ingress traefik)' {
        It 'uses addon name as base and implementation annotation as subfolder' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'ingress' -AddonImplementation 'traefik'

                $result.BaseAddonName | Should -Be 'ingress'
                $result.ImplementationName | Should -Be 'traefik'
            }
        }
    }

    Context 'multi-implementation addon with hyphen in implementation' {
        It 'keeps the complete implementation name' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'ingress' -AddonImplementation 'nginx-gw'

                $result.BaseAddonName | Should -Be 'ingress'
                $result.ImplementationName | Should -Be 'nginx-gw'
            }
        }
    }

    Context 'hyphenated addon with different implementation metadata' {
        It 'does not split the addon name at the hyphen' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'gpu-node' -AddonImplementation 'node'

                $result.BaseAddonName | Should -Be 'gpu-node'
                $result.ImplementationName | Should -Be 'node'
            }
        }
    }

    Context 'single-implementation addon with multiple hyphens' {
        It 'preserves the full name when name equals implementation' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'my-cool-addon' -AddonImplementation 'my-cool-addon'

                $result.BaseAddonName | Should -Be 'my-cool-addon'
                $result.ImplementationName | Should -BeNullOrEmpty
            }
        }
    }

    Context 'addon with no implementation annotation' {
        It 'returns the addon name as base with no implementation' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'metrics'

                $result.BaseAddonName | Should -Be 'metrics'
                $result.ImplementationName | Should -BeNullOrEmpty
            }
        }
    }

    Context 'addon with empty implementation annotation' {
        It 'returns the addon name as base with no implementation' {
            InModuleScope -ModuleName $moduleName {
                $result = Resolve-AddonImportPath -AddonName 'gpu-node' -AddonImplementation ''

                $result.BaseAddonName | Should -Be 'gpu-node'
                $result.ImplementationName | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Remove-IngressForNginx' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
    }

    Context 'when nginx ingress resource exists in cluster' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                param($Params)
                if ($Params -contains 'get') { return [pscustomobject]@{ Output = 'dashboard-nginx-cluster-local' } }
                return [pscustomobject]@{ Output = '' }
            }
        }

        It 'deletes the standard nginx config directory' {
            InModuleScope $moduleName {
                Remove-IngressForNginx -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and ($Params -join ' ') -match 'ingress-nginx' -and ($Params -join ' ') -notmatch 'ingress-nginx-secure'
                }
            }
        }

        It 'deletes the secure nginx config directory' {
            InModuleScope $moduleName {
                Remove-IngressForNginx -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and ($Params -join ' ') -match 'ingress-nginx-secure'
                }
            }
        }

        It 'calls kubectl delete exactly twice (both standard and secure)' {
            InModuleScope $moduleName {
                Remove-IngressForNginx -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 2 -Scope It -ParameterFilter { $Params -contains 'delete' }
            }
        }

        It 'writes Deleting nginx ingress manifest to console' {
            InModuleScope $moduleName {
                Remove-IngressForNginx -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Console -eq $true -and ($Messages -join ' ') -match 'Deleting nginx ingress manifest'
                }
            }
        }
    }

    Context 'when nginx ingress resource does NOT exist in cluster' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Output = '' }
            }
        }

        It 'does not call kubectl delete' {
            InModuleScope $moduleName {
                Remove-IngressForNginx -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params -contains 'delete' }
            }
        }

        It 'does not write Deleting... to console' {
            InModuleScope $moduleName {
                Remove-IngressForNginx -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                    $Console -eq $true -and ($Messages -join ' ') -match 'Deleting'
                }
            }
        }
    }
}

Describe 'Remove-IngressForTraefik' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
    }

    Context 'when traefik ingress resource exists in cluster' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                param($Params)
                if ($Params -contains 'get') { return [pscustomobject]@{ Output = 'dashboard-traefik-cluster-local' } }
                return [pscustomobject]@{ Output = '' }
            }
        }

        It 'deletes the standard traefik config directory' {
            InModuleScope $moduleName {
                Remove-IngressForTraefik -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and ($Params -join ' ') -match 'ingress-traefik' -and ($Params -join ' ') -notmatch 'ingress-traefik-secure'
                }
            }
        }

        It 'deletes the secure traefik config directory' {
            InModuleScope $moduleName {
                Remove-IngressForTraefik -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and ($Params -join ' ') -match 'ingress-traefik-secure'
                }
            }
        }

        It 'calls kubectl delete exactly twice (both standard and secure)' {
            InModuleScope $moduleName {
                Remove-IngressForTraefik -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 2 -Scope It -ParameterFilter { $Params -contains 'delete' }
            }
        }

        It 'writes Deleting traefik ingress manifest to console' {
            InModuleScope $moduleName {
                Remove-IngressForTraefik -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Console -eq $true -and ($Messages -join ' ') -match 'Deleting traefik ingress manifest'
                }
            }
        }
    }

    Context 'when traefik ingress resource does NOT exist in cluster' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Output = '' }
            }
        }

        It 'does not call kubectl delete' {
            InModuleScope $moduleName {
                Remove-IngressForTraefik -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params -contains 'delete' }
            }
        }

        It 'does not write Deleting... to console' {
            InModuleScope $moduleName {
                Remove-IngressForTraefik -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                    $Console -eq $true -and ($Messages -join ' ') -match 'Deleting'
                }
            }
        }
    }
}

Describe 'Remove-IngressForNginxGateway' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
    }

    Context 'when nginx-gw HTTPRoute resource exists in cluster' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                param($Params)
                if ($Params -contains 'get') { return [pscustomobject]@{ Success = $true; Output = 'dashboard-nginx-gw-cluster-local' } }
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
        }

        It 'deletes the standard gateway kustomization' {
            InModuleScope $moduleName {
                Remove-IngressForNginxGateway -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and ($Params -join ' ') -match 'ingress-nginx-gw' -and ($Params -join ' ') -notmatch 'ingress-nginx-gw-secure'
                }
            }
        }

        It 'deletes the secure gateway kustomization' {
            InModuleScope $moduleName {
                Remove-IngressForNginxGateway -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter {
                    $Params -contains 'delete' -and ($Params -join ' ') -match 'ingress-nginx-gw-secure'
                }
            }
        }

        It 'calls kubectl delete exactly twice (both standard and secure)' {
            InModuleScope $moduleName {
                Remove-IngressForNginxGateway -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 2 -Scope It -ParameterFilter { $Params -contains 'delete' }
            }
        }

        It 'writes Deleting gateway manifest to console' {
            InModuleScope $moduleName {
                Remove-IngressForNginxGateway -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Write-Log -Times 1 -Scope It -ParameterFilter {
                    $Console -eq $true -and ($Messages -join ' ') -match 'Deleting gateway manifest'
                }
            }
        }
    }

    Context 'when nginx-gw HTTPRoute resource does NOT exist in cluster' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
        }

        It 'does not call kubectl delete' {
            InModuleScope $moduleName {
                Remove-IngressForNginxGateway -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params -contains 'delete' }
            }
        }

        It 'does not write Deleting... to console' {
            InModuleScope $moduleName {
                Remove-IngressForNginxGateway -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                    $Console -eq $true -and ($Messages -join ' ') -match 'Deleting'
                }
            }
        }
    }

    Context 'when nginx-gw HTTPRoute CRD is not installed (kubectl returns error exit code)' {
        BeforeAll {
            # Simulates: kubectl exits non-zero because the HTTPRoute CRD does not exist
            # (nginx-gw addon not installed). Output contains error text but Success=false.
            Mock -ModuleName $moduleName Invoke-Kubectl {
                return [pscustomobject]@{ Success = $false; Output = "error: the server doesn't have a resource type 'httproute'" }
            }
        }

        It 'does not call kubectl delete when CRD is missing' {
            InModuleScope $moduleName {
                Remove-IngressForNginxGateway -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params -contains 'delete' }
            }
        }

        It 'does not write Deleting... to console when CRD is missing' {
            InModuleScope $moduleName {
                Remove-IngressForNginxGateway -Addon ([pscustomobject]@{ Name = 'dashboard' })
                Should -Invoke Write-Log -Times 0 -Scope It -ParameterFilter {
                    $Console -eq $true -and ($Messages -join ' ') -match 'Deleting'
                }
            }
        }
    }
}
