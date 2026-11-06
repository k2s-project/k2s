# SPDX-FileCopyrightText: © 2025 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"

Import-Module $infraModule, $nodeModule
Initialize-Logging

$logUseCase = 'Start-System'

function Wait-NetInterfaceAdapterUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdapterName,
        [int]$TimeoutSeconds = 60,
        [int]$DelaySeconds = 2
    )

    $endTime = [DateTime]::Now.AddSeconds($TimeoutSeconds)
    $adapterStatus = ''

    Write-Log "[$logUseCase] Waiting for network adapter '$AdapterName' to come up..."

    while ([DateTime]::Now -lt $endTime) {
        try {
            $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
            $adapterStatus = $adapter.Status
            if ($adapterStatus -eq 'Up') {
                Write-Log "[$logUseCase] Network adapter '$AdapterName' is up."
                $if = Get-NetIPInterface -InterfaceAlias $AdapterName -ErrorAction SilentlyContinue
                if ( $if ) {
                    Write-Log "[$logUseCase] Network adapter '$AdapterName' is up and interfaces are available: $if"
                    return $true
                }
                else {
                    Write-Log "[$logUseCase] Could not get IP interface for adapter '$AdapterName'. Retrying..."
                }
            }
        }
        catch {
            Write-Log "[$logUseCase] Could not get status for adapter '$AdapterName'. Retrying..."
        }

        Write-Log "[$logUseCase] Adapter status is '$adapterStatus'. Waiting $DelaySeconds seconds..."
        Start-Sleep -Seconds $DelaySeconds
    }

    Write-Log "Timeout reached. Network adapter '$AdapterName' did not come up within $TimeoutSeconds seconds. Current status: '$adapterStatus'"
    return $false
}

function Select-K2sIsRunning {
    $processName = 'k2s.exe'
    # Get the process information using Get-CimInstance (recommended over Get-WmiObject for modern PowerShell)
    # This allows access to the CommandLine property.
    $k2sProcess = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq $processName
    }

    if ($k2sProcess) {
        Write-Log "[$logUseCase] Process '$processName' is running."

        $found = $false
        foreach ($process in $k2sProcess) {
            $commandLine = $process.CommandLine

            # Proxy mutations own Flannel's stop/start sequence when restarting httpproxy.
            if ($commandLine -match '^\s*(?:"[^"]+"|\S+)\s+(?:install|start|system\s+proxy\s+(?:set|reset|override\s+(?:add|delete)))(?:\s|$)') {
                $found = $true
                break # Exit the loop once a matching argument is found for this process
            }
        }

        if ($found) {
            Write-Log "[$logUseCase] K2s is OK with the right parameters."
            return $true
        }
        else {
            Write-Log "[$logUseCase] K2s is not doing an install, start or proxy reconfiguration."
            return $false
        }
    }
    else {
        Write-Log "[$logUseCase] Process '$processName' is NOT running."
        return $false
    }
}

