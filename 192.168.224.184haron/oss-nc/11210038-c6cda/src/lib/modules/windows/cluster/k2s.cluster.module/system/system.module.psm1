# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$vmModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\linuxnode\vm\vm.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$vmNodeModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\vmnode\vmnode.module.psm1"

Import-Module $configModule, $logModule, $vmModule, $pathModule, $vmNodeModule

$kubeToolsPath = Get-KubeToolsPath

<#
.SYNOPSIS
Performs time synchronization across all nodes of the clusters.
#>
function Invoke-TimeSync {
    $timezoneStandardNameOnHost = (Get-TimeZone).Id
    $kubeConfigDir = Get-ConfiguredKubeConfigDir
    $windowsTimezoneConfig = "$kubeConfigDir\windowsZones.xml"
    [XML]$timezoneConfigXml = (Get-Content -Path $windowsTimezoneConfig)
    $timezonesLinux = ($timezoneConfigXml.supplementalData.windowsZones.mapTimezones.mapZone | Where-Object { $_.other -eq "$timezoneStandardNameOnHost" }).type
    $canPerformTimeSync = $false
    if ($timezonesLinux.Count -eq 0) {
        Write-Log "No equivalent Linux time zone for Windows time zone $timezoneStandardNameOnHost was found. Cannot perform time synchronization" -Console
        Write-Log 'Please perform time synchronization manually.' -Console
    }
    else {
        $timezoneLinux = $timezonesLinux[0]

        # Normalize legacy IANA timezone aliases removed in Debian 13 (trixie).
        # These names were deprecated by the IANA tz database and are no longer
        # present in the tzdata package shipped with Debian 13.
        $legacyAliases = @{
            'Asia/Calcutta'    = 'Asia/Kolkata'
            'Europe/Kiev'      = 'Europe/Kyiv'
            'Asia/Katmandu'    = 'Asia/Kathmandu'
            'Asia/Rangoon'     = 'Asia/Yangon'
            'Asia/Saigon'      = 'Asia/Ho_Chi_Minh'
            'America/Godthab'  = 'America/Nuuk'
        }
        if ($legacyAliases.ContainsKey($timezoneLinux)) {
            $normalized = $legacyAliases[$timezoneLinux]
            Write-Log "[TimeSync] Normalizing legacy timezone alias '$timezoneLinux' -> '$normalized'"
            $timezoneLinux = $normalized
        }

        $canPerformTimeSync = $true
    }

    if ($canPerformTimeSync) {
        Write-Log 'Performing time synchronization between nodes'

        #Set timezone in kubemaster
        (Invoke-CmdOnControlPlaneViaSSHKey "sudo timedatectl set-timezone $timezoneLinux 2>&1").Output | Write-Log

        # Directly set the VM system clock from the Windows host UTC time.
        # This is more reliable than 'hwclock --hctosys' in offline environments
        # where NTP is unreachable and the Hyper-V emulated RTC may have drifted
        # or be misinterpreted (e.g. UTC vs local time offset).
        $utcTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        Write-Log "[TimeSync] Setting VM clock to host UTC time: $utcTime"
        (Invoke-CmdOnControlPlaneViaSSHKey "sudo date -u -s '$utcTime' 2>&1").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo hwclock -w 2>&1').Output | Write-Log
    }
}

function Write-ImageRepairHint {
    Write-Log "[ControlPlane] Hint: if control-plane images were lost (e.g. after an unclean shutdown), run 'k2s image repair' to restore them from the local archives." -Console
}

function Wait-ForAPIServer {
    $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
    $iteration = 0
    while ($true) {
        $iteration++
        # try to apply the flannel resources
        $ErrorActionPreference = 'Continue'
        $result = $(echo yes | &"$kubeToolsPath\kubectl.exe" wait --timeout=60s --for=condition=Ready -n kube-system "pod/kube-apiserver-$($controlPlaneVMHostName.ToLower())" 2>&1)
        $ErrorActionPreference = 'Stop'
        if ($result -match 'condition met') {
            break;
        }
        if ($iteration -eq 10) {
            Write-Log $result -Error
            Write-ImageRepairHint
            throw $result
        }
        Start-Sleep 2
    }
    if ($iteration -eq 1) {
        Write-Log 'API Server running, no waiting needed'
    }
    else {
        Write-Log 'API Server now running'
    }
}

