# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot/httpproxy.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    foreach ($functionName in @(
            'Get-HttpProxyAllowedCIDRs',
            'Set-ProxyConfigInHttpProxy',
            'Install-WinHttpProxy',
            'Protect-HttpProxySensitiveText',
            'Get-HttpProxyNssmCommand',
            'Get-HttpProxyReadinessEndpoint',
            'Test-HttpProxyTcpReadiness',
            'Get-HttpProxyListenerOwnership',
            'Wait-HttpProxyReadiness',
            'Invoke-HttpProxyRecoveryStop',
            'Get-WindowsExcludedTcpPortRanges',
            'Get-HttpProxyFailureDiagnostics',
            'Start-WinHttpProxy'
        )) {
        $functionAst = $moduleAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $false)
        if ($null -eq $functionAst) {
            throw "Function '$functionName' was not found in $modulePath"
        }
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    $httpProxyPort = '8181'
    $proxyInboundFirewallRule = "HTTP Proxy Inbound Allow Port $httpProxyPort"

    # The module calls nssm by path; a script with the same name records the calls instead.
    $kubeBinPath = $TestDrive
    Set-Content -Path (Join-Path $TestDrive 'nssm.ps1') -Value '$global:nssmCalls.Add(($args -join " ")) | Out-Null'

    function Write-Log {
        param(
            [string[]]$Messages,
            [switch]$Console,
            [switch]$Progress,
            [switch]$Error
        )
    }
    function Write-ErrorMessage { param($Message) }
    function Get-ConfiguredClusterCIDR { }
    function Get-ConfiguredClusterCIDRServices { }
    function Get-ConfiguredControlPlaneCIDR { }
    function Get-LoopbackAdapterCIDR { }
    function Get-ConfiguredKubeSwitchIP { }
    function Get-K2sHosts { }
    function Get-ConfiguredLogDirectory { }
    function Remove-ServiceIfExists { param($Name) }
    function Start-ServiceAndSetToAutoStart { param($Name, [switch]$IgnoreErrors) }
    function Confirm-LoopbackAdapterIP { }
    function Get-Service { [CmdletBinding()] param($Name) }
    function Start-Service { [CmdletBinding()] param($Name) }
    function Set-Service { [CmdletBinding()] param($Name, $StartupType) }
    function Stop-Process { [CmdletBinding()] param($Id, [switch]$Force) }
    function Wait-Process { [CmdletBinding()] param($Id, $Timeout) }
    function Start-Process { [CmdletBinding()] param($FilePath, $ArgumentList, [switch]$NoNewWindow, [switch]$PassThru) }
    function Get-NetIPAddress { [CmdletBinding()] param($IPAddress, $AddressFamily) }
    function Get-NetTCPConnection { [CmdletBinding()] param($LocalPort, $State) }
    function Get-CimInstance { [CmdletBinding()] param($ClassName, $Filter) }
    function Invoke-CimMethod { [CmdletBinding()] param($InputObject, $MethodName) }
    function netsh { }
    function sc.exe { }
    function New-NetFirewallRule {
        [CmdletBinding()]
        param($DisplayName, $Group, $Direction, $LocalPort, $Protocol, $RemoteAddress, $Action)
    }
}

Describe 'Get-HttpProxyAllowedCIDRs' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        Mock Get-ConfiguredClusterCIDR { '172.20.0.0/16' }
        Mock Get-ConfiguredClusterCIDRServices { '172.21.0.0/16' }
        Mock Get-ConfiguredControlPlaneCIDR { '172.19.1.0/24' }
        Mock Get-LoopbackAdapterCIDR { '172.22.1.0/24' }
    }

    It 'returns the cluster, service, control plane and loopback adapter networks' {
        $result = @(Get-HttpProxyAllowedCIDRs)

        $result | Should -Be @('172.20.0.0/16', '172.21.0.0/16', '172.19.1.0/24', '172.22.1.0/24')
    }

    It 'skips networks that are not configured' {
        Mock Get-LoopbackAdapterCIDR { '' }

        $result = @(Get-HttpProxyAllowedCIDRs)

        $result | Should -Be @('172.20.0.0/16', '172.21.0.0/16', '172.19.1.0/24')
    }

    It 'fails instead of returning an empty whitelist' {
        Mock Get-ConfiguredClusterCIDR { $null }
        Mock Get-ConfiguredClusterCIDRServices { '' }
        Mock Get-ConfiguredControlPlaneCIDR { ' ' }
        Mock Get-LoopbackAdapterCIDR { $null }

        { Get-HttpProxyAllowedCIDRs } | Should -Throw '*No cluster network CIDR configured*'
    }
}

