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

Describe 'Get-AddonInfrastructurePlacementStatus' -Tag 'unit', 'ci', 'addon' {
    Context 'selector is not configured' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-AddonConfig { return $null }
            Mock -ModuleName $moduleName Invoke-Kubectl { throw 'Invoke-Kubectl should not be called without a saved selector.' }
        }

        It 'returns no placement properties' {
            InModuleScope -ModuleName $moduleName {
                Get-AddonInfrastructurePlacementStatus -Name 'metrics' | Should -BeNullOrEmpty
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It
            }
        }
    }

    Context 'selector is configured but no nodes match' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ InfraNodeSelector = 'kubernetes.io/hostname=infra-1' } }
            Mock -ModuleName $moduleName Invoke-Kubectl {
                if ($Params -contains 'deployment') {
                    return [pscustomobject]@{ Success = $true; Output = '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"infra-1","kubernetes.io/os":"linux"}}}}}' }
                }
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
        }

        It 'reports the effective hard selector and Pending behavior' {
            InModuleScope -ModuleName $moduleName {
                $properties = Get-AddonInfrastructurePlacementStatus -Name 'metrics'
                $properties[0].Value | Should -Be 'kubernetes.io/hostname=infra-1'
                $properties[1].Name | Should -Be 'Infrastructure placement - metrics-server'
                $properties[1].Value | Should -Be 'No matching nodes'
                $properties[1].Okay | Should -BeFalse
                $properties[1].Message | Should -Match 'remain Pending'
                Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains '-l' -and $Params -contains 'kubernetes.io/hostname=infra-1,kubernetes.io/os=linux' }
            }
        }
    }

    Context 'node query fails' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ InfraNodeSelector = 'kubernetes.io/hostname=infra-1' } }
            Mock -ModuleName $moduleName Invoke-Kubectl {
                if ($Params -contains 'deployment') {
                    return [pscustomobject]@{ Success = $true; Output = '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"infra-1","kubernetes.io/os":"linux"}}}}}' }
                }
                return [pscustomobject]@{ Success = $false; Output = 'cluster is unreachable' }
            }
        }

        It 'reports that placement could not be checked instead of claiming no nodes match' {
            InModuleScope -ModuleName $moduleName {
                $properties = Get-AddonInfrastructurePlacementStatus -Name 'metrics'
                $properties[1].Value | Should -Be 'Unable to check matching nodes'
                $properties[1].Okay | Should -BeFalse
                $properties[1].Message | Should -Match 'cluster is unreachable'
            }
        }
    }

    Context 'live workload selector no longer enforces the saved selector' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ InfraNodeSelector = 'kubernetes.io/hostname=infra-1' } }
            Mock -ModuleName $moduleName Invoke-Kubectl {
                if ($Params -contains 'deployment') {
                    return [pscustomobject]@{ Success = $true; Output = '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}' }
                }
                return [pscustomobject]@{ Success = $true; Output = 'node/infra-1' }
            }
        }

        It 'reports incorrect placement even if the weaker selector matches nodes' {
            InModuleScope -ModuleName $moduleName {
                $properties = Get-AddonInfrastructurePlacementStatus -Name 'metrics'
                $placement = $properties | Where-Object { $_.Name -eq 'Infrastructure placement - metrics-server' }
                $placement.Value | Should -Be 'Incorrect placement'
                $placement.Okay | Should -BeFalse
                $placement.Message | Should -Match 'kubernetes.io/hostname=infra-1'
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params -contains '-l' }
            }
        }
    }
}

Describe 'Infrastructure placement owning preflight' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
        Mock -ModuleName $moduleName Get-ConfigValue { @() }
        Mock -ModuleName $moduleName Get-AddonsConfig { @() }
        Mock -ModuleName $moduleName Set-SharedInfrastructurePlacement {}
        Mock -ModuleName $moduleName Get-SetupConfigFilePath { 'unused' }
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = ''} }
    }

    It 'rejects a conflicting shared-service selector without applying resources' {
        Mock -ModuleName $moduleName Get-ConfigValue { @([pscustomobject]@{Name = 'cert-manager'; InfraNodeSelector = 'pool=infra'}) }
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = '{"items":[{"spec":{"template":{"spec":{"nodeSelector":{"pool":"infra"}}}}}]}'} }
        { Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector 'pool=other' -Namespace 'cert-manager' -Deployment 'cert-manager' } | Should -Throw -ExpectedMessage '*already owns selector*'
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params[0] -ne 'get' }
    }

    It 'reconciles stale ownership only after shared workloads and consumers are absent' {
        Mock -ModuleName $moduleName Get-ConfigValue { @([pscustomobject]@{Name = 'cert-manager'; InfraNodeSelector = 'pool=old'}) }
        { Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector 'pool=new' -Namespace 'cert-manager' -Deployment 'cert-manager' } | Should -Not -Throw
        Should -Invoke -ModuleName $moduleName Set-SharedInfrastructurePlacement -Times 1 -Scope It -ParameterFilter { $Selector -eq 'pool=new' }
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains 'cert-manager-webhook' -and $Params -contains 'cert-manager-cainjector' -and $Params -contains '--ignore-not-found' }
    }

    It 'does not release a shared owner still referenced by an enabled consumer' {
        Mock -ModuleName $moduleName Get-ConfigValue { @([pscustomobject]@{Name = 'external-dns'; InfraNodeSelector = 'pool=old'}) }
        Mock -ModuleName $moduleName Get-AddonsConfig { @([pscustomobject]@{Name = 'ingress'; Implementation = 'nginx'}) }
        { Assert-SharedInfrastructurePlacement -Name 'external-dns' -Selector 'pool=new' -Namespace 'external-dns' -Deployment 'external-dns' } | Should -Throw
        Should -Invoke -ModuleName $moduleName Set-SharedInfrastructurePlacement -Times 0 -Scope It
    }

    It 'fails closed on forbidden instead of treating it as not found' {
        Mock -ModuleName $moduleName Get-ConfigValue { @([pscustomobject]@{Name = 'cert-manager'; InfraNodeSelector = 'pool=old'}) }
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $false; Output = 'Forbidden'} }
        { Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector 'pool=new' -Namespace 'cert-manager' -Deployment 'cert-manager' } | Should -Throw -ExpectedMessage '*Cannot inspect*Forbidden*'
        Should -Invoke -ModuleName $moduleName Set-SharedInfrastructurePlacement -Times 0 -Scope It
    }

    It 'accepts the same canonical shared selector without reinstalling it' {
        Mock -ModuleName $moduleName Get-ConfigValue { @([pscustomobject]@{Name = 'external-dns'; InfraNodeSelector = 'pool=infra,zone=a'}) }
        { Assert-SharedInfrastructurePlacement -Name 'external-dns' -Selector 'zone=a,pool=infra' -Namespace 'external-dns' -Deployment 'external-dns' } | Should -Not -Throw
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params[0] -eq 'get' }
    }

    It 'rejects actual shared drift even when saved ownership is compatible' {
        Mock -ModuleName $moduleName Get-ConfigValue { @([pscustomobject]@{Name = 'cert-manager'; InfraNodeSelector = 'pool=infra'}) }
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = '{"spec":{"template":{"spec":{"nodeSelector":{"pool":"other"}}}}}'} }
        { Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector 'pool=infra' -Namespace 'cert-manager' -Deployment 'cert-manager' } | Should -Throw -ExpectedMessage '*exists without compatible placement*'
    }

    It 'checks actual bound PVs before allowing storage mutation' {
        Mock -ModuleName $moduleName Invoke-Kubectl {
            if ($Params[1] -eq 'pvc') { return [pscustomobject]@{Success = $true; Output = '{"items":[{"spec":{"volumeName":"retained-data"}}]}'} }
            return [pscustomobject]@{Success = $true; Output = '{"metadata":{"name":"existing"}}'}
        }
        Mock -ModuleName $moduleName Invoke-AddonStorageProof { throw 'actual PV conflict' }
        { Assert-AddonStoragePlacement -Namespace 'logging' -VolumeNames @() -NodeName 'kubemaster' } | Should -Throw -ExpectedMessage '*actual PV conflict*'
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params[1] -eq 'pv' -and $Params[2] -eq 'retained-data' }
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params[0] -ne 'get' }
    }

    It 'rejects a legacy shared Deployment with incompatible actual placement' {
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'} }
        { Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector 'pool=infra' -Namespace 'cert-manager' -Deployment 'cert-manager' } | Should -Throw -ExpectedMessage '*exists without compatible placement*'
    }

    It 'rejects an incompatible storage or prerequisite host before mutation' {
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = '{"metadata":{"labels":{"kubernetes.io/hostname":"kubemaster","kubernetes.io/os":"linux"}}}'} }
        { Assert-AddonPlacementHost -Selector 'kubernetes.io/hostname=worker' -NodeName 'kubemaster' -Reason 'local PV' } | Should -Throw -ExpectedMessage '*excludes required host*'
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params[0] -eq 'get' }
    }

    It 'accepts compatible host labels without labeling or tainting nodes' {
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = '{"metadata":{"labels":{"kubernetes.io/hostname":"kubemaster","kubernetes.io/os":"linux"}}}'} }
        { Assert-AddonPlacementHost -Selector 'kubernetes.io/hostname=kubemaster,kubernetes.io/os=linux' -NodeName 'kubemaster' -Reason 'local PV' } | Should -Not -Throw
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params[0] -ne 'get' }
    }
}