function Wait-ForControlPlanePodsReady {
    param (
        [Parameter(Mandatory = $false)]
        [int] $TimeoutSeconds = 300,
        [Parameter(Mandatory = $false)]
        [switch] $SuppressRepairHint
    )

    $controlPlaneVMHostName = (Get-ConfigControlPlaneNodeHostname).ToLower()
    $kubeToolsPath = Get-KubeToolsPath
    $pods = @(
        "etcd-$controlPlaneVMHostName",
        "kube-apiserver-$controlPlaneVMHostName",
        "kube-controller-manager-$controlPlaneVMHostName",
        "kube-scheduler-$controlPlaneVMHostName"
    )

    Write-Log "[ControlPlane] Waiting for control-plane pods to be Ready (timeout: ${TimeoutSeconds}s)"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($pod in $pods) {
        $remainingSeconds = $TimeoutSeconds - [int]$stopwatch.Elapsed.TotalSeconds
        if ($remainingSeconds -le 0) {
            throw "Timed out waiting for control-plane pods to become Ready after ${TimeoutSeconds}s"
        }

        Write-Log "[ControlPlane] Waiting for pod '$pod' to be Ready (${remainingSeconds}s remaining)"

        $ErrorActionPreference = 'Continue'
        $result = &"$kubeToolsPath\kubectl.exe" wait --timeout="$($remainingSeconds)s" --for=condition=Ready -n kube-system "pod/$pod" 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'

        if ($exitCode -ne 0 -or $result -notmatch 'condition met|condition satisfied') {
            Write-Log "[ControlPlane] Pod '$pod' did not become Ready: $result" -Error

            $describeResult = &"$kubeToolsPath\kubectl.exe" describe pod -n kube-system $pod 2>&1
            Write-Log "[ControlPlane] Diagnostics for pod '$pod': $describeResult" -Error

            if (-not $SuppressRepairHint) {
                if ("$result $describeResult" -match 'ErrImagePull|ImagePullBackOff|image not known|failed to pull|image .* not found') {
                    Write-Log "[ControlPlane] Control-plane images appear to be missing from the CRI-O image store." -Console
                }
                Write-ImageRepairHint
            }

            throw "Control-plane pod '$pod' did not become Ready within ${TimeoutSeconds}s: $result"
        }
    }

    Write-Log '[ControlPlane] All control-plane pods are Ready'
}

<#
.SYNOPSIS
    Sets the correct labels and taints for the nodes.
.DESCRIPTION
    Sets the correct labels and taints for the K8s nodes.
.PARAMETER WorkerMachineName
    Optional: Name of the (Windows) worker node
.EXAMPLE
    # consider control-plane-only (i.e. hostname in KubeMaster VM, e.g. kubemaster)
    Update-NodeLabelsAndTaints
.EXAMPLE
    # consider control-plane and (Windows) worker node
    Update-NodeLabelsAndTaints -WorkerMachineName 'my-win-machine'
#>
function Update-NodeLabelsAndTaints {
    param (
        [Parameter(Mandatory = $false)]
        [string] $WorkerMachineName
    )
    Write-Log 'Updating node labels and taints...'
    Write-Log 'Waiting for K8s API server to be ready...'

    Wait-ForAPIServer

    $controlPlaneTaint = 'node-role.kubernetes.io/control-plane'

    # mark control-plane as worker (remove the control-plane tainting)
    (&"$kubeToolsPath\kubectl.exe" get nodes -o=jsonpath='{range .items[*]}~{.metadata.name}#{.spec.taints[*].key}') -split '~' | ForEach-Object {
        $parts = $_ -split '#'

        if ($parts[1] -match $controlPlaneTaint) {
            $node = $parts[0]

            Write-Log "Taint '$controlPlaneTaint' found on node '$node', untainting..."

            &"$kubeToolsPath\kubectl.exe" taint nodes $node "$controlPlaneTaint-"
        }
    }

    if ([string]::IsNullOrEmpty($WorkerMachineName) -eq $false) {
        $nodeName = $WorkerMachineName.ToLower()

        Write-Log "Labeling and tainting worker node '$nodeName'..."

        # mark nodes as worker
        &"$kubeToolsPath\kubectl.exe" label nodes $nodeName kubernetes.io/role=worker --overwrite

        # taint windows nodes
        &"$kubeToolsPath\kubectl.exe" taint nodes $nodeName OS=Windows:NoSchedule --overwrite
    }
}

function Get-Cni0IpAddressInControlPlaneUsingSshWithRetries {
    param (
        [int] $Retries,
        [int] $RetryTimeoutInSeconds
    )
    $ipAddr = ''
    for ($i = 1; $i -le $Retries; ++$i) {
        $rawOutput = (Invoke-CmdOnControlPlaneViaSSHKey "ip addr show dev cni0 | grep 'inet ' | awk '{print `$2}' | cut -d/ -f1" -NoLog).Output
        
        # Handle case where output might be an array (e.g., when SSH warnings are on separate lines)
        if ($rawOutput -is [array]) {
            $combinedOutput = $rawOutput -join ' '
        } else {
            $combinedOutput = [string]$rawOutput
        }
        
        # Try to extract valid IP address from potentially contaminated output
        if ($combinedOutput -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') {
            $ipAddr = $matches[1]
        } else {
            $ipAddr = $combinedOutput.Trim()
        }
        
        $isIpAddress = [bool]($ipAddr -as [ipaddress])
        if ($isIpAddress) {
            return $ipAddr
        }
        if ($i -lt $Retries) {
            Start-Sleep -s $RetryTimeoutInSeconds
        }
    }
    return $ipAddr
}

