# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $scriptPath = "$PSScriptRoot\ResetWinContainerStorage.ps1"
    # The script is executed as a DYNAMIC scriptblock ([scriptblock]::Create). A dynamic scriptblock
    # has no backing file, so inside it $PSScriptRoot is EMPTY. The script builds its module paths as
    # "$PSScriptRoot\..\..\..\modules\..."; with an empty $PSScriptRoot these become unresolvable
    # relative paths and the real 'Import-Module' would fail (fatally under CI's ErrorActionPreference
    # = 'Stop'). This is a TEST-ONLY artifact - production runs from a real .ps1 where $PSScriptRoot is
    # correct. Imports are neutralized two ways: (1) 'Import-Module' is mocked in BeforeEach (portable,
    # scoped, auto-removed - works even from the dynamic scriptblock), and (2) the '#Requires' and
    # 'Import-Module' lines are stripped here as belt-and-suspenders. All external module functions are
    # stubbed globally below.
    $scriptContent = (Get-Content -Path $scriptPath | Where-Object {
            $_ -notmatch '^#Requires\b' -and $_ -notmatch '^\s*Import-Module\b'
        }) -join [Environment]::NewLine

    # Stub external module functions consumed by the script.
    function global:Initialize-Logging { }
    # NOTE: the real Write-Log (k2s.infra.module) declares '[string[]] $Messages' (plural). Mirror that
    # here so the unit tests match production. In the shared CI runspace the real module is loaded by
    # other test files, so Pester binds the mock against '$Messages'; the assertions below reference the
    # message via "$Messages$Message" to stay correct regardless of which parameter name is resolved.
    function global:Write-Log { param([Parameter(ValueFromPipeline = $true)][string[]]$Messages, [switch]$Console, [switch]$Error) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:New-Error { param($Severity, $Code, $Message) return [PSCustomObject]@{ Severity = $Severity; Code = $Code; Message = $Message } }
    function global:Get-ErrCodeWrongSetupType { return 'wrong-setup-type' }
    function global:Get-ErrCodeSystemRunning { return 'system-running' }
    function global:Get-ErrCodeUserCancellation { return 'user-cancellation' }
    function global:Get-SetupInfo { return [PSCustomObject]@{ Name = 'k2s'; LinuxOnly = $false } }
    function global:Get-RunningState { param($SetupName) return [PSCustomObject]@{ IsRunning = $false } }
    function global:Get-KubeBinPath { return 'C:\k\bin' }
    function global:Get-StorageLocalDrive { return 'C:' }
    function global:Get-StorageLocalFolderName { return '\' }

    function Invoke-ResetWinContainerStorageScript {
        param(
            [string] $Containerd,
            [string] $Docker,
            [switch] $EncodeStructuredOutput
        )

        $invokeParams = @{
            Force = $true # skip the interactive Read-Host prompt
        }
        if ($PSBoundParameters.ContainsKey('Containerd')) {
            $invokeParams.Containerd = $Containerd
        }
        if ($PSBoundParameters.ContainsKey('Docker')) {
            $invokeParams.Docker = $Docker
        }
        if ($EncodeStructuredOutput) {
            # Use structured output so validation failures return (not exit) - keeps the test host alive.
            $invokeParams.EncodeStructuredOutput = $true
            $invokeParams.MessageType = 'reset-win-storage'
        }

        & ([scriptblock]::Create($scriptContent)) @invokeParams
    }
}

Describe 'ResetWinContainerStorage.ps1' -Tag 'unit', 'ci', 'image' {

    BeforeEach {
        Mock -CommandName Initialize-Logging { }
        Mock -CommandName Write-Log { }
        Mock -CommandName Send-ToCli { }
        # Neutralize module loading: inside the dynamic scriptblock $PSScriptRoot is empty, so the
        # script's relative module paths are unresolvable and a real Import-Module would fail. This
        # mock is scoped to the test and auto-removed afterwards (safe for the shared CI runspace).
        Mock -CommandName Import-Module { }
        Mock -CommandName Get-SetupInfo { return [PSCustomObject]@{ Name = 'k2s'; LinuxOnly = $false } }
        Mock -CommandName Get-RunningState { return [PSCustomObject]@{ IsRunning = $false } }
        # Docker daemon not running -> Get-Process returns nothing
        Mock -CommandName Get-Process { return $null }
        # Never actually touch the file system: report nothing to clean up so
        # the internal cleanup routine is skipped, but capture the resolved path.
        Mock -CommandName Test-Path { return $false }
        Mock -CommandName Get-StorageLocalDrive { return 'C:' }
        Mock -CommandName Get-StorageLocalFolderName { return '\' }
    }

    Context 'Containerd path resolution when no explicit path is provided' {

        It 'resolves the configured custom storage path as <drive><folder>\containerd' {
            Mock -CommandName Get-StorageLocalDrive { return 'D:' }
            Mock -CommandName Get-StorageLocalFolderName { return '\Somaris\appdata' }

            Invoke-ResetWinContainerStorageScript -Containerd ''

            Should -Invoke Test-Path -ParameterFilter { $Path -eq 'D:\Somaris\appdata\containerd' }
        }

        It 'resolves the default install to C:\containerd' {
            Mock -CommandName Get-StorageLocalDrive { return 'C:' }
            Mock -CommandName Get-StorageLocalFolderName { return '\' }

            Invoke-ResetWinContainerStorageScript -Containerd ''

            Should -Invoke Test-Path -ParameterFilter { $Path -eq 'C:\containerd' }
        }

        It 'falls back to C:\containerd when the storage helper throws' {
            Mock -CommandName Get-StorageLocalDrive { throw 'no storage config' }

            Invoke-ResetWinContainerStorageScript -Containerd ''

            Should -Invoke Test-Path -ParameterFilter { $Path -eq 'C:\containerd' }
        }
    }

    Context 'Explicit containerd path takes precedence' {

        It 'uses the explicit path and does not call the storage helpers' {
            Invoke-ResetWinContainerStorageScript -Containerd 'E:\Temp\Containerd'

            Should -Invoke Test-Path -ParameterFilter { $Path -eq 'E:\Temp\Containerd' }
            Should -Invoke Get-StorageLocalDrive -Exactly 0
            Should -Invoke Get-StorageLocalFolderName -Exactly 0
        }
    }

    Context 'Stopping the container runtime as a safety net before deletion' {
        BeforeEach {
            # Make the containerd directory "exist" (with a valid containerd layout so the safety
            # validation passes), but neutralize the actual destructive operations so no filesystem
            # changes occur during the test.
            Mock -CommandName Test-Path {
                param($Path)
                return ($Path -eq 'D:\containerd' -or
                    $Path -eq 'D:\containerd\root' -or
                    $Path -eq 'D:\containerd\state' -or
                    $Path -eq 'D:\containerd\root\io.containerd.snapshotter.v1.windows')
            }
            Mock -CommandName takeown { }
            Mock -CommandName icacls { }
            Mock -CommandName fsutil { }
            # Validation enumerates root/state for an 'io.containerd.*' child; return one for 'root'.
            Mock -CommandName Get-ChildItem {
                param($Path)
                if ($Path -eq 'D:\containerd\root') {
                    return @([PSCustomObject]@{ Name = 'io.containerd.snapshotter.v1.windows'; FullName = 'D:\containerd\root\io.containerd.snapshotter.v1.windows' })
                }
                return @()
            }
            Mock -CommandName Remove-Item { }
            Mock -CommandName Get-KubeBinPath { return 'C:\k\bin' }
            Mock -CommandName Get-Service { return [PSCustomObject]@{ Name = 'containerd'; Status = 'Running' } }
            Mock -CommandName Stop-Service { }
            Mock -CommandName Get-Process { return $null }
            Mock -CommandName Stop-Process { }
        }

        It 'stops the containerd service before cleaning the containerd storage' {
            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd'

            Should -Invoke Stop-Service -Exactly 1 -ParameterFilter { $Name -eq 'containerd' }
        }

        It 'does not stop the containerd service when there is nothing to clean' {
            Mock -CommandName Test-Path { return $false }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd'

            Should -Invoke Stop-Service -Exactly 0
        }
    }

    Context 'Removing Windows snapshotter layers via the HCS DestroyLayer path' {
        BeforeEach {
            $script:snapshotsPath = 'D:\containerd\root\io.containerd.snapshotter.v1.windows\snapshots'
            # containerd dir (with a valid containerd layout) and the snapshots dir "exist"; zap.exe
            # does NOT, so Invoke-ZapFolder takes its safe not-found branch and never launches a real
            # executable during the test.
            Mock -CommandName Test-Path {
                param($Path)
                return ($Path -eq 'D:\containerd' -or
                    $Path -eq $script:snapshotsPath -or
                    $Path -eq 'D:\containerd\root' -or
                    $Path -eq 'D:\containerd\state' -or
                    $Path -eq 'D:\containerd\root\io.containerd.snapshotter.v1.windows')
            }
            Mock -CommandName Get-ChildItem {
                param($Path)
                # Validation enumerates 'root' for an 'io.containerd.*' child.
                if ($Path -eq 'D:\containerd\root') {
                    return @([PSCustomObject]@{ Name = 'io.containerd.snapshotter.v1.windows'; FullName = 'D:\containerd\root\io.containerd.snapshotter.v1.windows' })
                }
                if ($Path -eq $script:snapshotsPath) {
                    # Deliberately unsorted, mixing single- and multi-digit IDs to prove NUMERIC
                    # (not lexicographic) descending ordering.
                    return @(
                        [PSCustomObject]@{ Name = '4'; FullName = "$script:snapshotsPath\4" },
                        [PSCustomObject]@{ Name = '2008'; FullName = "$script:snapshotsPath\2008" },
                        [PSCustomObject]@{ Name = '1'; FullName = "$script:snapshotsPath\1" },
                        [PSCustomObject]@{ Name = '138'; FullName = "$script:snapshotsPath\138" }
                    )
                }
                return @()
            }
            Mock -CommandName takeown { }
            Mock -CommandName icacls { }
            Mock -CommandName fsutil { }
            Mock -CommandName Remove-Item { }
            Mock -CommandName Get-KubeBinPath { return 'C:\k\bin' }
            Mock -CommandName Get-Service { return $null }
            Mock -CommandName Stop-Service { }
            Mock -CommandName Get-Process { return $null }
            Mock -CommandName Stop-Process { }
        }

        It 'enumerates the Windows snapshotter layers' {
            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd'

            Should -Invoke Get-ChildItem -ParameterFilter { $Path -eq $script:snapshotsPath }
        }

        It 'attempts to destroy every snapshot layer individually' {
            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd'

            # "$Messages$Message" reads the log text whether the resolved Write-Log parameter is
            # $Messages (real k2s.infra.module in the shared CI runspace) or $Message (isolated stub).
            Should -Invoke Write-Log -Exactly 4 -ParameterFilter { "$Messages$Message" -like '*Destroying container layer*' }
        }

        It 'destroys the snapshot layers in numeric descending order (child before parent)' {
            $script:destroyOrder = [System.Collections.Generic.List[string]]::new()
            Mock -CommandName Write-Log -ParameterFilter { "$Messages$Message" -like '*Destroying container layer:*' } -MockWith {
                # Capture the layer id (trailing path segment) in invocation order.
                $script:destroyOrder.Add((("$Messages$Message") -split '\\')[-1])
            }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd'

            $script:destroyOrder | Should -Be @('2008', '138', '4', '1')
        }
    }

    Context 'Validating the containerd storage layout before any destructive action' {
        BeforeEach {
            # Neutralize every destructive/side-effecting operation so a failed validation can be
            # proven to have skipped all of them.
            Mock -CommandName takeown { }
            Mock -CommandName icacls { }
            Mock -CommandName fsutil { }
            Mock -CommandName Remove-Item { }
            Mock -CommandName Get-ChildItem { return @() }
            Mock -CommandName Get-KubeBinPath { return 'C:\k\bin' }
            Mock -CommandName Get-Service { return $null }
            Mock -CommandName Stop-Service { }
            Mock -CommandName Get-Process { return $null }
            Mock -CommandName Stop-Process { }
        }

        It 'accepts a valid containerd directory (root, state, windows snapshotter) and proceeds to cleanup' {
            $existing = @('D:\containerd', 'D:\containerd\root', 'D:\containerd\state')
            Mock -CommandName Test-Path { param($Path) return ($existing -contains $Path) }
            # Validation now enumerates immediate child dirs under root/state and accepts any name
            # starting with 'io.containerd.'. Return such a plugin dir for 'root', nothing elsewhere.
            Mock -CommandName Get-ChildItem {
                param($Path)
                if ($Path -eq 'D:\containerd\root') {
                    return @([PSCustomObject]@{ Name = 'io.containerd.snapshotter.v1.windows'; FullName = 'D:\containerd\root\io.containerd.snapshotter.v1.windows' })
                }
                return @()
            }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd'

            Should -Invoke Write-Log -ParameterFilter { "$Messages$Message" -like '*Performing cleanup of*' }
        }

        It 'accepts a valid containerd directory with a different runtime layout (content store) and proceeds' {
            $existing = @('D:\containerd', 'D:\containerd\root', 'D:\containerd\state')
            Mock -CommandName Test-Path { param($Path) return ($existing -contains $Path) }
            # A different plugin (content store) still matches the 'io.containerd.' prefix.
            Mock -CommandName Get-ChildItem {
                param($Path)
                if ($Path -eq 'D:\containerd\root') {
                    return @([PSCustomObject]@{ Name = 'io.containerd.content.v1.content'; FullName = 'D:\containerd\root\io.containerd.content.v1.content' })
                }
                return @()
            }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd'

            Should -Invoke Write-Log -ParameterFilter { "$Messages$Message" -like '*Performing cleanup of*' }
        }

        It 'accepts an unknown FUTURE plugin directory (version-independent io.containerd.* prefix)' {
            $existing = @('D:\containerd', 'D:\containerd\root', 'D:\containerd\state')
            Mock -CommandName Test-Path { param($Path) return ($existing -contains $Path) }
            # No known plugin under root; only a future/unknown plugin under state. The prefix-based
            # fingerprint must still accept it (this would FAIL under the old fixed-list check).
            Mock -CommandName Get-ChildItem {
                param($Path)
                if ($Path -eq 'D:\containerd\state') {
                    return @([PSCustomObject]@{ Name = 'io.containerd.future.plugin'; FullName = 'D:\containerd\state\io.containerd.future.plugin' })
                }
                return @()
            }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd'

            Should -Invoke Write-Log -ParameterFilter { "$Messages$Message" -like '*Performing cleanup of*' }
        }

        It 'rejects a directory that is missing root' {
            $existing = @(
                'D:\containerd',
                'D:\containerd\state',
                'D:\containerd\root\io.containerd.snapshotter.v1.windows'
            )
            Mock -CommandName Test-Path { param($Path) return ($existing -contains $Path) }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd' -EncodeStructuredOutput

            Should -Invoke Send-ToCli -ParameterFilter { $Message.Error.Code -eq 'invalid-containerd-storage' }
            Should -Invoke takeown -Exactly 0
            Should -Invoke Remove-Item -Exactly 0
        }

        It 'rejects a directory that is missing state' {
            $existing = @(
                'D:\containerd',
                'D:\containerd\root',
                'D:\containerd\root\io.containerd.snapshotter.v1.windows'
            )
            Mock -CommandName Test-Path { param($Path) return ($existing -contains $Path) }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\containerd' -EncodeStructuredOutput

            Should -Invoke Send-ToCli -ParameterFilter { $Message.Error.Code -eq 'invalid-containerd-storage' }
            Should -Invoke takeown -Exactly 0
            Should -Invoke Remove-Item -Exactly 0
        }

        It 'rejects an existing directory that is not containerd storage' {
            # root/state present but their children are UNRELATED folders (no 'io.containerd.*' plugin).
            $existing = @(
                'D:\Projects',
                'D:\Projects\root',
                'D:\Projects\state'
            )
            Mock -CommandName Test-Path { param($Path) return ($existing -contains $Path) }
            Mock -CommandName Get-ChildItem {
                param($Path)
                if ($Path -eq 'D:\Projects\root' -or $Path -eq 'D:\Projects\state') {
                    return @(
                        [PSCustomObject]@{ Name = 'Downloads'; FullName = "$Path\Downloads" },
                        [PSCustomObject]@{ Name = 'bin'; FullName = "$Path\bin" }
                    )
                }
                return @()
            }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\Projects' -EncodeStructuredOutput

            Should -Invoke Send-ToCli -ParameterFilter { $Message.Error.Code -eq 'invalid-containerd-storage' }
            Should -Invoke takeown -Exactly 0
            Should -Invoke Remove-Item -Exactly 0
        }

        It 'rejects an empty directory' {
            $existing = @('D:\empty')
            Mock -CommandName Test-Path { param($Path) return ($existing -contains $Path) }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\empty' -EncodeStructuredOutput

            Should -Invoke Send-ToCli -ParameterFilter { $Message.Error.Code -eq 'invalid-containerd-storage' }
            Should -Invoke takeown -Exactly 0
            Should -Invoke Remove-Item -Exactly 0
        }

        It 'aborts an explicit --containerd invalid path before any ownership change or deletion' {
            $existing = @('D:\Projects')
            Mock -CommandName Test-Path { param($Path) return ($existing -contains $Path) }

            Invoke-ResetWinContainerStorageScript -Containerd 'D:\Projects' -EncodeStructuredOutput

            Should -Invoke Send-ToCli -ParameterFilter { $Message.Error.Code -eq 'invalid-containerd-storage' }
            Should -Invoke takeown -Exactly 0
            Should -Invoke icacls -Exactly 0
            Should -Invoke Remove-Item -Exactly 0
            Should -Invoke Stop-Service -Exactly 0
        }
    }
}