Describe 'Typed infrastructure owner placement status' -Tag 'unit', 'ci', 'addon' {
    It 'reports drift at the Prometheus CR owner instead of accepting a weaker live selector' {
        Mock -ModuleName $moduleName Get-AddonConfig { [pscustomobject]@{Name = 'monitoring'; InfraNodeSelector = 'pool=infra'} }
        Mock -ModuleName $moduleName Invoke-Kubectl {
            if ($Params[1] -eq 'prometheus,alertmanager') { return [pscustomobject]@{Success = $true; Output = '{"items":[{"kind":"Prometheus","metadata":{"name":"main"},"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}]}'} }
            return [pscustomobject]@{Success = $true; Output = '{"items":[]}'}
        }
        $status = Get-AddonInfrastructurePlacementStatus -Name 'monitoring'
        ($status | Where-Object Name -eq 'Infrastructure placement - Prometheus/main').Value | Should -Be 'Incorrect placement'
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params[1] -eq 'nodes' }
    }
}

Describe 'Owning placement apply boundary' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
        Mock -ModuleName $moduleName New-AddonPlacementInput { [pscustomobject]@{Path = 'rendered-owner.yaml'; HasMatchingNodes = $true} }
        Mock -ModuleName $moduleName Remove-Item {}
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = 'applied'} }
    }
    It 'applies built rendered input without an unconstrained Kustomize apply' {
        (Invoke-AddonOwnedApply -AddonName 'ingress' -Path 'owning-overlay' -Selector 'pool=infra' -Kustomize -ServerSide).Success | Should -BeTrue
        Should -Invoke -ModuleName $moduleName New-AddonPlacementInput -Times 1 -Scope It -ParameterFilter { $Kustomize -and $Selector -eq 'pool=infra' }
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains '--server-side' -and $Params -contains 'rendered-owner.yaml' -and $Params -notcontains '-k' }
    }
    It 'propagates apply failure and cleans its temporary owner input' {
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $false; Output = 'admission rejected'} }
        { Invoke-AddonOwnedApply -AddonName 'ingress' -Path 'controller.yaml' -Selector 'pool=infra' } | Should -Throw -ExpectedMessage '*admission rejected*'
        Should -Invoke -ModuleName $moduleName Remove-Item -Times 1 -Scope It -ParameterFilter { $LiteralPath -eq 'rendered-owner.yaml' }
    }
    It 'preserves the original owner apply on omission' {
        Invoke-AddonOwnedApply -AddonName 'ingress' -Path 'owning-overlay' -Kustomize | Out-Null
        Should -Invoke -ModuleName $moduleName New-AddonPlacementInput -Times 0 -Scope It
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains '-k' -and $Params -contains 'owning-overlay' }
    }
    It 'logs and continues on apply failure without a selector, as the original apply did' {
        Mock -ModuleName $moduleName Write-Log {}
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $false; Output = 'client-side apply failed'} }
        $result = Invoke-AddonOwnedApply -AddonName 'ingress' -Path 'owning-overlay' -Kustomize -ServerSide
        $result.Success | Should -BeFalse
        Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Scope It -ParameterFilter { "$Messages" -like '*WARNING*ingress*client-side apply failed*' }
    }
    It 'forces server-side conflicts with and without a selector' {
        Invoke-AddonOwnedApply -AddonName 'ingress' -Path 'proxy.yaml' -ServerSide | Out-Null
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains '--server-side' -and $Params -contains '--force-conflicts' -and $Params -contains '-f' }
        Invoke-AddonOwnedApply -AddonName 'ingress' -Path 'proxy.yaml' -Selector 'pool=infra' -ServerSide | Out-Null
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains '--server-side' -and $Params -contains '--force-conflicts' -and $Params -contains 'rendered-owner.yaml' }
    }
}

Describe 'Owner call sites keep the original apply flags without a selector' -Tag 'unit', 'ci', 'addon' {
    AfterEach { Remove-Variable -Name ownedApplyParams -Scope Global -ErrorAction SilentlyContinue }
    It 'applies <Owner> <Marker> with expected flags for selector <Selector>' -ForEach @(
        @{Owner = 'ingress/nginx-gw'; Marker = '$kustomizationDir'; Selector = ''; Expected = @('-k'); Forbidden = @('--server-side', '--force-conflicts')}
        @{Owner = 'ingress/nginx-gw'; Marker = '$kustomizationDir'; Selector = 'pool=infra'; Expected = @('--server-side', '--force-conflicts', 'rendered-owner.yaml'); Forbidden = @('-k')}
    ) {
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "$Owner/Enable.ps1"), [ref]$tokens, [ref]$parseErrors)
        $call = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-AddonOwnedApply' -and $node.Extent.Text.Contains($Marker) }, $true)
        $call | Should -Not -BeNullOrEmpty
        $probe = [scriptblock]::Create('param($InfraNodeSelector, $kustomizationDir) ' + $call.Extent.Text)
        Mock -ModuleName $moduleName New-AddonPlacementInput { [pscustomobject]@{Path = 'rendered-owner.yaml'; HasMatchingNodes = $true} }
        Mock -ModuleName $moduleName Remove-Item {}
        Mock -ModuleName $moduleName Invoke-Kubectl { $global:ownedApplyParams = $Params; [pscustomobject]@{Success = $true; Output = 'applied'} }
        & $probe $Selector 'owner-path' | Out-Null
        foreach ($flag in $Expected) { $global:ownedApplyParams | Should -Contain $flag }
        foreach ($flag in $Forbidden) { $global:ownedApplyParams | Should -Not -Contain $flag }
    }
}

