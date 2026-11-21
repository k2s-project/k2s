# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $module = "$PSScriptRoot\Smb-posix.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Smb-posix module dependency resolution' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # Regression guard (#2478): asserts the module imports its node-module dependency so the cmdlet resolves at runtime. Injects NO stub on purpose.
    Context 'Required cmdlet is in scope after import' {
        It 'resolves Invoke-CmdOnControlPlaneViaSSHKey inside the posix module scope' {
            InModuleScope -ModuleName $moduleName {
                Get-Command -Name 'Invoke-CmdOnControlPlaneViaSSHKey' -ErrorAction SilentlyContinue |
                    Should -Not -BeNullOrEmpty
            }
        }
    }
}

Describe 'Test-SambaPosixNegotiation' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # Each test stubs Invoke-CmdOnControlPlaneViaSSHKey in module scope with canned testparm output for host-free validation.

    Context 'POSIX settings present in testparm output' {
        It 'returns true when streams_xattr and store dos attributes = no are configured' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{
                        Output = @('vfs objects = streams_xattr', 'store dos attributes = no')
                    }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeTrue
            }
        }
    }

    Context 'POSIX settings missing' {
        It 'returns false when streams_xattr is absent' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{ Output = @('store dos attributes = no') }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeFalse
            }
        }

        It 'returns false when store dos attributes setting is absent' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{ Output = @('vfs objects = streams_xattr') }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeFalse
            }
        }
    }

    Context 'Bounded retry while smbd becomes ready' {
        It 'retries and returns true once POSIX settings appear on a later attempt' {
            InModuleScope -ModuleName $moduleName {
                # First attempt: smbd still restarting; second attempt: settings serviceable.
                $script:posixAttempt = 0
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    $script:posixAttempt++
                    if ($script:posixAttempt -lt 2) {
                        return [pscustomobject]@{ Output = @('# smbd not ready') }
                    }
                    return [pscustomobject]@{
                        Output = @('vfs objects = streams_xattr', 'store dos attributes = no')
                    }
                }
                # Stub the backoff so the test does not actually wait.
                function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' -Retries 5 -RetryDelaySeconds 1 | Should -BeTrue
                $script:posixAttempt | Should -BeGreaterOrEqual 2
            }
        }

        It 'returns false after exhausting the retry budget when settings never appear' {
            InModuleScope -ModuleName $moduleName {
                $script:posixCalls = 0
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    $script:posixCalls++
                    return [pscustomobject]@{ Output = @('# never ready') }
                }
                function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' -Retries 3 -RetryDelaySeconds 1 | Should -BeFalse
                $script:posixCalls | Should -Be 3
            }
        }
    }

    Context 'Section query returns nothing' {
        It 'falls back to a full configuration dump and still detects POSIX settings' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    if ($CmdToExecute -match '--section-name') {
                        return [pscustomobject]@{ Output = @() }
                    }
                    return [pscustomobject]@{
                        Output = @('vfs objects = streams_xattr', 'store dos attributes = no')
                    }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeTrue
            }
        }
    }
}

Describe 'Get-FstabVersionOption' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # AC#1 (#2478): an 'auto' or empty dialect must resolve to a concrete fstab vers= so the host mount succeeds.
    Context 'auto or empty dialect' {
        It 'defaults to the host fstab dialect for auto' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect 'auto' | Should -Be "vers=$script:DefaultSmbFstabDialect"
            }
        }

        It 'defaults to the host fstab dialect for an empty dialect' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect '' | Should -Be "vers=$script:DefaultSmbFstabDialect"
            }
        }
    }

    Context 'explicit dialect' {
        It 'pins the requested dialect' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect '3.1.1' | Should -Be 'vers=3.1.1'
            }
        }
    }

    # AC#1 (#2478): the Linux Samba host historically pinned 'vers=3'; an 'auto' dialect must not
    # downgrade it to 'vers=3.0' when a caller-specific default is supplied.
    Context 'caller-specific default dialect' {
        It 'uses the supplied default for auto' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect 'auto' -DefaultDialect '3' | Should -Be 'vers=3'
            }
        }

        It 'still pins an explicit dialect regardless of the default' {
            InModuleScope -ModuleName $moduleName {
                Get-FstabVersionOption -SmbDialect '3.1.1' -DefaultDialect '3' | Should -Be 'vers=3.1.1'
            }
        }
    }
}

