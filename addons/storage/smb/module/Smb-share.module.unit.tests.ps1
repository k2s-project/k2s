# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\Smb-share.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name

    Import-Module "$PSScriptRoot\..\..\..\..\lib\modules\windows\infra\k2s.infra.module\errors\errors.module.psm1" -Force
}

Describe 'Test-CsiPodsCondition' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'Condition invalid' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Test-CsiPodsCondition -Condition 'invalid' } | Should -Throw
            }
        }
    }

    Context 'Linux-only' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $true } }
        }

        Context 'default values' {
            Context 'Linux node Pod not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeFalse
                    }
                }
            }

            Context 'controller Pod not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeFalse
                    }
                }
            }

            Context 'all Pods running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $true' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeTrue
                    }
                }
            }
        }

        Context 'custom values' {
            Context 'Linux node Pod not deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeFalse
                    }
                }
            }

            Context 'controller Pod not deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeFalse
                    }
                }
            }

            Context 'all Pods deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $true' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeTrue
                    }
                }
            }
        }
    }

    Context 'not Linux-only' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $false } }
        }

        Context 'default values' {
            Context 'Windows node Pod not running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeFalse
                    }
                }
            }

            Context 'all Pods running' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Ready' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 0 }
                }

                It 'returns $true' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition | Should -BeTrue
                    }
                }
            }
        }

        Context 'custom values' {
            Context 'Windows node Pod not deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $false } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $false' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeFalse
                    }
                }
            }

            Context 'all Pods deleted' {
                BeforeAll {
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-controller' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                    Mock -ModuleName $moduleName Wait-ForPodCondition { return $true } -ParameterFilter {
                        $Condition -eq 'Deleted' -and $Label -eq 'app=csi-smb-node-win' -and $Namespace -eq 'storage-smb' -and $TimeoutSeconds -eq 123 }
                }

                It 'returns $true' {
                    InModuleScope -ModuleName $moduleName {
                        Test-CsiPodsCondition -Condition 'Deleted' -TimeoutSeconds 123 | Should -BeTrue
                    }
                }
            }
        }
    }
}

Describe 'New-SmbHostOnWindowsIfNotExisting' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'SMB share already existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SmbShare { return $true }
            Mock -ModuleName $moduleName Write-Log { }
        }

        Context 'SMB user already existing' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-LocalUser { return $true }
                Mock -ModuleName $moduleName Set-LocalUser { }
            }

            It 'does nothing except reset password' {
                InModuleScope $moduleName {
                    $config = @{WinShareName = 'test-name' }

                    New-SmbHostOnWindowsIfNotExisting -Config $config

                    Should -Invoke Write-Log -Scope Context -ParameterFilter { $Messages -match 'nothing to create' }
                }
            }

            It 'resets the user password before returning' {
                InModuleScope $moduleName {
                    $config = @{WinShareName = 'test-name' }

                    New-SmbHostOnWindowsIfNotExisting -Config $config

                    Should -Invoke Set-LocalUser -Times 1 -Scope Context
                }
            }
        }

        Context 'SMB user non-existent' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-LocalUser { return $null }
            }

            It 'does nothing' {
                InModuleScope $moduleName {
                    $config = @{WinShareName = 'test-name' }

                    New-SmbHostOnWindowsIfNotExisting -Config $config

                    Should -Invoke Write-Log -Scope Context -ParameterFilter { $Messages -match 'nothing to create' }
                }
            }
        }
    }

    Context 'SMB share non-existent' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SmbShare { return $null }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName New-Item { }
            Mock -ModuleName $moduleName New-SmbShare { }
            Mock -ModuleName $moduleName Add-FirewallExceptions { }
        }

        Context 'SMB user already existing' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-LocalUser { return $true }
                Mock -ModuleName $moduleName Set-LocalUser { }
            }

            It 'does not create a local SMB user' {
                InModuleScope $moduleName {
                    $config = @{WinShareName = 'test-name'; WinMountPath = 'test-path' }

                    New-SmbHostOnWindowsIfNotExisting -Config $config

                    Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages[0] -match 'User .+ already exists' }
                }
            }

            It 'resets the password to keep it in sync with Linux mount credentials' {
                InModuleScope $moduleName {
                    $config = @{WinShareName = 'test-name'; WinMountPath = 'test-path' }

                    New-SmbHostOnWindowsIfNotExisting -Config $config

                    Should -Invoke Set-LocalUser -Times 1 -Scope Context
                }
            }
        }
      
        Context 'SMB user non-existent' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-LocalUser { return $null }
                Mock -ModuleName $moduleName New-LocalUser {}
            }

            Context 'remote desktop users group exists' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-LocalGroup { return 1, 2 }
                    Mock -ModuleName $moduleName Add-LocalGroupMember { }
                }

                It 'adds SMB user to this group' {
                    InModuleScope $moduleName {
                        $config = @{WinShareName = 'test-name'; WinMountPath = 'test-path' }

                        New-SmbHostOnWindowsIfNotExisting -Config $config

                        Should -Invoke New-LocalUser -Times 1 -Scope Context
                        Should -Invoke Add-LocalGroupMember -Times 1 -Scope Context
                    }
                }
            }
           
            Context 'remote desktop users group non-existent' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-LocalGroup { return @() }
                }

                It 'does nothing' {
                    InModuleScope $moduleName {
                        $config = @{WinShareName = 'test-name'; WinMountPath = 'test-path' }

                        New-SmbHostOnWindowsIfNotExisting -Config $config

                        Should -Invoke New-LocalUser -Times 1 -Scope Context
                        Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages[0] -match 'group does not exist' }
                    }
                }
            }
        }


        It 'creates a local SMB directory' {
            InModuleScope $moduleName {
                Should -Invoke New-Item -Times 1 -Scope Context
            }
        }

        It 'creates a local SMB share' {
            InModuleScope $moduleName {
                Should -Invoke New-SmbShare -Times 1 -Scope Context
            }
        }

        It 'adds firewall exceptions' {
            InModuleScope $moduleName {
                Should -Invoke Add-FirewallExceptions -Times 1 -Scope Context
            }
        }
    }
}

Describe 'Remove-SmbHostOnWindows' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'default scope' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Remove-LocalUser { }
            Mock -ModuleName $moduleName Remove-Item { }
            Mock -ModuleName $moduleName Remove-SmbShare { }
            Mock -ModuleName $moduleName Remove-FirewallExceptions { }

            InModuleScope $moduleName {
                $config = @{WinShareName = 'test-name'; WinMountPath = 'test-path' }

                Remove-SmbHostOnWindows -Config $config
            }
        }

        It 'removes firewall exceptions' {
            InModuleScope $moduleName {
                Should -Invoke Remove-FirewallExceptions -Times 1 -Scope Context
            }
        }

        It 'removes the local SMB share' {
            InModuleScope $moduleName {
                Should -Invoke Remove-SmbShare -Times 1 -Scope Context
            }
        }

        It 'removes the local SMB directory' {
            InModuleScope $moduleName {
                Should -Invoke Remove-Item -Times 1 -Scope Context
            }
        }

        It 'removes the local SMB user' {
            InModuleScope $moduleName {
                Should -Invoke Remove-LocalUser -Times 1 -Scope Context
            }
        }
    }
}