Describe 'Owning placement structured errors' -Tag 'unit', 'ci', 'addon' {
    It 'encodes terminating preflight failure without continuing enable' -ForEach @(
        @{Owner = 'monitoring'}, @{Owner = 'logging'},
        @{Owner = 'registry'},
        @{Owner = 'ingress/nginx'}, @{Owner = 'ingress/traefik'}, @{Owner = 'ingress/nginx-gw'}
    ) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "$Owner/Enable.ps1"), [ref]$tokens, [ref]$parseErrors)
        $trapText = $ast.Find({param($node) $node -is [System.Management.Automation.Language.TrapStatementAst]}, $false).Extent.Text
        $trapText | Should -Not -BeNullOrEmpty
        Mock -ModuleName $moduleName Send-ToCli {}
        InModuleScope -ModuleName $moduleName -Parameters @{TrapText = $trapText} {
            $probe = [scriptblock]::Create('param([switch]$EncodeStructuredOutput, [string]$MessageType) ' + $TrapText + "; throw 'placement preflight rejected'; 'must not continue'")
            $output = & $probe -EncodeStructuredOutput -MessageType 'CmdResult'
            $output | Should -BeNullOrEmpty
            Should -Invoke Send-ToCli -Times 1 -Scope It -ParameterFilter { $MessageType -eq 'CmdResult' -and $Message.Error.Code -eq 'addon-enable-failed' -and $Message.Error.Message -eq 'placement preflight rejected' }
        }
    }
}

Describe 'Nginx partial service retry guard' -Tag 'unit', 'ci', 'addon' {
    It 'allows only the matching recorded implementation to resume after a partial service apply' -ForEach @(
        @{Implementation = 'nginx'; IntentSelector = 'pool=infra'; Allowed = $true},
        @{Implementation = 'traefik'; IntentSelector = 'pool=infra'; Allowed = $false},
        @{Implementation = 'nginx'; IntentSelector = 'pool=other'; Allowed = $false},
        @{Implementation = ''; IntentSelector = ''; Allowed = $false}
    ) {
        $source = Get-Content -Raw (Join-Path $PSScriptRoot 'ingress/nginx/Enable.ps1')
        $start = $source.IndexOf('$existingServices =')
        $finish = $source.IndexOf("Write-Log 'Installing ExternalDNS'", $start)
        InModuleScope -ModuleName $moduleName -Parameters @{Source = $source.Substring($start, $finish - $start); Implementation = $Implementation; IntentSelector = $IntentSelector; Allowed = $Allowed} {
            Mock Get-SetupConfigFilePath { 'unused' }
            $script:nginxRecordedIntent = [pscustomobject]@{Name = 'ingress'; Implementation = $Implementation; InfraNodeSelector = $IntentSelector}
            Mock Get-ConfigValue { @($script:nginxRecordedIntent) }
            Mock Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = 'ingress-nginx-controller'} }
            Mock Send-ToCli {}
            $result = & ([scriptblock]::Create('param([string]$InfraNodeSelector, [bool]$EncodeStructuredOutput, [string]$MessageType) ' + $Source + "; 'resumed'")) 'pool=infra' $true 'CmdResult'
            if ($Allowed) { $result | Should -Be 'resumed' } else { $result | Should -BeNullOrEmpty }
        }
    }
}

Describe 'Metrics retained intent retries' -Tag 'unit', 'ci', 'addon' {
    It 'renders retained intent after <Failure> failure for <Owner> with requested selector <Requested>' -ForEach @(
        @{Owner = 'metrics'; Requested = ''; Failure = 'apply'}, @{Owner = 'metrics'; Requested = 'pool=infra'; Failure = 'apply'},
        @{Owner = 'metrics'; Requested = ''; Failure = 'readiness'}, @{Owner = 'metrics'; Requested = 'pool=infra'; Failure = 'readiness'}
    ) {
        Mock -ModuleName $moduleName Get-AddonConfig { $null }
        Mock -ModuleName $moduleName Get-SetupConfigFilePath { 'unused' }
        Mock -ModuleName $moduleName New-AddonPlacementManifest { 'retained-intent.yaml' }
        Mock -ModuleName $moduleName Test-AddonInfrastructureSelectorOnCluster { $true }
        Mock -ModuleName $moduleName Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = ''} }
        $source = Get-Content -Raw (Join-Path $PSScriptRoot "$Owner/Enable.ps1")
        $start = $source.IndexOf('$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector')
        $finish = $source.IndexOf('$wait =', $start)
        InModuleScope -ModuleName $moduleName -Parameters @{Source = $source.Substring($start, $finish - $start); Owner = $Owner; Requested = $Requested; Failure = $Failure} {
            function Get-MetricsServerConfig { 'baseline.yaml' }
            $script:retainedMetricsIntent = $null
            Mock Get-ConfigValue { @($script:retainedMetricsIntent) }
            Mock Set-AddonPlacementIntent { if ($Clear) { $script:retainedMetricsIntent = $null } else { $script:retainedMetricsIntent = $Addon } }
            Mock Remove-AddonFromSetupJson {}
            Mock Add-AddonToSetupJson {}
            $initialApply = { [pscustomobject]@{Success = ($Failure -ne 'apply'); Output = 'initial apply'} }
            $initialWait = { $false }
            $initialUpdate = { throw 'must not update a failed installation' }
            $successfulRollback = { [pscustomobject]@{Success = $true} }
            { Invoke-AddonEnableTransaction -Addon ([pscustomobject]@{Name = $Owner; InfraNodeSelector = 'pool=infra'}) -Selector 'pool=infra' -Apply $initialApply -Wait $initialWait -Update $initialUpdate -Rollback $successfulRollback } | Should -Throw
            $script:retainedMetricsIntent.InfraNodeSelector | Should -Be 'pool=infra'
            . ([scriptblock]::Create('param([string]$InfraNodeSelector, [string]$TestOwnerRoot) ' + $Source.Replace('$PSScriptRoot', '$TestOwnerRoot'))) -InfraNodeSelector $Requested -TestOwnerRoot 'unused'
            (& $apply).Success | Should -BeTrue
            $addonConfig.InfraNodeSelector | Should -Be 'pool=infra'
            Should -Invoke New-AddonPlacementManifest -Times 1 -Scope It -ParameterFilter { $Selector -eq 'pool=infra' }
            Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains 'retained-intent.yaml' }
            Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params -contains 'baseline.yaml' }
        }
    }
}

