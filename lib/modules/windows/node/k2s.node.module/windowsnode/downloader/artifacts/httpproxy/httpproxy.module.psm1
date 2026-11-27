# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
$networkModule = "$PSScriptRoot\..\..\..\network\loopbackadapter.module.psm1"
$nssmModule = "$PSScriptRoot\..\nssm\nssm.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule, $networkModule, $nssmModule

$kubeBinPath = Get-KubeBinPath

$httpProxyPort = '8181'
$proxyInboundFirewallRule = "HTTP Proxy Inbound Allow Port $httpProxyPort"

function Install-WinHttpProxy {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Proxy for Host')]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'No Proxy for Host')]
        [string[]]$ProxyOverrides = @()
    )


    $httpProxyLogDir = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'httpproxy'
    mkdir -Force $httpProxyLogDir | Out-Null

    Write-Log '[HttpProxy] Removing httpproxy service if existent'
    Remove-ServiceIfExists 'httpproxy'

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        &$kubeBinPath\nssm install httpproxy "$kubeBinPath\httpproxy.exe" *>&1 | Out-Null
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if (!(Get-Service -Name 'httpproxy' -ErrorAction SilentlyContinue)) {
        throw '[HttpProxy] Failed to create httpproxy service'
    }
    &$kubeBinPath\nssm set httpproxy AppDirectory $kubeBinPath | Out-Null

    Set-ProxyConfigInHttpProxy -Proxy:$Proxy -ProxyOverrides:$ProxyOverrides

    &$kubeBinPath\nssm set httpproxy AppStdout "$httpProxyLogDir\httpproxy_stdout.log" | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStderr "$httpProxyLogDir\httpproxy_stderr.log" | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set httpproxy Start SERVICE_AUTO_START | Out-Null

    # Give the console control handler enough time to run Stop-System.ps1 during
    # Windows shutdown. NSSM default is ~1.5s per method which is too short for
    # HNS cleanup. 30s for the console method covers all shutdown operations;
    # window and thread methods are skipped (not applicable for a console app).
    &$kubeBinPath\nssm set httpproxy AppStopMethodConsole 30000 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStopMethodWindow 0 | Out-Null
    &$kubeBinPath\nssm set httpproxy AppStopMethodThreads 0 | Out-Null

    # Only the cluster networks may reach the proxy; this mirrors the --allowed-cidr whitelist of httpproxy.
    New-NetFirewallRule -DisplayName $proxyInboundFirewallRule -Group 'k2s' -Direction Inbound -LocalPort $httpProxyPort -Protocol TCP -RemoteAddress (Get-HttpProxyAllowedCIDRs) -Action Allow | Out-Null
    Start-Service httpproxy
}

function Protect-HttpProxySensitiveText {
    <#
    .SYNOPSIS
        Redacts credentials and sensitive proxy configuration from text.
    .DESCRIPTION
        Masks userinfo credentials in proxy URLs (scheme://user:pass@host -> scheme://[REDACTED]@host)
        as well as common credential key/value pairs and authorization headers so diagnostics and logs
        never expose proxy passwords or tokens.
    .PARAMETER Text
        The input string to sanitize.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $sanitized = $Text
    $sanitized = $sanitized -replace '([a-zA-Z][a-zA-Z0-9+\-.]*://)[^\s/?#"''`,;\r\n]+@', '$1[REDACTED]@'
    $sanitized = $sanitized -replace '(?<![^\s=:"'',;])[^\s/?#:"''`,;\r\n]+:[^\s/?#"''`,;\r\n]*@', '[REDACTED]@'
    $sanitized = $sanitized -replace '(?i)((?:proxy[-_]?)?(?:password|passwd|pwd|secret|token|apikey|api_key)["'']?\s*[=:]\s*)(?:"[^"\r\n]*"|''[^''\r\n]*''|[^\s,;''"`\r\n]+)', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)((?:Proxy-)?Authorization\s*:\s*)([^\r\n]+)', '$1[REDACTED]'
    return $sanitized
}

function Get-HttpProxyNssmCommand {
    if ([string]::IsNullOrWhiteSpace($kubeBinPath)) {
        return $null
    }

    foreach ($candidate in @("$kubeBinPath\nssm.exe", "$kubeBinPath\nssm.ps1")) {
        if (Test-Path -Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-HttpProxyReadinessEndpoint {
    <#
    .SYNOPSIS
        Resolves the local Windows host endpoint used to probe httpproxy TCP readiness.
    .DESCRIPTION
        Uses the configured KubeSwitch/control-plane host IP when it is bound locally on the
        Windows host, and falls back to 127.0.0.1 when the cluster vSwitch is absent/stopped.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 65535)]
        [int]$Port = 8181
    )

    $configuredHost = $null
    try {
        $configuredHost = Get-ConfiguredKubeSwitchIP
    }
    catch {
        $configuredHost = $null
    }

    $endpointHost = '127.0.0.1'
    $isFallback = $true

    if (-not [string]::IsNullOrWhiteSpace($configuredHost)) {
        $boundAddresses = @(
            Get-NetIPAddress -IPAddress $configuredHost -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.IPAddress) }
        )
        if ($boundAddresses.Count -gt 0) {
            $endpointHost = $configuredHost
            $isFallback = $false
        }
    }

    return [pscustomobject]@{
        Host           = $endpointHost
        Port           = $Port
        ConfiguredHost = $configuredHost
        IsFallback     = $isFallback
        Endpoint       = "${endpointHost}:${Port}"
    }
}