function Invoke-KubectlWithKubeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KubeConfigPath,
        [Parameter(Mandatory = $true)]
        [array]$Params
    )

    $kubeBinPathTools = Get-KubeToolsPath
    $savedErrorActionPreference = $ErrorActionPreference
    $output = $null
    $exitCode = 1

    try {
        $ErrorActionPreference = 'Continue'
        $output = &"$kubeBinPathTools\kubectl.exe" --kubeconfig="$KubeConfigPath" @Params 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    return [pscustomobject]@{
        Success  = ($exitCode -eq 0)
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-WindowsWorkerNodeRoutes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KubeConfigPath
    )

    $windowsNodeRoutes = [System.Collections.ArrayList]@()
    $ipv4CidrPattern = '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
    $nodeQueryResult = Invoke-KubectlWithKubeConfig -KubeConfigPath $KubeConfigPath -Params @('get', 'nodes', '-l', 'kubernetes.io/os=windows', '-o', 'json')
    if (-not $nodeQueryResult.Success) {
        $message = "[$logUseCase] WARNING: Could not query Windows worker nodes: $($nodeQueryResult.Output)"
        Write-Log $message
        return [pscustomobject]@{
            Success = $false
            Routes  = $windowsNodeRoutes
            Error   = $message
        }
    }

    try {
        $nodes = ($nodeQueryResult.Output | Out-String | ConvertFrom-Json).items
    }
    catch {
        $message = "[$logUseCase] WARNING: Failed parsing Windows worker node list: $_"
        Write-Log $message
        return [pscustomobject]@{
            Success = $false
            Routes  = $windowsNodeRoutes
            Error   = $message
        }
    }

    foreach ($node in $nodes) {
        $internalIpEntry = $node.status.addresses | Where-Object { $_.type -eq 'InternalIP' } | Select-Object -First 1
        $internalIp = if ($internalIpEntry) { $internalIpEntry.address } else { '' }

        $podCIDR = ''
        $primaryPodCIDR = [string]$node.spec.podCIDR
        if ($primaryPodCIDR -match $ipv4CidrPattern) {
            $podCIDR = $primaryPodCIDR
        }

        if ([string]::IsNullOrWhiteSpace($podCIDR) -and $node.spec.podCIDRs) {
            foreach ($candidateCIDR in $node.spec.podCIDRs) {
                $candidateCIDRText = [string]$candidateCIDR
                if ($candidateCIDRText -match $ipv4CidrPattern) {
                    $podCIDR = $candidateCIDRText
                    break
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($internalIp) -or [string]::IsNullOrWhiteSpace($podCIDR)) {
            Write-Log "[$logUseCase] Skipping Windows node '$($node.metadata.name)' due to missing InternalIP or PodCIDR"
            continue
        }

        $windowsNodeRoutes.Add([pscustomobject]@{
                NodeName   = $node.metadata.name
                InternalIP = $internalIp
                PodCIDR    = $podCIDR
            }) | Out-Null
    }

    return [pscustomobject]@{
        Success = $true
        Routes  = $windowsNodeRoutes
        Error   = $null
    }
}

function Wait-ForControlPlaneTransitReachability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$WindowsNodeRoutes,
        [int]$TimeoutSeconds = 120,
        [int]$DelaySeconds = 5
    )

    if ($null -eq $WindowsNodeRoutes -or $WindowsNodeRoutes.Count -eq 0) {
        return $true
    }

    $targetIps = @($WindowsNodeRoutes | Select-Object -ExpandProperty InternalIP -Unique)
    if ($targetIps.Count -eq 0) {
        return $true
    }

    $endTime = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $sshResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'true' -IgnoreErrors -NoLog
    if (-not $sshResult.Success) {
        $message = "[$logUseCase] Cannot check transit reachability because control-plane SSH failed: $($sshResult.Output)"
        Write-Log $message -Console
        throw $message
    }
    while ([DateTime]::UtcNow -lt $endTime) {
        $unreachableIps = [System.Collections.ArrayList]@()
        foreach ($targetIp in $targetIps) {
            $pingCommand = "ping -c 1 -W 2 $targetIp >/dev/null 2>&1"
            $pingResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $pingCommand -IgnoreErrors -NoLog
            if (-not $pingResult.Success) {
                if ($pingResult.ExitCode -ne 1) {
                    $message = "[$logUseCase] Cannot check transit reachability to '$targetIp' because SSH or the ping command failed: $($pingResult.Output)"
                    Write-Log $message -Console
                    throw $message
                }
                $unreachableIps.Add($targetIp) | Out-Null
            }
        }

        if ($unreachableIps.Count -eq 0) {
            Write-Log "[$logUseCase] Control-plane transit path to Windows node(s) is reachable"
            return $true
        }

        $remainingSeconds = [int][Math]::Max(0, ($endTime - [DateTime]::UtcNow).TotalSeconds)
        Write-Log "[$logUseCase] Waiting for control-plane transit path to Windows node(s): $($unreachableIps -join ', ') (${remainingSeconds}s remaining)"
        Start-Sleep -Seconds $DelaySeconds
    }

    Write-Log "[$logUseCase] WARNING: Timed out waiting for control-plane transit reachability to Windows node(s)"
    return $false
}