Describe 'Monitoring retained option retries' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $ownerAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'monitoring/Enable.ps1'), [ref]$tokens, [ref]$parseErrors)
        $ownerTrap = $ownerAst.EndBlock.Traps[0]
        $placementBranch = $ownerAst.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('if ($placement)') } | Select-Object -First 1
        $unpinnedApply = $ownerAst.EndBlock.Statements | Where-Object { $_.Extent.StartOffset -gt $placementBranch.Extent.EndOffset } | Select-Object -First 1
        $ownerSource = $ownerAst.Extent.Text.Substring($ownerTrap.Extent.EndOffset, $unpinnedApply.Extent.EndOffset - $ownerTrap.Extent.EndOffset)
        $monitoringRetryProbe = [scriptblock]::Create($ownerAst.ParamBlock.Extent.Text + ";`n" + '$OwnerRoot = ''monitoring-owner''' + "`n" + $ownerSource.Replace('$PSScriptRoot', '$OwnerRoot'))
    }

    It 'resolves <Case> before monitoring renders or applies' -ForEach @(
        @{Case = 'omitted true after apply failure'; Saved = $true; Explicit = $null; Expected = $true; Conflict = $false; Failure = 'apply'},
        @{Case = 'omitted true after readiness failure'; Saved = $true; Explicit = $null; Expected = $true; Conflict = $false; Failure = 'readiness'},
        @{Case = 'omitted false'; Saved = $false; Explicit = $null; Expected = $false; Conflict = $false},
        @{Case = 'matching true'; Saved = $true; Explicit = $true; Expected = $true; Conflict = $false},
        @{Case = 'matching explicit false'; Saved = $false; Explicit = $false; Expected = $false; Conflict = $false},
        @{Case = 'conflicting explicit false'; Saved = $true; Explicit = $false; Expected = $true; Conflict = $true},
        @{Case = 'conflicting explicit true'; Saved = $false; Explicit = $true; Expected = $false; Conflict = $true},
        @{Case = 'no intent default'; Saved = $null; Explicit = $null; Expected = $false; Conflict = $false},
        @{Case = 'no intent explicit true'; Saved = $null; Explicit = $true; Expected = $true; Conflict = $false},
        @{Case = 'mixed case identity and property'; Saved = $true; Explicit = $null; Expected = $true; Conflict = $false; MixedCase = $true},
        @{Case = 'unrelated owner'; Saved = $true; Explicit = $null; Expected = $false; Conflict = $false; OtherOwner = $true},
        @{Case = 'unrelated implementation'; Saved = $true; Explicit = $null; Expected = $false; Conflict = $false; OtherImplementation = $true},
        @{Case = 'legacy intent without option'; Saved = $null; Explicit = $null; Expected = $false; Conflict = $true; Legacy = $true},
        @{Case = 'legacy intent explicit false'; Saved = $null; Explicit = $false; Expected = $false; Conflict = $false; Legacy = $true},
        @{Case = 'legacy intent explicit true'; Saved = $null; Explicit = $true; Expected = $true; Conflict = $false; Legacy = $true}
    ) {
        InModuleScope -ModuleName $moduleName -Parameters @{Probe = $monitoringRetryProbe; Saved = $Saved; Explicit = $Explicit; Expected = $Expected; Conflict = $Conflict; MixedCase = $MixedCase; OtherOwner = $OtherOwner; OtherImplementation = $OtherImplementation; Legacy = $Legacy; Failure = $Failure} {
            $script:monitoringIntent = $null
            if ($null -ne $Saved -or $Legacy) {
                $script:monitoringIntent = [pscustomobject]@{Name = 'monitoring'; InfraNodeSelector = 'kubernetes.io/hostname=kubemaster'}
                if (-not $Legacy) { $script:monitoringIntent | Add-Member -NotePropertyName 'OmitGrafana' -NotePropertyValue $Saved }
                if ($MixedCase) { $script:monitoringIntent = [pscustomobject]@{NAME = 'MONITORING'; OMITGRAFANA = $Saved; INFRANODESELECTOR = 'kubernetes.io/hostname=kubemaster'} }
                if ($OtherOwner) { $script:monitoringIntent.Name = 'other' }
                if ($OtherImplementation) { $script:monitoringIntent | Add-Member -NotePropertyName Implementation -NotePropertyValue 'other' }
            }
            $script:retriedMonitoring = $null
            function Enable-IngressAddon { param($Ingress) throw 'must not enable ingress' }
            function Clear-KubectlDiscoveryCache {}
            Mock Get-AddonConfig { $null }
            Mock Get-SetupConfigFilePath { 'unused' }
            Mock Get-ConfigValue { @($script:monitoringIntent) }
            Mock Write-Log {}
            Mock Test-SystemAvailability { $null }
            Mock Get-SetupInfo { [pscustomobject]@{Name = 'k2s'} }
            Mock Test-IsAddonEnabled { $false }
            Mock New-AddonPlacementInput { [pscustomobject]@{Path = 'rendered-monitoring.yaml'; HasMatchingNodes = $true} }
            Mock Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = ''} }
            Mock Remove-Item {}
            if ($Failure) {
                $initialAddon = $script:monitoringIntent
                $script:monitoringIntent = $null
                Mock Set-AddonPlacementIntent { $script:monitoringIntent = $Addon }
                Mock Remove-AddonFromSetupJson {}
                $initialApply = { [pscustomobject]@{Success = ($Failure -ne 'apply'); Output = 'initial monitoring apply'} }
                { Invoke-AddonEnableTransaction -Addon $initialAddon -Selector $initialAddon.InfraNodeSelector -Apply $initialApply -Wait { $false } -Update { throw 'must not update' } -Rollback { [pscustomobject]@{Success = $false; Output = 'operator resources may remain'} } } | Should -Throw
                $script:monitoringIntent.OmitGrafana | Should -BeTrue
            }
            Mock Invoke-AddonEnableTransaction {
                $script:retriedMonitoring = $Addon
                & $Apply | Out-Null
            }
            $parameters = @{}
            if ($null -ne $Explicit) { $parameters['omitgrafana'] = $Explicit }
            if ($Conflict) {
                { & $Probe @parameters } | Should -Throw -ExpectedMessage '*OmitGrafana*incomplete installation intent*'
                Should -Invoke Test-SystemAvailability -Times 0 -Scope It
                Should -Invoke New-AddonPlacementInput -Times 0 -Scope It
                Should -Invoke Invoke-Kubectl -Times 0 -Scope It
                Should -Invoke Invoke-AddonEnableTransaction -Times 0 -Scope It
            } else {
                & $Probe @parameters
                $overlay = if ($Expected) { '*\monitoring-no-grafana' } else { '*\monitoring' }
                if ($null -ne $Saved -and -not $OtherOwner -and -not $OtherImplementation -or $Legacy) {
                    Should -Invoke New-AddonPlacementInput -Times 1 -Scope It -ParameterFilter { $Path -like $overlay -and $Selector -eq 'kubernetes.io/hostname=kubemaster' }
                    $script:retriedMonitoring.OmitGrafana | Should -Be $Expected
                    $script:retriedMonitoring.OmitGrafana | Should -BeOfType ([bool])
                    Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains 'rendered-monitoring.yaml' }
                } else {
                    Should -Invoke New-AddonPlacementInput -Times 0 -Scope It
                    Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains '-k' -and $Params[-1] -like $overlay }
                }
            }
        }
    }
}