function Test-HttpProxyTcpReadiness {
    <#
    .SYNOPSIS
        Performs a bounded local TCP connection test against the httpproxy endpoint.
    .DESCRIPTION
        Connects using System.Net.Sockets.TcpClient with an explicit timeout and always closes
        and disposes the client and wait handle in a finally block.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetHost,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 65535)]
        [int]$Port = 8181,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 60000)]
        [int]$ConnectTimeoutMs = 1500
    )

    $endpoint = "${TargetHost}:${Port}"
    $client = $null
    $waitHandle = $null

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $asyncResult = $client.BeginConnect($TargetHost, $Port, $null, $null)
        $waitHandle = $asyncResult.AsyncWaitHandle
        $signaled = $waitHandle.WaitOne($ConnectTimeoutMs, $false)

        if (-not $signaled) {
            return [pscustomobject]@{
                Success  = $false
                Endpoint = $endpoint
                Error    = "TCP connect to $endpoint timed out after ${ConnectTimeoutMs}ms"
            }
        }

        $client.EndConnect($asyncResult)
        if (-not $client.Connected) {
            return [pscustomobject]@{
                Success  = $false
                Endpoint = $endpoint
                Error    = "TCP client did not remain connected to $endpoint"
            }
        }

        return [pscustomobject]@{
            Success  = $true
            Endpoint = $endpoint
            Error    = $null
        }
    }
    catch {
        $baseException = $_.Exception.GetBaseException()
        $errorMessage = if ($baseException) { $baseException.Message } else { $_.Exception.Message }
        return [pscustomobject]@{
            Success  = $false
            Endpoint = $endpoint
            Error    = "TCP connect to $endpoint failed: $(Protect-HttpProxySensitiveText -Text $errorMessage)"
        }
    }
    finally {
        if ($null -ne $client) {
            try { $client.Close() } catch {}
            try { $client.Dispose() } catch {}
        }
        if ($null -ne $waitHandle) {
            try { $waitHandle.Close() } catch {}
        }
    }
}

function Get-HttpProxyListenerOwnership {
    <#
    .SYNOPSIS
        Verifies that TCP port 8181 is owned exclusively by the NSSM-managed httpproxy.exe process.
    .DESCRIPTION
        Queries Win32_Service for the NSSM service PID, inspects active TCP listeners on the target
        port via Get-NetTCPConnection, and confirms via Win32_Process that each listener belongs to
        httpproxy.exe whose ParentProcessId matches the NSSM service PID (and ExecutablePath matches
        the expected binary when available). Rejects unrelated processes and orphaned httpproxy.exe.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 65535)]
        [int]$Port = 8181,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName = 'httpproxy',
        [Parameter(Mandatory = $false)]
        [string]$ExpectedExePath = $(if ($kubeBinPath) { Join-Path -Path $kubeBinPath -ChildPath 'httpproxy.exe' } else { '' })
    )

    $serviceCim = $null
    try {
        $serviceCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            IsOwned               = $false
            Reason                = "Failed to query Win32_Service for '$ServiceName': $(Protect-HttpProxySensitiveText -Text $_.Exception.Message)"
            ServiceState          = $null
            ServicePid            = 0
            MatchedPid            = 0
            MatchedProcessName    = $null
            MatchedExecutablePath = $null
            Listeners             = @()
        }
    }

    if ($null -eq $serviceCim) {
        return [pscustomobject]@{
            IsOwned               = $false
            Reason                = "Service '$ServiceName' was not found in Win32_Service"
            ServiceState          = $null
            ServicePid            = 0
            MatchedPid            = 0
            MatchedProcessName    = $null
            MatchedExecutablePath = $null
            Listeners             = @()
        }
    }

    $serviceState = $serviceCim.State
    $servicePid = if ($null -ne $serviceCim.ProcessId) { [int]$serviceCim.ProcessId } else { 0 }

    $listeners = @()
    try {
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    }
    catch {
        if ($_.Exception.Message -match 'No matching MSFT_NetTCPConnection' -or
            $_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
            $listeners = @()
        }
        else {
            return [pscustomobject]@{
                IsOwned               = $false
                Reason                = "Failed to query TCP listeners on port ${Port}: $(Protect-HttpProxySensitiveText -Text $_.Exception.Message)"
                ServiceState          = $serviceState
                ServicePid            = $servicePid
                MatchedPid            = 0
                MatchedProcessName    = $null
                MatchedExecutablePath = $null
                Listeners             = @()
            }
        }
    }

    $listenerDetails = [System.Collections.Generic.List[object]]::new()
    $matchedListeners = [System.Collections.Generic.List[object]]::new()
    $foreignListeners = [System.Collections.Generic.List[object]]::new()

    $normalizedExpectedExe = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExePath)) {
        try {
            $normalizedExpectedExe = [System.IO.Path]::GetFullPath($ExpectedExePath.Trim())
        }
        catch {
            $normalizedExpectedExe = $ExpectedExePath.Trim()
        }
    }

    foreach ($listener in $listeners) {
        $ownerPid = if ($null -ne $listener.OwningProcess) { [int]$listener.OwningProcess } else { 0 }
        $proc = $null
        if ($ownerPid -gt 0) {
            try {
                $proc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction Stop
            }
            catch {
                $proc = $null
            }
        }

        $procName = if ($proc) { $proc.Name } else { $null }
        $parentPid = if ($proc -and $null -ne $proc.ParentProcessId) { [int]$proc.ParentProcessId } else { 0 }
        $exePath = if ($proc) { $proc.ExecutablePath } else { $null }

        $exeMatches = $true
        if ($normalizedExpectedExe) {
            if ([string]::IsNullOrWhiteSpace($exePath)) {
                $exeMatches = $false
            }
            else {
                $normalizedActualExe = $exePath.Trim()
                try {
                    $normalizedActualExe = [System.IO.Path]::GetFullPath($normalizedActualExe)
                }
                catch {
                    # Keep trimmed string if GetFullPath fails on synthetic test paths
                }
                $exeMatches = [string]::Equals($normalizedActualExe, $normalizedExpectedExe, [StringComparison]::OrdinalIgnoreCase)
            }
        }

        $isOwnerMatch = ($serviceState -eq 'Running') -and
            ($servicePid -gt 0) -and
            ($null -ne $proc) -and
            ($procName -ieq 'httpproxy.exe') -and
            ($parentPid -eq $servicePid) -and
            $exeMatches

        $detail = [pscustomobject]@{
            LocalAddress    = $listener.LocalAddress
            LocalPort       = $listener.LocalPort
            OwningProcess   = $ownerPid
            ProcessName     = $procName
            ParentProcessId = $parentPid
            ExecutablePath  = $exePath
            IsExpectedOwner = $isOwnerMatch
        }
        $listenerDetails.Add($detail)

        if ($isOwnerMatch) {
            $matchedListeners.Add($detail)
        }
        else {
            $foreignListeners.Add($detail)
        }
    }

    if ($serviceState -ne 'Running' -or $servicePid -le 0) {
        $reason = "Service '$ServiceName' is not running with a valid PID (State='$serviceState', ProcessId=$servicePid)"
        if ($foreignListeners.Count -gt 0) {
            $foreignSummary = ($foreignListeners | ForEach-Object {
                    "PID=$($_.OwningProcess) Name='$($_.ProcessName)' ParentPID=$($_.ParentProcessId) Path='$($_.ExecutablePath)' Addr=$($_.LocalAddress):$($_.LocalPort)"
                }) -join '; '
            $reason = "$reason; Port $Port has listener(s) not owned by '$ServiceName': $foreignSummary"
        }
        return [pscustomobject]@{
            IsOwned               = $false
            Reason                = $reason
            ServiceState          = $serviceState
            ServicePid            = $servicePid
            MatchedPid            = 0
            MatchedProcessName    = $null
            MatchedExecutablePath = $null
            Listeners             = @($listenerDetails)
        }
    }

    if ($listeners.Count -eq 0) {
        return [pscustomobject]@{
            IsOwned               = $false
            Reason                = "No TCP listener found on port $Port in Listen state"
            ServiceState          = $serviceState
            ServicePid            = $servicePid
            MatchedPid            = 0
            MatchedProcessName    = $null
            MatchedExecutablePath = $null
            Listeners             = @()
        }
    }

    if ($foreignListeners.Count -gt 0) {
        $foreignSummary = ($foreignListeners | ForEach-Object {
                "PID=$($_.OwningProcess) Name='$($_.ProcessName)' ParentPID=$($_.ParentProcessId) Path='$($_.ExecutablePath)' Addr=$($_.LocalAddress):$($_.LocalPort)"
            }) -join '; '
        return [pscustomobject]@{
            IsOwned               = $false
            Reason                = "Port $Port has listener(s) not owned by '$ServiceName' NSSM PID ${servicePid}: $foreignSummary"
            ServiceState          = $serviceState
            ServicePid            = $servicePid
            MatchedPid            = 0
            MatchedProcessName    = $null
            MatchedExecutablePath = $null
            Listeners             = @($listenerDetails)
        }
    }

    $primaryMatch = $matchedListeners[0]
    return [pscustomobject]@{
        IsOwned               = $true
        Reason                = "Port $Port is owned by httpproxy.exe (PID=$($primaryMatch.OwningProcess), ParentPID=$servicePid)"
        ServiceState          = $serviceState
        ServicePid            = $servicePid
        MatchedPid            = $primaryMatch.OwningProcess
        MatchedProcessName    = $primaryMatch.ProcessName
        MatchedExecutablePath = $primaryMatch.ExecutablePath
        Listeners             = @($listenerDetails)
    }
}

