# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        "$PSScriptRoot\loopbackadapter.module.psm1", [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ($errors | Out-String) }
    foreach ($name in @('Invoke-LoopbackDeviceCommand', 'Wait-LoopbackAdapterCount', 'New-LoopbackAdapter', 'Remove-LoopbackAdapter')) {
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        Invoke-Expression $function.Extent.Text
    }
    function Write-Log { param($Message, [switch]$Console) }
    function Get-NetAdapter { [CmdletBinding()] param($Name) }
    function Set-NetIPInterface { [CmdletBinding()] param($InterfaceAlias, $InterfaceMetric) }
    function Set-NewNameForLoopbackAdapter { param($Adapter) }
    function Get-L2BridgeName {}
}

Describe 'Bounded loopback enumeration' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log {}
        Mock Start-Sleep {}
        $script:adapter = [pscustomobject]@{ Name = 'Ethernet 2'; InterfaceDescription = 'Microsoft KM-TEST Loopback Adapter'; PnPDeviceID = 'ROOT\NET\0001' }
        Mock Get-NetAdapter { $script:adapter }
    }

    It 'returns an immediately visible adapter without sleeping' {
        (Wait-LoopbackAdapterCount -ExpectedCount 1).Name | Should -Be 'Ethernet 2'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'waits for delayed enumeration instead of reinstalling a device' {
        $script:queries = 0
        Mock Get-NetAdapter {
            $script:queries++
            if ($script:queries -ge 3) { $script:adapter }
        }
        (Wait-LoopbackAdapterCount -ExpectedCount 1).PnPDeviceID | Should -Be 'ROOT\NET\0001'
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'accepts a device appearing on the final allowed query' {
        $script:queries = 0
        Mock Get-NetAdapter {
            $script:queries++
            if ($script:queries -eq 31) { $script:adapter }
        }
        (Wait-LoopbackAdapterCount -ExpectedCount 1).Name | Should -Be 'Ethernet 2'
        Should -Invoke Get-NetAdapter -Times 31 -Exactly
        Should -Invoke Start-Sleep -Times 30 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'fails after exactly 31 queries and 60 seconds of configured sleeps' {
        Mock Get-NetAdapter {}
        { Wait-LoopbackAdapterCount -ExpectedCount 1 } | Should -Throw '*timed out*expected 1, found 0*setupapi.dev.log*'
        Should -Invoke Get-NetAdapter -Times 31 -Exactly
        Should -Invoke Start-Sleep -Times 30 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'fails immediately on duplicate devices rather than selecting one' {
        Mock Get-NetAdapter { $script:adapter; $script:adapter }
        { Wait-LoopbackAdapterCount -ExpectedCount 1 } | Should -Throw '*More than one*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'does not disguise adapter-query errors as missing devices' {
        Mock Get-NetAdapter { throw 'network inventory unavailable' }
        { Wait-LoopbackAdapterCount -ExpectedCount 1 } | Should -Throw '*network inventory unavailable*'
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'waits for an old device to disappear before permitting recreation' {
        $script:queries = 0
        Mock Get-NetAdapter {
            $script:queries++
            if ($script:queries -le 2) { $script:adapter }
        }
        Wait-LoopbackAdapterCount -ExpectedCount 0
        Should -Invoke Get-NetAdapter -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'fails explicitly when old device removal never becomes visible' {
        { Wait-LoopbackAdapterCount -ExpectedCount 0 -MaxAttempts 3 } | Should -Throw '*expected 0, found 1*Ethernet 2*'
        Should -Invoke Get-NetAdapter -Times 3 -Exactly
    }
}

Describe 'Checked loopback device commands' -Tag 'unit', 'ci', 'network' {
    BeforeEach { Mock Write-Log {} }

    It 'captures successful native output in the product log' {
        Invoke-LoopbackDeviceCommand -DevConExe $env:ComSpec -Parameters @('/d', '/c', 'echo device installed')
        Should -Invoke Write-Log -ParameterFilter { $Message -like '*device installed*' }
        Should -Invoke Write-Log -ParameterFilter { $Message -like '*exited with code 0*' }
    }

    It 'includes native stderr and nonzero exit status in the failure' {
        { Invoke-LoopbackDeviceCommand -DevConExe $env:ComSpec -Parameters @('/d', '/c', 'echo device installation failed 1>&2 & exit /b 7') } |
            Should -Throw '*exit code 7*device installation failed*'
    }

    It 'does not treat benign stderr with a zero exit code as an installer failure' {
        $ErrorActionPreference = 'Stop'
        { Invoke-LoopbackDeviceCommand -DevConExe $env:ComSpec -Parameters @('/d', '/c', 'echo device diagnostic 1>&2 & exit /b 0') } |
            Should -Not -Throw
        $ErrorActionPreference | Should -Be 'Stop'
    }

    It 'fails for an unavailable executable instead of reusing a prior exit code' {
        { Invoke-LoopbackDeviceCommand -DevConExe "$TestDrive\missing.exe" -Parameters @('install') } | Should -Throw
    }

    It 'fails on process-launch errors even after a successful native command' {
        Invoke-LoopbackDeviceCommand -DevConExe $env:ComSpec -Parameters @('/d', '/c', 'exit /b 0')
        $invalidExe = Join-Path $TestDrive 'invalid.exe'
        Set-Content -LiteralPath $invalidExe -Value 'not an executable'
        { Invoke-LoopbackDeviceCommand -DevConExe $invalidExe -Parameters @('install') } | Should -Throw
    }
}

Describe 'Loopback creation and cleanup ordering' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        $script:adapter = [pscustomobject]@{ Name = 'Loopbackk2s'; InterfaceDescription = 'Microsoft KM-TEST Loopback Adapter'; PnPDeviceID = 'ROOT\NET\0001' }
        $script:events = [Collections.Generic.List[string]]::new()
        Mock Write-Log {}
        Mock Get-NetAdapter {}
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { $Name -eq 'Loopbackk2s' -and $ErrorAction -eq 'Stop' }
        Mock Get-L2BridgeName { 'Loopbackk2s' }
        Mock Set-NewNameForLoopbackAdapter { $script:events.Add('rename') }
        Mock Set-NetIPInterface {}
        Mock Invoke-LoopbackDeviceCommand { $script:events.Add($Parameters[0]) }
        Mock Wait-LoopbackAdapterCount {
            $script:events.Add("wait-$ExpectedCount")
            if ($ExpectedCount -eq 1) { $script:adapter }
        }
    }

    It 'preserves the existing-adapter fast path' {
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { $Name -eq 'Loopbackk2s' }
        (New-LoopbackAdapter -Name 'Loopbackk2s' -DevConExe 'devgon.exe').Name | Should -Be 'Loopbackk2s'
        Should -Invoke Invoke-LoopbackDeviceCommand -Times 0 -Exactly
        Should -Invoke Wait-LoopbackAdapterCount -Times 0 -Exactly
    }

    It 'installs once then discovers, renames and sets the existing metric' {
        (New-LoopbackAdapter -Name 'Loopbackk2s' -DevConExe 'devgon.exe').Name | Should -Be 'Loopbackk2s'
        ($script:events -join ',') | Should -Be 'install,wait-1,rename'
        Should -Invoke Invoke-LoopbackDeviceCommand -Times 1 -Exactly -ParameterFilter {
            $Parameters[0] -eq 'install' -and $Parameters[2] -eq "$env:SystemRoot\inf\netloop.inf" -and $Parameters[4] -eq '*MSLOOP'
        }
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $InterfaceMetric -eq 254 }
    }

    It 'checks old-device removal before installing the replacement' {
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { -not $Name }
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { $Name -eq 'Loopbackk2s' -and $ErrorAction -eq 'SilentlyContinue' }
        New-LoopbackAdapter -Name 'another-name' -DevConExe 'devgon.exe'
        ($script:events -join ',') | Should -Be 'remove,wait-0,install,wait-1,rename'
    }

    It 'never polls or renames after device installation fails' {
        Mock Invoke-LoopbackDeviceCommand { throw 'installer exit code 1' }
        { New-LoopbackAdapter -Name 'Loopbackk2s' -DevConExe 'devgon.exe' } | Should -Throw '*installer exit code 1*'
        Should -Invoke Wait-LoopbackAdapterCount -Times 0 -Exactly
        Should -Invoke Set-NewNameForLoopbackAdapter -Times 0 -Exactly
    }

    It 'never installs a replacement when removal fails' {
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { -not $Name }
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { $Name -eq 'Loopbackk2s' }
        Mock Invoke-LoopbackDeviceCommand { throw 'removal failed' } -ParameterFilter { $Parameters[0] -eq 'remove' }
        { New-LoopbackAdapter -Name 'another-name' -DevConExe 'devgon.exe' } | Should -Throw '*removal failed*'
        Should -Invoke Invoke-LoopbackDeviceCommand -Times 0 -Exactly -ParameterFilter { $Parameters[0] -eq 'install' }
    }

    It 'does not reinstall on discovery timeout' {
        Mock Wait-LoopbackAdapterCount { throw 'discovery timed out' }
        { New-LoopbackAdapter -Name 'Loopbackk2s' -DevConExe 'devgon.exe' } | Should -Throw '*discovery timed out*'
        Should -Invoke Invoke-LoopbackDeviceCommand -Times 1 -Exactly
        Should -Invoke Set-NewNameForLoopbackAdapter -Times 0 -Exactly
    }

    It 'does not install while an old device remains visible' {
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { -not $Name }
        Mock Get-NetAdapter { $script:adapter } -ParameterFilter { $Name -eq 'Loopbackk2s' }
        Mock Wait-LoopbackAdapterCount { throw 'old device still visible' } -ParameterFilter { $ExpectedCount -eq 0 }
        { New-LoopbackAdapter -Name 'another-name' -DevConExe 'devgon.exe' } | Should -Throw '*old device still visible*'
        Should -Invoke Invoke-LoopbackDeviceCommand -Times 0 -Exactly -ParameterFilter { $Parameters[0] -eq 'install' }
    }

    It 'does not remove a non-loopback adapter' {
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Physical adapter' } }
        { Remove-LoopbackAdapter -Name 'Ethernet' -DevConExe 'devgon.exe' } | Should -Throw '*not a Microsoft KM-TEST*'
        Should -Invoke Invoke-LoopbackDeviceCommand -Times 0 -Exactly
    }
}