Describe 'Restore-SmbShareAndFolderWindowsHost' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'SMB share access already working' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                InModuleScope -ModuleName $moduleName {
                    $script:Success = $true
                }
            }

            InModuleScope -ModuleName $moduleName {
                $config = @{WinMountPath = 'test-path' }

                Restore-SmbShareAndFolderWindowsHost -Config $config
            }
        }

        It 'does not mount anything' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages[0] -match 'nothing to do' }
            }
        }
    }

    Context 'SMB share not working yet' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                InModuleScope -ModuleName $moduleName {
                    if ($script:testFlag -eq $true) {
                        $script:Success = $true
                    }
                    else {
                        $script:Success = $false
                        $script:testFlag = $true
                    }
                }
            }
            Mock -ModuleName $moduleName New-SmbHostOnWindowsIfNotExisting {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxClient {}
            Mock -ModuleName $moduleName Wait-ForSharedFolderMountOnLinuxClient {}

            InModuleScope -ModuleName $moduleName {
                $config = @{WinMountPath = 'test-path' }

                Restore-SmbShareAndFolderWindowsHost -Config $config
            }
        }

        It 'creates SMB host on Windows' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-SmbHostOnWindowsIfNotExisting -Times 1 -Scope Context
            }
        }

        It 'creates SMB mount on Linux' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-SharedFolderMountOnLinuxClient -Times 1 -Scope Context
            }
        }

        It 'waits for SMB mount becoming available on Linux' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Wait-ForSharedFolderMountOnLinuxClient -Times 1 -Scope Context
            }
        }

        Context 'mount failed on Linux' {
            BeforeAll {
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $false
                    }
                }
            }

            It 'throws' {
                InModuleScope -ModuleName $moduleName {
                    $config = @{WinMountPath = 'test-path' }

                    { Restore-SmbShareAndFolderWindowsHost -Config $config } | Should -Throw
                }
            }
        }
    }
}

Describe 'New-StorageClassManifest' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'RemotePath not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { New-StorageClassManifest -StorageClassName 'test' } | Should -Throw -ExpectedMessage 'RemotePath not specified'
            }
        }
    }
    
    Context 'StorageClassName not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { New-StorageClassManifest -RemotePath 'test' } | Should -Throw -ExpectedMessage 'StorageClassName not specified'
            }
        }
    }

    Context 'valid template' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Content { return 'line1', 'name: SC_NAME', 'line3', 'source: SC_SOURCE', 'mountOptions:', 'MOUNT_OPTIONS' } -ParameterFilter { $Path -match '\\manifests\\base\\storage-classes\\template_StorageClass.yaml' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Convert-ToUnixPath { return 'unix-path' } -ParameterFilter { $Path -eq 'remote-path' }
            Mock -ModuleName $moduleName Set-Content {}

            InModuleScope -ModuleName $moduleName {
                New-StorageClassManifest -RemotePath 'remote-path' -StorageClassName 'my-storage-class'
            }
        }

        It 'replaces placeholders in template content' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value[0] -match 'name: my-storage-class' -and $Value[0] -match 'source: unix-path' }
            }
        }
       
        It 'creates new manifest file' {
            InModuleScope -ModuleName $moduleName {                
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Path -match '\\manifests\\base\\storage-classes\\generated_my-storage-class.yaml' }
            }
        }

        It 'generates default mount options when Config not provided' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value[0] -match 'noperm' -and $Value[0] -match 'noserverino' }
            }
        }
    }

    Context 'valid template with POSIX config' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Content { return 'name: SC_NAME', 'source: SC_SOURCE', 'reclaimPolicy: SC_RECLAIM_POLICY', 'mountOptions:', 'MOUNT_OPTIONS' } -ParameterFilter { $Path -match '\\manifests\\base\\storage-classes\\template_StorageClass.yaml' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Convert-ToUnixPath { return 'unix-path' } -ParameterFilter { $Path -eq 'remote-path' }
            Mock -ModuleName $moduleName Set-Content {}

            InModuleScope -ModuleName $moduleName {
                $posixConfig = [pscustomobject]@{
                    SmbDialect            = '3.1.1'
                    EnablePosixExtensions = $true
                    UseServerInode        = $false
                }
                New-StorageClassManifest -RemotePath 'remote-path' -StorageClassName 'posix-sc' -Config $posixConfig
            }
        }

        It 'does not include noperm in POSIX mode' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value[0] -notmatch 'noperm' }
            }
        }

        It 'does not include handletimeout in POSIX mode' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value[0] -notmatch 'handletimeout' }
            }
        }

        It 'includes noserverino when UseServerInode is false' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value[0] -match 'noserverino' }
            }
        }
    }

    Context 'valid template with configured mount options' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Content { return 'name: SC_NAME', 'source: SC_SOURCE', 'reclaimPolicy: SC_RECLAIM_POLICY', 'mountOptions:', 'MOUNT_OPTIONS' } -ParameterFilter { $Path -match '\\manifests\\base\\storage-classes\\template_StorageClass.yaml' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Convert-ToUnixPath { return 'unix-path' } -ParameterFilter { $Path -eq 'remote-path' }
            Mock -ModuleName $moduleName Set-Content {}

            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject]@{
                    SmbDialect            = '3.1.1'
                    EnablePosixExtensions = $true
                    UseServerInode        = $false
                    MountOptions          = @('dir_mode=0700', 'file_mode=0600', 'uid=1001', 'gid=1001')
                }
                New-StorageClassManifest -RemotePath 'remote-path' -StorageClassName 'smb-postgres' -Config $config
            }
        }

        It 'generates exactly the configured mount options as YAML list entries' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter {
                    $Value[0] -match '(?m)^mountOptions:\r?\n  - dir_mode=0700\n  - file_mode=0600\n  - uid=1001\n  - gid=1001\s*\z'
                }
            }
        }

        It 'does not add generated mount options' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value[0] -notmatch '0777' -and $Value[0] -notmatch 'noserverino' -and $Value[0] -notmatch 'vers=' }
            }
        }
    }
}

Describe 'New-StorageClassManifest mount-options injection' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'template containing a MOUNT_OPTIONS reference in a comment (regression #2478)' {
        BeforeAll {
            # Mirrors the real template, which carried a "# NOTE: ... MOUNT_OPTIONS ..." comment.
            # An unanchored replace matched the token in BOTH the comment and the real placeholder,
            # duplicating the options and leaking the comment text into the cifs -o string (mount error 22).
            Mock -ModuleName $moduleName Get-Content { return 'mountOptions:', '# NOTE: MOUNT_OPTIONS placeholder must start at column 0.', 'MOUNT_OPTIONS' } -ParameterFilter { $Path -match '\\manifests\\base\\storage-classes\\template_StorageClass.yaml' }
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Convert-ToUnixPath { return 'unix-path' } -ParameterFilter { $Path -eq 'remote-path' }
            Mock -ModuleName $moduleName Set-Content {}

            InModuleScope -ModuleName $moduleName {
                New-StorageClassManifest -RemotePath 'remote-path' -StorageClassName 'regression-sc'
            }
        }

        It 'preserves a commented MOUNT_OPTIONS reference instead of expanding it' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value[0] -match '# NOTE: MOUNT_OPTIONS placeholder must start at column 0' }
            }
        }

        It 'injects the mount options exactly once' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter {
                    ([regex]::Matches($Value[0], 'dir_mode=0777')).Count -eq 1
                }
            }
        }
    }
}

Describe 'Wait-ForPodToBeReady' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'success' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $true } -ParameterFilter { $Condition -eq 'Ready' -and $TimeoutSeconds -eq 123 }
        }

        It 'does not throw' {
            InModuleScope -ModuleName $moduleName {
                { Wait-ForPodToBeReady -TimeoutSeconds 123 } | Should -Not -Throw
            }
        }
    }

    Context 'failure' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $false } -ParameterFilter { $Condition -eq 'Ready' -and $TimeoutSeconds -eq 123 }
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Wait-ForPodToBeReady -TimeoutSeconds 123 } | Should -Throw -ExpectedMessage 'StorageClass not ready within 123s'
            }
        }
    }
}

Describe 'Wait-ForPodToBeDeleted' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'success' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $true } -ParameterFilter { $Condition -eq 'Deleted' -and $TimeoutSeconds -eq 123 }
        }

        It 'does not throw' {
            InModuleScope -ModuleName $moduleName {
                { Wait-ForPodToBeDeleted -TimeoutSeconds 123 } | Should -Not -Throw
            }
        }
    }

    Context 'failure' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Test-CsiPodsCondition { return $false } -ParameterFilter { $Condition -eq 'Deleted' -and $TimeoutSeconds -eq 123 }
        }

        It 'logs that it failed' {
            InModuleScope -ModuleName $moduleName {
                Wait-ForPodToBeDeleted -TimeoutSeconds 123 
                
                Should -Invoke Write-Log -Times 1 -Scope Context -ParameterFilter { $Messages -match 'StorageClass not deleted within 123s' }                
            }
        }
    }
}