function Wait-HttpProxyReadiness {
    <#
    .SYNOPSIS
        Polls httpproxy listener ownership and TCP reachability until consecutive checks succeed or timeout expires.
    .DESCRIPTION
        Enforces both per-attempt TimeoutSeconds and optional OverallDeadlineUtc. Requires
        RequiredConsecutiveSuccesses consecutive passing checks (ownership + local TCP connect)
        and resets the consecutive counter to 0 on any failed check.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetHost,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 65535)]
        [int]$Port = 8181,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 20,
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60)]
        [int]$PollIntervalSeconds = 1,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10)]
        [int]$RequiredConsecutiveSuccesses = 2,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 60000)]
        [int]$ConnectTimeoutMs = 1500,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName = 'httpproxy',
        [Parameter(Mandatory = $false)]
        [string]$ExpectedExePath = $(if ($kubeBinPath) { Join-Path -Path $kubeBinPath -ChildPath 'httpproxy.exe' } else { '' }),
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[datetime]]$OverallDeadlineUtc = $null
    )

    $startUtc = (Get-Date).ToUniversalTime()
    $attemptDeadlineUtc = $startUtc.AddSeconds($TimeoutSeconds)
    $effectiveDeadlineUtc = $attemptDeadlineUtc
    if ($null -ne $OverallDeadlineUtc -and $OverallDeadlineUtc.Value -lt $effectiveDeadlineUtc) {
        $effectiveDeadlineUtc = $OverallDeadlineUtc.Value
    }

    $consecutiveSuccesses = 0
    $checksPerformed = 0
    $lastFailure = 'Readiness timeout expired before check could complete'
    $lastOwnership = $null

    while ($true) {
        $nowUtc = (Get-Date).ToUniversalTime()
        if ($checksPerformed -gt 0 -and $nowUtc -ge $effectiveDeadlineUtc) {
            break
        }
        if ($checksPerformed -eq 0 -and $null -ne $OverallDeadlineUtc -and $nowUtc -ge $OverallDeadlineUtc.Value) {
            $lastFailure = 'Overall readiness budget exhausted before check could start'
            break
        }

        $checksPerformed++
        $lastOwnership = Get-HttpProxyListenerOwnership -Port $Port -ServiceName $ServiceName -ExpectedExePath $ExpectedExePath

        if (-not $lastOwnership.IsOwned) {
            $consecutiveSuccesses = 0
            $lastFailure = $lastOwnership.Reason
        }
        else {
            $tcpResult = Test-HttpProxyTcpReadiness -TargetHost $TargetHost -Port $Port -ConnectTimeoutMs $ConnectTimeoutMs
            if ($tcpResult.Success) {
                $consecutiveSuccesses++
                if ($consecutiveSuccesses -ge $RequiredConsecutiveSuccesses) {
                    $elapsed = [Math]::Round(((Get-Date).ToUniversalTime() - $startUtc).TotalSeconds, 2)
                    return [pscustomobject]@{
                        Ready                = $true
                        ConsecutiveSuccesses = $consecutiveSuccesses
                        ChecksPerformed      = $checksPerformed
                        ElapsedSeconds       = $elapsed
                        LastFailure          = $null
                        Ownership            = $lastOwnership
                        Endpoint             = "${TargetHost}:${Port}"
                    }
                }
            }
            else {
                $consecutiveSuccesses = 0
                $lastFailure = $tcpResult.Error
            }
        }

        $afterCheckUtc = (Get-Date).ToUniversalTime()
        if ($afterCheckUtc -ge $effectiveDeadlineUtc) {
            break
        }

        if ($PollIntervalSeconds -gt 0) {
            $remainingMs = ($effectiveDeadlineUtc - $afterCheckUtc).TotalMilliseconds
            if ($remainingMs -gt 0) {
                $sleepMs = [Math]::Min($PollIntervalSeconds * 1000, [int][Math]::Ceiling($remainingMs))
                if ($sleepMs -ge ($PollIntervalSeconds * 1000)) {
                    Start-Sleep -Seconds $PollIntervalSeconds
                }
                elseif ($sleepMs -gt 0) {
                    Start-Sleep -Milliseconds $sleepMs
                }
            }
        }
    }

    $totalElapsed = [Math]::Round(((Get-Date).ToUniversalTime() - $startUtc).TotalSeconds, 2)
    return [pscustomobject]@{
        Ready                = $false
        ConsecutiveSuccesses = $consecutiveSuccesses
        ChecksPerformed      = $checksPerformed
        ElapsedSeconds       = $totalElapsed
        LastFailure          = $lastFailure
        Ownership            = $lastOwnership
        Endpoint             = "${TargetHost}:${Port}"
    }
}