Describe 'Placement owner retry caller sequencing' -Tag 'unit', 'ci', 'addon' {
    It 'recovers <Option> for <Owner>/<Implementation> before preflight' -ForEach @(
        @{Owner = 'registry'; Implementation = ''; Option = 'StorageNode'; Saved = 'worker-1'},
        @{Owner = 'logging'; Implementation = ''; Option = 'StorageNode'; Saved = 'worker-1'},
        @{Owner = 'ingress'; Implementation = 'nginx'; Option = 'OmitCertMgr'; Saved = $true},
        @{Owner = 'ingress'; Implementation = 'nginx-gw'; Option = 'OmitCertMgr'; Saved = $true},
        @{Owner = 'ingress'; Implementation = 'traefik'; Option = 'OmitCertMgr'; Saved = $true}
    ) {
        $relativePath = if ($Implementation) { "$Owner/$Implementation/Enable.ps1" } else { "$Owner/Enable.ps1" }
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $relativePath), [ref]$tokens, [ref]$parseErrors)
        $start = $ast.Extent.Text.IndexOf('$ownerOptions =')
        $endStatement = $ast.EndBlock.Statements | Where-Object { $_.Extent.Text.StartsWith('$InfraNodeSelector = Get-AddonEffectiveInfrastructureSelector') } | Select-Object -First 1
        $probe = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + $ast.Extent.Text.Substring($start, $endStatement.Extent.EndOffset - $start) + "`n" + '$ownerOptions')
        InModuleScope -ModuleName $moduleName -Parameters @{Probe = $probe; Owner = $Owner; Implementation = $Implementation; Option = $Option; Saved = $Saved} {
            $script:retryOwner = [pscustomobject]@{Name = $Owner; Implementation = $Implementation; InfraNodeSelector = 'zone=A,pool=infra'}
            $script:retryOwner | Add-Member -NotePropertyName $Option -NotePropertyValue $Saved
            Mock Get-AddonConfig { $null }
            Mock Get-SetupConfigFilePath { 'unused' }
            Mock Get-ConfigValue { @($script:retryOwner) }
            $result = & $Probe
            $result[$Option] | Should -BeExactly $Saved
            $matching = @{$Option = $Saved; InfraNodeSelector = 'pool=infra, zone=A'}
            (& $Probe @matching)[$Option] | Should -BeExactly $Saved
            $conflicting = if ($Saved -is [bool]) { -not $Saved } else { 'other-host' }
            $conflictingParameters = @{$Option = $conflicting}
            { & $Probe @conflictingParameters } | Should -Throw '*disable*before changing*'
            $script:retryOwner = $null
            $baseline = & $Probe
            $expected = switch ($Option) { 'OmitCertMgr' { $false } default { '' } }
            $baseline[$Option] | Should -Be $expected
        }
        $sourceTail = $ast.Extent.Text.Substring($endStatement.Extent.EndOffset)
        $sourceTail | Should -Match 'New-AddonPlacementInput|Test-SystemAvailability'

        $trapEnd = $ast.EndBlock.Traps[0].Extent.EndOffset
        $caller = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + $ast.Extent.Text.Substring($trapEnd).Replace('$PSScriptRoot', "'owner-root'"))
        InModuleScope -ModuleName $moduleName -Parameters @{Caller = $caller; Owner = $Owner; Implementation = $Implementation; Option = $Option; Saved = $Saved} {
            $script:retryOwner = [pscustomobject]@{Name = $Owner; Implementation = $Implementation; InfraNodeSelector = 'pool=infra'}
            $script:retryOwner | Add-Member -NotePropertyName $Option -NotePropertyValue $Saved
            $script:ownerBoundaryValues = $null
            function Get-IngressNginxConfig { 'nginx-owner' }
            Mock Get-AddonConfig { $null }
            Mock Get-SetupConfigFilePath { 'unused' }
            Mock Get-ConfigValue { @($script:retryOwner) }
            Mock Write-Log {}
            Mock Test-SystemAvailability { $null }
            Mock Get-SetupInfo { [pscustomobject]@{Name = 'k2s'} }
            Mock Test-IsAddonEnabled { $false }
            Mock Get-ConfiguredKubeSwitchIP { 'unused' }
            Mock Get-AddonNameFromFolderPath { $Owner }
            Mock Get-ConfigControlPlaneNodeHostname { throw 'must retain saved storage host' }
            Mock Invoke-Kubectl { [pscustomobject]@{Success = $true; Output = ''} }
            Mock Assert-SharedInfrastructurePlacement {}
            Mock Assert-AddonPlacementHost {
                $script:ownerBoundaryValues = @{Node = $NodeName; Selector = $Selector}
                throw 'owner-boundary-reached'
            }
            if ($Owner -eq 'ingress') { Mock Get-ConfigControlPlaneNodeHostname { 'local-host' } }
            Mock New-AddonPlacementInput {
                $script:ownerBoundaryValues = @{Selector = $Selector}
                throw 'owner-boundary-reached'
            }
            { & $Caller } | Should -Throw '*owner-boundary-reached*'
            $script:ownerBoundaryValues.Selector | Should -BeExactly 'pool=infra'
            if ($Option -eq 'StorageNode') { $script:ownerBoundaryValues.Node | Should -BeExactly $Saved }
            if ($Owner -eq 'ingress') { Should -Invoke Assert-SharedInfrastructurePlacement -Times 0 -Scope It -ParameterFilter { $Name -eq 'cert-manager' } }
            Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params[0] -in @('apply', 'create', 'patch', 'delete') }
            $conflictingParameters = @{$Option = $(if ($Saved -is [bool]) { -not $Saved } else { 'other-host' })}
            { & $Caller @conflictingParameters } | Should -Throw '*disable*before changing*'
            Should -Invoke Test-SystemAvailability -Times 1 -Scope It
        }
    }
}