Describe 'New-StorageClasses' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    BeforeAll {
        Mock -ModuleName $moduleName Add-Secret {}
        Mock -ModuleName $moduleName New-StorageClassManifest {}
        Mock -ModuleName $moduleName New-StorageClassKustomization {}
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Success = $true } }
        Mock -ModuleName $moduleName Wait-ForPodToBeReady {}
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'SmbHostType invalid' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { New-StorageClasses -SmbHostType 'invalid' -Config @{} } | Should -Throw
            }
        }
    }

    Context 'all succeeds' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                New-StorageClasses -SmbHostType 'Windows' -Config @{}
            }
        }

        It 'creates SMB creds secret' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Add-Secret -Times 1 -Scope Context -ParameterFilter {
                    $Name -eq $script:smbCredsName -and $Namespace -eq 'storage-smb' -and $Literals -contains "username=$script:smbUserName" -and $Literals -contains "password=$($creds.GetNetworkCredential().Password)"
                }
            }
        }

        It 'waits for the StorageClass creation' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Wait-ForPodToBeReady -Times 1 -Scope Context -ParameterFilter { $TimeoutSeconds -eq $script:storageClassTimeoutSeconds }
            }
        }
    }

    Context 'Windows host type' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                $config = @{WinHostRemotePath = 'win-remote'; StorageClassName = 'sc-name' }

                New-StorageClasses -SmbHostType 'Windows' -Config $config
            }
        }

        It 'creates a new SC manifest file containing the Windows remote path' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-StorageClassManifest -Times 1 -Scope Context -ParameterFilter { $RemotePath -eq 'win-remote' }
            }
        }
       
        It 'creates a new SC manifest file containing the storage class name' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-StorageClassManifest -Times 1 -Scope Context -ParameterFilter { $StorageClassName -eq 'sc-name' }
            }
        }
    }

    Context 'Linux host type' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                $config = @{LinuxHostRemotePath = 'linux-remote'; StorageClassName = 'sc-name' }

                New-StorageClasses -SmbHostType 'linux' -Config $config
            }
        }

        It 'creates a new SC manifest file containing the linux remote path' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-StorageClassManifest -Times 1 -Scope Context -ParameterFilter { $RemotePath -eq 'linux-remote' }
            }
        }
       
        It 'creates a new SC manifest file containing the storage class name' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-StorageClassManifest -Times 1 -Scope Context -ParameterFilter { $StorageClassName -eq 'sc-name' }
            }
        }
    }

    Context 'not Linux-only' {
        It 'applies the manifest files from Windows folder' {
            InModuleScope -ModuleName $moduleName {
                New-StorageClasses -SmbHostType 'Windows' -Config @{ }

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k' -and $Params[2] -match '\\manifests\\windows'
                }
            }
        }
    }

    Context 'Linux-only' {
        It 'applies the manifest files from base folder' {
            InModuleScope -ModuleName $moduleName {
                New-StorageClasses -SmbHostType 'Windows' -LinuxOnly $true -Config @{ }

                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'apply' -and $Params -contains '-k' -and $Params[2] -match '\\manifests\\base'
                }
            }
        }
    }

    Context 'Invoke-Kubectl failes' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { New-StorageClasses -SmbHostType 'Windows' -Config @{} } | Should -Throw -ExpectedMessage 'oops'
            }
        }
    }
}

Describe 'Remove-StorageClasses' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    BeforeAll {
        Mock -ModuleName $moduleName Remove-PersistentVolumeClaimsForStorageClass {}
        Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Success = $true } }
        Mock -ModuleName $moduleName Wait-ForPodToBeDeleted {}
        Mock -ModuleName $moduleName Remove-Secret {}
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'not Linux-only' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                $config = @{StorageClassName = 'sc-name-1' }, @{StorageClassName = 'sc-name-2' }

                Remove-StorageClasses -Config $config
            }
        }

        It 'removes PVCs related to the SC' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-PersistentVolumeClaimsForStorageClass -Times 1 -Scope Context -ParameterFilter {
                    $StorageClass -eq 'sc-name-1'
                }
                Should -Invoke Remove-PersistentVolumeClaimsForStorageClass -Times 1 -Scope Context -ParameterFilter {
                    $StorageClass -eq 'sc-name-2'
                }
            }
        }

        It 'deletes resources from windows manifests folder' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains '-k' -and $Params[2] -match '\\manifests\\windows'
                }
            }
        }

        It 'waits for Pods deletion' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Wait-ForPodToBeDeleted -Times 1 -Scope Context -ParameterFilter { $TimeoutSeconds -eq $script:storageClassTimeoutSeconds }
            }
        }

        It 'deletes the SMB creds secret' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Secret -Times 1 -Scope Context -ParameterFilter { $Name -eq $script:smbCredsName -and $Namespace -eq 'storage-smb' }
            }
        }
    }

    Context 'Linux-only' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                $config = @{StorageClassName = 'sc-name-1' }, @{StorageClassName = 'sc-name-2' }

                Remove-StorageClasses -LinuxOnly $true -Config $config
            }
        }

        It 'removes PVCs related to the SC' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-PersistentVolumeClaimsForStorageClass -Times 1 -Scope Context -ParameterFilter {
                    $StorageClass -eq 'sc-name-1'
                }
                Should -Invoke Remove-PersistentVolumeClaimsForStorageClass -Times 1 -Scope Context -ParameterFilter {
                    $StorageClass -eq 'sc-name-2'
                }
            }
        }

        It 'deletes resources from base manifesst folder' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Invoke-Kubectl -Times 1 -Scope Context -ParameterFilter {
                    $Params -contains 'delete' -and $Params -contains '-k' -and $Params[2] -match '\\manifests\\base'
                }
            }
        }

        It 'waits for Pods deletion' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Wait-ForPodToBeDeleted -Times 1 -Scope Context -ParameterFilter { { $TimeoutSeconds -eq $script:storageClassTimeoutSeconds } }
            }
        }

        It 'deletes the SMB creds secret' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-Secret -Times 1 -Scope Context -ParameterFilter { $Name -eq $script:smbCredsName -and $Namespace -eq 'storage-smb' }
            }
        }
    }

    Context 'Invoke-Kubectl failes' {
        BeforeAll {
            Mock -ModuleName $moduleName Invoke-Kubectl { return [pscustomobject]@{Output = 'oops'; Success = $false } }
            Mock -ModuleName $moduleName Write-Warning { }
        }

        It 'logs a warning' {
            InModuleScope -ModuleName $moduleName {
                Remove-StorageClasses -Config @{}

                Should -Invoke Write-Warning -Times 1 -Scope Context -ParameterFilter { $Message -match 'oops' }
            }
        }
    }
}

Describe 'New-StorageClassKustomization' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'success' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-Content { return 'line-1', 'resources: [SC_RESOURCES]', 'line-3' } -ParameterFilter { $Path -match '\\manifests\\base\\storage-classes\\template_kustomization.yaml' }
            Mock -ModuleName $moduleName Set-Content { }
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'adds StorageClass manifests as resources to kustomization file' {
            InModuleScope -ModuleName $moduleName {
                New-StorageClassKustomization -Manifests 'm-1', 'm-2'

                Should -Invoke Set-Content -Times 1 -Scope Context -ParameterFilter { $Value[0] -match 'resources: \[m-1,m-2\]' -and $Path -match '\\manifests\\base\\storage-classes\\kustomization.yaml' }
            }   
        }
    }
}

Describe 'Remove-SmbShareAndFolderWindowsHost' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'nodes cleanup skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-SharedFolderMountOnLinuxClient {}
            Mock -ModuleName $moduleName Remove-SmbHostOnWindows {}

            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolderWindowsHost -SkipNodesCleanup -Config @{}
            }
        }

        It 'does not cleanup the Linux node' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-SharedFolderMountOnLinuxClient -Times 0 -Scope Context
                Should -Invoke Remove-SmbHostOnWindows -Times 1 -Scope Context
            }
        }
    }

    Context 'nodes cleanup not skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-SharedFolderMountOnLinuxClient {}
            Mock -ModuleName $moduleName Remove-SmbHostOnWindows {}

            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolderWindowsHost -Config @{}
            }
        }

        It 'cleanups up the Linux node' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Remove-SharedFolderMountOnLinuxClient -Times 1 -Scope Context
                Should -Invoke Remove-SmbHostOnWindows -Times 1 -Scope Context
            }
        }
    }
}