function Invoke-HttpProxyRecoveryStop {
    <#
    .SYNOPSIS
        Stops the httpproxy service cleanly via NSSM/SCM and terminates only lingering child httpproxy.exe.
    .DESCRIPTION
        Coordinates service shutdown with NSSM/SCM without triggering CTRL_SHUTDOWN_EVENT or Stop-System.ps1.
        Waits up to TimeoutSeconds for the service to reach Stopped state and, only if a child httpproxy.exe
        owned by the prior NSSM service PID remains alive, terminates that verified child process.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName = 'httpproxy',
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$TimeoutSeconds = 15
    )

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log "[HttpProxy] Service '$ServiceName' not found during recovery stop"
        return [pscustomobject]@{
            Stopped             = $true
            ServiceStatus       = $null
            PriorServicePid     = 0
            TerminatedChildPids = @()
        }
    }

    $serviceCim = $null
    try {
        $serviceCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    }
    catch {
        $serviceCim = $null
    }

    $priorServicePid = if ($serviceCim -and $null -ne $serviceCim.ProcessId) { [int]$serviceCim.ProcessId } else { 0 }
    $priorChildPids = [System.Collections.Generic.List[int]]::new()
    if ($priorServicePid -gt 0) {
        try {
            $children = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$priorServicePid" -ErrorAction Stop |
                    Where-Object { $_.Name -ieq 'httpproxy.exe' })
            foreach ($child in $children) {
                if ($null -ne $child.ProcessId -and [int]$child.ProcessId -gt 0) {
                    $priorChildPids.Add([int]$child.ProcessId)
                }
            }
        }
        catch {
            # Best-effort inspection before stop
        }
    }

    if ($svc.Status -ne 'Stopped') {
        $deadlineUtc = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
        $nssmProc = $null
        $nssmCmd = Get-HttpProxyNssmCommand
        try {
            if ($nssmCmd) {
                Write-Log "[HttpProxy] Stopping service '$ServiceName' via NSSM (timeout=${TimeoutSeconds}s)"
                if ($nssmCmd -like '*.ps1') {
                    $previousErrorActionPreference = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'
                        &$nssmCmd stop $ServiceName 2>&1 | Out-Null
                    }
                    finally {
                        $ErrorActionPreference = $previousErrorActionPreference
                    }
                }
                else {
                    try {
                        $nssmProc = Start-Process -FilePath $nssmCmd -ArgumentList @('stop', $ServiceName) -NoNewWindow -PassThru -ErrorAction Stop
                    }
                    catch {
                        Write-Log "[HttpProxy] Failed to launch NSSM stop for '$ServiceName': $(Protect-HttpProxySensitiveText -Text $_.Exception.Message)"
                    }
                }
            }

            $afterNssmSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($null -ne $afterNssmSvc -and $afterNssmSvc.Status -ne 'Stopped') {
                if ($null -ne $serviceCim) {
                    Write-Log "[HttpProxy] Issuing non-blocking StopService for '$ServiceName' via Win32_Service"
                    try {
                        Invoke-CimMethod -InputObject $serviceCim -MethodName StopService -ErrorAction SilentlyContinue | Out-Null
                    }
                    catch {
                        # Best-effort non-blocking stop signal
                    }
                }
                else {
                    Write-Log "[HttpProxy] Issuing non-blocking stop for '$ServiceName' via sc.exe"
                    $previousErrorActionPreference = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = 'Continue'
                        sc.exe stop $ServiceName 2>&1 | Out-Null
                    }
                    finally {
                        $ErrorActionPreference = $previousErrorActionPreference
                    }
                }
            }

            while ($true) {
                $currentSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
                if ($null -eq $currentSvc -or $currentSvc.Status -eq 'Stopped') {
                    break
                }
                $nowUtc = (Get-Date).ToUniversalTime()
                if ($nowUtc -ge $deadlineUtc) {
                    break
                }
                $remainingMs = [int][Math]::Ceiling(($deadlineUtc - $nowUtc).TotalMilliseconds)
                if ($remainingMs -le 0) {
                    break
                }
                $sleepMs = [Math]::Min(1000, $remainingMs)
                if ($sleepMs -ge 1000) {
                    Start-Sleep -Seconds 1
                }
                else {
                    Start-Sleep -Milliseconds $sleepMs
                }
            }
        }
        finally {
            if ($null -ne $nssmProc) {
                try {
                    if (-not $nssmProc.HasExited) {
                        Stop-Process -Id $nssmProc.Id -Force -ErrorAction SilentlyContinue
                        Wait-Process -Id $nssmProc.Id -Timeout 2 -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    # Best-effort cleanup of timed-out nssm stop helper
                }
                try { $nssmProc.Dispose() } catch {}
            }
        }
    }

    $terminatedPids = [System.Collections.Generic.List[int]]::new()
    if ($priorServicePid -gt 0) {
        $lingeringChildren = @()
        try {
            $lingeringChildren = @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$priorServicePid" -ErrorAction Stop |
                    Where-Object { $_.Name -ieq 'httpproxy.exe' })
        }
        catch {
            $lingeringChildren = @()
        }

        $candidatePids = [System.Collections.Generic.HashSet[int]]::new()
        foreach ($child in $lingeringChildren) {
            if ($null -ne $child.ProcessId -and [int]$child.ProcessId -gt 0) {
                [void]$candidatePids.Add([int]$child.ProcessId)
            }
        }
        foreach ($recordedPid in $priorChildPids) {
            try {
                $stillChild = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$recordedPid" -ErrorAction Stop
                if ($stillChild -and $stillChild.Name -ieq 'httpproxy.exe' -and [int]$stillChild.ParentProcessId -eq $priorServicePid) {
                    [void]$candidatePids.Add($recordedPid)
                }
            }
            catch {
                # Process already exited
            }
        }

        foreach ($childPid in $candidatePids) {
            Write-Log "[HttpProxy] Terminating lingering child httpproxy.exe PID $childPid owned by prior NSSM service PID $priorServicePid"
            Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $childPid -Timeout 5 -ErrorAction SilentlyContinue
            $terminatedPids.Add($childPid)
        }
    }

    if ($terminatedPids.Count -gt 0) {
        $postKillDeadlineUtc = (Get-Date).ToUniversalTime().AddSeconds(2)
        while ($true) {
            $postKillSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($null -eq $postKillSvc -or $postKillSvc.Status -ne 'StopPending') {
                break
            }
            if ((Get-Date).ToUniversalTime() -ge $postKillDeadlineUtc) {
                break
            }
            Start-Sleep -Milliseconds 200
        }
    }

    $finalSvc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $finalStatus = if ($finalSvc) { "$($finalSvc.Status)" } else { $null }
    return [pscustomobject]@{
        Stopped             = ($null -eq $finalSvc -or $finalSvc.Status -eq 'Stopped')
        ServiceStatus       = $finalStatus
        PriorServicePid     = $priorServicePid
        TerminatedChildPids = @($terminatedPids)
    }
}

