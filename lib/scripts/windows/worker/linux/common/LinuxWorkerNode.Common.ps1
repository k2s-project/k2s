# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

function Import-LinuxWorkerScriptModules {
    Param(
        [switch] $IncludeAddons = $false,
        [switch] $IncludePuttyTools = $false
    )

    $infraModule =   "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
    $nodeModule =    "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
    $clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

    $modulePaths = @($infraModule, $nodeModule, $clusterModule)
    if ($IncludeAddons) {
        $addonsModule = "$PSScriptRoot\..\..\..\..\..\..\addons\addons.module.psm1"
        $modulePaths += $addonsModule
    }

    Import-Module $modulePaths

    if ($IncludePuttyTools) {
        $puttyToolsHelper = "$PSScriptRoot\..\..\..\..\windows\host\system\package\New-K2sPackage.PuttyTools.ps1"
        . $puttyToolsHelper
    }
}

function Initialize-LinuxWorkerScriptEnvironment {
    Param(
        [switch] $ShowLogs = $false,
        [switch] $IncludeAddons = $false,
        [switch] $IncludePuttyTools = $false
    )

    Import-LinuxWorkerScriptModules -IncludeAddons:$IncludeAddons -IncludePuttyTools:$IncludePuttyTools
    Initialize-Logging -ShowLogs:$ShowLogs

    $installationPath = Get-KubePath
    Set-Location $installationPath
    $ProgressPreference = 'SilentlyContinue'
}

function Assert-LinuxWorkerPuttyToolsReady {
    Param(
        [string] $LogPrefix = '[NodeAdd]',
        [string] $Proxy = ''
    )

    $puttyToolsHelper = "$PSScriptRoot\..\..\..\..\windows\host\system\package\New-K2sPackage.PuttyTools.ps1"
    . $puttyToolsHelper

    Assert-PuttyToolsReady -LogPrefix $LogPrefix -Proxy $Proxy
}

function Assert-LinuxWorkerNodeSshConnectivity {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $LogPrefix = '[NodeAdd]',
        [string] $TargetDescription = 'node'
    )

    $connectionCheck = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which ls' -UserName $UserName -IpAddress $IpAddress
    if (!$connectionCheck.Success) {
        throw "$LogPrefix Cannot connect to $TargetDescription with IP '$IpAddress'. Error: $($connectionCheck.Output)"
    }
}

function Assert-LinuxWorkerNodeAuthorizedKey {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $LogPrefix = '[NodeAdd]'
    )

    $localPublicKeyFilePath = "$(Get-SSHKeyControlPlane).pub"
    if (!(Test-Path -Path $localPublicKeyFilePath)) {
        throw "$LogPrefix Precondition not met: SSH public key file '$localPublicKeyFilePath' must exist."
    }
    $localPublicKey = (Get-Content -Raw $localPublicKeyFilePath).Trim()
    if ([string]::IsNullOrWhiteSpace($localPublicKey)) {
        throw "$LogPrefix Precondition not met: SSH public key file '$localPublicKeyFilePath' is empty."
    }

    $authorizedKeysFilePath = '~/.ssh/authorized_keys'
    $authorizedKeysRaw = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "[ -f $authorizedKeysFilePath ] && cat $authorizedKeysFilePath || echo 'File $authorizedKeysFilePath not available'" -UserName $UserName -IpAddress $IpAddress).Output
    $authorizedKeys = if ($authorizedKeysRaw -is [array]) { $authorizedKeysRaw -join "`n" } else { [string]$authorizedKeysRaw }
    $authorizedKeys = $authorizedKeys.Replace("`r", '')
    $normalizedLocalPublicKey = $localPublicKey.Replace("`r", '')
    if (!($authorizedKeys.Contains($normalizedLocalPublicKey))) {
        throw "$LogPrefix Precondition not met: the K2s public key from '$localPublicKeyFilePath' is NOT in '$authorizedKeysFilePath' on the remote machine at $IpAddress. Please add it manually."
    }
}