Describe 'New-SmbHostOnLinuxIfNotExisting' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # Regression guard (#2478): the POSIX 'vfs objects = streams_xattr' share config needs streams_xattr.so,
    # which ships in samba-vfs-modules. That package must be installed only when POSIX extensions are requested.
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
        Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey { return [pscustomobject]@{ Output = '' } }
        Mock -ModuleName $moduleName Install-DebianPackages {}
        Mock -ModuleName $moduleName Get-SambaSharePosixConfig { return @() }
        Mock -ModuleName $moduleName Test-SambaPosixNegotiation { return $true }
    }

    Context 'POSIX extensions enabled' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                New-SmbHostOnLinuxIfNotExisting -Config ([pscustomobject]@{ LinuxShareName = 'linux-smb-posix'; EnablePosixExtensions = $true })
            }
        }

        It 'installs samba-vfs-modules alongside cifs-utils and samba' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Install-DebianPackages -Times 1 -Scope Context -ParameterFilter {
                    $packages -contains 'cifs-utils' -and $packages -contains 'samba' -and $packages -contains 'samba-vfs-modules'
                }
            }
        }
    }

    Context 'POSIX extensions disabled' {
        BeforeAll {
            InModuleScope -ModuleName $moduleName {
                New-SmbHostOnLinuxIfNotExisting -Config ([pscustomobject]@{ LinuxShareName = 'linux-smb'; EnablePosixExtensions = $false })
            }
        }

        It 'installs cifs-utils and samba without samba-vfs-modules' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Install-DebianPackages -Times 1 -Scope Context -ParameterFilter {
                    $packages -contains 'cifs-utils' -and $packages -contains 'samba' -and $packages -notcontains 'samba-vfs-modules'
                }
            }
        }
    }
}

Describe 'Restore-SmbShareAndFolderLinuxHost' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'testing skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                InModuleScope -ModuleName $moduleName { $script:Success = $true }
            }
            Mock -ModuleName $moduleName New-SmbHostOnLinuxIfNotExisting {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxHost {}

            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolderLinuxHost -SkipTest -Config @{}
            }
        }

        It 'creates SMB share and mount' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Wait-ForSharedFolderOnLinuxHost -Times 1 -Scope Context
                Should -Invoke New-SmbHostOnLinuxIfNotExisting -Times 1 -Scope Context
                Should -Invoke New-SharedFolderMountOnLinuxHost -Times 1 -Scope Context
            }
        }
    }

    Context 'testing not skipped' {
        Context 'everything already working' {
            BeforeAll {
                Mock -ModuleName $moduleName Write-Log {}
                Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $true
                    }
                }

                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolderLinuxHost -Config @{}
                }
            }

            It 'does not mount anything' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Write-Log -Times 1 -ParameterFilter { $Messages[0] -match 'nothing to restore' } -Scope Context
                }
            }
        }

        Context 'SMB share on Linux not working' {
            BeforeAll {
                Mock -ModuleName $moduleName Write-Log {}
                Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                    InModuleScope -ModuleName $moduleName {
                        if ($script:testFlag2 -eq $true) {
                            $script:Success = $true
                        }
                        else {
                            $script:Success = $false
                            $script:testFlag2 = $true
                        }
                    }
                }
                Mock -ModuleName $moduleName New-SmbHostOnLinuxIfNotExisting {}
                Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxHost {}

                InModuleScope -ModuleName $moduleName {
                    Restore-SmbShareAndFolderLinuxHost -Config @{}
                }
            }

            It 'creates SMB share and mount' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke New-SmbHostOnLinuxIfNotExisting -Times 1 -Scope Context
                    Should -Invoke New-SharedFolderMountOnLinuxHost -Times 1 -Scope Context
                }
            }
        }
    }

    Context 'SMB share creation on Linux failed' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Wait-ForSharedFolderOnLinuxHost {
                InModuleScope -ModuleName $moduleName {
                    $script:Success = $false
                }
            }
            Mock -ModuleName $moduleName New-SmbHostOnLinuxIfNotExisting {}
            Mock -ModuleName $moduleName New-SharedFolderMountOnLinuxHost {}
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Restore-SmbShareAndFolderLinuxHost -Config @{} } | Should -Throw -ExpectedMessage 'Unable to mount shared folder with CIFS on Linux host'
            }
        }
    }
}

Describe 'Remove-SmbShareAndFolderLinuxHost' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'nodes cleanup skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-SharedFolderMountOnLinuxHost {}
            Mock -ModuleName $moduleName Remove-SmbHostOnLinux {}
        }

        It 'does not remove mount and share host on Linux' {
            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolderLinuxHost -SkipNodesCleanup -Config @{}

                Should -Invoke Remove-SharedFolderMountOnLinuxHost -Times 0 -Scope Context
                Should -Invoke Remove-SmbHostOnLinux -Times 0 -Scope Context
            }
        }
    }

    Context 'nodes cleanup not skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-SharedFolderMountOnLinuxHost {}
            Mock -ModuleName $moduleName Remove-SmbHostOnLinux {}
        }

        It 'does remove mount and share host on Linux' {
            InModuleScope -ModuleName $moduleName {
                Remove-SmbShareAndFolderLinuxHost -Config @{}

                Should -Invoke Remove-SharedFolderMountOnLinuxHost -Times 1 -Scope Context
                Should -Invoke Remove-SmbHostOnLinux -Times 1 -Scope Context
            }
        }
    }
}

Describe 'Remove-SmbShareAndFolder' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'nodes cleanup skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}            
        }

        Context 'Windows host' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return 'Windows' }
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderLinuxHost { throw 'unexpected' }
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderWindowsHost {}

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder -SkipNodesCleanup -Config @{}
                }
            }

            It 'propagates the skipped cleanup for Windows' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderWindowsHost -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $true }
                }
            }
        }

        Context 'Linux host' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return 'Linux' }
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderWindowsHost { throw 'unexpected' }
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderLinuxHost {}

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder -SkipNodesCleanup -Config @{}
                }
            }

            It 'propagates the skipped cleanup for Linux' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderLinuxHost -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $true }
                }
            }
        }
       
        Context 'Host type unknown' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return $null }
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderWindowsHost {}
                Mock -ModuleName $moduleName Remove-SmbShareAndFolderLinuxHost {}

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder -Config @{}
                }
            }

            It 'calls removal for both host types' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderWindowsHost -Times 1 -Scope Context
                    Should -Invoke Remove-SmbShareAndFolderLinuxHost -Times 1 -Scope Context
                }
            }
        }
    }

    Context 'nodes cleanup not skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{LinuxOnly = $false } }
            Mock -ModuleName $moduleName Remove-SmbShareAndFolderWindowsHost {}
            Mock -ModuleName $moduleName Remove-SmbShareAndFolderLinuxHost {}
        }

        Context 'Windows host' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return 'Windows' }

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder -Config @{}
                }
            }

            It 'propagates the cleanup info for Windows' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderWindowsHost -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $false }
                }
            }
        }

        Context 'Linux host' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SmbHostType { return 'Linux' }

                InModuleScope -ModuleName $moduleName {
                    Remove-SmbShareAndFolder -Config @{}
                }
            }

            It 'propagates the cleanup info for Linux' {
                InModuleScope -ModuleName $moduleName {
                    Should -Invoke Remove-SmbShareAndFolderLinuxHost -Times 1 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $false }
                }
            }
        }
    }
}