function Get-WindowsExcludedTcpPortRanges {
    <#
    .SYNOPSIS
        Queries Windows IPv4 and IPv6 excluded TCP port ranges and checks whether the target port is excluded.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 65535)]
        [int]$Port = 8181
    )

    $allRanges = [System.Collections.Generic.List[object]]::new()
    $matchingRanges = [System.Collections.Generic.List[object]]::new()
    $rawErrors = [System.Collections.Generic.List[string]]::new()

    foreach ($family in @('ipv4', 'ipv6')) {
        try {
            $netshCommand = Get-Command -Name 'netsh' -ErrorAction SilentlyContinue
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(netsh int $family show excludedportrange protocol=tcp 2>&1)
                $netshExitCode = if ($null -ne $netshCommand -and $netshCommand.CommandType -eq [System.Management.Automation.CommandTypes]::Application) { $LASTEXITCODE } else { 0 }
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            if ($netshExitCode -ne 0) {
                $errText = ($output | ForEach-Object { "$_" }) -join ' '
                $rawErrors.Add("${family}: netsh exited with code ${netshExitCode}: $(Protect-HttpProxySensitiveText -Text $errText)")
            }
            foreach ($line in $output) {
                $lineText = "$line"
                if ($lineText -match '^\s*(\d+)\s+(\d+)\b') {
                    $startPort = [int]$Matches[1]
                    $endPort = [int]$Matches[2]
                    $containsPort = ($Port -ge $startPort) -and ($Port -le $endPort)
                    $entry = [pscustomobject]@{
                        Family       = $family
                        StartPort    = $startPort
                        EndPort      = $endPort
                        ContainsPort = $containsPort
                        Display      = "${family}: ${startPort}-${endPort}"
                    }
                    $allRanges.Add($entry)
                    if ($containsPort) {
                        $matchingRanges.Add($entry)
                    }
                }
            }
        }
        catch {
            $rawErrors.Add("${family}: $(Protect-HttpProxySensitiveText -Text $_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        Port                = $Port
        PortInExcludedRange = ($matchingRanges.Count -gt 0)
        MatchingRanges      = @($matchingRanges)
        AllRanges           = @($allRanges)
        RawErrors           = @($rawErrors)
    }
}

function Get-HttpProxyFailureDiagnostics {
    <#
    .SYNOPSIS
        Collects redacted diagnostics when httpproxy fails readiness verification.
    .DESCRIPTION
        Captures endpoint, attempt count, elapsed time, last readiness error, Windows service and
        NSSM state, TCP port 8181 listener ownership, httpproxy stdout/stderr log tail excerpts,
        and Windows excluded TCP port range overlaps. All output is redacted for credentials.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        [Parameter(Mandatory = $false)]
        [int]$Port = 8181,
        [Parameter(Mandatory = $false)]
        [int]$Attempts = 0,
        [Parameter(Mandatory = $false)]
        [double]$ElapsedSeconds = 0,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LastFailure = '',
        [Parameter(Mandatory = $false)]
        [string]$ServiceName = 'httpproxy',
        [Parameter(Mandatory = $false)]
        [string]$ExpectedExePath = $(if ($kubeBinPath) { Join-Path -Path $kubeBinPath -ChildPath 'httpproxy.exe' } else { '' }),
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 200)]
        [int]$LogTailLines = 25
    )

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $serviceStatus = if ($svc) { "$($svc.Status)" } else { 'NotFound' }
    $serviceStartType = if ($svc -and $null -ne $svc.StartType) { "$($svc.StartType)" } else { 'Unknown' }

    $serviceCim = $null
    try {
        $serviceCim = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop
    }
    catch {
        $serviceCim = $null
    }
    $cimState = if ($serviceCim) { "$($serviceCim.State)" } else { 'Unknown' }
    $cimPid = if ($serviceCim -and $null -ne $serviceCim.ProcessId) { [int]$serviceCim.ProcessId } else { 0 }
    $cimPath = if ($serviceCim) { Protect-HttpProxySensitiveText -Text "$($serviceCim.PathName)" } else { '' }

    $nssmStatus = 'Unavailable'
    $nssmCmd = Get-HttpProxyNssmCommand
    if ($nssmCmd) {
        try {
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $nssmRaw = (&$nssmCmd status $ServiceName 2>&1 | Out-String).Trim()
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }
            if (-not [string]::IsNullOrWhiteSpace($nssmRaw)) {
                $nssmStatus = Protect-HttpProxySensitiveText -Text $nssmRaw
            }
        }
        catch {
            $nssmStatus = "Error querying nssm status: $(Protect-HttpProxySensitiveText -Text $_.Exception.Message)"
        }
    }

    $ownership = Get-HttpProxyListenerOwnership -Port $Port -ServiceName $ServiceName -ExpectedExePath $ExpectedExePath

    $stderrPath = $null
    $stdoutPath = $null
    $stderrTail = '(log directory unavailable)'
    $stdoutTail = '(log directory unavailable)'

    try {
        $logRoot = Get-ConfiguredLogDirectory
        if (-not [string]::IsNullOrWhiteSpace($logRoot)) {
            $httpProxyLogDir = Join-Path -Path $logRoot -ChildPath 'httpproxy'
            $stderrPath = Join-Path -Path $httpProxyLogDir -ChildPath 'httpproxy_stderr.log'
            $stdoutPath = Join-Path -Path $httpProxyLogDir -ChildPath 'httpproxy_stdout.log'

            if (Test-Path -Path $stderrPath) {
                $stderrLines = @(Get-Content -Path $stderrPath -Tail $LogTailLines -ErrorAction SilentlyContinue)
                $stderrTail = if ($stderrLines.Count -gt 0) {
                    Protect-HttpProxySensitiveText -Text ($stderrLines -join "`n")
                }
                else {
                    '(empty)'
                }
            }
            else {
                $stderrTail = '(file not found)'
            }

            if (Test-Path -Path $stdoutPath) {
                $stdoutLines = @(Get-Content -Path $stdoutPath -Tail $LogTailLines -ErrorAction SilentlyContinue)
                $stdoutTail = if ($stdoutLines.Count -gt 0) {
                    Protect-HttpProxySensitiveText -Text ($stdoutLines -join "`n")
                }
                else {
                    '(empty)'
                }
            }
            else {
                $stdoutTail = '(file not found)'
            }
        }
    }
    catch {
        $errMsg = Protect-HttpProxySensitiveText -Text $_.Exception.Message
        $stderrTail = "(failed to read log: $errMsg)"
        $stdoutTail = "(failed to read log: $errMsg)"
    }

    $excludedPorts = Get-WindowsExcludedTcpPortRanges -Port $Port
    $redactedLastFailure = Protect-HttpProxySensitiveText -Text $LastFailure

    $listenerDescription = if ($ownership.Listeners.Count -gt 0) {
        ($ownership.Listeners | ForEach-Object {
                "$($_.LocalAddress):$($_.LocalPort) PID=$($_.OwningProcess) Name='$($_.ProcessName)' ParentPID=$($_.ParentProcessId) Path='$($_.ExecutablePath)' ExpectedOwner=$($_.IsExpectedOwner)"
            }) -join '; '
    }
    else {
        'none'
    }

    $excludedDescription = if ($excludedPorts.PortInExcludedRange) {
        "YES ($(($excludedPorts.MatchingRanges | ForEach-Object { $_.Display }) -join ', '))"
    }
    else {
        "NO (checked $($excludedPorts.AllRanges.Count) range(s))"
    }

    $summaryLines = @(
        "httpproxy readiness diagnostics:"
        "  Endpoint: $Endpoint"
        "  Attempts: $Attempts"
        "  ElapsedSeconds: $ElapsedSeconds"
        "  LastFailure: $redactedLastFailure"
        "  Service: Status=$serviceStatus, StartType=$serviceStartType, CimState=$cimState, ServicePid=$cimPid, PathName=$cimPath"
        "  NssmStatus: $nssmStatus"
        "  Port${Port}Ownership: IsOwned=$($ownership.IsOwned), Reason=$($ownership.Reason)"
        "  Port${Port}Listeners: $listenerDescription"
        "  Port${Port}InWindowsExcludedRange: $excludedDescription"
        "  StderrLog ($stderrPath): $stderrTail"
        "  StdoutLog ($stdoutPath): $stdoutTail"
    )
    $summary = Protect-HttpProxySensitiveText -Text ($summaryLines -join "`n")

    return [pscustomobject]@{
        Endpoint            = $Endpoint
        Port                = $Port
        Attempts            = $Attempts
        ElapsedSeconds      = $ElapsedSeconds
        LastFailure         = $redactedLastFailure
        ServiceStatus       = $serviceStatus
        ServiceStartType    = $serviceStartType
        ServiceState        = $cimState
        ServicePid          = $cimPid
        NssmStatus          = $nssmStatus
        Ownership           = $ownership
        StderrPath          = $stderrPath
        StderrTail          = $stderrTail
        StdoutPath          = $stdoutPath
        StdoutTail          = $stdoutTail
        ExcludedPortRanges  = $excludedPorts
        PortInExcludedRange = $excludedPorts.PortInExcludedRange
        Summary             = $summary
    }
}