Describe 'Set-ProxyConfigInHttpProxy' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        $global:nssmCalls = [System.Collections.Generic.List[string]]::new()
        Mock Get-HttpProxyAllowedCIDRs { '172.20.0.0/16', '172.19.1.0/24' }
        Mock Get-K2sHosts { }
    }

    AfterAll {
        Remove-Variable -Name nssmCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'passes every allowed network to httpproxy' {
        Set-ProxyConfigInHttpProxy

        $global:nssmCalls | Should -Contain 'set httpproxy AppParameters --allowed-cidr 172.20.0.0/16 --allowed-cidr 172.19.1.0/24'
    }

    It 'appends the forward proxy after the allowed networks' {
        Set-ProxyConfigInHttpProxy -Proxy 'http://proxy.example:3128'

        $global:nssmCalls | Should -Contain 'set httpproxy AppParameters --allowed-cidr 172.20.0.0/16 --allowed-cidr 172.19.1.0/24 --forwardproxy http://proxy.example:3128'
    }

    It 'does not log plaintext credentials from the forward proxy URL' {
        Mock Write-Log {}

        Set-ProxyConfigInHttpProxy -Proxy 'http://alice:SuperSecret99@proxy.example:3128'

        $global:nssmCalls | Should -Contain 'set httpproxy AppParameters --allowed-cidr 172.20.0.0/16 --allowed-cidr 172.19.1.0/24 --forwardproxy http://alice:SuperSecret99@proxy.example:3128'
        Should -Invoke Write-Log -Times 1 -Exactly -ParameterFilter {
            ($Messages -join ' ') -match 'http://\[REDACTED\]@proxy\.example:3128'
        }
        Should -Invoke Write-Log -Times 0 -Exactly -ParameterFilter {
            ($Messages -join ' ') -match 'SuperSecret99|alice'
        }
    }
}

Describe 'Install-WinHttpProxy' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        $global:nssmCalls = [System.Collections.Generic.List[string]]::new()
        Mock Get-HttpProxyAllowedCIDRs { '172.20.0.0/16', '172.19.1.0/24' }
        Mock Get-K2sHosts { }
        Mock Get-ConfiguredLogDirectory { Join-Path $TestDrive 'log' }
        Mock mkdir { }
        Mock Remove-ServiceIfExists { }
        Mock Get-Service { [pscustomobject]@{ Name = 'httpproxy' } }
        Mock Start-Service { }
        Mock New-NetFirewallRule { }
    }

    AfterAll {
        Remove-Variable -Name nssmCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'allows inbound proxy connections only from the allowed networks' {
        Install-WinHttpProxy

        Should -Invoke New-NetFirewallRule -Exactly 1 -ParameterFilter {
            $DisplayName -eq 'HTTP Proxy Inbound Allow Port 8181' -and
            $Direction -eq 'Inbound' -and
            $LocalPort -eq '8181' -and
            $Action -eq 'Allow' -and
            (@($RemoteAddress) -join ',') -eq '172.20.0.0/16,172.19.1.0/24'
        }
    }
}

Describe 'Protect-HttpProxySensitiveText' -Tag 'unit', 'ci', 'httpproxy' {
    It 'redacts userinfo credentials in http proxy URLs' {
        $result = Protect-HttpProxySensitiveText -Text 'forwardproxy=http://user:pass@proxy:8080'

        $result | Should -Be 'forwardproxy=http://[REDACTED]@proxy:8080'
        $result | Should -Not -Match 'user|pass'
    }

    It 'redacts credentials containing @ in the password' {
        $result = Protect-HttpProxySensitiveText -Text 'https://svc:p@ss!@proxy:3128/path'

        $result | Should -Be 'https://[REDACTED]@proxy:3128/path'
        $result | Should -Not -Match 'svc|p@ss!'
    }

    It 'redacts credential key/value pairs and authorization headers' {
        $inputText = "proxy_password=TopSecret1`nProxy-Authorization: Basic dXNlcjpwYXNz"
        $result = Protect-HttpProxySensitiveText -Text $inputText

        $result | Should -Match 'proxy_password=\[REDACTED\]'
        $result | Should -Match 'Proxy-Authorization:\s*\[REDACTED\]'
        $result | Should -Not -Match 'TopSecret1|dXNlcjpwYXNz'
    }

    It 'redacts schemeless userinfo credentials and JSON-quoted secret keys' {
        $schemeless = Protect-HttpProxySensitiveText -Text '--forwardproxy user:pass@proxy:8080'
        $schemeless | Should -Be '--forwardproxy [REDACTED]@proxy:8080'
        $schemeless | Should -Not -Match 'user|pass'

        $jsonText = Protect-HttpProxySensitiveText -Text '{"password": "secret", "proxy_token": "tok123"}'
        $jsonText | Should -Be '{"password": [REDACTED], "proxy_token": [REDACTED]}'
        $jsonText | Should -Not -Match 'secret|tok123'
    }

    It 'preserves credential-free URLs unchanged' {
        $result = Protect-HttpProxySensitiveText -Text 'http://proxy.example:3128'

        $result | Should -Be 'http://proxy.example:3128'
    }

    It 'returns empty string for null or empty inputs' {
        Protect-HttpProxySensitiveText -Text '' | Should -Be ''
        Protect-HttpProxySensitiveText -Text $null | Should -Be ''
        Protect-HttpProxySensitiveText | Should -Be ''
    }
}

