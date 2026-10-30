# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot 'new-wsl-vm-as-linuxnode.module.psm1'
    $tokens = $null
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

    foreach ($name in @('Invoke-WslCommand', 'New-WslLinuxVmAsControlPlaneNode')) {
        $definition = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $false)
        if ($null -eq $definition) { throw "Missing function: $name" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    function Write-Log { param($Message, [switch]$Console) }
    function Get-KubeBinPath { }
    function Get-ControlPlaneOnWslRootfsFilePath { }
}

Describe 'WSL native diagnostics and exit handling' -Tag 'unit', 'ci', 'wsl' {
    BeforeEach {
        Mock Get-Command { [pscustomobject]@{ Source = $env:ComSpec } } -ParameterFilter { $Name -eq 'wsl.exe' }
        Mock Write-Log {}
    }

    It 'logs stderr warnings without exposing ErrorRecords to the install wrapper on exit zero' {
        $captured = @(& {
            Invoke-WslCommand -Arguments @('/d', '/c', 'echo wsl: Nested virtualization is not supported on this machine. 1>&2 & exit /b 0')
        } *>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { throw "Installer would abort: $_" }
            $_
        })

        ($captured -join "`n") | Should -Match 'Nested virtualization is not supported'
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -like '*Nested virtualization is not supported*' -and $Console
        }
    }

    It 'throws a nonzero native exit with its diagnostics' {
        { Invoke-WslCommand -Arguments @('/d', '/c', 'echo import failed 1>&2 & exit /b 5') } |
            Should -Throw '*exit code 5*import failed*'
    }

    It 'restores the caller error preference after native <ExitCode>' -ForEach @(
        @{ ExitCode = 0 }
        @{ ExitCode = 5 }
    ) {
        $ErrorActionPreference = 'Stop'
        try {
            Invoke-WslCommand -Arguments @('/d', '/c', "exit /b $ExitCode")
        }
        catch {
            if ($ExitCode -eq 0) { throw }
        }

        $ErrorActionPreference | Should -Be 'Stop'
    }

    It 'fails if the executable is unavailable rather than trusting a stale exit code' {
        Mock Get-Command { throw 'wsl.exe unavailable' } -ParameterFilter { $Name -eq 'wsl.exe' }

        { Invoke-WslCommand -Arguments @('--import', 'KubeMaster') } | Should -Throw '*wsl.exe unavailable*'
    }

    It 'logs an explicitly allowed unregister failure without emitting an ErrorRecord' {
        $captured = @(& {
            Invoke-WslCommand -Arguments @('/d', '/c', 'echo distribution missing 1>&2 & exit /b 1') -IgnoreErrors
        } *>&1)

        @($captured | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) | Should -BeNullOrEmpty
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -like '*exit code 1; continuing best-effort cleanup.*'
        }
    }
}

Describe 'WSL control-plane setup failure propagation' -Tag 'unit', 'ci', 'wsl' {
    BeforeEach {
        $script:wslCalls = [System.Collections.Generic.List[string]]::new()
        $script:failingCommand = ''
        Mock Write-Log {}
        Mock Get-KubeBinPath { 'C:\K2s lab\bin' }
        Mock Get-ControlPlaneOnWslRootfsFilePath { 'C:\K2s lab\bin\Kubemaster-Base.rootfs.tar.gz' }
        Mock Test-Path { $true }
        Mock Start-Sleep {}
        Mock Invoke-WslCommand {
            $script:wslCalls.Add(($Arguments -join '|'))
            if ($Arguments[0] -eq $script:failingCommand) { throw 'WSL native operation failed with exit code 5' }
            if ($Arguments -contains 'systemctl is-system-running 2>/dev/null || echo "unknown"; exit 0') {
                'running'
            }
        }
    }

    It 'preserves import paths with spaces and required operation ordering' {
        New-WslLinuxVmAsControlPlaneNode -VmName 'KubeMaster'

        $script:wslCalls[0] | Should -Be '--unregister|KubeMaster'
        $script:wslCalls[1] | Should -Be "--import|KubeMaster|$env:SystemDrive\wsl|C:\K2s lab\bin\Kubemaster-Base.rootfs.tar.gz"
        $script:wslCalls[2] | Should -Be '-s|KubeMaster'
        $script:wslCalls[3] | Should -Be '--exec|/bin/true'
        $script:wslCalls[-1] | Should -Be '--shutdown'
        Should -Invoke Invoke-WslCommand -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq '--unregister' -and $IgnoreErrors
        }
        Should -Invoke Invoke-WslCommand -Times 0 -Exactly -ParameterFilter {
            $Arguments[0] -ne '--unregister' -and $IgnoreErrors
        }
    }

    It 'does not continue initialization after <Command> fails' -ForEach @(
        @{ Command = '--import'; LastCall = '--import|KubeMaster' }
        @{ Command = '-s'; LastCall = '-s|KubeMaster' }
        @{ Command = '--exec'; LastCall = '--exec|/bin/true' }
    ) {
        $script:failingCommand = $Command

        { New-WslLinuxVmAsControlPlaneNode -VmName 'KubeMaster' } | Should -Throw '*exit code 5*'

        $script:wslCalls[-1] | Should -BeLike "$LastCall*"
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}