function Get-MissingWindowsPodRoutesOnControlPlane {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$WindowsNodeRoutes
    )

    $missingRoutes = [System.Collections.ArrayList]@()
    foreach ($nodeRoute in $WindowsNodeRoutes) {
        $routeResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "ip -4 route show $($nodeRoute.PodCIDR)" -IgnoreErrors -NoLog
        if (-not $routeResult.Success) {
            $message = "[$logUseCase] Cannot inspect Windows pod route '$($nodeRoute.PodCIDR)' on control plane: $($routeResult.Output)"
            Write-Log $message -Console
            throw $message
        }
        $routeOutput = ($routeResult.Output | Out-String).Trim()
        $expectedGatewayPattern = "(^|\s)via\s+$([regex]::Escape($nodeRoute.InternalIP))(\s|$)"

        if ([string]::IsNullOrWhiteSpace($routeOutput) -or $routeOutput -notmatch $expectedGatewayPattern) {
            $missingRoutes.Add($nodeRoute) | Out-Null
        }
    }

    return $missingRoutes
}

function Restore-ControlPlaneTransitRoute {
    <#
    .SYNOPSIS
        Ensures the control plane has a route to the Windows loopback adapter subnet.
    .DESCRIPTION
        After a reboot or k2s stop/start, the Linux control-plane node may lose its
        route to the Windows loopback adapter subnet (e.g. 172.22.1.0/24). Without this
        route, flannel's host-gw mode cannot install pod subnet routes because the
        gateway (the Windows node's InternalIP on the loopback adapter) is unreachable.
        This function checks for and restores the transit route via the KubeSwitch gateway.
    #>
    $loopbackCIDR = Get-LoopbackAdapterCIDR
    $kubeSwitchIP = Get-ConfiguredKubeSwitchIP

    if ([string]::IsNullOrWhiteSpace($loopbackCIDR) -or [string]::IsNullOrWhiteSpace($kubeSwitchIP)) {
        Write-Log "[$logUseCase] WARNING: Cannot restore transit route - loopbackCIDR='$loopbackCIDR', kubeSwitchIP='$kubeSwitchIP'"
        return
    }

    $routeCheckCmd = "ip -4 route show $loopbackCIDR"
    $routeResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $routeCheckCmd -IgnoreErrors -NoLog
    if (-not $routeResult.Success) {
        $message = "[$logUseCase] Cannot inspect transit route '$loopbackCIDR' on control plane: $($routeResult.Output)"
        Write-Log $message -Console
        throw $message
    }
    $existingRoute = ($routeResult.Output | Out-String).Trim()

    if (-not [string]::IsNullOrWhiteSpace($existingRoute) -and $existingRoute -match "(^|\s)via\s+$([regex]::Escape($kubeSwitchIP))(\s|$)") {
        Write-Log "[$logUseCase] Transit route to $loopbackCIDR via $kubeSwitchIP already exists on control plane"
        return
    }

    Write-Log "[$logUseCase] Transit route to $loopbackCIDR missing or incorrect on control plane, restoring via $kubeSwitchIP" -Console
    $addRouteCmd = "sudo ip route replace $loopbackCIDR via $kubeSwitchIP"
    $addResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $addRouteCmd -IgnoreErrors
    if ($addResult.Success) {
        Write-Log "[$logUseCase] Transit route to $loopbackCIDR via $kubeSwitchIP restored successfully"
    }
    else {
        $addOutput = ($addResult.Output | Out-String).Trim()
        $message = "[$logUseCase] Failed to restore transit route to $loopbackCIDR via $kubeSwitchIP - $addOutput"
        Write-Log $message -Console
        throw $message
    }
}

function Restart-FlannelDaemonSetWithWindowsRouteRepair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$KubeConfigPath,
        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 3
    )

    # Ensure the control plane can reach the Windows loopback adapter subnet
    # before attempting flannel restart. After reboot or stop/start, this transit
    # route may be missing, causing flannel's host-gw route additions to fail
    # with "network is unreachable".
    Restore-ControlPlaneTransitRoute

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $windowsNodeRouteResult = Get-WindowsWorkerNodeRoutes -KubeConfigPath $KubeConfigPath
        if (-not $windowsNodeRouteResult.Success) {
            Write-Log "[$logUseCase] WARNING: Skipping route validation on attempt $attempt/$MaxAttempts because Windows node query failed"
            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds 5
                continue
            }

            throw "[$logUseCase] Cannot validate Windows pod routes after $MaxAttempts attempts"
        }

        $windowsNodeRoutes = $windowsNodeRouteResult.Routes

        if ($windowsNodeRoutes.Count -eq 0) {
            Write-Log "[$logUseCase] No Windows worker nodes found, restarting flannel daemonset once"
            $restartResult = Invoke-KubectlWithKubeConfig -KubeConfigPath $KubeConfigPath -Params @('rollout', 'restart', 'daemonset/kube-flannel-ds', '-n', 'kube-flannel')
            $restartResult.Output | Write-Log
            if (-not $restartResult.Success) {
                throw "[$logUseCase] Failed to restart flannel: $($restartResult.Output)"
            }
            return
        }

        Write-Log "[$logUseCase] Restarting flannel daemonset with Windows route validation (attempt $attempt/$MaxAttempts)"
        Wait-ForControlPlaneTransitReachability -WindowsNodeRoutes $windowsNodeRoutes -TimeoutSeconds 120 -DelaySeconds 5 | Out-Null

        $restartResult = Invoke-KubectlWithKubeConfig -KubeConfigPath $KubeConfigPath -Params @('rollout', 'restart', 'daemonset/kube-flannel-ds', '-n', 'kube-flannel')
        $restartResult.Output | Write-Log
        if (-not $restartResult.Success) {
            throw "[$logUseCase] Failed to restart flannel: $($restartResult.Output)"
        }

        $statusResult = Invoke-KubectlWithKubeConfig -KubeConfigPath $KubeConfigPath -Params @('rollout', 'status', 'daemonset/kube-flannel-ds', '-n', 'kube-flannel', '--timeout=120s')
        if ($statusResult.Success) {
            $statusResult.Output | Write-Log
        }
        else {
            Write-Log "[$logUseCase] WARNING: Flannel daemonset rollout status check failed: $($statusResult.Output)"
        }

        $missingRoutes = Get-MissingWindowsPodRoutesOnControlPlane -WindowsNodeRoutes $windowsNodeRoutes
        if ($statusResult.Success -and $missingRoutes.Count -eq 0) {
            Write-Log "[$logUseCase] Flannel host-gw routes to Windows pod CIDR(s) are present"
            return
        }

        if ($missingRoutes.Count -gt 0) {
            $missingRouteDescriptions = $missingRoutes | ForEach-Object { "$($_.PodCIDR) via $($_.InternalIP) ($($_.NodeName))" }
            Write-Log "[$logUseCase] WARNING: Missing flannel route(s) after restart: $($missingRouteDescriptions -join '; ')"
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds 5
        }
    }

    throw "[$logUseCase] Could not repair flannel host-gw route(s) to Windows nodes after $MaxAttempts attempts"
}