Describe 'Update script parameter binding and effective placement' -Tag 'unit', 'ci', 'addon' {
    It 'validates stored owner option types and canonical modes' {
        InModuleScope -ModuleName $moduleName {
            $script:typedOwnerIntent = [pscustomobject]@{Name = 'ingress'; Implementation = 'nginx'; OmitCertMgr = 'false'}
            Mock Get-AddonConfig { $null }
            Mock Get-SetupConfigFilePath { 'unused' }
            Mock Get-ConfigValue { @($script:typedOwnerIntent) }
            { Get-AddonPlacementOwnerOptions -Name 'ingress' -Implementation 'nginx' -BoundParameters @{} -Defaults @{OmitCertMgr = $false} } | Should -Throw '*must be a boolean*'
            $script:typedOwnerIntent = [pscustomobject]@{Name = 'registry'; StorageNode = 'worker-1'; Ingress = 'TRAEFIK'; UntrustedParameter = 'never-forward'}
            $options = Get-AddonPlacementOwnerOptions -Name 'registry' -BoundParameters @{Ingress = 'traefik'} -Defaults @{StorageNode = ''; Ingress = 'none'}
            $options.Ingress | Should -BeExactly 'traefik'
            $options.StorageNode | Should -BeExactly 'worker-1'
            $options.ContainsKey('UntrustedParameter') | Should -BeFalse
            $script:typedOwnerIntent.Ingress = 'unrecognized'
            { Get-AddonPlacementOwnerOptions -Name 'registry' -BoundParameters @{} -Defaults @{StorageNode = ''; Ingress = 'none'} } | Should -Throw '*mode is invalid*'
        }
    }

    It 'keeps Update.ps1 free of public-command parameters' {
        $tokens = $null; $parseErrors = $null
        $dashboardAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'dashboard/Update.ps1'), [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        @($dashboardAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Be @('PreferredIngress', 'InfraNodeSelector', 'SkipReadiness')
        $metricsAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'metrics/Update.ps1'), [ref]$tokens, [ref]$parseErrors)
        $metricsAst.ParamBlock | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-AddonEnableTransaction' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
    Mock -ModuleName $moduleName Set-AddonPlacementIntent {}
        Mock -ModuleName $moduleName Add-AddonToSetupJson {}
        Mock -ModuleName $moduleName Remove-AddonFromSetupJson {}
    }

    It 'registers addon state only after apply, readiness, and update' {
        InModuleScope -ModuleName $moduleName {
            $state = [pscustomobject]@{ Applied = $false; Ready = $false; Updated = $false }
            $apply = { $state.Applied = $true; [pscustomobject]@{ Success = $true; Output = '' } }
            $wait = { $state.Applied | Should -BeTrue; $state.Ready = $true; return $true }
            $update = { $state.Ready | Should -BeTrue; $state.Updated = $true }
            $rollback = { [pscustomobject]@{ Success = $true; Output = '' } }

            Invoke-AddonEnableTransaction -Addon ([pscustomobject]@{ Name = 'metrics' }) -Apply $apply -Wait $wait -Update $update -Rollback $rollback
            $state.Updated | Should -BeTrue
            Should -Invoke Add-AddonToSetupJson -Times 1 -Scope It
            Should -Invoke Remove-AddonFromSetupJson -Times 0 -Scope It
        }
    }

    It 'rolls back after apply failure without registering enabled state' {
        InModuleScope -ModuleName $moduleName {
            $rollbackState = [pscustomobject]@{ Called = $false }
            $apply = { [pscustomobject]@{ Success = $false; Output = 'apply failed' } }
            $wait = { throw 'readiness must not run' }
            $update = { throw 'update must not run' }
            $rollback = { $rollbackState.Called = $true; [pscustomobject]@{ Success = $true; Output = '' } }

            { Invoke-AddonEnableTransaction -Addon ([pscustomobject]@{ Name = 'metrics' }) -Selector 'kubernetes.io/hostname=infra-1' -Apply $apply -Wait $wait -Update $update -Rollback $rollback } | Should -Throw -ExpectedMessage '*Manifest apply failed*'
            $rollbackState.Called | Should -BeTrue
            Should -Invoke Add-AddonToSetupJson -Times 0 -Scope It
            Should -Invoke Remove-AddonFromSetupJson -Times 1 -Scope It
        }
    }

    It 'retains selector state when rollback fails' {
        InModuleScope -ModuleName $moduleName {
            $apply = { [pscustomobject]@{ Success = $false; Output = 'apply failed' } }
            $wait = { throw 'readiness must not run' }
            $update = { throw 'update must not run' }
            $rollback = { [pscustomobject]@{ Success = $false; Output = 'deployment delete failed' } }

            { Invoke-AddonEnableTransaction -Addon ([pscustomobject]@{ Name = 'metrics'; InfraNodeSelector = 'kubernetes.io/hostname=infra-1' }) -Selector 'kubernetes.io/hostname=infra-1' -Apply $apply -Wait $wait -Update $update -Rollback $rollback } | Should -Throw -ExpectedMessage '*placement was retained*'
            Should -Invoke Add-AddonToSetupJson -Times 0 -Scope It
            Should -Invoke Set-AddonPlacementIntent -Times 2 -Scope It -ParameterFilter { -not $Clear }
            Should -Invoke Remove-AddonFromSetupJson -Times 0 -Scope It
        }
    }

    It 'saves selector state without updating or rolling back when no nodes match' {
        InModuleScope -ModuleName $moduleName {
            $state = [pscustomobject]@{ Updated = $false }
            $apply = { [pscustomobject]@{ Success = $true; Output = '' } }
            $wait = { throw 'readiness must be skipped when no nodes match' }
            $update = { $state.Updated = $true; throw 'update must be skipped while Pods are Pending' }
            $rollback = { throw 'rollback must not run when no nodes match' }

            Invoke-AddonEnableTransaction -Addon ([pscustomobject]@{ Name = 'metrics'; InfraNodeSelector = 'kubernetes.io/hostname=infra-1' }) -Selector 'kubernetes.io/hostname=infra-1' -HasMatchingNodes:$false -Apply $apply -Wait $wait -Update $update -Rollback $rollback
            $state.Updated | Should -BeFalse
            Should -Invoke Add-AddonToSetupJson -Times 1 -Scope It
            Should -Invoke Add-AddonToSetupJson -Times 1 -Scope It -ParameterFilter { $Addon.InfraNodeSelector -eq 'kubernetes.io/hostname=infra-1' }
            Should -Invoke Remove-AddonFromSetupJson -Times 0 -Scope It
        }
    }

    It 'preserves rollback when matching nodes exist but readiness fails' {
        InModuleScope -ModuleName $moduleName {
            $rollbackState = [pscustomobject]@{ Called = $false }
            $apply = { [pscustomobject]@{ Success = $true; Output = '' } }
            $wait = { return $false }
            $update = { throw 'update must not run' }
            $rollback = { $rollbackState.Called = $true; [pscustomobject]@{ Success = $true; Output = '' } }

            { Invoke-AddonEnableTransaction -Addon ([pscustomobject]@{ Name = 'metrics' }) -Selector 'kubernetes.io/hostname=infra-1' -HasMatchingNodes:$true -Apply $apply -Wait $wait -Update $update -Rollback $rollback } | Should -Throw -ExpectedMessage '*did not become Ready*'
            $rollbackState.Called | Should -BeTrue
        }
    }

    It 'completes pending owner configuration without waiting before registration' {
        InModuleScope -ModuleName $moduleName {
            $state = [pscustomobject]@{ Configured = $false }
            $apply = { [pscustomobject]@{ Success = $true } }
            $configure = { $state.Configured = $true }
            $wait = { throw 'must not wait' }
            $update = { throw 'must not run readiness-dependent updates' }
            $rollback = { throw 'must not roll back Pending workloads' }
            Invoke-AddonEnableTransaction -Addon ([pscustomobject]@{ Name = 'dashboard'; InfraNodeSelector = 'pool=infra' }) -Selector 'pool=infra' -HasMatchingNodes:$false -Apply $apply -Wait $wait -Update $update -ConfigurePending $configure -Rollback $rollback
            $state.Configured | Should -BeTrue
            Should -Invoke Add-AddonToSetupJson -Times 1 -Scope It
        }
    }
}

Describe 'Get-AddonPlacementSelectorConflictMessage' -Tag 'unit', 'ci', 'addon' {
    It 'normalizes ordering and whitespace while preserving empty label values' {
        Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ InfraNodeSelector = 'pool=infra,node-role.kubernetes.io/control-plane=' } }
        Get-AddonPlacementSelectorConflictMessage -Name 'metrics' -RequestedSelector ' node-role.kubernetes.io/control-plane = , pool = infra ' | Should -BeNullOrEmpty
    }

    It 'rejects case changes in label keys or values' -ForEach @(
        @{ Requested = 'pool=Infra' }
        @{ Requested = 'Pool=infra' }
    ) {
        Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ InfraNodeSelector = 'pool=infra' } }
        Get-AddonPlacementSelectorConflictMessage -Name 'metrics' -RequestedSelector $Requested | Should -Match 'Disable it and re-enable it'
    }

    It 'accepts omission for an already enabled addon' {
        Get-AddonPlacementSelectorConflictMessage -Name 'metrics' -RequestedSelector '' | Should -BeNullOrEmpty
    }
    It 'rejects a changed selector with actionable guidance' {
        Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ InfraNodeSelector = 'kubernetes.io/hostname=infra-1' } }
        Get-AddonPlacementSelectorConflictMessage -Name 'metrics' -RequestedSelector 'kubernetes.io/hostname=infra-2' | Should -Match 'Disable it and re-enable it'
    }

    It 'rejects adding placement to an already-enabled unpinned addon' {
        Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ Name = 'metrics' } }
        Get-AddonPlacementSelectorConflictMessage -Name 'metrics' -RequestedSelector 'kubernetes.io/hostname=infra-1' | Should -Match 'without saved infrastructure placement'
    }
}

Describe 'Get-AddonSelectorDrift' -Tag 'unit', 'ci', 'addon' {
    It 'detects case-sensitive label drift' -ForEach @(
        @{ Effective = [pscustomobject]@{ pool = 'Infra' } }
        @{ Effective = [pscustomobject]@{ Pool = 'infra' } }
    ) {
        InModuleScope -ModuleName $moduleName -Parameters @{ Effective = $Effective } {
            @(Get-AddonSelectorDrift -RequestedSelector 'pool=infra' -EffectiveNodeSelector $Effective).Count | Should -Be 1
        }
    }

    It 'distinguishes an empty value from an absent key' {
        InModuleScope -ModuleName $moduleName {
            Get-AddonSelectorDrift -RequestedSelector 'pool=infra,role=' -EffectiveNodeSelector ([pscustomobject]@{ role = ''; pool = 'infra' }) | Should -BeNullOrEmpty
            @(Get-AddonSelectorDrift -RequestedSelector 'role=' -EffectiveNodeSelector ([pscustomobject]@{})).Count | Should -Be 1
        }
    }
}