Describe 'Enable-SmbShare' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'SMB host type not set' {
        It 'throws' {
            { Enable-SmbShare } | Should -Throw -ExpectedMessage 'SMB host type not set'
        }
    }

    Context 'invalid SMB host type' {
        It 'throws' {
            { Enable-SmbShare -SmbHostType 'invalid' } | Should -Throw
        }
    }

    Context 'system is not running' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { return @{Code = 'unavailable' } }
        }

        It 'returns error' {
            (Enable-SmbShare -SmbHostType 'Windows').Error.Code | Should -Be 'unavailable'
        }
    }

    Context 'addon is already enabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $true } -ParameterFilter { $Addon.Name -eq $AddonName } 
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                $err = (Enable-SmbShare -SmbHostType 'Windows').Error
                
                $err.Severity | Should -Be Warning
                $err.Code | Should -Be (Get-ErrCodeAddonAlreadyEnabled) 
                $err.Message | Should -Match 'already enabled'
            }
        }
    }

    Context 'addon is disabled' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { }
            Mock -ModuleName $moduleName Test-IsAddonEnabled { return $false } -ParameterFilter { $Addon.Name -eq $AddonName }
        }

        Context 'setup type invalid for this addon' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-SetupInfo { return [pscustomobject]@{Name = 'invalid-type' } }
            }

            It 'returns error' {
                $err = (Enable-SmbShare -SmbHostType 'Linux').Error
                     
                $err.Severity | Should -Be Warning
                $err.Code | Should -Be (Get-ErrCodeWrongSetupType)
                $err.Message | Should -Match 'can only be enabled for'
            }
        }

        Context 'setup type valid for this addon' {
            BeforeAll {
                $setupInfo = [pscustomobject]@{Name = 'k2s'; LinuxOnly = $true }

                Mock -ModuleName $moduleName Get-SetupInfo { return $setupInfo }
                Mock -ModuleName $moduleName Copy-ScriptsToHooksDir { }
                Mock -ModuleName $moduleName Add-AddonToSetupJson { }
                Mock -ModuleName $moduleName Get-StorageConfig { return @{Prop = 'val1' }, @{Prop = 'val2' } }
                Mock -ModuleName $moduleName Restore-SmbShareAndFolder { }
                Mock -ModuleName $moduleName New-SmbShareNamespace { }  
                Mock -ModuleName $moduleName New-StorageClasses { }
                Mock -ModuleName $moduleName Write-Log { }
                Mock -ModuleName $moduleName Get-StorageConfigFromRaw { return @{Prop = 'val1'; EnhancedProp = 'val-a' }, @{Prop = 'val2'; EnhancedProp = 'val-b' } }
            }

            Context 'POSIX storage with Windows host' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-StorageConfigFromRaw {
                        return [pscustomobject]@{ EnablePosixExtensions = $true; StorageClassName = 'smb-posix' }
                    }
                }

                It 'returns a clear unsupported host error before provisioning' {
                    InModuleScope -ModuleName $moduleName {
                        $err = (Enable-SmbShare -SmbHostType 'windows').Error

                        $err.Code | Should -Be 'posix-unsupported-on-windows'
                        $err.Message | Should -Be "The 'posix' protocol cannot be used with a Windows SMB host. It is only supported on Linux targets (use '-t linux')."
                        Should -Invoke Restore-SmbShareAndFolder -Times 0 -Scope It
                    }
                }
            }

            Context 'POSIX storage with Linux host' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-StorageConfigFromRaw {
                        return [pscustomobject]@{ EnablePosixExtensions = $true; StorageClassName = 'smb-posix' }
                    }
                }

                It 'continues with Linux host provisioning' {
                    InModuleScope -ModuleName $moduleName {
                        (Enable-SmbShare -SmbHostType 'linux').Error | Should -BeNullOrEmpty
                        Should -Invoke Restore-SmbShareAndFolder -Times 1 -Scope It
                    }
                }
            }

            Context 'invalid mount options' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-StorageConfigFromRaw {
                        return [pscustomobject]@{ StorageClassName = 'smb' }, [pscustomobject]@{ StorageClassName = 'smb-postgres'; MountOptions = @('dir_mode=0700 file_mode=0600') }
                    }
                }

                It 'returns an error identifying the StorageClass before provisioning' {
                    InModuleScope -ModuleName $moduleName {
                        $err = (Enable-SmbShare -SmbHostType 'windows').Error

                        $err.Code | Should -Be 'invalid-mount-options'
                        $err.Message | Should -Match "^Invalid 'mountOptions' for StorageClass 'smb-postgres': 'dir_mode=0700 file_mode=0600' is not a valid mount option"
                        Should -Invoke Restore-SmbShareAndFolder -Times 0 -Scope It
                        Should -Invoke New-StorageClasses -Times 0 -Scope It
                        Should -Invoke Add-AddonToSetupJson -Times 0 -Scope It
                    }
                }
            }

            Context 'valid mount options' {
                BeforeAll {
                    Mock -ModuleName $moduleName Get-StorageConfigFromRaw {
                        return [pscustomobject]@{ StorageClassName = 'smb-postgres'; MountOptions = @('dir_mode=0700', 'file_mode=0600') }
                    }
                }

                It 'continues with provisioning' {
                    InModuleScope -ModuleName $moduleName {
                        (Enable-SmbShare -SmbHostType 'windows').Error | Should -BeNullOrEmpty
                        Should -Invoke Restore-SmbShareAndFolder -Times 1 -Scope It
                        Should -Invoke New-StorageClasses -Times 1 -Scope It
                    }
                }
            }

            It 'enables the addon passing the correct params' {
                InModuleScope -ModuleName $moduleName {
                    $smbHostType = 'Linux'

                    $result = Enable-SmbShare -SmbHostType $smbHostType

                    $result.Error | Should -BeNullOrEmpty

                    Should -Invoke Copy-ScriptsToHooksDir -Times 1 -Scope Context
                    Should -Invoke Add-AddonToSetupJson -Times 1 -Scope Context -ParameterFilter { $Addon.Name -eq $AddonName -and $Addon.SmbHostType -eq $smbHostType -and $Addon.Storage[0].Prop -eq 'val1' -and $Addon.Storage[1].Prop -eq 'val2' }
                    Should -Invoke Restore-SmbShareAndFolder -Times 2 -Scope Context -ParameterFilter {
                        $SmbHostType -eq $smbHostType -and $SkipTest -eq $true
                    }
                    Should -Invoke New-SmbShareNamespace -Times 1 -Scope Context
                    Should -Invoke New-StorageClasses -Times 1 -Scope Context -ParameterFilter { $SmbHostType -eq $smbHostType -and $LinuxOnly -eq $true }
                }
            }
        }
    }
}