Describe 'Get-HttpProxyReadinessEndpoint' -Tag 'unit', 'ci', 'httpproxy' {
    It 'returns the configured KubeSwitch IP on port 8181 when bound locally' {
        Mock Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '172.19.1.1' } }

        $result = Get-HttpProxyReadinessEndpoint -Port 8181

        $result.Host | Should -Be '172.19.1.1'
        $result.Port | Should -Be 8181
        $result.ConfiguredHost | Should -Be '172.19.1.1'
        $result.IsFallback | Should -BeFalse
        $result.Endpoint | Should -Be '172.19.1.1:8181'
    }

    It 'falls back to 127.0.0.1:8181 when the switch IP is not bound locally' {
        Mock Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
        Mock Get-NetIPAddress { @() }

        $result = Get-HttpProxyReadinessEndpoint -Port 8181

        $result.Host | Should -Be '127.0.0.1'
        $result.Port | Should -Be 8181
        $result.ConfiguredHost | Should -Be '172.19.1.1'
        $result.IsFallback | Should -BeTrue
        $result.Endpoint | Should -Be '127.0.0.1:8181'
    }

    It 'falls back to 127.0.0.1:8181 when Get-ConfiguredKubeSwitchIP is empty or throws' {
        Mock Get-ConfiguredKubeSwitchIP { '' }
        Mock Get-NetIPAddress { }

        $emptyResult = Get-HttpProxyReadinessEndpoint -Port 8181
        $emptyResult.Endpoint | Should -Be '127.0.0.1:8181'
        $emptyResult.IsFallback | Should -BeTrue

        Mock Get-ConfiguredKubeSwitchIP { throw 'config unavailable' }
        $throwResult = Get-HttpProxyReadinessEndpoint -Port 8181
        $throwResult.Endpoint | Should -Be '127.0.0.1:8181'
        $throwResult.IsFallback | Should -BeTrue
    }
}

Describe 'Test-HttpProxyTcpReadiness' -Tag 'unit', 'ci', 'httpproxy' {
    It 'returns Success = true against a real ephemeral TcpListener on 127.0.0.1:0' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            $result = Test-HttpProxyTcpReadiness -TargetHost '127.0.0.1' -Port $port -ConnectTimeoutMs 1500

            $result.Success | Should -BeTrue
            $result.Endpoint | Should -Be "127.0.0.1:$port"
            $result.Error | Should -BeNullOrEmpty
        }
        finally {
            $listener.Stop()
        }
    }

    It 'returns Success = false within timeout for a closed local port' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $closedPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Test-HttpProxyTcpReadiness -TargetHost '127.0.0.1' -Port $closedPort -ConnectTimeoutMs 500
        $stopwatch.Stop()

        $result.Success | Should -BeFalse
        $result.Endpoint | Should -Be "127.0.0.1:$closedPort"
        $result.Error | Should -Not -BeNullOrEmpty
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 5
    }
}