<#
.SYNOPSIS
    Starts the httpproxy Windows service and verifies TCP port 8181 readiness and listener ownership.
.DESCRIPTION
    Ensures NSSM stop-method timeouts are configured, verifies whether an already-running httpproxy
    service is healthy (without restarting it), or starts/recovers the service using bounded retries
    and overall time budget before allowing proxy-dependent cluster startup steps to proceed.
.PARAMETER OnlyProxy
    When specified, skips Confirm-LoopbackAdapterIP and flanneld startup after httpproxy is verified ready.
.PARAMETER MaxAttempts
    Maximum number of start/recovery attempts. Default: 3.
.PARAMETER ReadinessTimeoutSeconds
    Per-attempt readiness polling timeout in seconds. Default: 20.
.PARAMETER PollIntervalSeconds
    Interval in seconds between readiness checks. Default: 1.
.PARAMETER RequiredConsecutiveSuccesses
    Number of consecutive passing ownership + TCP checks required before declaring readiness. Default: 2.
.PARAMETER ConnectTimeoutMs
    TCP connect timeout in milliseconds per readiness probe. Default: 1500.
.PARAMETER ServiceControlTimeoutSeconds
    Timeout in seconds to wait for NSSM/SCM to stop the service during recovery. Default: 15.
.PARAMETER MaxOverallDurationSeconds
    Hard overall time budget in seconds enforced across all attempts and recovery steps. Default: 120.