Describe 'Disable-SmbShare' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'node cleanup skipped' {
        BeforeAll {
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Test-SystemAvailability { }
            Mock -ModuleName $moduleName Get-StorageConfig { }
            Mock -ModuleName $moduleName Remove-TempManifests { }
            Mock -ModuleName $moduleName Remove-ScriptsFromHooksDir { }
            Mock -ModuleName $moduleName Remove-AddonFromSetupJson { }
        }

        It 'does not test system availability' {
            InModuleScope -ModuleName $moduleName {
                (Disable-SmbShare -SkipNodesCleanup).Error | Should -BeNullOrEmpty                
                                
                Should -Invoke Test-SystemAvailability -Times 0 -Scope Context
            }
        }
    }

    Context 'system unavailable' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-SystemAvailability { return @{Code = 'err-code'; Message = 'err-msg' } }
        }

        It 'returns error' {
            InModuleScope -ModuleName $moduleName {
                $err = (Disable-SmbShare).Error
                
                $err.Code | Should -Be 'err-code'
                $err.Message | Should -Be 'err-msg'
            }
        }
    }  

    Context 'system available' {
        BeforeAll {
            Mock -ModuleName $moduleName Remove-SmbShareAndFolder { }
            Mock -ModuleName $moduleName Remove-AddonFromSetupJson { }
            Mock -ModuleName $moduleName Remove-ScriptsFromHooksDir { }
            Mock -ModuleName $moduleName Write-Log { }            
            Mock -ModuleName $moduleName Remove-TempManifests { }
            Mock -ModuleName $moduleName Get-StorageConfig { return @{}, @{} }
        }

        Context 'node cleanup skipped' {
            BeforeAll {
                Mock -ModuleName $moduleName Test-SystemAvailability { throw 'unexpected' }
                Mock -ModuleName $moduleName Remove-StorageClasses { throw 'unexpected' }
                Mock -ModuleName $moduleName Remove-SmbShareNamespace { throw 'unexpected' }
                Mock -ModuleName $moduleName Get-SetupInfo { }
            }

            It 'disables the addon skipping node cleanup' {
                InModuleScope -ModuleName $moduleName {
                    $err = (Disable-SmbShare -SkipNodesCleanup).Error
                
                    $err | Should -BeNullOrEmpty
    
                    Should -Invoke Remove-TempManifests -Times 1 -Scope Context
                    Should -Invoke Remove-SmbShareAndFolder -Times 2 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $true }
                    Should -Invoke Remove-AddonFromSetupJson -Times 1 -Scope Context -ParameterFilter { $Addon.Name -eq $AddonName }
                    Should -Invoke Remove-ScriptsFromHooksDir -Times 1 -Scope Context
                }
            }
        }

        Context 'node cleanup not skipped' {
            BeforeAll {
                Mock -ModuleName $moduleName Test-SystemAvailability { }
                Mock -ModuleName $moduleName Remove-StorageClasses { }
                Mock -ModuleName $moduleName Remove-SmbShareNamespace { }
                Mock -ModuleName $moduleName Get-SetupInfo { return @{ LinuxOnly = $false } }
            }

            It 'disables the addon cleaning up the node' {
                InModuleScope -ModuleName $moduleName {
                    $err = (Disable-SmbShare).Error
                
                    $err | Should -BeNullOrEmpty
    
                    Should -Invoke Remove-StorageClasses -Times 1 -Scope Context
                    Should -Invoke Remove-TempManifests -Times 1 -Scope Context
                    Should -Invoke Remove-SmbShareNamespace -Times 1 -Scope Context
                    Should -Invoke Remove-SmbShareAndFolder -Times 2 -Scope Context -ParameterFilter { $SkipNodesCleanup -eq $false }
                    Should -Invoke Remove-AddonFromSetupJson -Times 1 -Scope Context -ParameterFilter { $Addon.Name -eq $AddonName }
                    Should -Invoke Remove-ScriptsFromHooksDir -Times 1 -Scope Context
                }
            }
        }
    }
}

Describe 'Restore-SmbShareAndFolder' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'SMB host type not set' {
        It 'throws' {
            { Restore-SmbShareAndFolder -Config @{} } | Should -Throw
        }
    }

    Context 'SMB host type invalid' {
        It 'throws' {
            { Restore-SmbShareAndFolder -SmbHostType 'invalid' -Config @{} } | Should -Throw
        }
    }

    Context 'Config not set' {
        It 'throws' {
            { Restore-SmbShareAndFolder -SmbHostType 'linux' } | Should -Throw
        }
    }

    Context 'Windows host' {
        BeforeAll {
            Mock -ModuleName $moduleName Restore-SmbShareAndFolderWindowsHost {}
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-Item {}
        }

        It 'calls Windows-specific restore function skipping the tests' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Windows' -SkipTest -Config @{}

                Should -Invoke Restore-SmbShareAndFolderWindowsHost -Times 1 -Scope Context -ParameterFilter { $SkipTest -eq $true }
            }
        }

        It 'calls Windows-specific restore function not skipping the tests' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Windows' -Config @{}

                Should -Invoke Restore-SmbShareAndFolderWindowsHost -Times 1 -Scope Context -ParameterFilter { $SkipTest -eq $false }
            }
        }

        It 'removes the test file' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Windows' -Config @{}

                Should -Invoke Remove-Item -Times 1 -Scope Context -ParameterFilter { $Path -match '.+mountedInVm\.txt' }
            }
        }
    }

    Context 'Linux host' {
        BeforeAll {
            Mock -ModuleName $moduleName Restore-SmbShareAndFolderLinuxHost {}
            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Remove-Item {}
        }

        It 'calls Linux-specific restore function skipping the tests' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Linux' -SkipTest -Config @{}

                Should -Invoke Restore-SmbShareAndFolderLinuxHost -Times 1 -Scope Context -ParameterFilter { $SkipTest -eq $true }
            }
        }

        It 'calls Linux-specific restore function not skipping the tests' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Linux' -Config @{}

                Should -Invoke Restore-SmbShareAndFolderLinuxHost -Times 1 -Scope Context -ParameterFilter { $SkipTest -eq $false }
            }
        }

        It 'removes the test file' {
            InModuleScope -ModuleName $moduleName {
                Restore-SmbShareAndFolder -SmbHostType 'Linux' -Config @{}

                Should -Invoke Remove-Item -Times 1 -Scope Context -ParameterFilter { $Path -match '.+mountedInVm\.txt' }
            }
        }
    }
}

Describe 'Get-SmbHostType' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    BeforeAll {
        Mock -ModuleName $moduleName Get-AddonConfig { }
    }

    It "returns 'windows' unchanged when configured" {
        InModuleScope -ModuleName $moduleName {
            Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = 'windows' } }
            Get-SmbHostType | Should -Be 'windows'
        }
    }

    It "returns 'linux' unchanged when configured (protects #2478 Linux-host path)" {
        InModuleScope -ModuleName $moduleName {
            Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = 'linux' } }
            Get-SmbHostType | Should -Be 'linux'
        }
    }

    It 'normalizes case and surrounding whitespace of a valid value' {
        InModuleScope -ModuleName $moduleName {
            Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = '  Linux  ' } }
            Get-SmbHostType | Should -Be 'linux'
        }
    }

    It "defaults to 'windows' when SmbHostType is empty" {
        InModuleScope -ModuleName $moduleName {
            Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = '' } }
            Get-SmbHostType | Should -Be 'windows'
        }
    }

    It "defaults to 'windows' when SmbHostType is whitespace only" {
        InModuleScope -ModuleName $moduleName {
            Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = '   ' } }
            Get-SmbHostType | Should -Be 'windows'
        }
    }

    It "defaults to 'windows' when SmbHostType property is null" {
        InModuleScope -ModuleName $moduleName {
            Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = $null } }
            Get-SmbHostType | Should -Be 'windows'
        }
    }

    It "defaults to 'windows' when config is null" {
        InModuleScope -ModuleName $moduleName {
            Mock Get-AddonConfig { return $null }
            Get-SmbHostType | Should -Be 'windows'
        }
    }

    It "returns 'windows' when configured SmbHostType is invalid (not in windows,linux)" {
        InModuleScope -ModuleName $moduleName {
            Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = 'my-type' } }
            Get-SmbHostType | Should -Be 'windows'
        }
    }

    Context '-AllowUnspecified (disable-cleanup path, protects #2605 "remove both host types")' {
        It "returns the configured value unchanged when valid" {
            InModuleScope -ModuleName $moduleName {
                Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = 'linux' } }
                Get-SmbHostType -AllowUnspecified | Should -Be 'linux'
            }
        }

        It "returns empty (not 'windows') when SmbHostType is empty" {
            InModuleScope -ModuleName $moduleName {
                Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = '' } }
                Get-SmbHostType -AllowUnspecified | Should -Be ''
            }
        }

        It "returns empty (not 'windows') when config is null" {
            InModuleScope -ModuleName $moduleName {
                Mock Get-AddonConfig { return $null }
                Get-SmbHostType -AllowUnspecified | Should -Be ''
            }
        }

        It "returns empty (not 'windows') when configured value is invalid" {
            InModuleScope -ModuleName $moduleName {
                Mock Get-AddonConfig { return [PSCustomObject]@{Name = 'addon1'; SmbHostType = 'my-type' } }
                Get-SmbHostType -AllowUnspecified | Should -Be ''
            }
        }
    }
}