function Get-LinuxWorkerNodeProvisioningContext {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = '',
        [string] $LogPrefix = '[NodeAdd]',
        [string] $TargetDescription = 'remote computer'
    )

    $actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo $(hostname)' -UserName $UserName -IpAddress $IpAddress).Output
    $k8sFormattedNodeName = $actualHostname.ToLower()

    if (![string]::IsNullOrWhiteSpace($NodeName) -and ($NodeName.ToLower() -ne $k8sFormattedNodeName)) {
        throw "$LogPrefix Precondition not met: the passed NodeName '$NodeName' does not match the hostname '$actualHostname' of the $TargetDescription with IP '$IpAddress'."
    }

    $installedDistribution = Get-InstalledDistribution -UserName $UserName -IpAddress $IpAddress
    $osMessage = "{0} Detected OS on {1}: {2}" -f $LogPrefix, $TargetDescription, $installedDistribution
    Write-Log $osMessage -Console
    Test-SupportedWorkerOS -OS $installedDistribution

    $architecture = Get-RemoteArchitecture -UserName $UserName -IpAddress $IpAddress
    $archMessage = "{0} Detected architecture on {1}: {2}" -f $LogPrefix, $TargetDescription, $architecture
    Write-Log $archMessage -Console

    # arm64 is only supported on Debian-family external nodes today (K2s issue #3052); fail
    # fast here, before any package download or remote mutation starts, rather than failing
    # deep into provisioning. Generic to the Debian family, not tied to a single release.
    if ($architecture -eq 'arm64' -and $installedDistribution -notlike 'debian*') {
        throw "$LogPrefix Unsupported architecture/distro combination: architecture 'arm64' is only supported on Debian-family distributions, detected OS '$installedDistribution' on $TargetDescription with IP '$IpAddress'."
    }

    # Check only node names (not entire output) to avoid false positives from OS-IMAGE column
    $existingNodeNames = @((Invoke-Kubectl -Params @('get', 'nodes', '-o', 'jsonpath={.items[*].metadata.name}')).Output -split '\s+' | Where-Object { $_ })
    if ($existingNodeNames -contains $k8sFormattedNodeName) {
        throw "$LogPrefix Precondition not met: node '$k8sFormattedNodeName' is already part of the cluster."
    }

    [PSCustomObject]@{
        ActualHostname         = $actualHostname
        KubernetesNodeName     = $k8sFormattedNodeName
        InstalledDistribution  = $installedDistribution
        Architecture           = $architecture
    }
}

function Disable-LinuxWorkerNodeSwap {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $LogPrefix = '[NodeAdd]'
    )

    Write-Log "$LogPrefix Disabling swap on remote node at $IpAddress" -Console
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapon --show' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "swapFiles=`$(cat /proc/swaps | awk 'NR>1 {print `$1}')" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapoff -a' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "for swapFile in `$swapFiles; do sudo rm '`$swapFile'; done" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo sed -i '/\sswap\s/d' /etc/fstab" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapon --show' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    Write-Log "$LogPrefix Swap disabled successfully" -Console
}

<#
.SYNOPSIS
Starts kubelet and container runtime services on a Linux worker node.

.DESCRIPTION
Connects to a remote Linux worker node via SSH and starts crio/containerd and kubelet services.
This is used when starting individual nodes (via --node flag) to ensure they transition back to Ready.

.PARAMETER NodeName
The name of the worker node.

.PARAMETER IpAddress
The IP address of the worker node.

.PARAMETER UserName
The SSH username for the remote connection.