function Get-AssignedPodSubnetworkNumber {
    param (
        [string] $NodeName = $(throw 'Argument missing: NodeName')
    )

    $maxRetries = 3
    $retryDelay = 5  # seconds
    $attempt = 0
    $podCIDR = $null
    $success = $false

    while ($attempt -lt $maxRetries) {
        $attempt++
        Write-Log "Attempt $attempt Trying to get podCIDR for node $NodeName..."

        # Run the kubectl command
        $podCIDR = &"$kubeToolsPath\kubectl.exe" get nodes $NodeName -o jsonpath="'{.spec.podCIDR}'"
        $success = ($LASTEXITCODE -eq 0 -and $podCIDR -ne '' -and $podCIDR -ne "''")

        if ($success) {
            Write-Log "Found podCIDR $podCIDR"
            break
        }
        else {
            Write-Log "Attempt $attempt failed or podCIDR is empty. Retrying in $retryDelay seconds..."
            Start-Sleep -Seconds $retryDelay
        }
    }

    $subnetNumber = ''

    if ($success) {
        $searchPattern = "^'\d{1,3}\.\d{1,3}\.(?<subnet>\d{1,3})\.\d{1,3}\/24'$"
        $m = [regex]::Matches($podCIDR, $searchPattern)
        if (-not $m[0]) { throw "Cannot get subnet number from '$podCIDR'." }
        $subnetNumber = $m[0].Groups['subnet'].Value
    }
    else {
        Write-Log "[ERR] Failed to get podCIDR for node $NodeName" -Console
    }
    return [pscustomobject]@{ Success = $success; PodSubnetworkNumber = $subnetNumber }
}

function Get-AssignedPodNetworkCIDR {
    param (
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $UserPwd = '',
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $getPodCidrCommand = "kubectl get nodes $NodeName -o jsonpath=`"{.spec.podCIDR}`""
    if ([string]::IsNullOrWhiteSpace($UserPwd)) {
        $cmdExecutionResult = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $getPodCidrCommand -UserName $UserName -IpAddress $IpAddress)
    }
    else {
        $remoteUser = "$UserName@$IpAddress"
        $cmdExecutionResult = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $getPodCidrCommand -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd")
    }

    $success = $cmdExecutionResult.Success
    $rawOutput = $cmdExecutionResult.Output

    if ($success) {
        # Handle case where output might be an array (e.g., when SSH warnings are on separate lines)
        $podNetworkCIDR = ''
        if ($rawOutput -is [array]) {
            # Join array elements and search for CIDR pattern
            $combinedOutput = $rawOutput -join ' '
        } else {
            $combinedOutput = [string]$rawOutput
        }
        
        # Validate the CIDR format
        if ([string]::IsNullOrWhiteSpace($combinedOutput)) {
            throw "The retrieved pod network CIDR for the node '$NodeName' is empty, null or contain only whitespaces"
        }
        
        # Clean and validate CIDR format (should be like 172.20.0.0/24)
        $combinedOutput = $combinedOutput.Trim()
        
        # Extract only the CIDR if SSH warnings contaminated the output
        # Pattern: 172.20.0.0/24 close - IO is still pending...
        if ($combinedOutput -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2})') {
            $podNetworkCIDR = $matches[1]
        } else {
            $podNetworkCIDR = $combinedOutput
        }
        
        if ($podNetworkCIDR -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
            throw "The retrieved pod network CIDR for the node '$NodeName' has invalid format: '$podNetworkCIDR'. Expected format: x.x.x.x/xx (raw output was: '$combinedOutput')"
        }
    } else {
        $podNetworkCIDR = ''
    }
    
    return [pscustomobject]@{ Success = $cmdExecutionResult.Success; PodNetworkCIDR = $podNetworkCIDR }
}

Export-ModuleMember Invoke-TimeSync,
Wait-ForAPIServer,
Wait-ForControlPlanePodsReady,
Update-NodeLabelsAndTaints,
Get-Cni0IpAddressInControlPlaneUsingSshWithRetries,
Get-AssignedPodSubnetworkNumber,
Get-AssignedPodNetworkCIDR