Describe 'Get-Status' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'setup error' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return @{Error = 'oops' } } 
        }
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-Status } | Should -Throw -ExpectedMessage 'oops' }
        }
    }
    
    Context "setup type not 'k2s'" {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return @{Error = $null; Name = 'invalid' } } 
        }
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-Status } | Should -Throw -ExpectedMessage '*invalid setup type*' }
        }
    }

    Context 'succeeded' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-SetupInfo { return @{Name = 'k2s' } } 
            Mock -ModuleName $moduleName Get-SmbHostType { return 'my-type' }  
            Mock -ModuleName $moduleName Test-CsiPodsCondition {}           
        }

        Context 'always' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-StorageConfig {} 

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns SMB host type' {
                InModuleScope -ModuleName $moduleName {
                    $script:result[0].Name | Should -Be 'SmbHostType'
                    $script:result[0].Value | Should -Be 'my-type'
                    $script:result[0].Message | Should -BeNullOrEmpty
                    $script:result[0].Okay | Should -BeNullOrEmpty
                }
            }
        }

        Context 'SMB shares are not working' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-StorageConfig { return @{StorageClassName = 'smb-1' }, @{StorageClassName = 'smb-2' } } 
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $false
                    }
                }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns not-working status' {
                InModuleScope -ModuleName $moduleName {
                    $script:result[1].Name | Should -Be 'ShareForStorageClass_smb-1'
                    $script:result[1].Value | Should -BeFalse
                    $script:result[1].Message | Should -Match 'is not working'
                    $script:result[1].Okay | Should -BeFalse
                    $script:result[2].Name | Should -Be 'ShareForStorageClass_smb-2'
                    $script:result[2].Value | Should -BeFalse
                    $script:result[2].Message | Should -Match 'is not working'
                    $script:result[2].Okay | Should -BeFalse
                }
            }
        }

        Context 'SMB shares are working' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-StorageConfig { return @{StorageClassName = 'smb-1' }, @{StorageClassName = 'smb-2' } } 
                Mock -ModuleName $moduleName Test-SharedFolderMountOnWinNode {
                    InModuleScope -ModuleName $moduleName {
                        $script:Success = $true
                    }
                }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns is-working status' {
                InModuleScope -ModuleName $moduleName {
                    $script:result[1].Name | Should -Be 'ShareForStorageClass_smb-1'
                    $script:result[1].Value | Should -BeTrue
                    $script:result[1].Message | Should -Match 'is working'
                    $script:result[1].Okay | Should -BeTrue
                    $script:result[2].Name | Should -Be 'ShareForStorageClass_smb-2'
                    $script:result[2].Value | Should -BeTrue
                    $script:result[2].Message | Should -Match 'is working'
                    $script:result[2].Okay | Should -BeTrue
                }
            }
        }

        Context 'Pods are not running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-StorageConfig {} 
                Mock -ModuleName $moduleName Test-CsiPodsCondition { return $false } -ParameterFilter { $Condition -eq 'Ready' }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns not-running status' {
                InModuleScope -ModuleName $moduleName {
                    $script:result[1].Name | Should -Be 'AreCsiPodsRunning'
                    $script:result[1].Value | Should -BeFalse
                    $script:result[1].Message | Should -Match 'are not running'
                    $script:result[1].Okay | Should -BeFalse
                }
            }
        }

        Context 'Pods are running' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-StorageConfig {} 
                Mock -ModuleName $moduleName Test-CsiPodsCondition { return $true } -ParameterFilter { $Condition -eq 'Ready' }

                InModuleScope -ModuleName $moduleName {
                    $script:result = Get-Status
                }
            }

            It 'returns are-running status' {
                InModuleScope -ModuleName $moduleName {
                    $script:result[1].Name | Should -Be 'AreCsiPodsRunning'
                    $script:result[1].Value | Should -BeTrue
                    $script:result[1].Message | Should -Match 'are running'
                    $script:result[1].Okay | Should -BeTrue
                }
            }
        }
    }
}

Describe 'Backup-AddonData' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'backup directory not specified' {
        It 'throws' {
            { Backup-AddonData } | Should -Throw -ExpectedMessage 'Please specify the back-up directory.'
        }
    }

    Context 'backup directory not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'test-dir\storage-smb' }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -ne 'test-dir\storage-smb' }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName New-Item { }
            Mock -ModuleName $moduleName Copy-Item { }
            Mock -ModuleName $moduleName Get-StorageConfig { return @{WinMountPath = 'path' } }

            InModuleScope -ModuleName $moduleName {
                Backup-AddonData -BackupDir 'test-dir'
            }
        }

        It 'gets created' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke New-Item -Times 1 -ParameterFilter { $Path -eq 'test-dir\storage-smb' -and $ItemType -eq 'Directory' } -Scope Context
            }
        }
    }

    Context 'backup directory specified' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'test-dir\storage-smb' }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -ne 'test-dir\storage-smb' }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Copy-Item { }
        }

        Context 'one SMB share configured' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-StorageConfig { return @{WinMountPath = 'c:\win\dir' } }
            }

            It 'copies folder of that share' {
                InModuleScope -ModuleName $moduleName {
                    Backup-AddonData -BackupDir 'test-dir'

                    Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 'c:\win\dir' -and $Destination -eq 'test-dir\storage-smb\dir_0' } -Scope Context
                }
            }
        }
       
        Context 'multiple SMB shares configured' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-StorageConfig { return @{WinMountPath = 'c:\win\dir1' }, @{WinMountPath = 'c:\win\dir2' } }
            }

            It 'copies all share folders' {
                InModuleScope -ModuleName $moduleName {
                    Backup-AddonData -BackupDir 'test-dir'

                    Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 'c:\win\dir1' -and $Destination -eq 'test-dir\storage-smb\dir1_0' } -Scope Context
                    Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 'c:\win\dir2' -and $Destination -eq 'test-dir\storage-smb\dir2_1' } -Scope Context
                }
            }
        }
    }
}

Describe 'Restore-AddonData'-Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'backup directory not specified' {
        It 'throws' {
            { Restore-AddonData } | Should -Throw -ExpectedMessage 'Please specify the back-up directory.'
        }
    }

    Context 'backup directory not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'test-dir\storage-smb' }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -ne 'test-dir\storage-smb' }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Copy-Item { }
            Mock -ModuleName $moduleName Get-StorageConfig { }

            InModuleScope -ModuleName $moduleName {
                Restore-AddonData -BackupDir 'test-dir'
            }
        }

        It 'notifies the user' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Write-Log -Times 1 -ParameterFilter { $Messages[0] -match 'not existing, skipping' } -Scope Context
            }
        }

        It 'skips the restore' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-Item -Times 0 -Scope Context
            }
        }
    }

    Context 'backup directory existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'test-dir\storage-smb' }
            Mock -ModuleName $moduleName Test-Path { throw 'unexpected' } -ParameterFilter { $Path -ne 'test-dir\storage-smb' }
            Mock -ModuleName $moduleName Write-Log { }
            Mock -ModuleName $moduleName Copy-Item { }
            Mock -ModuleName $moduleName Get-StorageConfig { return @{WinMountPath = 'c:\win\dir1' }, @{WinMountPath = 'c:\win\dir2' } }

            InModuleScope -ModuleName $moduleName {
                Restore-AddonData -BackupDir 'test-dir'
            }
        }

        It 'restores the data' {
            InModuleScope -ModuleName $moduleName {
                Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 'test-dir\storage-smb\dir1_0\*' -and $Destination -eq 'c:\win\dir1' } -Scope Context
                Should -Invoke Copy-Item -Times 1 -ParameterFilter { $Path -eq 'test-dir\storage-smb\dir2_1\*' -and $Destination -eq 'c:\win\dir2' } -Scope Context
            }
        }
    }
}