Describe 'Get-SambaSharePosixConfig' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # AC#2c (#2478): POSIX shares must declare streams_xattr; non-POSIX shares must not.
    Context 'POSIX extensions enabled' {
        It 'returns the streams_xattr and store dos attributes settings' {
            InModuleScope -ModuleName $moduleName {
                $lines = Get-SambaSharePosixConfig -Config ([pscustomobject]@{ EnablePosixExtensions = $true })
                $lines | Should -Contain 'vfs objects = streams_xattr'
                $lines | Should -Contain 'store dos attributes = no'
            }
        }
    }

    Context 'POSIX extensions disabled' {
        It 'returns no POSIX share lines' {
            InModuleScope -ModuleName $moduleName {
                Get-SambaSharePosixConfig -Config ([pscustomobject]@{ EnablePosixExtensions = $false }) | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Get-StorageClassMountOptions' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'mountOptions not configured' {
        It 'returns the generated default options' {
            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject]@{ EnablePosixExtensions = $false; UseServerInode = $false; SmbDialect = 'auto' }

                $opts = Get-StorageClassMountOptions -Config $config

                $opts | Should -Be @('dir_mode=0777', 'file_mode=0777', 'uid=1001', 'gid=1001', 'noperm', 'mfsymlinks', 'cache=strict', 'noserverino')
            }
        }
    }

    Context 'mountOptions configured' {
        It 'returns exactly the configured options in order' {
            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject]@{ EnablePosixExtensions = $false; UseServerInode = $false; SmbDialect = 'auto'; MountOptions = @('dir_mode=0700', 'file_mode=0600', 'uid=1001', 'gid=1001') }

                $opts = Get-StorageClassMountOptions -Config $config

                $opts | Should -Be @('dir_mode=0700', 'file_mode=0600', 'uid=1001', 'gid=1001')
            }
        }

        It 'does not add POSIX or dialect specific options' {
            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject]@{ EnablePosixExtensions = $true; UseServerInode = $false; SmbDialect = '3.1.1'; MountOptions = @('dir_mode=0700') }

                $opts = Get-StorageClassMountOptions -Config $config

                $opts | Should -Be @('dir_mode=0700')
            }
        }
    }
}

Describe 'Get-StorageClassMountOptionsError' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    Context 'Config not specified' {
        It 'throws' {
            InModuleScope -ModuleName $moduleName {
                { Get-StorageClassMountOptionsError } | Should -Throw -ExpectedMessage 'Config not specified'
            }
        }
    }

    Context 'valid configuration' {
        It 'returns nothing when mountOptions is not configured' {
            InModuleScope -ModuleName $moduleName {
                Get-StorageClassMountOptionsError -Config ([pscustomobject]@{ StorageClassName = 'smb' }) | Should -BeNullOrEmpty
            }
        }

        It 'returns nothing for valid options' {
            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject]@{ StorageClassName = 'smb-postgres'; MountOptions = @('dir_mode=0700', 'file_mode=0600', 'uid=1001', 'noperm', 'cache=strict', 'vers=3.1.1', 'prefixpath=/data', 'iocharset=utf8') }

                Get-StorageClassMountOptionsError -Config $config | Should -BeNullOrEmpty
            }
        }

        It 'returns nothing for a single option parsed from JSON' {
            InModuleScope -ModuleName $moduleName {
                $config = '{ "storageClassName": "smb-postgres", "mountOptions": [ "dir_mode=0700" ] }' | ConvertFrom-Json

                Get-StorageClassMountOptionsError -Config $config | Should -BeNullOrEmpty
            }
        }
    }

    Context 'invalid configuration' {
        It 'rejects mountOptions that is not an array' {
            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject]@{ StorageClassName = 'smb-postgres'; MountOptions = 'dir_mode=0700' }

                Get-StorageClassMountOptionsError -Config $config | Should -Match "^Invalid 'mountOptions' for StorageClass 'smb-postgres': expected a non-empty array"
            }
        }

        It 'rejects an empty array' {
            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject]@{ StorageClassName = 'smb-postgres'; MountOptions = @() }

                Get-StorageClassMountOptionsError -Config $config | Should -Match "^Invalid 'mountOptions' for StorageClass 'smb-postgres': expected a non-empty array"
            }
        }

        It "rejects option '<Option>'" -ForEach @(
            @{ Option = '' }
            @{ Option = ' ' }
            @{ Option = 'dir_mode=0700 file_mode=0600' }
            @{ Option = 'dir_mode=0700,file_mode=0600' }
            @{ Option = '-dir_mode=0700' }
            @{ Option = 'dir_mode: 0700' }
            @{ Option = 'uid=1001 # comment' }
            @{ Option = '"noperm"' }
            @{ Option = '[noperm]' }
            @{ Option = 'password=$secret' }
        ) {
            InModuleScope -ModuleName $moduleName -Parameters @{ Option = $Option } {
                param($Option)

                $config = [pscustomobject]@{ StorageClassName = 'smb-postgres'; MountOptions = @('noperm', $Option) }

                Get-StorageClassMountOptionsError -Config $config | Should -Match "^Invalid 'mountOptions' for StorageClass 'smb-postgres': '.*' is not a valid mount option"
            }
        }

        It 'rejects an option with a trailing line break' {
            InModuleScope -ModuleName $moduleName {
                $config = [pscustomobject]@{ StorageClassName = 'smb-postgres'; MountOptions = @("dir_mode=0700`n") }

                Get-StorageClassMountOptionsError -Config $config | Should -Match "(?s)^Invalid 'mountOptions' for StorageClass 'smb-postgres': 'dir_mode=0700\n' is not a valid mount option"
            }
        }

        It 'rejects non-string options' {
            InModuleScope -ModuleName $moduleName {
                $config = '{ "storageClassName": "smb-postgres", "mountOptions": [ 1001 ] }' | ConvertFrom-Json

                Get-StorageClassMountOptionsError -Config $config | Should -Match "^Invalid 'mountOptions' for StorageClass 'smb-postgres': '1001' is not a valid mount option"
            }
        }
    }
}