.PARAMETER LogPrefix
Prefix for log messages (e.g., '[LocalVM]', '[BareMetal]').
#>
function Start-LinuxWorkerNodeServices {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [switch] $WaitForReady = $false,
        [string] $LogPrefix = '[Worker]'
    )

    $workerNodeName = $NodeName.ToLower()

    $sshProbeToken = 'k2s-ssh-ok'
    $sshProbeCmd = "echo $sshProbeToken"
    $startServicesCmd = 'sudo systemctl start crio 2>/dev/null || true; sudo systemctl start containerd 2>/dev/null || true; sudo systemctl start kubelet'
    $maxSshRetries = 12
    $retryDelaySeconds = 5
    $sshProbeTimeoutSeconds = 5
    $startServicesTimeoutSeconds = 60
    $sshProbeResult = $null
    $sshProbeSucceeded = $false
    $startServicesResult = $null
    $waitingLogged = $false

    for ($attempt = 1; $attempt -le $maxSshRetries; $attempt++) {
        $sshProbeResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $sshProbeCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$true -ExecutionTimeoutSeconds $sshProbeTimeoutSeconds
        $sshProbeOutput = if ($sshProbeResult.Output -is [array]) { $sshProbeResult.Output -join "`n" } else { [string]$sshProbeResult.Output }
        $sshProbeSucceeded = $sshProbeResult.Success -or ($sshProbeOutput -match [regex]::Escape($sshProbeToken))

        if ($sshProbeSucceeded) {
            if (-not $sshProbeResult.Success) {
                Write-Log "$LogPrefix SSH probe token received from '$workerNodeName' despite non-zero ssh exit code; continuing."
            }
            break
        }

        if ($attempt -lt $maxSshRetries) {
            if (-not $waitingLogged) {
                Write-Log "$LogPrefix Waiting for SSH connection to node '$workerNodeName'..." -Console
                $waitingLogged = $true
            }
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }

    if (-not $sshProbeSucceeded) {
        Write-Log "$LogPrefix Failed to establish SSH connection to '$workerNodeName' after retries: $($sshProbeResult.Output)" -Console

        try {
            $tcpCheck = Test-NetConnection -ComputerName $IpAddress -Port 22 -WarningAction SilentlyContinue
            Write-Log "$LogPrefix Connectivity check for '$IpAddress': Ping=$($tcpCheck.PingSucceeded), Tcp22=$($tcpCheck.TcpTestSucceeded)"

            $matchingVmAdapters = @(Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue | Where-Object {
                @($_.IPAddresses) -contains $IpAddress
            })

            if ($matchingVmAdapters.Count -eq 0) {
                Write-Log "$LogPrefix No Hyper-V VM adapter currently reports guest IP '$IpAddress'. The VM may have lost this IP (check 'ip address' / netplan inside the Linux VM)." -Console
            } else {
                $switches = ($matchingVmAdapters | Select-Object -ExpandProperty SwitchName -Unique) -join ', '
                Write-Log "$LogPrefix Hyper-V adapter for '$IpAddress' is attached to switch(es): $switches"
            }

            $staleNodeAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like 'vEthernet (k2s-node-*'
            })
            if ($staleNodeAdapters.Count -gt 3) {
                Write-Log "$LogPrefix Detected $($staleNodeAdapters.Count) 'vEthernet (k2s-node-*)' adapters on host. This can interfere with local VM reachability after full stop/start."
            }
        } catch {
            Write-Log "$LogPrefix Failed to collect SSH failure diagnostics: $($_.Exception.Message)"
        }

        throw "$LogPrefix Failed to establish SSH connection to node '$workerNodeName' ($IpAddress) after $maxSshRetries retries"
    }

    $startServicesResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $startServicesCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$true -ExecutionTimeoutSeconds $startServicesTimeoutSeconds
    
    if ($startServicesResult.Success) {
        Write-Log "$LogPrefix Started kubelet/runtime services on '$workerNodeName'"

        if ($WaitForReady) {
            $maxRetries = 30
            $retryIntervalSeconds = 2
            $totalTimeoutSeconds = $maxRetries * $retryIntervalSeconds
            Write-Log "$LogPrefix Waiting for node '$workerNodeName' to transition to Ready (max ~$totalTimeoutSeconds seconds)..." -Console
            $retryCount = 0
            while ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds $retryIntervalSeconds
                $nodeStatusOutput = (Invoke-Kubectl -Params @('get', 'node', $workerNodeName, '--no-headers')).Output | Out-String
                $nodeStatus = $nodeStatusOutput.Trim()
                if (-not [string]::IsNullOrWhiteSpace($nodeStatus) -and $nodeStatus -match '\s+Ready(?:\s|,)') {
                    Write-Log "$LogPrefix Node '$workerNodeName' is now Ready" -Console
                    return
                }
                $retryCount++
            }
            Write-Log "$LogPrefix Timeout waiting for node '$workerNodeName' to become Ready" -Console
            throw "$LogPrefix Node '$workerNodeName' did not transition to Ready within $totalTimeoutSeconds seconds after starting services"
        }
    } else {
        $errorOutput = ($startServicesResult.Output | Out-String).Trim()
        Write-Log "$LogPrefix Service start command returned non-zero for '$workerNodeName': $errorOutput" -Console

        # The systemctl start command may return non-zero even when services are already running.
        # Verify actual service state before deciding to fail.
        $verifyCmd = 'systemctl is-active kubelet 2>/dev/null'
        $verifyResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $verifyCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$true -ExecutionTimeoutSeconds 10
        $kubeletStatus = ($verifyResult.Output | Out-String).Trim()

        if ($kubeletStatus -eq 'active') {
            Write-Log "$LogPrefix kubelet is active on '$workerNodeName' despite non-zero start exit code; continuing." -Console

            if ($WaitForReady) {
                $maxRetries = 30
                $retryIntervalSeconds = 2
                $totalTimeoutSeconds = $maxRetries * $retryIntervalSeconds
                Write-Log "$LogPrefix Waiting for node '$workerNodeName' to transition to Ready (max ~$totalTimeoutSeconds seconds)..." -Console
                $retryCount = 0
                while ($retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds $retryIntervalSeconds
                    $nodeStatusOutput = (Invoke-Kubectl -Params @('get', 'node', $workerNodeName, '--no-headers')).Output | Out-String
                    $nodeStatus = $nodeStatusOutput.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($nodeStatus) -and $nodeStatus -match '\s+Ready(?:\s|,)') {
                        Write-Log "$LogPrefix Node '$workerNodeName' is now Ready" -Console
                        return
                    }
                    $retryCount++
                }
                Write-Log "$LogPrefix Timeout waiting for node '$workerNodeName' to become Ready" -Console
                throw "$LogPrefix Node '$workerNodeName' did not transition to Ready within $totalTimeoutSeconds seconds after starting services"
            }
            return
        }

        # kubelet truly not running — collect diagnostics and throw
        Write-Log "$LogPrefix Failed to start kubelet/runtime services on '$workerNodeName' (kubelet status: $kubeletStatus)" -Console
        try {
            $diagCmd = 'journalctl -u kubelet -u crio -u containerd --no-pager -n 50 2>/dev/null; echo "---SERVICE-STATUS---"; systemctl is-active kubelet crio containerd 2>/dev/null'
            $diagResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $diagCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$true -ExecutionTimeoutSeconds 15
            $diagOutput = ($diagResult.Output | Out-String).Trim()
            Write-Log "$LogPrefix Service diagnostics from '$workerNodeName':`n$diagOutput"
        }
        catch {
            Write-Log "$LogPrefix Failed to collect service diagnostics from '$workerNodeName': $($_.Exception.Message)"
        }

        throw "$LogPrefix Failed to start kubelet/runtime services on '$workerNodeName': $errorOutput"
    }
}