Describe 'Get-StorageConfig' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    Context 'config file not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-StorageConfigPath { return 'non-existent' }
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'non-existent' }            
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-StorageConfig } | Should -Throw -ExpectedMessage '* file * not found' }
        }
    }
    
    Context 'no content loaded' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-StorageConfigPath { return 'test-path' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'test-path' }            
            Mock -ModuleName $moduleName Get-Content { return 'content' } -ParameterFilter { $Path -eq 'test-path' }            
            Mock -ModuleName $moduleName ConvertFrom-Json { return $null } -ParameterFilter { $InputObject -eq 'content' }            
        }

        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-StorageConfig } | Should -Throw -ExpectedMessage '* file * empty or invalid' }
        }
    }
    
    Context 'raw switch set' {
        BeforeAll {
            $jsonObj = @{Prop1 = 'val1'; Prop2 = 'val2' }

            Mock -ModuleName $moduleName Get-StorageConfigPath { return 'test-path' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'test-path' }            
            Mock -ModuleName $moduleName Get-Content { return 'content' } -ParameterFilter { $Path -eq 'test-path' }            
            Mock -ModuleName $moduleName ConvertFrom-Json { return $jsonObj } -ParameterFilter { $InputObject -eq 'content' }            
        }

        It 'returns parsed object from json file' {
            InModuleScope -ModuleName $moduleName {
                $actual = Get-StorageConfig -Raw

                $actual.Prop1 | Should -Be 'val1'
                $actual.Prop2 | Should -Be 'val2'
            }
        }
    }
  
    Context 'raw switch not set' {
        BeforeAll {
            $jsonObj = @{Prop = 'my-val-1' }, @{Prop = 'my-val-2' }

            Mock -ModuleName $moduleName Get-StorageConfigPath { return 'test-path' }
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'test-path' }            
            Mock -ModuleName $moduleName Get-Content { return 'content' } -ParameterFilter { $Path -eq 'test-path' }            
            Mock -ModuleName $moduleName ConvertFrom-Json { return $jsonObj } -ParameterFilter { $InputObject -eq 'content' }            
            Mock -ModuleName $moduleName Get-StorageConfigFromRaw { return @{Prop = 'val1' }, @{Prop = 'val2' } } -ParameterFilter { $RawConfig[0].Prop -eq 'my-val-1' -and $RawConfig[1].Prop -eq 'my-val-2' }          
        }

        It 'returns enriched object from json file' {
            InModuleScope -ModuleName $moduleName {
                $actual = Get-StorageConfig

                $actual | Should -HaveCount 2
                $actual[0].Prop | Should -Be 'val1'
                $actual[1].Prop | Should -Be 'val2'
            }
        }
    }
}

Describe 'Get-StorageConfigFromRaw' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'raw config not specified' {
        It 'throws' {
            { Get-StorageConfigFromRaw } | Should -Throw -ExpectedMessage 'RawConfig not specified'
        }
    }
  
    Context 'successful' {
        BeforeAll {
            Mock -ModuleName $moduleName Expand-PathSMB { return "exp\$($FilePath)" }            
            Mock -ModuleName $moduleName Get-ConfiguredIPControlPlane { return 'control-plane-ip' }            
            Mock -ModuleName $moduleName Get-ConfiguredKubeSwitchIP { return 'switch-ip' }            
        }

        It 'returns enriched config object' {
            InModuleScope -ModuleName $moduleName {
                $config = @{
                    winMountPath     = 'win\dir-a';
                    linuxMountPath   = 'linux\dir-b' ; 
                    linuxShareName   = 'linux-smb-shareB';
                    winShareName     = 'win-smb-shareA';
                    storageClassName = 'sc1' 
                }, @{
                    winMountPath     = 'win\dir-c'; 
                    linuxMountPath   = 'linux\dir-d' ; 
                    linuxShareName   = 'linux-smb-shareD';
                    winShareName     = 'win-smb-shareC';
                    storageClassName = 'sc2' 
                }

                $actual = Get-StorageConfigFromRaw -RawConfig $config

                $actual[0].WinMountPath | Should -Be 'exp\win\dir-a'
                $actual[0].WinShareName | Should -Be 'win-smb-shareA'
                $actual[0].WinHostRemotePath | Should -Be '\\switch-ip\win-smb-shareA'
                $actual[0].LinuxMountPath | Should -Be 'linux\dir-b'
                $actual[0].LinuxShareName | Should -Be 'linux-smb-shareB'
                $actual[0].LinuxHostRemotePath | Should -Be '\\control-plane-ip\linux-smb-shareB'
                $actual[0].StorageClassName | Should -Be 'sc1'
                
                $actual[1].WinMountPath | Should -Be 'exp\win\dir-c'
                $actual[1].WinShareName | Should -Be 'win-smb-shareC'
                $actual[1].WinHostRemotePath | Should -Be '\\switch-ip\win-smb-shareC'
                $actual[1].LinuxMountPath | Should -Be 'linux\dir-d'
                $actual[1].LinuxShareName | Should -Be 'linux-smb-shareD'
                $actual[1].LinuxHostRemotePath | Should -Be '\\control-plane-ip\linux-smb-shareD'
                $actual[1].StorageClassName | Should -Be 'sc2'
            }
        }

        It 'defaults POSIX fields when not specified' {
            InModuleScope -ModuleName $moduleName {
                $config = @{
                    winMountPath     = 'win\dir';
                    linuxMountPath   = 'linux\dir';
                    storageClassName = 'sc1'
                }

                $actual = Get-StorageConfigFromRaw -RawConfig $config

                $actual[0].LinuxShareName | Should -Be 'linux-sc1-share'
                $actual[0].WinShareName | Should -Be 'win-sc1-share'
                $actual[0].SmbDialect | Should -Be 'auto'
                $actual[0].EnablePosixExtensions | Should -BeFalse
                $actual[0].UseServerInode | Should -BeFalse
                $actual[0].MountOptions | Should -BeNullOrEmpty
            }
        }

        It 'parses POSIX fields when specified' {
            InModuleScope -ModuleName $moduleName {
                $config = @{
                    winMountPath           = 'win\dir';
                    linuxMountPath         = 'linux\dir';
                    storageClassName       = 'sc1';
                    smbDialect             = '3.1.1';
                    enablePosixExtensions  = $true;
                    useServerInode         = $true
                }

                $actual = Get-StorageConfigFromRaw -RawConfig $config

                $actual[0].SmbDialect | Should -Be '3.1.1'
                $actual[0].EnablePosixExtensions | Should -BeTrue
                $actual[0].UseServerInode | Should -BeTrue
            }
        }

        It 'parses mountOptions when specified' {
            InModuleScope -ModuleName $moduleName {
                $config = '[{ "winMountPath": "win\\dir", "linuxMountPath": "linux/dir", "storageClassName": "smb-postgres", "mountOptions": [ "dir_mode=0700" ] }]' | ConvertFrom-Json

                $actual = Get-StorageConfigFromRaw -RawConfig $config

                $actual[0].MountOptions.GetType().IsArray | Should -BeTrue
                $actual[0].MountOptions | Should -Be @('dir_mode=0700')
            }
        }

        It 'defaults invalid smbDialect to auto' {
            InModuleScope -ModuleName $moduleName {
                $config = @{
                    winMountPath     = 'win\dir';
                    linuxMountPath   = 'linux\dir';
                    storageClassName = 'sc1';
                    smbDialect       = 'invalid'
                }

                $actual = Get-StorageConfigFromRaw -RawConfig $config

                $actual[0].SmbDialect | Should -Be 'auto'
            }
        }
    }
}

Describe 'Hooks path resolution' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    It 'resolves module paths correctly when hook scripts are executed from runtime location (addons\hooks)' {
        # Runtime location where Copy-ScriptsToHooksDir installs hook scripts
        $runtimeHooksDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..\..\..\hooks'))
        $sourceHooksDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..\hooks'))

        $hookFiles = Get-ChildItem -Path $sourceHooksDir -Filter '*.ps1'
        $hookFiles.Count | Should -BeGreaterThan 0

        foreach ($hookFile in $hookFiles) {
            $content = Get-Content -Path $hookFile.FullName -Raw

            # Match module import variables (e.g., $logModule, $smbShareModule)
            $matches = [regex]::Matches($content, '\$(\w+Module)\s*=\s*["''](?:\$PSScriptRoot[/\\])?([^"'']+)["'']')
            $matches.Count | Should -BeGreaterThan 0 -Because "Hook script '$($hookFile.Name)' should define module paths"

            foreach ($m in $matches) {
                $varName = $m.Groups[1].Value
                $relPath = $m.Groups[2].Value
                $resolvedPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($runtimeHooksDir, $relPath))

                (Test-Path -Path $resolvedPath) | Should -BeTrue -Because "Variable `$$varName with relative path '$relPath' in hook '$($hookFile.Name)' must resolve to an existing file at '$resolvedPath' when executed from runtime hooks directory '$runtimeHooksDir'"
            }
        }
    }
}