#>
function Start-WinHttpProxy {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$OnlyProxy = $false,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$MaxAttempts = 3,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 300)]
        [int]$ReadinessTimeoutSeconds = 20,
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60)]
        [int]$PollIntervalSeconds = 1,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10)]
        [int]$RequiredConsecutiveSuccesses = 2,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 60000)]
        [int]$ConnectTimeoutMs = 1500,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$ServiceControlTimeoutSeconds = 15,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 3600)]
        [int]$MaxOverallDurationSeconds = 120
    )

    $port = if ($httpProxyPort) { [int]$httpProxyPort } else { 8181 }
    $expectedExePath = if ($kubeBinPath) { Join-Path -Path $kubeBinPath -ChildPath 'httpproxy.exe' } else { '' }
    $overallStartUtc = (Get-Date).ToUniversalTime()
    $overallDeadlineUtc = $overallStartUtc.AddSeconds($MaxOverallDurationSeconds)

    $endpointInfo = Get-HttpProxyReadinessEndpoint -Port $port
    Write-Log "[HttpProxy] Verifying httpproxy readiness on $($endpointInfo.Endpoint) (MaxAttempts=$MaxAttempts, ReadinessTimeoutSeconds=$ReadinessTimeoutSeconds, RequiredConsecutiveSuccesses=$RequiredConsecutiveSuccesses, MaxOverallDurationSeconds=$MaxOverallDurationSeconds)"

    $svc = Get-Service -Name 'httpproxy' -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        $missingFailure = "Windows service 'httpproxy' is not installed"
        $diagnostics = Get-HttpProxyFailureDiagnostics -Endpoint $endpointInfo.Endpoint -Port $port -Attempts 0 -ElapsedSeconds 0 -LastFailure $missingFailure -ServiceName 'httpproxy' -ExpectedExePath $expectedExePath
        Write-Log "[HttpProxy] $($diagnostics.Summary)" -Console
        throw "[HttpProxy] $missingFailure. $($diagnostics.Summary)"
    }

    # Ensure NSSM stop-method timeouts are configured. This is self-healing for
    # installations that were created before these settings were added to
    # Install-WinHttpProxy, so existing systems also get the fix on next start.
    $nssmCmd = Get-HttpProxyNssmCommand
    if ($nssmCmd) {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            &$nssmCmd set httpproxy AppStopMethodConsole 30000 2>&1 | Out-Null
            &$nssmCmd set httpproxy AppStopMethodWindow 0 2>&1 | Out-Null
            &$nssmCmd set httpproxy AppStopMethodThreads 0 2>&1 | Out-Null
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }

    $isReady = $false
    $attemptsMade = 0
    $lastFailure = 'httpproxy readiness verification did not succeed'

    if ($svc.Status -eq 'Running') {
        $remainingBeforeInitial = ($overallDeadlineUtc - (Get-Date).ToUniversalTime()).TotalSeconds
        if ($remainingBeforeInitial -gt 0) {
            $initialTimeout = [Math]::Max(1, [Math]::Min($ReadinessTimeoutSeconds, [int][Math]::Ceiling($remainingBeforeInitial)))
            Write-Log "[HttpProxy] Service 'httpproxy' is already running; verifying readiness on $($endpointInfo.Endpoint) without restarting"
            $initialWait = Wait-HttpProxyReadiness -TargetHost $endpointInfo.Host -Port $port -TimeoutSeconds $initialTimeout -PollIntervalSeconds $PollIntervalSeconds -RequiredConsecutiveSuccesses $RequiredConsecutiveSuccesses -ConnectTimeoutMs $ConnectTimeoutMs -ServiceName 'httpproxy' -ExpectedExePath $expectedExePath -OverallDeadlineUtc $overallDeadlineUtc
            if ($initialWait.Ready) {
                if ($svc.StartType -ne 'Automatic') {
                    if ($nssmCmd) {
                        $previousErrorActionPreference = $ErrorActionPreference
                        try {
                            $ErrorActionPreference = 'Continue'
                            &$nssmCmd set httpproxy Start SERVICE_AUTO_START 2>&1 | Out-Null
                        }
                        finally {
                            $ErrorActionPreference = $previousErrorActionPreference
                        }
                    }
                    else {
                        Set-Service -Name 'httpproxy' -StartupType Automatic -ErrorAction SilentlyContinue
                    }
                }
                Write-Log "[HttpProxy] Existing running httpproxy is healthy on $($endpointInfo.Endpoint) ($($initialWait.ConsecutiveSuccesses) consecutive checks passed)" -Console
                $isReady = $true
            }
            else {
                $lastFailure = $initialWait.LastFailure
                Write-Log "[HttpProxy] Existing running httpproxy is unhealthy ($(Protect-HttpProxySensitiveText -Text $lastFailure)); starting bounded recovery" -Console
            }
        }
        else {
            $lastFailure = "Overall readiness budget of ${MaxOverallDurationSeconds}s exhausted"
        }
    }

    if (-not $isReady) {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $remainingOverall = ($overallDeadlineUtc - (Get-Date).ToUniversalTime()).TotalSeconds
            if ($remainingOverall -le 0) {
                $lastFailure = "Overall readiness budget of ${MaxOverallDurationSeconds}s exhausted before attempt $attempt"
                break
            }

            $attemptsMade = $attempt
            $currentSvc = Get-Service -Name 'httpproxy' -ErrorAction SilentlyContinue
            if (($attempt -gt 1) -or ($null -ne $currentSvc -and $currentSvc.Status -ne 'Stopped')) {
                $stopTimeout = [Math]::Max(1, [Math]::Min($ServiceControlTimeoutSeconds, [int][Math]::Ceiling($remainingOverall)))
                Write-Log "[HttpProxy] Performing clean recovery stop before attempt $attempt/$MaxAttempts"
                $stopResult = Invoke-HttpProxyRecoveryStop -ServiceName 'httpproxy' -TimeoutSeconds $stopTimeout
                if (-not $stopResult.Stopped) {
                    $lastFailure = "Failed to stop 'httpproxy' service cleanly before attempt $attempt (ServiceStatus='$($stopResult.ServiceStatus)', PriorServicePid=$($stopResult.PriorServicePid))"
                    Write-Log "[HttpProxy] $lastFailure" -Console
                    continue
                }
            }

            $remainingOverall = ($overallDeadlineUtc - (Get-Date).ToUniversalTime()).TotalSeconds
            if ($remainingOverall -le 0) {
                $lastFailure = "Overall readiness budget of ${MaxOverallDurationSeconds}s exhausted during recovery stop on attempt $attempt"
                break
            }

            try {
                Start-ServiceAndSetToAutoStart -Name 'httpproxy'
            }
            catch {
                $lastFailure = "Failed to start httpproxy service on attempt ${attempt}: $(Protect-HttpProxySensitiveText -Text $_.Exception.Message)"
                Write-Log "[HttpProxy] $lastFailure"
                continue
            }

            $remainingOverall = ($overallDeadlineUtc - (Get-Date).ToUniversalTime()).TotalSeconds
            if ($remainingOverall -le 0) {
                $lastFailure = "Overall readiness budget of ${MaxOverallDurationSeconds}s exhausted after starting service on attempt $attempt"
                break
            }

            $attemptTimeout = [Math]::Max(1, [Math]::Min($ReadinessTimeoutSeconds, [int][Math]::Ceiling($remainingOverall)))
            $waitResult = Wait-HttpProxyReadiness -TargetHost $endpointInfo.Host -Port $port -TimeoutSeconds $attemptTimeout -PollIntervalSeconds $PollIntervalSeconds -RequiredConsecutiveSuccesses $RequiredConsecutiveSuccesses -ConnectTimeoutMs $ConnectTimeoutMs -ServiceName 'httpproxy' -ExpectedExePath $expectedExePath -OverallDeadlineUtc $overallDeadlineUtc

            if ($waitResult.Ready) {
                Write-Log "[HttpProxy] httpproxy is ready on $($endpointInfo.Endpoint) after $attempt attempt(s) ($($waitResult.ConsecutiveSuccesses) consecutive checks passed)" -Console
                $isReady = $true
                break
            }

            $lastFailure = $waitResult.LastFailure
            Write-Log "[HttpProxy] httpproxy readiness attempt $attempt/$MaxAttempts failed: $(Protect-HttpProxySensitiveText -Text $lastFailure)"
        }
    }

    if (-not $isReady) {
        $elapsedSeconds = [Math]::Round(((Get-Date).ToUniversalTime() - $overallStartUtc).TotalSeconds, 2)
        $diagnostics = Get-HttpProxyFailureDiagnostics -Endpoint $endpointInfo.Endpoint -Port $port -Attempts $attemptsMade -ElapsedSeconds $elapsedSeconds -LastFailure $lastFailure -ServiceName 'httpproxy' -ExpectedExePath $expectedExePath
        Write-Log "[HttpProxy] $($diagnostics.Summary)" -Console
        throw "[HttpProxy] httpproxy failed readiness verification on $($endpointInfo.Endpoint) after $attemptsMade attempt(s) (${elapsedSeconds}s): $($diagnostics.LastFailure)`n$($diagnostics.Summary)"
    }

    if ($OnlyProxy) { return }
    Confirm-LoopbackAdapterIP
    # Flanneld must remain SERVICE_DEMAND_START to prevent cbr0 L2Bridge race condition.
    Start-Service 'flanneld' -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    Write-Log "Service 'flanneld' started"
}