function Stop-StartupNetworkingServices {
    foreach ($serviceName in @('kubeproxy', 'kubelet', 'flanneld')) {
        Stop-Service -Name $serviceName -Force -NoWait -ErrorAction Stop
        if (-not (Wait-ForServiceStopped -ServiceName $serviceName -MaxRetries 10 -SleepSeconds 1)) {
            throw "[$logUseCase] Cannot recover startup networking: service '$serviceName' did not stop"
        }
    }
}

function Initialize-StartupWindowsNetwork {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 5)]
        [int]$MaxAttempts = 3,
        [string]$PodSubnetworkNumber = '1'
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "[$logUseCase] Stabilizing Windows startup network (attempt $attempt/$MaxAttempts)"
        Stop-StartupNetworkingServices
        Test-DefaultSwitch -ResolveConflict -SwitchObservationSeconds 30
        try {
            Confirm-LoopbackAdapterIP
            Remove-FlannelConflictingRoutesOnLoopback
            Start-Service -Name 'flanneld' -ErrorAction Stop
            if (-not (Wait-ForServiceRunning -ServiceName 'flanneld')) {
                throw "[$logUseCase] flanneld did not start during Windows network recovery"
            }
            Wait-NetworkL2BridgeReady -PodSubnetworkNumber $PodSubnetworkNumber
            Add-HostBridgeIpReservation -PodSubnetworkNumber $PodSubnetworkNumber
            Test-DefaultSwitch -SwitchObservationSeconds 30
        }
        catch {
            $startupError = $_
            # A late collision can prevent cbr0 readiness before the final check.
            try {
                Test-DefaultSwitch
            }
            catch {
                $startupError = $_
            }
            # Retry only a late subnet collision, not an unrelated inspection failure.
            $message = $startupError.Exception.Message
            if (-not $message.StartsWith('[PREREQ-FAILED] Hyper-V Default Switch subnet (') -or
                -not $message.Contains('collides with K2s network configuration')) {
                throw $startupError
            }
            Write-Log "[$logUseCase] Default Switch changed during network initialization: $message" -Console
            Stop-StartupNetworkingServices
            if ($attempt -eq $MaxAttempts) {
                throw $startupError
            }
            continue
        }

        Write-Log "[$logUseCase] Windows startup network validated before Linux route repair"
        return
    }
}