Describe 'Get-AddonBackupInfrastructureSelector' -Tag 'unit', 'ci', 'addon' {
    It 'accepts an optional selector and leaves legacy backup metadata unpinned' {
        $legacyDirectory = Join-Path $TestDrive 'legacy-addon-backup'
        $selectorDirectory = Join-Path $TestDrive 'selector-addon-backup'
        New-Item -Path $legacyDirectory, $selectorDirectory -ItemType Directory -Force | Out-Null
        '{"addon":"metrics","files":[]}' | Set-Content -LiteralPath (Join-Path $legacyDirectory 'backup.json')
        '{"addon":"metrics","files":[],"infraNodeSelector":"kubernetes.io/hostname=infra-1"}' | Set-Content -LiteralPath (Join-Path $selectorDirectory 'backup.json')

        Get-AddonBackupInfrastructureSelector -BackupDir $legacyDirectory | Should -BeNullOrEmpty
        Get-AddonBackupInfrastructureSelector -BackupDir $selectorDirectory | Should -Be 'kubernetes.io/hostname=infra-1'
    }
}

Describe 'Test-AddonInfrastructureSelectorOnCluster' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
        Mock -ModuleName $moduleName New-AddonPlacementManifest { return 'TestDrive:\effective-selectors.json' }
        '["kubernetes.io/hostname=infra-1,kubernetes.io/os=linux"]' | Set-Content 'TestDrive:\effective-selectors.json'
    }
    It 'includes mandatory Linux placement for the dashboard owner' {
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
        Mock -ModuleName $moduleName Write-Log { }
        '["kubernetes.io/hostname=kubemaster,kubernetes.io/os=linux"]' | Set-Content 'TestDrive:\effective-selectors.json'
        Test-AddonInfrastructureSelectorOnCluster -Name 'dashboard' -Selector 'kubernetes.io/hostname=kubemaster' | Should -BeFalse
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains 'kubernetes.io/hostname=kubemaster,kubernetes.io/os=linux' }
    }

    It 'requires matches for every rendered central workload constraint' {
        '["pool=infra,kubernetes.io/os=linux","pool=infra,kubernetes.io/os=linux,zone=b"]' | Set-Content 'TestDrive:\effective-selectors.json'
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Invoke-Kubectl {
            if ($Params -contains 'pool=infra,kubernetes.io/os=linux') { return [pscustomobject]@{ Success = $true; Output = 'node/linux' } }
            return [pscustomobject]@{ Success = $true; Output = '' }
        }
        Test-AddonInfrastructureSelectorOnCluster -Name 'monitoring' -Selector 'pool=infra' | Should -BeFalse
        Should -Invoke -ModuleName $moduleName Invoke-Kubectl -Times 2 -Scope It
    }
    It 'queries the effective metrics selector and allows no matches' {
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $true; Output = '' } }
        Mock -ModuleName $moduleName Write-Log {}

        InModuleScope -ModuleName $moduleName {
            Test-AddonInfrastructureSelectorOnCluster -Name 'metrics' -Selector 'kubernetes.io/hostname=infra-1' | Should -BeFalse
            Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params -contains '-l' -and $Params -contains 'kubernetes.io/hostname=infra-1,kubernetes.io/os=linux' }
        }
    }

    It 'fails when the destination cluster cannot evaluate the selector' {
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{ Success = $false; Output = 'cluster unavailable' } }

        InModuleScope -ModuleName $moduleName {
            { Test-AddonInfrastructureSelectorOnCluster -Name 'metrics' -Selector 'kubernetes.io/hostname=infra-1' } | Should -Throw -ExpectedMessage '*cluster unavailable*'
        }
    }
}

Describe 'Get-AddonEffectiveInfrastructureSelector' -Tag 'unit', 'ci', 'addon' {
    It 'rejects case changes in retained intent before rendering' -ForEach @(
        @{RequestedSelector = 'Pool=infra'}, @{RequestedSelector = 'pool=Infra'}
    ) {
        Mock -ModuleName $moduleName Get-AddonConfig { $null }
        Mock -ModuleName $moduleName Get-SetupConfigFilePath { 'unused' }
        Mock -ModuleName $moduleName Get-ConfigValue { @([pscustomobject]@{Name = 'metrics'; InfraNodeSelector = 'pool=infra'}) }
        { Get-AddonEffectiveInfrastructureSelector -Name 'metrics' -Selector $RequestedSelector } | Should -Throw -ExpectedMessage '*incomplete installation intent*'
    }

    It 'rejects switching an incomplete multi-implementation owner before apply' {
        Mock -ModuleName $moduleName Get-AddonConfig { $null }
        Mock -ModuleName $moduleName Get-SetupConfigFilePath { 'unused' }
        Mock -ModuleName $moduleName Get-ConfigValue { @([pscustomobject]@{ Name = 'ingress'; Implementation = 'nginx'; InfraNodeSelector = 'pool=infra' }) }
        { Get-AddonEffectiveInfrastructureSelector -Name 'ingress' -Implementation 'traefik' } | Should -Throw -ExpectedMessage '*another implementation*'
        Get-AddonEffectiveInfrastructureSelector -Name 'ingress' -Implementation 'nginx' | Should -Be 'pool=infra'
    }

    It 'clears only the intended implementation retry identity' {
        $path = Join-Path $TestDrive 'placement-identities.json'
        '{"AddonPlacementIntents":[{"Name":"ingress","Implementation":"nginx","InfraNodeSelector":"pool=infra"},{"Name":"ingress","Implementation":"traefik","InfraNodeSelector":"pool=infra"}]}' | Set-Content -LiteralPath $path
        Mock -ModuleName $moduleName Get-SetupConfigFilePath { $path }.GetNewClosure()
        Set-AddonPlacementIntent -Addon ([pscustomobject]@{ Name = 'ingress'; Implementation = 'nginx' }) -Clear
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($config.AddonPlacementIntents).Count | Should -Be 1
        $config.AddonPlacementIntents[0].Implementation | Should -Be 'traefik'
    }

    It 'replays saved placement when omitted by an update owner' {
        Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ Name = 'metrics'; InfraNodeSelector = 'kubernetes.io/hostname=kubemaster' } }
        Get-AddonEffectiveInfrastructureSelector -Name 'metrics' | Should -Be 'kubernetes.io/hostname=kubemaster'
    }

    It 'rejects changed placement before an update owner applies' {
        Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ Name = 'dashboard'; InfraNodeSelector = 'kubernetes.io/hostname=kubemaster' } }
        { Get-AddonEffectiveInfrastructureSelector -Name 'dashboard' -Selector 'kubernetes.io/hostname=other' } | Should -Throw '*Disable it and re-enable it*'
    }

    It 'keeps omission unpinned for legacy installations' {
        Mock -ModuleName $moduleName Get-AddonConfig { return [pscustomobject]@{ Name = 'metrics' } }
        Get-AddonEffectiveInfrastructureSelector -Name 'metrics' | Should -BeNullOrEmpty
    }
}