Describe 'Get-HttpProxyListenerOwnership' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        $script:expectedExePath = Join-Path $TestDrive 'httpproxy.exe'
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_Service') {
                return [pscustomobject]@{ Name = 'httpproxy'; State = 'Running'; ProcessId = 4000 }
            }
            if ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=4001') {
                return [pscustomobject]@{
                    ProcessId       = 4001
                    Name            = 'httpproxy.exe'
                    ParentProcessId = 4000
                    ExecutablePath  = $script:expectedExePath
                }
            }
            return $null
        }
        Mock Get-NetTCPConnection {
            [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 8181; OwningProcess = 4001 }
        }
    }

    It 'accepts httpproxy.exe child of NSSM Win32_Service.ProcessId with matching path' {
        $result = Get-HttpProxyListenerOwnership -Port 8181 -ExpectedExePath $script:expectedExePath

        $result.IsOwned | Should -BeTrue
        $result.ServiceState | Should -Be 'Running'
        $result.ServicePid | Should -Be 4000
        $result.MatchedPid | Should -Be 4001
        $result.MatchedProcessName | Should -Be 'httpproxy.exe'
        $result.MatchedExecutablePath | Should -Be $script:expectedExePath
    }

    It 'accepts dual-stack IPv4 and IPv6 listeners owned by the same verified httpproxy.exe' {
        Mock Get-NetTCPConnection {
            [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 8181; OwningProcess = 4001 }
            [pscustomobject]@{ LocalAddress = '::'; LocalPort = 8181; OwningProcess = 4001 }
        }

        $result = Get-HttpProxyListenerOwnership -Port 8181 -ExpectedExePath $script:expectedExePath

        $result.IsOwned | Should -BeTrue
        $result.Listeners.Count | Should -Be 2
    }

    It 'rejects an unrelated process owning port 8181' {
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_Service') {
                return [pscustomobject]@{ Name = 'httpproxy'; State = 'Running'; ProcessId = 4000 }
            }
            if ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=9876') {
                return [pscustomobject]@{
                    ProcessId       = 9876
                    Name            = 'otherapp.exe'
                    ParentProcessId = 1200
                    ExecutablePath  = 'C:\Apps\otherapp.exe'
                }
            }
            return $null
        }
        Mock Get-NetTCPConnection {
            [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 8181; OwningProcess = 9876 }
        }

        $result = Get-HttpProxyListenerOwnership -Port 8181 -ExpectedExePath $script:expectedExePath

        $result.IsOwned | Should -BeFalse
        $result.Reason | Should -Match 'otherapp\.exe'
        $result.Reason | Should -Match '9876'
        $result.Listeners[0].IsExpectedOwner | Should -BeFalse
    }

    It 'rejects an orphaned httpproxy.exe whose ParentProcessId does not match NSSM service PID' {
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_Service') {
                return [pscustomobject]@{ Name = 'httpproxy'; State = 'Running'; ProcessId = 4000 }
            }
            if ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=4001') {
                return [pscustomobject]@{
                    ProcessId       = 4001
                    Name            = 'httpproxy.exe'
                    ParentProcessId = 9999
                    ExecutablePath  = $script:expectedExePath
                }
            }
            return $null
        }

        $result = Get-HttpProxyListenerOwnership -Port 8181 -ExpectedExePath $script:expectedExePath

        $result.IsOwned | Should -BeFalse
        $result.Reason | Should -Match 'ParentPID=9999'
    }

    It 'rejects httpproxy.exe when its ExecutablePath does not match expected binary' {
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_Service') {
                return [pscustomobject]@{ Name = 'httpproxy'; State = 'Running'; ProcessId = 4000 }
            }
            if ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=4001') {
                return [pscustomobject]@{
                    ProcessId       = 4001
                    Name            = 'httpproxy.exe'
                    ParentProcessId = 4000
                    ExecutablePath  = 'C:\rogue\httpproxy.exe'
                }
            }
            return $null
        }

        $result = Get-HttpProxyListenerOwnership -Port 8181 -ExpectedExePath $script:expectedExePath

        $result.IsOwned | Should -BeFalse
        $result.Reason | Should -Match 'rogue'
    }

    It 'fails closed when ExecutablePath is empty or null and ExpectedExePath is specified' {
        $script:blankExePath = $null
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_Service') {
                return [pscustomobject]@{ Name = 'httpproxy'; State = 'Running'; ProcessId = 4000 }
            }
            if ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=4001') {
                return [pscustomobject]@{
                    ProcessId       = 4001
                    Name            = 'httpproxy.exe'
                    ParentProcessId = 4000
                    ExecutablePath  = $script:blankExePath
                }
            }
            return $null
        }

        foreach ($candidate in @($null, '', '   ')) {
            $script:blankExePath = $candidate
            $result = Get-HttpProxyListenerOwnership -Port 8181 -ExpectedExePath $script:expectedExePath

            $result.IsOwned | Should -BeFalse
            $result.Listeners[0].IsExpectedOwner | Should -BeFalse
        }
    }

    It 'rejects when Win32_Service is not Running' {
        Mock Get-CimInstance {
            param($ClassName)
            if ($ClassName -eq 'Win32_Service') {
                return [pscustomobject]@{ Name = 'httpproxy'; State = 'Stopped'; ProcessId = 0 }
            }
            return $null
        }
        Mock Get-NetTCPConnection { @() }

        $result = Get-HttpProxyListenerOwnership -Port 8181 -ExpectedExePath $script:expectedExePath

        $result.IsOwned | Should -BeFalse
        $result.Reason | Should -Match 'not running'
    }

    It 'rejects when no Listen socket exists on port 8181' {
        Mock Get-NetTCPConnection {
            throw 'No matching MSFT_NetTCPConnection resources found'
        }

        $result = Get-HttpProxyListenerOwnership -Port 8181 -ExpectedExePath $script:expectedExePath

        $result.IsOwned | Should -BeFalse
        $result.Reason | Should -Match 'No TCP listener found on port 8181'
    }
}

