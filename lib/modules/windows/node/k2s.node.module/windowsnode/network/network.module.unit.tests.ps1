# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\network.module.psm1", [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    foreach ($name in @('Invoke-NetshNlm', 'Test-NetshNlmHiddenSupported', 'Set-K2sInterfaceHidden', 'Test-K2sInterfaceFirewallPosture', 'Set-K2sInterfaceHiddenOrPrivate')) {
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Invoke-Expression $function.Extent.Text
    }
    function Write-Log { param($Message, [switch]$Console) }
    function Get-NetAdapter { [CmdletBinding()] param($Name, [switch]$IncludeHidden) }
    function Get-NetConnectionProfile { [CmdletBinding()] param($InterfaceAlias) }
    function Set-InterfacePrivate { param($InterfaceAlias) }
}

Describe 'netsh nlm hidden support detection' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        $script:netshNlmHiddenSupported = $null
        Mock Write-Log {}
    }

    It 'is supported when netsh prints the hidden usage' {
        Mock Invoke-NetshNlm { [pscustomobject]@{ ExitCode = 1; Output = 'Usage: hidden [guid|alias] action [hide|unhide|unchanged]' } }
        Test-NetshNlmHiddenSupported | Should -BeTrue
    }

    It 'is not supported when netsh does not know the command' {
        Mock Invoke-NetshNlm { [pscustomobject]@{ ExitCode = 1; Output = 'The following command was not found: nlm set hidden.' } }
        Test-NetshNlmHiddenSupported | Should -BeFalse
    }

    It 'queries netsh only once' {
        Mock Invoke-NetshNlm { [pscustomobject]@{ ExitCode = 1; Output = 'unhide' } }
        Test-NetshNlmHiddenSupported | Out-Null
        Test-NetshNlmHiddenSupported | Out-Null
        Should -Invoke Invoke-NetshNlm -Times 1 -Exactly
    }
}

Describe 'Set-K2sInterfaceHidden' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log {}
        Mock Start-Sleep {}
        Mock Test-NetshNlmHiddenSupported { $true }
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'vEthernet (KubeSwitch)' } }
        Mock Invoke-NetshNlm { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }

    It 'calls netsh nlm set hidden with alias, hide action and private category' {
        $result = Set-K2sInterfaceHidden -InterfaceAlias 'vEthernet (KubeSwitch)'
        $result.Applied | Should -BeTrue
        Should -Invoke Invoke-NetshNlm -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq 'set|hidden|alias|vEthernet (KubeSwitch)|action|hide|category|private'
        }
    }

    It 'does not call netsh when hiding is not supported' {
        Mock Test-NetshNlmHiddenSupported { $false }
        (Set-K2sInterfaceHidden -InterfaceAlias 'vEthernet (KubeSwitch)').Applied | Should -BeFalse
        Should -Invoke Invoke-NetshNlm -Times 0 -Exactly
    }

    It 'does not call netsh when the interface does not exist' {
        Mock Get-NetAdapter {}
        (Set-K2sInterfaceHidden -InterfaceAlias 'vEthernet (KubeSwitch)').Applied | Should -BeFalse
        Should -Invoke Invoke-NetshNlm -Times 0 -Exactly
    }

    It 'retries and reports failure without throwing' {
        Mock Invoke-NetshNlm { [pscustomobject]@{ ExitCode = 1; Output = 'The parameter is incorrect.' } }
        $result = Set-K2sInterfaceHidden -InterfaceAlias 'vEthernet (KubeSwitch)' -MaxAttempts 3
        $result.Applied | Should -BeFalse
        $result.Error | Should -Match 'parameter is incorrect'
        Should -Invoke Invoke-NetshNlm -Times 3 -Exactly
    }

    It 'succeeds when a retry works' {
        $script:calls = 0
        Mock Invoke-NetshNlm {
            $script:calls++
            [pscustomobject]@{ ExitCode = $(if ($script:calls -lt 2) { 1 } else { 0 }); Output = '' }
        }
        (Set-K2sInterfaceHidden -InterfaceAlias 'vEthernet (KubeSwitch)').Applied | Should -BeTrue
        Should -Invoke Invoke-NetshNlm -Times 2 -Exactly
    }
}