<#
.SYNOPSIS
Resolves node SSH credentials from cluster config and starts kubelet/runtime services.

.DESCRIPTION
Looks up the node's IpAddress and Username from the cluster config, then calls
Start-LinuxWorkerNodeServices. Logs a warning if the config entry is incomplete.
Used by both bare-metal and local-vm Start.ps1 scripts when --node is specified.

.PARAMETER NodeName
The name of the worker node (as registered in the cluster config).

.PARAMETER LogPrefix
Prefix for log messages (e.g., '[LocalVM]', '[BareMetal]').
#>
function Invoke-LinuxWorkerNodeStart {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [switch] $WaitForReady = $false,
        [string] $LogPrefix = '[Worker]'
    )

    $workerNodeName = $NodeName.ToLower()
    $nodeConfig = Get-NodeConfig -NodeName $workerNodeName
    $nodeUserName = ''
    if ($null -ne $nodeConfig) {
        $nodeUserName = $nodeConfig.UserName
        if ([string]::IsNullOrWhiteSpace($nodeUserName)) {
            $nodeUserName = $nodeConfig.Username
        }
    }

    if ($null -ne $nodeConfig -and -not [string]::IsNullOrWhiteSpace($nodeUserName) -and -not [string]::IsNullOrWhiteSpace($nodeConfig.IpAddress)) {
        try {
            Start-LinuxWorkerNodeServices -NodeName $workerNodeName -IpAddress $nodeConfig.IpAddress -UserName $nodeUserName -WaitForReady:$WaitForReady -LogPrefix $LogPrefix
        }
        catch {
            Write-Log "$LogPrefix Error starting services on node '$workerNodeName': $($_.Exception.Message)" -Console
            throw
        }
    } else {
        Write-Log "$LogPrefix Cannot start kubelet/runtime on node '$workerNodeName' because Username/IpAddress is missing in cluster config." -Console
    }
}

<#
.SYNOPSIS
Stops kubelet and container runtime services on a Linux worker node and optionally waits for node to transition to NotReady.

