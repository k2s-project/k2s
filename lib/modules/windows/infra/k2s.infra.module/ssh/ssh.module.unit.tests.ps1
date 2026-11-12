# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ssh.module.psm1') -Force
}

Describe 'Remove-SshKnownHostEntry' -Tag 'unit', 'ci', 'ssh' {
    BeforeEach {
        Mock Write-Log -ModuleName ssh.module
    }

    It 'does nothing when ssh-keygen.exe is not available' {
        Mock Get-Command -ModuleName ssh.module { $null }
        Mock Start-Process -ModuleName ssh.module

        Remove-SshKnownHostEntry -HostName '172.19.1.100'

        Should -Invoke Start-Process -ModuleName ssh.module -Times 0 -Exactly
    }

    It 'redirects the output of ssh-keygen.exe to files instead of a pipe' {
        Mock Get-Command -ModuleName ssh.module { [pscustomobject]@{ Name = 'ssh-keygen.exe' } }
        Mock Start-Process -ModuleName ssh.module {
            $process = [pscustomobject]@{ Id = 4711 }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) $true }
            $process
        }
        Mock Stop-Process -ModuleName ssh.module

        Remove-SshKnownHostEntry -HostName '172.19.1.100'

        Should -Invoke Start-Process -ModuleName ssh.module -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'ssh-keygen.exe' -and
            $ArgumentList[0] -eq '-R' -and
            $ArgumentList[1] -eq '172.19.1.100' -and
            $RedirectStandardOutput -and
            $RedirectStandardError
        }
        Should -Invoke Stop-Process -ModuleName ssh.module -Times 0 -Exactly
    }

    It 'terminates ssh-keygen.exe when it does not finish within the timeout' {
        Mock Get-Command -ModuleName ssh.module { [pscustomobject]@{ Name = 'ssh-keygen.exe' } }
        $script:requestedWaitMilliseconds = $null
        Mock Start-Process -ModuleName ssh.module {
            $process = [pscustomobject]@{ Id = 4711 }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) $false }
            $process
        }
        Mock Stop-Process -ModuleName ssh.module

        Remove-SshKnownHostEntry -HostName '172.19.1.100' -TimeoutSeconds 5

        Should -Invoke Stop-Process -ModuleName ssh.module -Times 1 -Exactly -ParameterFilter { $Id -eq 4711 }
    }

    It 'writes the output of ssh-keygen.exe to the log' {
        Mock Get-Command -ModuleName ssh.module { [pscustomobject]@{ Name = 'ssh-keygen.exe' } }
        Mock Start-Process -ModuleName ssh.module {
            $process = [pscustomobject]@{ Id = 4711 }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($milliseconds) $true }
            $process
        }
        Mock Get-Content -ModuleName ssh.module { 'Host 172.19.1.100 not found in known_hosts' }

        Remove-SshKnownHostEntry -HostName '172.19.1.100'

        Should -Invoke Write-Log -ModuleName ssh.module -Times 1 -Exactly
    }
}
