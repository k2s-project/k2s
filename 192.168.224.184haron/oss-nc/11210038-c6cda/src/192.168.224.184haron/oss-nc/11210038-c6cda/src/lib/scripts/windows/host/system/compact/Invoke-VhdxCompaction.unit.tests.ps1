# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $scriptPath = "$PSScriptRoot\Invoke-VhdxCompaction.ps1"
    # Create a temp copy without #Requires -RunAsAdministrator so tests can run in non-elevated CI
    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) 'Invoke-VhdxCompaction.tests.tmp.ps1'
    (Get-Content -Path $scriptPath | Where-Object { $_ -notmatch '^#Requires\s+-RunAsAdministrator' }) | Set-Content -Path $tempScript -Encoding UTF8

    function global:Initialize-Logging { param([switch]$ShowLogs) }
    function global:Get-KubePath { return 'C:\k2s' }
    function global:Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
    function global:Get-ConfigWslFlag { return $false }
    function global:Get-ConfigLinuxOnly { return $false }
    function global:Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
    function global:Get-ConfiguredIPControlPlane { return '172.19.1.100' }
    function global:Invoke-CmdOnControlPlaneViaSSHKey { param($CmdToExecute, [switch]$IgnoreErrors) return [PSCustomObject]@{ Output = @('fstrim done') } }
    function global:Write-Log { param([string]$Message, [switch]$Console, [switch]$Error) }

    function New-MockVm {
        param([string]$Name = 'kubemaster', [string]$State = 'Off')
        return [PSCustomObject]@{ Name = $Name; State = $State }
    }

    function New-MockDisk {
        param([string]$Path = 'C:\VMs\KubeMaster.vhdx', [int]$ControllerNumber = 0, [int]$ControllerLocation = 0)
        return [PSCustomObject]@{ Path = $Path; ControllerNumber = $ControllerNumber; ControllerLocation = $ControllerLocation }
    }

    Mock -CommandName Initialize-Logging { }
}

AfterAll {
    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) 'Invoke-VhdxCompaction.tests.tmp.ps1'
    if (Test-Path $tempScript) { Remove-Item $tempScript -Force }
}