# Ensures flanneld, kubelet, and kubeproxy are running and refreshes Linux-side
# DaemonSets. Called both after L2 bridge recreation (unclean reboot with cbr0
# removed) and when cbr0 survived a reboot but services aren't running.
function Start-K8sNetworkingServices {
    Initialize-StartupWindowsNetwork
    Write-Log "[$logUseCase] Ensuring flanneld, kubelet and kubeproxy are running"

    foreach ($serviceName in @('kubelet', 'kubeproxy')) {
        Start-Service -Name $serviceName -ErrorAction Stop
        if (-not (Wait-ForServiceRunning -ServiceName $serviceName)) {
            throw "[$logUseCase] Service '$serviceName' did not start"
        }
    }

    # Restore kubelet and kubeproxy to auto-start in case Stop-System.ps1
    # set them to SERVICE_DEMAND_START during a previous shutdown.
    $kubeBinPathLocal = Get-KubeBinPath
    if (Test-Path "$kubeBinPathLocal\nssm.exe") {
        Write-Log "[$logUseCase] Restoring kubelet and kubeproxy to auto-start"
        &"$kubeBinPathLocal\nssm.exe" set kubelet Start SERVICE_AUTO_START 2>&1 | Out-Null
        &"$kubeBinPathLocal\nssm.exe" set kubeproxy Start SERVICE_AUTO_START 2>&1 | Out-Null
    }

    # Restart Linux-side system pods to refresh projected service account tokens.
    # After a reboot the API server restarts with potentially new signing keys,
    # making existing projected tokens in kube-proxy and flannel pods invalid
    # (results in Unauthorized errors in their logs).
    # Must use explicit --kubeconfig because this script runs as LOCAL SYSTEM
    # (via httpproxy NSSM service), which has no user-level KUBECONFIG env var.
    $kubeConfigPath = "$(Get-KubePath)\config"
    $controlPlaneHostname = Get-ConfigControlPlaneNodeHostname
    Write-Log "[$logUseCase] Waiting for API server before restarting system DaemonSets (kubeconfig: $kubeConfigPath)..."
    try {
        $apiReady = $false
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            $waitResult = Invoke-KubectlWithKubeConfig -KubeConfigPath $kubeConfigPath -Params @(
                'wait', '--timeout=30s', '--for=condition=Ready', '-n', 'kube-system',
                "pod/kube-apiserver-$($controlPlaneHostname.ToLower())"
            )
            if ($waitResult.Success) {
                $apiReady = $true
                break
            }
            Write-Log "[$logUseCase] API server not ready yet (attempt $attempt/20): $($waitResult.Output)"
            Start-Sleep -Seconds 2
        }
        if ($apiReady) {
            Write-Log "[$logUseCase] Restarting Linux-side system DaemonSets to refresh service account tokens..."
            $proxyRestart = Invoke-KubectlWithKubeConfig -KubeConfigPath $kubeConfigPath -Params @('rollout', 'restart', 'daemonset/kube-proxy', '-n', 'kube-system')
            $proxyRestart.Output | Write-Log
            if (-not $proxyRestart.Success) {
                throw "[$logUseCase] Failed to restart Linux kube-proxy: $($proxyRestart.Output)"
            }
            Restart-FlannelDaemonSetWithWindowsRouteRepair -KubeConfigPath $kubeConfigPath -MaxAttempts 6
            $dnsRestart = Invoke-KubectlWithKubeConfig -KubeConfigPath $kubeConfigPath -Params @('rollout', 'restart', 'deployment/coredns', '-n', 'kube-system')
            $dnsRestart.Output | Write-Log
            if (-not $dnsRestart.Success) {
                throw "[$logUseCase] Failed to restart CoreDNS: $($dnsRestart.Output)"
            }
            Write-Log "[$logUseCase] Linux-side system DaemonSet restart completed"
        } else {
            throw "[$logUseCase] API server not ready after 20 attempts; startup network recovery incomplete"
        }
    } catch {
        Write-Log "[$logUseCase] Failed to restart Linux-side DaemonSets: $_" -Console
        throw
    }
}

