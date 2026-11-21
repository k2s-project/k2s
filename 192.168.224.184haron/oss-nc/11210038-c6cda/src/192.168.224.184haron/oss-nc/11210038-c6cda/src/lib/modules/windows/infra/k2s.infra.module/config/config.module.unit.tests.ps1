# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Load the module to be tested
Import-Module "$PSScriptRoot\config.module.psm1"

Describe "Get-MinimalProvisioningBaseMemorySize" {
    It "should return 2GB " {
        $result = Get-MinimalProvisioningBaseMemorySize       
        $result | Should -Be 2GB
    }
}

Describe "Get-MinimalProvisioningBaseImageDiskSize" {
    It "should return 10GB" {
        $result = Get-MinimalProvisioningBaseImageDiskSize        
        $result | Should -Be 10GB
    }
}

Describe "Get-SSHKeyControlPlane" {
    Context "When default key file exists" {
        It "should return the default SSH control plane key path" {
            Mock Test-Path -ModuleName 'config.module' { return $true }
            $keyPath = Get-SSHKeyControlPlane
            $keyPath | Should -Not -BeNullOrEmpty
            $keyPath | Should -BeLike "*id_rsa"
        }
    }

    Context "When default key file does not exist, but key exists in a user directory" {
        It "should return the existing key path from the user directory" {
            Mock Test-Path -ModuleName 'config.module' {
                param($Path)
                if ($Path -like "*Users" -or $Path -eq 'C:\Users\user1\.ssh\k2s\id_rsa') { return $true }
                return $false
            }
            Mock Get-ChildItem -ModuleName 'config.module' {
                return @([PSCustomObject]@{ Name = 'user1'; FullName = 'C:\Users\user1' })
            } -ParameterFilter { $Path -like "*Users" }

            $keyPath = Get-SSHKeyControlPlane
            $keyPath | Should -Be 'C:\Users\user1\.ssh\k2s\id_rsa'
        }
    }

    Context "When default key points to systemprofile, key does not exist, but user .ssh directory exists" {
        It "should return the derived key path in the user directory" {
            Mock Test-Path -ModuleName 'config.module' {
                param($Path)
                if ($Path -like "*Users" -or $Path -eq 'C:\Users\user1\.ssh') { return $true }
                return $false
            }
            Mock Get-ChildItem -ModuleName 'config.module' {
                return @([PSCustomObject]@{ Name = 'user1'; FullName = 'C:\Users\user1' })
            } -ParameterFilter { $Path -like "*Users" }

            InModuleScope 'config.module' {
                $origKey = $script:sshKeyControlPlane
                $script:sshKeyControlPlane = 'C:\Windows\System32\config\systemprofile\.ssh\k2s\id_rsa'
                try {
                    $keyPath = Get-SSHKeyControlPlane
                    $keyPath | Should -Be 'C:\Users\user1\.ssh\k2s\id_rsa'
                }
                finally {
                    $script:sshKeyControlPlane = $origKey
                }
            }
        }
    }

    Context "When no key or user directory exists" {
        It "should return default sshKeyControlPlane path" {
            Mock Test-Path -ModuleName 'config.module' {
                param($Path)
                if ($Path -like "*Users") { return $true }
                return $false
            }
            Mock Get-ChildItem -ModuleName 'config.module' { return @() }

            $keyPath = Get-SSHKeyControlPlane
            $keyPath | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Get-SshConfigDir" {
    Context "When default sshConfigDir exists" {
        It "should return default sshConfigDir" {
            Mock Test-Path -ModuleName 'config.module' { return $true }
            $sshDir = Get-SshConfigDir
            $sshDir | Should -Not -BeNullOrEmpty
            $sshDir | Should -BeLike "*.ssh*"
        }
    }

    Context "When default sshConfigDir does not exist, but key exists in a user directory" {
        It "should return parent .ssh folder of the found key" {
            Mock Test-Path -ModuleName 'config.module' {
                param($Path)
                if ($Path -like "*Users" -or $Path -eq 'C:\Users\user1\.ssh\k2s\id_rsa') { return $true }
                return $false
            }
            Mock Get-ChildItem -ModuleName 'config.module' {
                return @([PSCustomObject]@{ Name = 'user1'; FullName = 'C:\Users\user1' })
            } -ParameterFilter { $Path -like "*Users" }

            $sshDir = Get-SshConfigDir
            $sshDir | Should -Be 'C:\Users\user1\.ssh'
        }
    }

    Context "When default sshConfigDir and key do not exist, but user .ssh directory exists" {
        It "should return user .ssh directory" {
            Mock Test-Path -ModuleName 'config.module' {
                param($Path)
                if ($Path -like "*Users" -or $Path -eq 'C:\Users\user1\.ssh') { return $true }
                return $false
            }
            Mock Get-ChildItem -ModuleName 'config.module' {
                return @([PSCustomObject]@{ Name = 'user1'; FullName = 'C:\Users\user1' })
            } -ParameterFilter { $Path -like "*Users" }

            $sshDir = Get-SshConfigDir
            $sshDir | Should -Be 'C:\Users\user1\.ssh'
        }
    }

    Context "When no dir or key exists anywhere" {
        It "should return default sshConfigDir" {
            Mock Test-Path -ModuleName 'config.module' {
                param($Path)
                if ($Path -like "*Users") { return $true }
                return $false
            }
            Mock Get-ChildItem -ModuleName 'config.module' { return @() }

            $sshDir = Get-SshConfigDir
            $sshDir | Should -Not -BeNullOrEmpty
        }
    }
}