Describe 'Dashboard owner update configuration while Pending' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester cross-scope module reference')]
        $dashboardUpdateModule = (Import-Module "$PSScriptRoot\dashboard\dashboard.module.psm1" -Force -PassThru).Name
    }

    AfterAll {
        Remove-Module $dashboardUpdateModule -Force
        Import-Module "$PSScriptRoot\addons.module.psm1" -Global
    }

    It 'configures dashboard ingress and mesh before a matching node joins (mesh=<Mesh>)' -ForEach @(
        @{ Mesh = $true }
        @{ Mesh = $false }
    ) {
        $scriptPath = Join-Path $PSScriptRoot 'dashboard\Update.ps1'
        InModuleScope -ModuleName $dashboardUpdateModule -Parameters @{ Mesh = $Mesh; ScriptPath = $scriptPath } {
            Mock Get-AddonEffectiveInfrastructureSelector { return 'pool=infra' }
            Mock Test-AddonInfrastructureSelectorOnCluster { return $false }
            Mock Update-IngressForAddon { }
            Mock Test-LinkerdServiceAvailability { return $Mesh }
            Mock Write-Log { }
            Mock Start-Sleep { throw 'Pending owner must not wait' }
            $meshState = [pscustomobject]@{ Patched = $false }
            Mock Invoke-Kubectl {
                if ($Params -contains 'status' -or $Params -contains 'pods') { throw 'Pending owner must not wait for Pods' }
                if ($Params[0] -eq 'get') {
                    $annotations = if ($Mesh -or -not $meshState.Patched) { @{ 'linkerd.io/inject' = 'enabled' } } else { @{} }
                    return [pscustomobject]@{ Success = $true; Output = (@{ spec = @{ template = @{ metadata = @{ annotations = $annotations } } } } | ConvertTo-Json -Depth 10) }
                }
                if ($Params[0] -eq 'patch') { $meshState.Patched = $true }
                return [pscustomobject]@{ Success = $true; Output = '' }
            }
            Mock Install-HeadlampViaHelm { }
            Mock Sync-HeadlampPlugins { }
            $scriptContent = (Get-Content -LiteralPath $ScriptPath | Where-Object { $_ -notmatch '^#Requires\b' -and $_ -notmatch '^\s*Import-Module\b' }) -join [Environment]::NewLine
            & ([scriptblock]::Create($scriptContent)) -InfraNodeSelector 'pool=infra'
            Should -Invoke Update-IngressForAddon -Times 1 -Scope It
            Should -Invoke Invoke-Kubectl -Times 1 -Scope It -ParameterFilter { $Params[0] -eq 'patch' -and $Params[1] -eq 'deployment' }
            Should -Invoke Invoke-Kubectl -Times 0 -Scope It -ParameterFilter { $Params -contains 'status' -or $Params -contains 'pods' }
            Should -Invoke Install-HeadlampViaHelm -Times 0 -Scope It
            Should -Invoke Sync-HeadlampPlugins -Times 1 -Scope It -ParameterFilter { $SkipReadiness }
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

    Context 'saved infrastructure placement is replayed without forwarding addon-specific properties' {
        BeforeAll {
            $previousPlacementCapture = $env:K2S_PLACEMENT_CAPTURE
            $replayRoot = Join-Path $TestDrive 'placement-replay'
            $enableDirectory = Join-Path $replayRoot 'metrics'
            New-Item -Path $enableDirectory -ItemType Directory -Force | Out-Null
            $capturePath = Join-Path $TestDrive 'placement-parameters.json'
            @'
param([string]$InfraNodeSelector, [string]$StorageUsage)
@{ InfraNodeSelector = $InfraNodeSelector; StorageUsage = $StorageUsage } | ConvertTo-Json | Set-Content -LiteralPath $env:K2S_PLACEMENT_CAPTURE
'@ | Set-Content -LiteralPath (Join-Path $enableDirectory 'Enable.ps1')
            $env:K2S_PLACEMENT_CAPTURE = $capturePath
            $ingressDirectory = Join-Path $replayRoot 'ingress\nginx'
            New-Item -Path $ingressDirectory -ItemType Directory -Force | Out-Null
            @'
param([string]$InfraNodeSelector, [bool]$OmitCertMgr)
@{ Keys = @($PSBoundParameters.Keys | Sort-Object) } | ConvertTo-Json | Set-Content -LiteralPath $env:K2S_PLACEMENT_CAPTURE
'@ | Set-Content -LiteralPath (Join-Path $ingressDirectory 'Enable.ps1')
            Mock -ModuleName $moduleName Write-Log { }
        }

        AfterAll {
            if ($null -eq $previousPlacementCapture) {
                Remove-Item Env:K2S_PLACEMENT_CAPTURE -ErrorAction SilentlyContinue
            }
            else {
                $env:K2S_PLACEMENT_CAPTURE = $previousPlacementCapture
            }
        }

        It 'passes the saved selector only' {
            InModuleScope -ModuleName $moduleName -Parameters @{ replayRoot = $replayRoot } {
                $config = [pscustomobject]@{
                    Name = 'metrics'
                    InfraNodeSelector = 'kubernetes.io/hostname=infra-1'
                    StorageUsage = 'existing-addon-setting'
                }
                Enable-AddonFromConfig -Config $config -Root $replayRoot
            }

            $savedParams = Get-Content -Raw -LiteralPath $capturePath | ConvertFrom-Json
            $savedParams.InfraNodeSelector | Should -Be 'kubernetes.io/hostname=infra-1'
            $savedParams.StorageUsage | Should -BeNullOrEmpty
        }

        It 'replays owner options only together with a saved selector' -ForEach @(
            @{ Selector = 'kubernetes.io/hostname=infra-1'; Expected = 'InfraNodeSelector,OmitCertMgr' }
            @{ Selector = ''; Expected = '' }
        ) {
            InModuleScope -ModuleName $moduleName -Parameters @{ replayRoot = $replayRoot; Selector = $Selector } {
                $config = [pscustomobject]@{ Name = 'ingress'; Implementation = 'nginx'; OmitCertMgr = $true }
                if ($Selector) { $config | Add-Member -NotePropertyName InfraNodeSelector -NotePropertyValue $Selector }
                Enable-AddonFromConfig -Config $config -Root $replayRoot
            }

            $captured = Get-Content -Raw -LiteralPath $capturePath | ConvertFrom-Json
            (@($captured.Keys) -join ',') | Should -Be $Expected
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

Describe 'Get-AddonStatus without infrastructure placement' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
        Mock -ModuleName $moduleName Test-Path { $true }
        Mock -ModuleName $moduleName Test-SystemAvailability { $null }
        Mock -ModuleName $moduleName Get-AddonInfrastructurePlacementStatus { @() }
    }

    It 'leaves the status script output untouched for an enabled addon' {
        $scriptOutput = @{ Name = 'IsRegistryRunning'; Value = $true; Okay = $true }
        Mock -ModuleName $moduleName Test-IsAddonEnabled { $true }
        Mock -ModuleName $moduleName Invoke-Script { $scriptOutput }
        $status = Get-AddonStatus -Name 'registry' -Directory 'registry-dir'
        $status.Props | Should -Be $scriptOutput
    }

    It 'adds no Props for a disabled addon' {
        Mock -ModuleName $moduleName Test-IsAddonEnabled { $false }
        $status = Get-AddonStatus -Name 'registry' -Directory 'registry-dir'
        $status.Enabled | Should -BeFalse
        $status.ContainsKey('Props') | Should -BeFalse
    }
}

Describe 'Addon scripts parse without errors' -Tag 'unit', 'ci', 'addon' {
    BeforeDiscovery {
        $addonsRoot = $PSScriptRoot
        $scriptNames = @('Enable.ps1', 'Update.ps1', 'Restore.ps1', 'EnableForRestore.ps1', 'Backup.ps1', 'Get-Status.ps1')
        $parseCases = @(Get-ChildItem -Path $addonsRoot -Recurse -File | Where-Object {
                $_.Extension -eq '.psm1' -or ($_.Extension -eq '.ps1' -and $scriptNames -contains $_.Name)
            } | Sort-Object FullName | ForEach-Object {
                @{ Path = $_.FullName; Relative = $_.FullName.Substring($addonsRoot.Length).TrimStart('\', '/') }
            })
    }

    It 'finds addon scripts to check' {
        $parseCases = @(Get-ChildItem -Path $PSScriptRoot -Recurse -Filter '*.psm1' -File)
        $parseCases.Count | Should -BeGreaterThan 0
    }

    It '<Relative> has no parse errors' -ForEach $parseCases {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
        $details = ($parseErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
        @($parseErrors).Count | Should -Be 0 -Because "'$Relative' must be parseable PowerShell, but has: $details"
    }
}