Describe 'Invoke-VhdxCompaction' -Tag 'unit', 'ci', 'compact' {

    Describe 'Pre-condition: K2s not installed' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return $null }
            Mock Write-Log {}
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not proceed to VM lookup when K2s is not installed' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Get-ConfigControlPlaneNodeHostname -Times 0 -Scope It
        }
    }

    Describe 'Pre-condition: WSL installation' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $true }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not proceed to VM lookup on WSL installation' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Get-ConfigControlPlaneNodeHostname -Times 0 -Scope It
        }
    }

    Describe 'Pre-condition: VM not found' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return $null }
            Mock Get-VMHardDiskDrive { return $null }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not proceed to disk lookup when VM does not exist' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Get-VMHardDiskDrive -Times 0 -Scope It
        }
    }

    Describe 'Pre-condition: VM in intermediate state' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VMHardDiskDrive { return $null }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not proceed to disk lookup when VM is in Saved state' {
            Mock Get-VM { return New-MockVm -State 'Saved' }
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Get-VMHardDiskDrive -Times 0 -Scope It
        }

        It 'does not proceed to disk lookup when VM is in Paused state' {
            Mock Get-VM { return New-MockVm -State 'Paused' }
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Get-VMHardDiskDrive -Times 0 -Scope It
        }

        It 'does not proceed to disk lookup when VM is in Starting state' {
            Mock Get-VM { return New-MockVm -State 'Starting' }
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Get-VMHardDiskDrive -Times 0 -Scope It
        }

        It 'does not proceed to disk lookup when VM is in Stopping state' {
            Mock Get-VM { return New-MockVm -State 'Stopping' }
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Get-VMHardDiskDrive -Times 0 -Scope It
        }

        It 'does not proceed to disk lookup when VM is in FastSaved state' {
            Mock Get-VM { return New-MockVm -State 'FastSaved' }
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Get-VMHardDiskDrive -Times 0 -Scope It
        }
    }

    Describe 'Pre-condition: No hard disk found on VM' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return $null }
            Mock Mount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not proceed to compaction when no hard disk drive is attached' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Mount-VHD -Times 0 -Scope It
        }
    }

    Describe 'Pre-condition: VHDX file missing from disk' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk -Path 'C:\VMs\Missing.vhdx' }
            Mock Test-Path { return $false }
            Mock Mount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not proceed to compaction when VHDX file does not exist on disk' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Mount-VHD -Times 0 -Scope It
        }
    }

    Describe 'Pre-condition: Insufficient host free disk space' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 1GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not proceed to compaction when host has insufficient free space' {
            { & $tempScript -Yes } | Should -Not -Throw
            Should -Invoke Mount-VHD -Times 0 -Scope It
        }
    }

    Describe 'Pre-condition: VHDX already mounted (stale from previous run)' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $true } }
            Mock Dismount-VHD {}
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'dismounts the stale mount before proceeding' {
            { & $tempScript -Yes } | Should -Not -Throw
            Should -Invoke Dismount-VHD -Times 1 -Scope It
        }
    }

    Describe 'Multiple VHDs: picks primary OS disk' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive {
                return @(
                    (New-MockDisk -Path 'C:\VMs\Data.vhdx'  -ControllerNumber 0 -ControllerLocation 1),
                    (New-MockDisk -Path 'C:\VMs\KubeMaster.vhdx' -ControllerNumber 0 -ControllerLocation 0)
                )
            }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'proceeds to mount and optimize when multiple disks exist' {
            { & $tempScript -Yes } | Should -Not -Throw
            Should -Invoke Mount-VHD    -Times 1 -Scope It
            Should -Invoke Optimize-VHD -Times 1 -Scope It
        }
    }

    Describe 'Happy path: cluster already stopped, no-restart' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'mounts, optimizes, and dismounts VHDX without stopping or starting cluster' {
            { & $tempScript -NoRestart } | Should -Not -Throw
            Should -Invoke Mount-VHD    -Times 1 -Scope It
            Should -Invoke Optimize-VHD -Times 1 -Scope It
            Should -Invoke Dismount-VHD -Times 1 -Scope It
        }
    }

    Describe 'Failure: Mount-VHD fails' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD { throw 'Mount failed' }
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not proceed to optimize when mount fails' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Optimize-VHD -Times 0 -Scope It
        }
    }

    Describe 'Failure: Optimize-VHD fails' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD { throw 'Optimize failed' }
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'dismounts VHDX after optimization failure' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Dismount-VHD -Times 1 -Scope It
        }
    }

    Describe 'Failure: Dismount-VHD fails after optimization' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD { throw 'Dismount failed' }
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'does not crash when dismount fails after optimization' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Optimize-VHD -Times 1 -Scope It
        }
    }

    Describe 'User cancellation at confirmation prompt' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Running' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Invoke-CmdOnControlPlaneViaSSHKey { return [PSCustomObject]@{ Output = @() } }
            Mock Read-Host { return 'n' }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'exits cleanly and never mounts VHDX when user answers n' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Mount-VHD    -Times 0 -Scope It
            Should -Invoke Optimize-VHD -Times 0 -Scope It
        }
    }

    Describe 'Yes flag bypasses confirmation prompt' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            $script:stopCount = 0
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM {
                if ($script:stopCount -eq 0) { $script:stopCount++; return New-MockVm -State 'Running' }
                return New-MockVm -State 'Off'
            }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Invoke-CmdOnControlPlaneViaSSHKey { return [PSCustomObject]@{ Output = @() } }
            Mock Read-Host { return 'n' }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'never calls Read-Host when -Yes is specified' {
            { & $tempScript -Yes } | Should -Not -Throw
            Should -Invoke Read-Host -Times 0 -Scope It
        }
    }

    Describe 'Get-VHD unavailable: compaction continues' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { throw 'Get-VHD not available' }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'still proceeds to mount and optimize when Get-VHD fails' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Mount-VHD    -Times 1 -Scope It
            Should -Invoke Optimize-VHD -Times 1 -Scope It
        }
    }

    Describe 'Get-PSDrive unavailable: compaction continues' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $false }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VM { return New-MockVm -State 'Off' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { throw 'Drive not found' }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'still mounts and optimizes VHDX when Get-PSDrive fails' {
            { & $tempScript } | Should -Not -Throw
            Should -Invoke Mount-VHD    -Times 1 -Scope It
            Should -Invoke Optimize-VHD -Times 1 -Scope It
        }
    }

    Describe 'Linux-only: cluster already stopped' -Tag 'unit', 'ci', 'compact' {
        BeforeEach {
            Mock Get-RootConfigk2s { return [PSCustomObject]@{ dummy = $true } }
            Mock Get-ConfigWslFlag { return $false }
            Mock Get-ConfigLinuxOnly { return $true }
            Mock Get-ConfigControlPlaneNodeHostname { return 'kubemaster' }
            Mock Get-VMHardDiskDrive { return New-MockDisk }
            Mock Test-Path { return $true }
            Mock Get-Item { return [PSCustomObject]@{ Length = 4GB } }
            Mock Get-VMSnapshot { return @() }
            Mock Get-VHD { return [PSCustomObject]@{ Attached = $false } }
            Mock Get-PSDrive { return [PSCustomObject]@{ Free = 10GB } }
            Mock Invoke-CmdOnControlPlaneViaSSHKey { return [PSCustomObject]@{ Output = @('fstrim done') } }
            Mock Mount-VHD {}
            Mock Optimize-VHD {}
            Mock Dismount-VHD {}
            Mock Write-Log {}
            Mock Get-KubePath { return 'C:\k2s' }
            Mock Initialize-Logging {}
            Mock Import-Module {}
            Mock Set-Location {}
        }

        It 'mounts, optimizes, and dismounts VHDX for linux-only stopped cluster' {
            Mock Get-VM { return New-MockVm -State 'Off' }
            { & $tempScript -Yes } | Should -Not -Throw
            Should -Invoke Mount-VHD    -Times 1 -Scope It
            Should -Invoke Optimize-VHD -Times 1 -Scope It
            Should -Invoke Dismount-VHD -Times 1 -Scope It
        }
    }
}