function Stop-WinHttpProxy {
    Stop-ServiceAndSetToManualStart 'flanneld'
    Stop-ServiceAndSetToManualStart 'httpproxy'
}

function Remove-WinHttpProxy {
    Remove-ServiceIfExists 'httpproxy'
    $rule = Get-NetFirewallRule -DisplayName $proxyInboundFirewallRule -ErrorAction SilentlyContinue
    if ($null -ne $rule) {
        Remove-NetFirewallRule -DisplayName $proxyInboundFirewallRule
    }
}

function Get-HttpProxyAllowedCIDRs {
    # Cluster pods, services, the control plane network and the loopback adapter network are the only clients of the proxy.
    $allowedCIDRs = @(
        @(
            Get-ConfiguredClusterCIDR
            Get-ConfiguredClusterCIDRServices
            Get-ConfiguredControlPlaneCIDR
            Get-LoopbackAdapterCIDR
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($allowedCIDRs.Count -eq 0) {
        throw '[HttpProxy] No cluster network CIDR configured, cannot restrict access to the httpproxy'
    }
    return $allowedCIDRs
}

function Set-ProxyConfigInHttpProxy {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Proxy for Host')]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'No Proxy for Host')]
        [string[]]$ProxyOverrides = @()
    )
    $appParameters = (Get-HttpProxyAllowedCIDRs | ForEach-Object { "--allowed-cidr $_" }) -join ' '
    if ( $Proxy -ne '' ) {
        $appParameters = $appParameters + " --forwardproxy $Proxy"
    }
    
    $k2sHosts = Get-K2sHosts
    
    $allNoProxyHosts = @()
    if ($ProxyOverrides.Count -gt 0) {
        $allNoProxyHosts += $ProxyOverrides
    }
    $allNoProxyHosts += $k2sHosts
    
    $uniqueNoProxyHosts = $allNoProxyHosts | Sort-Object -Unique
    
    if ($uniqueNoProxyHosts.Count -gt 0) {
        $noProxyValue = $uniqueNoProxyHosts -join ','
        &$kubeBinPath\nssm set httpproxy AppEnvironmentExtra "NO_PROXY=$noProxyValue" | Out-Null
        Write-Log "HTTP Proxy service configured with NO_PROXY: $noProxyValue"
    } else {
        &$kubeBinPath\nssm set httpproxy AppEnvironmentExtra "NO_PROXY=.local" | Out-Null
        Write-Log "HTTP Proxy service configured with default NO_PROXY: .local"
    }
        
    &$kubeBinPath\nssm set httpproxy AppParameters $appParameters | Out-Null
    
    if ( $Proxy -ne '' ) {
        $redactedProxy = Protect-HttpProxySensitiveText -Text $Proxy
        Write-Log "[HttpProxy] HTTP Proxy service configured with forward proxy: $redactedProxy"
    }
}