Describe 'Test-K2sInterfaceFirewallPosture' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log {}
        $script:adapter = [pscustomobject]@{ Name = 'vEthernet (KubeSwitch)'; HiddenInterface = $false }
    }

    It 'reports an unknown interface as not acceptable' {
        Mock Get-NetAdapter {}
        $posture = Test-K2sInterfaceFirewallPosture -InterfaceAlias 'vEthernet (KubeSwitch)'
        $posture.IsAcceptable | Should -BeFalse
        $posture.CurrentCategory | Should -Be 'Unknown'
    }

    It 'accepts an interface that is only returned with -IncludeHidden' {
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { $IncludeHidden }
        Mock Get-NetAdapter {} -ParameterFilter { -not $IncludeHidden }
        $posture = Test-K2sInterfaceFirewallPosture -InterfaceAlias 'vEthernet (KubeSwitch)'
        $posture.IsHidden | Should -BeTrue
        $posture.IsAcceptable | Should -BeTrue
    }

    It 'accepts a visible interface with Private profile' {
        Mock Get-NetAdapter { $script:adapter }
        Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Private' } }
        $posture = Test-K2sInterfaceFirewallPosture -InterfaceAlias 'vEthernet (KubeSwitch)'
        $posture.IsHidden | Should -BeFalse
        $posture.IsAcceptable | Should -BeTrue
    }

    It 'rejects a visible interface with Public profile' {
        Mock Get-NetAdapter { $script:adapter }
        Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Public' } }
        $posture = Test-K2sInterfaceFirewallPosture -InterfaceAlias 'vEthernet (KubeSwitch)'
        $posture.IsAcceptable | Should -BeFalse
        $posture.CurrentCategory | Should -Be 'Public'
    }

    It 'rejects a visible interface without a profile' {
        Mock Get-NetAdapter { $script:adapter }
        Mock Get-NetConnectionProfile {}
        (Test-K2sInterfaceFirewallPosture -InterfaceAlias 'vEthernet (KubeSwitch)').CurrentCategory | Should -Be 'NoProfile'
    }
}

Describe 'Set-K2sInterfaceHiddenOrPrivate' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log {}
        Mock Set-InterfacePrivate {}
        Mock Test-K2sInterfaceFirewallPosture { @{ IsHidden = $false } }
        Mock Set-K2sInterfaceHidden { [pscustomobject]@{ Applied = $true; Error = $null } }
    }

    It 'hides the interface and does not touch the profile when supported' {
        Mock Test-NetshNlmHiddenSupported { $true }
        Set-K2sInterfaceHiddenOrPrivate -InterfaceAlias 'vEthernet (KubeSwitch)'
        Should -Invoke Set-K2sInterfaceHidden -Times 1 -Exactly
        Should -Invoke Set-InterfacePrivate -Times 0 -Exactly
    }

    It 'does nothing when the interface is already hidden' {
        Mock Test-NetshNlmHiddenSupported { $true }
        Mock Test-K2sInterfaceFirewallPosture { @{ IsHidden = $true } }
        Set-K2sInterfaceHiddenOrPrivate -InterfaceAlias 'vEthernet (KubeSwitch)'
        Should -Invoke Set-K2sInterfaceHidden -Times 0 -Exactly
        Should -Invoke Set-InterfacePrivate -Times 0 -Exactly
    }

    It 'falls back to Private when netsh nlm hidden is not supported' {
        Mock Test-NetshNlmHiddenSupported { $false }
        Set-K2sInterfaceHiddenOrPrivate -InterfaceAlias 'vEthernet (KubeSwitch)'
        Should -Invoke Set-K2sInterfaceHidden -Times 0 -Exactly
        Should -Invoke Set-InterfacePrivate -Times 1 -Exactly -ParameterFilter { $InterfaceAlias -eq 'vEthernet (KubeSwitch)' }
    }

    It 'falls back to Private when hiding fails' {
        Mock Test-NetshNlmHiddenSupported { $true }
        Mock Set-K2sInterfaceHidden { [pscustomobject]@{ Applied = $false; Error = 'boom' } }
        Set-K2sInterfaceHiddenOrPrivate -InterfaceAlias 'vEthernet (KubeSwitch)'
        Should -Invoke Set-InterfacePrivate -Times 1 -Exactly
    }
}