.DESCRIPTION
Connects to a remote Linux worker node via SSH and stops kubelet, crio, and containerd services.
If -WaitForNotReady is specified, polls the node status until it transitions to NotReady state or timeout occurs.
This is used when stopping individual nodes (via --node flag) to ensure they transition to NotReady.

.PARAMETER NodeName
The name of the worker node.

.PARAMETER IpAddress
The IP address of the worker node.

.PARAMETER UserName
The SSH username for the remote connection.

.PARAMETER WaitForNotReady
If specified, waits for the node to transition to NotReady state (up to 60 seconds).

.PARAMETER LogPrefix
Prefix for log messages (e.g., '[LocalVM]', '[BareMetal]').
#>
function Stop-LinuxWorkerNodeServices {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [switch] $WaitForNotReady = $false,
        [string] $LogPrefix = '[Worker]'
    )

    $workerNodeName = $NodeName.ToLower()

    $stopServicesCmd = 'sudo systemctl stop kubelet; sudo systemctl stop crio || true; sudo systemctl stop containerd || true'
    $stopServicesResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $stopServicesCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$true
    
    if ($stopServicesResult.Success) {
        Write-Log "$LogPrefix Stopped kubelet/runtime services on '$workerNodeName'"
        
        if ($WaitForNotReady) {
            Write-Log "$LogPrefix Waiting for node '$workerNodeName' to transition to NotReady (max ~60 seconds)..." -Console
            # Poll kubectl to wait for node to NOT be Ready. Since kubectl wait doesn't support negative conditions directly,
            # we poll with timeout
            $maxRetries = 30
            $retryCount = 0
            while ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 2
                $nodeStatusOutput = (Invoke-Kubectl -Params @('get', 'node', $workerNodeName, '--no-headers')).Output | Out-String
                $nodeStatus = $nodeStatusOutput.Trim()
                if (-not [string]::IsNullOrWhiteSpace($nodeStatus) -and -not ($nodeStatus -match '\s+Ready\s+')) {
                    Write-Log "$LogPrefix Node '$workerNodeName' is now NotReady" -Console
                    return
                }
                $retryCount++
            }
            Write-Log "$LogPrefix Timeout waiting for node to become NotReady (this may be normal)" -Console
        } else {
            Write-Log "$LogPrefix Node readiness can take up to ~50 seconds to flip from Ready to NotReady." -Console
            Write-Log "$LogPrefix Use stop command with wait option to wait for the state change." -Console
        }
    } else {
        Write-Log "$LogPrefix Failed to stop kubelet/runtime services on '$workerNodeName': $($stopServicesResult.Output)"
    }
}

<#
.SYNOPSIS
Resolves node SSH credentials from cluster config and stops kubelet/runtime services.

.DESCRIPTION
Looks up the node's IpAddress and Username from the cluster config, then calls
Stop-LinuxWorkerNodeServices. Logs a warning if the config entry is incomplete.
Used by both bare-metal and local-vm Stop.ps1 scripts when --node is specified.

.PARAMETER NodeName
The name of the worker node (as registered in the cluster config).

.PARAMETER WaitForNotReady
If specified, waits for the node to transition to NotReady state (up to 60 seconds).

.PARAMETER LogPrefix
Prefix for log messages (e.g., '[LocalVM]', '[BareMetal]').
#>
function Invoke-LinuxWorkerNodeStop {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [switch] $WaitForNotReady = $false,
        [string] $LogPrefix = '[Worker]'
    )

    $workerNodeName = $NodeName.ToLower()
    $nodeConfig = Get-NodeConfig -NodeName $workerNodeName
    $nodeUserName = ''
    if ($null -ne $nodeConfig) {
        $nodeUserName = $nodeConfig.UserName
        if ([string]::IsNullOrWhiteSpace($nodeUserName)) {
            $nodeUserName = $nodeConfig.Username
        }
    }

    if ($null -ne $nodeConfig -and -not [string]::IsNullOrWhiteSpace($nodeUserName) -and -not [string]::IsNullOrWhiteSpace($nodeConfig.IpAddress)) {
        Stop-LinuxWorkerNodeServices -NodeName $workerNodeName -IpAddress $nodeConfig.IpAddress -UserName $nodeUserName -WaitForNotReady:$WaitForNotReady -LogPrefix $LogPrefix
    } else {
        Write-Log "$LogPrefix Cannot stop kubelet/runtime on node '$workerNodeName' because Username/IpAddress is missing in cluster config."
    }
}