Describe 'Start-WinHttpProxy' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        $global:nssmCalls = [System.Collections.Generic.List[string]]::new()
        $script:fakeNow = [datetime]::new(2026, 11, 27, 10, 0, 0, [DateTimeKind]::Utc)
        $script:expectedExePath = Join-Path $TestDrive 'httpproxy.exe'
        $script:svcStatus = 'Stopped'
        $script:svcStartType = 'Automatic'
        $script:servicePid = 4000
        $script:childPid = 4001
        $script:childProcessName = 'httpproxy.exe'
        $script:childParentPid = 4000
        $script:childExePath = $script:expectedExePath
        $script:tcpResults = $null
        $script:tcpCallCount = 0
        $script:logRoot = Join-Path $TestDrive 'logs-missing'

        Mock Get-Date { $script:fakeNow }
        Mock Start-Sleep {
            param($Seconds, $Milliseconds)
            if ($Seconds -gt 0) {
                $script:fakeNow = $script:fakeNow.AddSeconds($Seconds)
            }
            if ($Milliseconds -gt 0) {
                $script:fakeNow = $script:fakeNow.AddMilliseconds($Milliseconds)
            }
        }
        Mock Write-Log { }
        Mock Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
        Mock Get-NetIPAddress { [pscustomobject]@{ IPAddress = '172.19.1.1' } }
        Mock Confirm-LoopbackAdapterIP { }
        Mock Start-Service { }
        Mock Invoke-CimMethod { $script:svcStatus = 'Stopped' }
        Mock Set-Service { }
        Mock Stop-Process { }
        Mock Wait-Process { }
        Mock Start-Process { }
        Mock sc.exe { }
        Mock netsh { @() }
        Mock Get-ConfiguredLogDirectory { $script:logRoot }

        Mock Get-Service {
            [pscustomobject]@{
                Name      = $Name
                Status    = $script:svcStatus
                StartType = $script:svcStartType
            }
        }
        Mock Start-ServiceAndSetToAutoStart {
            $script:svcStatus = 'Running'
            $script:svcStartType = 'Automatic'
        }
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_Service') {
                $cimState = if ($script:svcStatus -eq 'Running') { 'Running' } else { 'Stopped' }
                $cimPid = if ($script:svcStatus -eq 'Running') { $script:servicePid } else { 0 }
                return [pscustomobject]@{
                    Name      = 'httpproxy'
                    State     = $cimState
                    ProcessId = $cimPid
                    PathName  = "`"$TestDrive\nssm.exe`""
                }
            }
            if ($ClassName -eq 'Win32_Process') {
                if ($Filter -eq "ProcessId=$($script:childPid)" -or ($Filter -eq "ParentProcessId=$($script:servicePid)" -and $script:childParentPid -eq $script:servicePid)) {
                    if ($script:svcStatus -eq 'Running' -or $script:childParentPid -ne $script:servicePid) {
                        return [pscustomobject]@{
                            ProcessId       = $script:childPid
                            Name            = $script:childProcessName
                            ParentProcessId = $script:childParentPid
                            ExecutablePath  = $script:childExePath
                        }
                    }
                }
                return $null
            }
            return $null
        }
        Mock Get-NetTCPConnection {
            if ($script:svcStatus -eq 'Running' -or $script:childParentPid -ne $script:servicePid) {
                return [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 8181; OwningProcess = $script:childPid }
            }
            return @()
        }
        Mock Test-HttpProxyTcpReadiness {
            $script:tcpCallCount++
            $ok = $true
            if ($null -ne $script:tcpResults) {
                $idx = [Math]::Min($script:tcpCallCount - 1, $script:tcpResults.Count - 1)
                $ok = [bool]$script:tcpResults[$idx]
            }
            if ($ok) {
                return [pscustomobject]@{ Success = $true; Endpoint = "${TargetHost}:${Port}"; Error = $null }
            }
            return [pscustomobject]@{ Success = $false; Endpoint = "${TargetHost}:${Port}"; Error = "TCP connect to ${TargetHost}:${Port} refused" }
        }
    }

    AfterAll {
        Remove-Variable -Name nssmCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'starts a stopped service, verifies 2 consecutive passing checks, and starts flanneld' {
        Start-WinHttpProxy

        Should -Invoke Start-ServiceAndSetToAutoStart -Times 1 -Exactly -ParameterFilter { $Name -eq 'httpproxy' }
        Should -Invoke Test-HttpProxyTcpReadiness -Times 2 -Exactly
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        $global:nssmCalls | Should -Not -Contain 'stop httpproxy'
        $global:nssmCalls | Should -Contain 'set httpproxy AppStopMethodConsole 30000'
        $global:nssmCalls | Should -Contain 'set httpproxy AppStopMethodWindow 0'
        $global:nssmCalls | Should -Contain 'set httpproxy AppStopMethodThreads 0'
        Should -Invoke Confirm-LoopbackAdapterIP -Times 1 -Exactly
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'flanneld' }
    }

    It 'waits for delayed readiness without restarting the service' {
        $script:tcpResults = @($false, $false, $false, $true, $true)

        Start-WinHttpProxy -ReadinessTimeoutSeconds 20 -PollIntervalSeconds 1 -RequiredConsecutiveSuccesses 2

        Should -Invoke Start-ServiceAndSetToAutoStart -Times 1 -Exactly
        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        $global:nssmCalls | Should -Not -Contain 'stop httpproxy'
        Should -Invoke Test-HttpProxyTcpReadiness -Times 5 -Exactly
        Should -Invoke Start-Sleep -Times 4 -Exactly -ParameterFilter { $Seconds -eq 1 }
        Should -Invoke Confirm-LoopbackAdapterIP -Times 1 -Exactly
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'flanneld' }
    }

    It 'recovers from a transient failure on attempt 1 via clean stop and restart on attempt 2' {
        $script:attempt = 0
        Mock Start-ServiceAndSetToAutoStart {
            $script:attempt++
            $script:svcStatus = 'Running'
            $script:svcStartType = 'Automatic'
        }
        Mock Test-HttpProxyTcpReadiness {
            $script:tcpCallCount++
            if ($script:attempt -eq 1) {
                return [pscustomobject]@{ Success = $false; Endpoint = "${TargetHost}:${Port}"; Error = 'connection refused' }
            }
            return [pscustomobject]@{ Success = $true; Endpoint = "${TargetHost}:${Port}"; Error = $null }
        }

        Start-WinHttpProxy -MaxAttempts 3 -ReadinessTimeoutSeconds 2 -PollIntervalSeconds 1 -RequiredConsecutiveSuccesses 2

        $global:nssmCalls | Should -Contain 'stop httpproxy'
        Should -Invoke Start-ServiceAndSetToAutoStart -Times 2 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 1 -Exactly
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'flanneld' }
    }

    It 'throws with full details on persistent failure and never calls Confirm-LoopbackAdapterIP or flanneld' {
        $script:tcpResults = @($false)

        $thrown = $null
        try {
            Start-WinHttpProxy -MaxAttempts 3 -ReadinessTimeoutSeconds 2 -PollIntervalSeconds 1
        }
        catch {
            $thrown = $_
        }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match '172\.19\.1\.1:8181'
        $thrown.Exception.Message | Should -Match '3 attempt\(s\)'
        $thrown.Exception.Message | Should -Match 'ElapsedSeconds:'
        $thrown.Exception.Message | Should -Match 'LastFailure:'
        $thrown.Exception.Message | Should -Match 'httpproxy readiness diagnostics:'
        Should -Invoke Start-ServiceAndSetToAutoStart -Times 3 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'enforces both per-attempt timeout and overall duration budget' {
        $script:svcStatus = 'Running'
        $script:tcpResults = @($false)

        $perAttempt = Wait-HttpProxyReadiness -TargetHost '172.19.1.1' -Port 8181 -TimeoutSeconds 3 -PollIntervalSeconds 1 -RequiredConsecutiveSuccesses 2
        $perAttempt.Ready | Should -BeFalse
        $perAttempt.ChecksPerformed | Should -Be 3
        $perAttempt.ElapsedSeconds | Should -Be 3

        $script:svcStatus = 'Stopped'
        $script:fakeNow = [datetime]::new(2026, 11, 27, 10, 0, 0, [DateTimeKind]::Utc)
        $thrown = $null
        try {
            Start-WinHttpProxy -MaxAttempts 3 -ReadinessTimeoutSeconds 5 -PollIntervalSeconds 1 -MaxOverallDurationSeconds 7
        }
        catch {
            $thrown = $_
        }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match 'Overall readiness budget of 7s exhausted'
        Should -Invoke Start-ServiceAndSetToAutoStart -Times 2 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'rejects an unrelated listener owning port 8181 without killing it or starting flanneld' {
        $script:childPid = 9876
        $script:childProcessName = 'otherapp.exe'
        $script:childParentPid = 1111
        $script:childExePath = 'C:\Apps\otherapp.exe'

        $thrown = $null
        try {
            Start-WinHttpProxy -MaxAttempts 2 -ReadinessTimeoutSeconds 1 -PollIntervalSeconds 1
        }
        catch {
            $thrown = $_
        }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match 'otherapp\.exe'
        $thrown.Exception.Message | Should -Match '9876'
        Should -Invoke Stop-Process -Times 0 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'resets consecutive success counter when a briefly available listener crashes' {
        $script:svcStatus = 'Running'
        $script:tcpResults = @($true, $false, $true)
        $waitResult = Wait-HttpProxyReadiness -TargetHost '172.19.1.1' -Port 8181 -TimeoutSeconds 3 -PollIntervalSeconds 1 -RequiredConsecutiveSuccesses 2

        $waitResult.Ready | Should -BeFalse
        $waitResult.ConsecutiveSuccesses | Should -Be 1
        $waitResult.ChecksPerformed | Should -Be 3

        $script:svcStatus = 'Stopped'
        $script:fakeNow = [datetime]::new(2026, 11, 27, 10, 0, 0, [DateTimeKind]::Utc)
        $script:tcpCallCount = 0
        $script:tcpResults = @($true, $false, $true, $true)

        Start-WinHttpProxy -MaxAttempts 1 -ReadinessTimeoutSeconds 10 -PollIntervalSeconds 1 -RequiredConsecutiveSuccesses 2

        Should -Invoke Test-HttpProxyTcpReadiness -Times 7 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 1 -Exactly
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'flanneld' }
    }

    It 'accepts an already-running healthy proxy without stopping or restarting it' {
        $script:svcStatus = 'Running'
        $script:svcStartType = 'Manual'

        Start-WinHttpProxy

        Should -Invoke Invoke-CimMethod -Times 0 -Exactly
        Should -Invoke Start-ServiceAndSetToAutoStart -Times 0 -Exactly
        $global:nssmCalls | Should -Not -Contain 'stop httpproxy'
        $global:nssmCalls | Should -Contain 'set httpproxy Start SERVICE_AUTO_START'
        Should -Invoke Test-HttpProxyTcpReadiness -Times 2 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 1 -Exactly
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'flanneld' }
    }

    It 'recovers an already-running unhealthy proxy via bounded stop and restart' {
        $script:svcStatus = 'Running'
        $script:recovered = $false
        Mock Start-ServiceAndSetToAutoStart {
            $script:recovered = $true
            $script:svcStatus = 'Running'
        }
        Mock Test-HttpProxyTcpReadiness {
            if (-not $script:recovered) {
                return [pscustomobject]@{ Success = $false; Endpoint = "${TargetHost}:${Port}"; Error = 'socket hung' }
            }
            return [pscustomobject]@{ Success = $true; Endpoint = "${TargetHost}:${Port}"; Error = $null }
        }

        Start-WinHttpProxy -MaxAttempts 2 -ReadinessTimeoutSeconds 2 -PollIntervalSeconds 1 -RequiredConsecutiveSuccesses 2

        $global:nssmCalls | Should -Contain 'stop httpproxy'
        Should -Invoke Start-ServiceAndSetToAutoStart -Times 1 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 1 -Exactly
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'flanneld' }
    }

    It 'skips Confirm-LoopbackAdapterIP and flanneld when -OnlyProxy is set on success and failure' {
        Start-WinHttpProxy -OnlyProxy

        Should -Invoke Test-HttpProxyTcpReadiness -Times 2 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly

        $script:fakeNow = [datetime]::new(2026, 11, 27, 10, 0, 0, [DateTimeKind]::Utc)
        $script:tcpResults = @($false)
        { Start-WinHttpProxy -OnlyProxy -MaxAttempts 1 -ReadinessTimeoutSeconds 1 -PollIntervalSeconds 1 } | Should -Throw '*httpproxy failed readiness verification*'
        Should -Invoke Confirm-LoopbackAdapterIP -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
    }

    It 'collects diagnostics with log excerpts, excluded port ranges, and redacted credentials on failure' {
        $script:logRoot = Join-Path $TestDrive 'logs-present'
        $httpProxyLogDir = Join-Path $script:logRoot 'httpproxy'
        New-Item -ItemType Directory -Path $httpProxyLogDir -Force | Out-Null
        Set-Content -Path (Join-Path $httpProxyLogDir 'httpproxy_stderr.log') -Value @(
            'starting httpproxy with forwardproxy http://alice:SecretPass123@proxy.internal:8080'
            'Proxy-Authorization: Basic dXNlcjpzZWNyZXQ='
        )
        Set-Content -Path (Join-Path $httpProxyLogDir 'httpproxy_stdout.log') -Value 'proxy_password=MySuperSecret listen failed on :8181'

        Mock netsh {
            @(
                'Start Port    End Port'
                '----------    --------'
                '      8100        8200'
            )
        }
        $script:tcpResults = @($false)

        $thrown = $null
        try {
            Start-WinHttpProxy -MaxAttempts 1 -ReadinessTimeoutSeconds 1 -PollIntervalSeconds 1
        }
        catch {
            $thrown = $_
        }

        $thrown | Should -Not -BeNullOrEmpty
        $msg = $thrown.Exception.Message
        $msg | Should -Match 'Port8181InWindowsExcludedRange: YES \(ipv4: 8100-8200'
        $msg | Should -Match 'http://\[REDACTED\]@proxy\.internal:8080'
        $msg | Should -Match 'Proxy-Authorization:\s*\[REDACTED\]'
        $msg | Should -Match 'proxy_password=\[REDACTED\]'
        $msg | Should -Not -Match 'SecretPass123|dXNlcjpzZWNyZXQ=|MySuperSecret'

        Should -Invoke Write-Log -ParameterFilter {
            ($Messages -join ' ') -match 'httpproxy readiness diagnostics:' -and
            ($Messages -join ' ') -notmatch 'SecretPass123|dXNlcjpzZWNyZXQ=|MySuperSecret'
        }
    }

    It 'does not mask readiness failure when httpproxy log files are missing' {
        $script:logRoot = Join-Path $TestDrive 'nonexistent-log-dir'
        $script:tcpResults = @($false)

        $thrown = $null
        try {
            Start-WinHttpProxy -MaxAttempts 1 -ReadinessTimeoutSeconds 1 -PollIntervalSeconds 1
        }
        catch {
            $thrown = $_
        }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match 'httpproxy failed readiness verification'
        $thrown.Exception.Message | Should -Match '\(file not found\)'
    }

    It 'skips starting service cleanly when Invoke-HttpProxyRecoveryStop returns Stopped = false' {
        $script:svcStatus = 'Running'
        $script:tcpResults = @($false)
        Mock Invoke-CimMethod { }

        $thrown = $null
        try {
            Start-WinHttpProxy -MaxAttempts 2 -ReadinessTimeoutSeconds 1 -ServiceControlTimeoutSeconds 1 -PollIntervalSeconds 1 -MaxOverallDurationSeconds 10
        }
        catch {
            $thrown = $_
        }

        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match "Failed to stop 'httpproxy' service cleanly before attempt 2"
        Should -Invoke Start-ServiceAndSetToAutoStart -Times 0 -Exactly
        Should -Invoke Confirm-LoopbackAdapterIP -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
        Should -Invoke Write-Log -ParameterFilter {
            ($Messages -join ' ') -match "Failed to stop 'httpproxy' service cleanly before attempt 1"
        }
    }

    It 'does not throw when nssm writes to stderr under ErrorActionPreference Stop' {
        $nssmPath = Join-Path $TestDrive 'nssm.ps1'
        $origNssmContent = Get-Content -Path $nssmPath -Raw
        $prevPref = $ErrorActionPreference
        try {
            Set-Content -Path $nssmPath -Value @'
$global:nssmCalls.Add(($args -join " ")) | Out-Null
Write-Error "simulated nssm stderr output"
'@
            $ErrorActionPreference = 'Stop'
            $script:svcStatus = 'Running'
            $script:svcStartType = 'Manual'

            { Start-WinHttpProxy } | Should -Not -Throw

            $ErrorActionPreference | Should -Be 'Stop'
            $global:nssmCalls | Should -Contain 'set httpproxy AppStopMethodConsole 30000'
            $global:nssmCalls | Should -Contain 'set httpproxy Start SERVICE_AUTO_START'
        }
        finally {
            $ErrorActionPreference = $prevPref
            Set-Content -Path $nssmPath -Value $origNssmContent
        }
    }
}

Describe 'Invoke-HttpProxyRecoveryStop' -Tag 'unit', 'ci', 'httpproxy' {
    BeforeEach {
        $global:nssmCalls = [System.Collections.Generic.List[string]]::new()
        $script:fakeNow = [datetime]::new(2026, 11, 27, 10, 0, 0, [DateTimeKind]::Utc)
        Mock Get-Date { $script:fakeNow }
        Mock Start-Sleep {
            param($Seconds, $Milliseconds)
            if ($Seconds -gt 0) {
                $script:fakeNow = $script:fakeNow.AddSeconds($Seconds)
            }
            if ($Milliseconds -gt 0) {
                $script:fakeNow = $script:fakeNow.AddMilliseconds($Milliseconds)
            }
        }
        Mock Write-Log { }
        Mock Invoke-CimMethod { }
        Mock Stop-Process { }
        Mock Wait-Process { }
        Mock Start-Process { }
        Mock sc.exe { }
    }

    AfterAll {
        Remove-Variable -Name nssmCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'terminates only lingering httpproxy.exe children of the prior NSSM service PID' {
        Mock Get-Service { [pscustomobject]@{ Name = 'httpproxy'; Status = 'Running' } }
        Mock Get-CimInstance {
            param($ClassName, $Filter)
            if ($ClassName -eq 'Win32_Service') {
                return [pscustomobject]@{ Name = 'httpproxy'; State = 'Running'; ProcessId = 4000 }
            }
            if ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ParentProcessId=4000') {
                return @(
                    [pscustomobject]@{ ProcessId = 4001; Name = 'httpproxy.exe'; ParentProcessId = 4000 }
                    [pscustomobject]@{ ProcessId = 4002; Name = 'other.exe'; ParentProcessId = 4000 }
                )
            }
            if ($ClassName -eq 'Win32_Process' -and $Filter -eq 'ProcessId=4001') {
                return [pscustomobject]@{ ProcessId = 4001; Name = 'httpproxy.exe'; ParentProcessId = 4000 }
            }
            return $null
        }

        $result = Invoke-HttpProxyRecoveryStop -ServiceName 'httpproxy' -TimeoutSeconds 2

        $global:nssmCalls | Should -Contain 'stop httpproxy'
        Should -Invoke Invoke-CimMethod -Times 1 -Exactly -ParameterFilter { $MethodName -eq 'StopService' }
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4001 }
        Should -Invoke Wait-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4001 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 4002 }
        $result.TerminatedChildPids | Should -Contain 4001
        $result.Stopped | Should -BeFalse
    }
}
