# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\security.module.psm1", [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | Out-String)
    }
    $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-SshKey'
        }, $true)
    Invoke-Expression $function.Extent.Text
    function Write-Log { param($Messages) }
    function Set-SshPrivateKeyPermissions { param($Path) }
}

Describe 'New-SshKey permissions' -Tag 'unit', 'ci', 'security' {
    BeforeEach {
        $sshKeyControlPlane = 'C:\test-profile\.ssh\k2s\id_rsa'
        $sshConfigDir = 'C:\test-profile\.ssh'
        Mock Write-Log {}
        Mock Set-SshPrivateKeyPermissions {}
        Mock Test-Path { $true }
        Mock Test-Path { $false } -ParameterFilter { $Path -like '*known_hosts' }
        Mock ssh-keygen.exe {}
    }

    It 'secures a reused key without generating a replacement' {
        New-SshKey -IpAddress '172.19.1.100' | Should -Be 'C:\test-profile\.ssh\k2s\id_rsa.pub'
        Should -Invoke Set-SshPrivateKeyPermissions -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'C:\test-profile\.ssh\k2s\id_rsa'
        }
        Should -Invoke ssh-keygen.exe -Times 0 -Exactly
    }

    It 'secures a newly generated key before returning its public-key path' {
        $script:keyCreated = $false
        Mock Test-Path { $script:keyCreated } -ParameterFilter { $Path -eq 'C:\test-profile\.ssh\k2s\id_rsa' }
        Mock ssh-keygen.exe { $script:keyCreated = $true }
        New-SshKey -IpAddress '172.19.1.100' | Should -Be 'C:\test-profile\.ssh\k2s\id_rsa.pub'
        Should -Invoke ssh-keygen.exe -Times 1 -Exactly
        Should -Invoke Set-SshPrivateKeyPermissions -Times 1 -Exactly
    }

    It 'fails rather than returning a public-key path when ACL repair fails' {
        Mock Set-SshPrivateKeyPermissions { throw 'Cannot secure private key' }
        { New-SshKey -IpAddress '172.19.1.100' } | Should -Throw '*Cannot secure private key*'
    }
}