try {
    Write-Log "[$logUseCase] started"

    # This must run before Select-K2sIsRunning because the invoking k2s start process
    # is otherwise detected as an already-running operation and skips recovery.
    Write-Log "[$logUseCase] Validating and recovering Hyper-V Default Switch network"
    Test-DefaultSwitch -ResolveConflict -SwitchObservationSeconds 120

    # check if k2s is running
    $k2sRunning = Select-K2sIsRunning
    if ($k2sRunning) {
        Write-Log "[$logUseCase] k2s is running, no need todo anything"
        Write-Log "[$logUseCase] finished"
        return
    }

    # check if there is an HNS network with l2 bridge
    $PodSubnetworkNumber = '1'
    $l2BridgeSwitchName = Get-L2BridgeSwitchName
    $found = Invoke-HNSCommand -Command {
        param($l2BridgeSwitchName)
        Get-HNSNetwork | Where-Object Name -Like $l2BridgeSwitchName
    } -ArgumentList $l2BridgeSwitchName
    if ($found -and -not (Test-NetworkL2BridgeReady -PodSubnetworkNumber $PodSubnetworkNumber)) {
        Write-Log "[$logUseCase] Existing cbr0 network has no healthy endpoint and route; rebuilding it"
        Write-NetworkL2BridgeDiagnostics -PodSubnetworkNumber $PodSubnetworkNumber
        $found = $null
    }
    if ($found) {
        Write-Log "[$logUseCase] External switch with l2 bridge network already exists"
        # cbr0 survived the reboot — Stop-System.ps1 either didn't run or failed
        # to remove it. Check if flanneld is actually running. Since flanneld is
        # always SERVICE_DEMAND_START, it won't be running after a reboot unless
        # something explicitly started it (which only happens via this script or
        # Start-WinHttpProxy). If it's stopped, we need to start all networking
        # services. If it's already running, this is just a normal httpproxy
        # restart (e.g. NSSM auto-restart) and nothing needs to be done.
        $flanneldSvc = Get-Service -Name 'flanneld' -ErrorAction SilentlyContinue
        if ($null -ne $flanneldSvc -and $flanneldSvc.Status -ne 'Running') {
            Write-Log "[$logUseCase] flanneld is not running (status: $($flanneldSvc.Status)) - post-reboot recovery needed"
            Confirm-LoopbackAdapterIP
            Start-K8sNetworkingServices
        }
        else {
            Write-Log "[$logUseCase] flanneld is running, no recovery needed"
        }
    }
    else {
        Write-Log "[$logUseCase] Switch cbr0 with l2 bridge network does not exist, check for Loopback Adapter"
        # need to start the services to see the NIC
        Start-Service -Name 'vmcompute'
        Start-Service -Name 'hns'
        $hns = Get-HNSNetwork
        $hnsNames = $hns | Select-Object -ExpandProperty Name
        $logText = "[$logUseCase] HNS networks available: " + $hnsNames
        Write-Log $logText
        $adapterName = Get-L2BridgeName
        $nic = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
        if ( $null -eq $nic ) {
            Write-Log "[$logUseCase] Loopback Adapter is not there, must be during install"
        }
        else {
            if ( $nic.Status -eq 'Disabled' ) {
                # Adapter is disabled, must be after a stop
                Write-Log "[$logUseCase] Loopback Adapter is disabled, must be a normal startup"
            }
            else {
                # Adapter is enabled, must be after a reboot where no stop was done before
                Write-Log "[$logUseCase] Loopback Adapter is not disabled, must be a start of windows after no stop was done"
                $adapterName = Get-L2BridgeName

                # Stop k8s networking services to prevent race condition with L2 bridge recreation.
                # All NSSM-managed services auto-started after unclean reboot and may have programmed
                # HNS policies against a transient cbr0 that flannel created before Start-System ran.
                # We must stop and restart them so they reprogram policies against the proper cbr0.
                Write-Log "[$logUseCase] Stopping kubeproxy, kubelet and flanneld services..."
                Stop-StartupNetworkingServices

                # Additional delay to ensure flanneld releases all L2 bridge resources
                Start-Sleep -Seconds 2

                Enable-NetAdapter -Name $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                $return = Wait-NetInterfaceAdapterUp -AdapterName $adapterName
                if ($return -eq $true) {
                    $DnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $adapterName
                    Enable-LoopbackAdapter
                    Write-Log "[$logUseCase] Remove and recreate external switch"
                    Remove-ExternalSwitch
                    New-ExternalSwitch -adapterName $adapterName -PodSubnetworkNumber $PodSubnetworkNumber
                    Set-LoopbackAdapterExtendedProperties -AdapterName $adapterName -DnsServers $DnsServers
                    Write-Log "[$logUseCase] External switch recreated successfully, restart networking services"
                    Start-K8sNetworkingServices

                    Write-Log "[$logUseCase] Attempt to repair kubeswitch"
                    Repair-KubeSwitch
                    # Set-PrivateNetworkProfileForLoopbackAdapter
                }
                else {
                    Write-Log "[$logUseCase] ERROR: Could not repair k8s network !"
                    Disable-NetAdapter -Name $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Write-Log "[$logUseCase] Revalidating Hyper-V Default Switch after networking startup"
    Test-DefaultSwitch
    Write-Log "[$logUseCase] finished"
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
}
catch {
    Write-Log "[$logUseCase] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}
