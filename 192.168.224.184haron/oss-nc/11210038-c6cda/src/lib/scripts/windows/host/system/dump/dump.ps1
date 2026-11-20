# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Dumps K2s system status to target folder.

.DESCRIPTION
Collects information about K2s from the respective nodes into log files and config files.
The log files and config files are later archived into a zip file.

.PARAMETER OpenDumpFolder
If set to $true, then the dump target folder will be opened in Windows explorer afterwards.
For non-interactive sessions, it is recommended to set it to $false.
Default: $true.

.PARAMETER ShowLogs
If set to $true, then the logs are written into the console with more verbosity.

.PARAMETER ZipFileName
Name of the final zip file.

.PARAMETER Nodes
Comma-separated additional node names to collect diagnostics for.

.EXAMPLE
PS> .\dump.ps1
#>

Param (
    [Parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the dump target folder will be opened in Windows explorer afterwards.')]
    [bool] $OpenDumpFolder = $true,

    [Parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the logs are written into the console with more verbosity.')]
    [switch] $ShowLogs,

    [Parameter(Mandatory = $false, HelpMessage = 'Name of the final zip file.')]
    [string] $ZipFileName = '',

    [Parameter(Mandatory = $false, HelpMessage = 'Comma-separated additional node names to collect diagnostics for.')]
    [string] $Nodes = ''
)

$ErrorActionPreference = 'Stop'
if ($Trace) {
    Set-PSDebug -Trace 1
}

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$runningStateModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\runningstate\runningstate.module.psm1"
Import-Module $infraModule, $nodeModule, $runningStateModule

Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile

function Invoke-k2sLogCollection(
    [string] $LogDirectory,
    [string] $LogCollectionDirectory
) {
    if (-not (Test-Path $LogCollectionDirectory)) {
        New-Item -ItemType Directory -Path $LogCollectionDirectory -Force | Out-Null
    }
    Copy-Item -Path "$LogDirectory\*" -Destination $LogCollectionDirectory -Exclude '*.zip' -Force -Recurse
}

function Invoke-k2sConfigCollection(
    [string] $ConfigCollectionDirectory
) {
    if (-not (Test-Path $ConfigCollectionDirectory)) {
        New-Item -ItemType Directory -Path $ConfigCollectionDirectory -Force | Out-Null
    }

    $setupJsonFile = Get-SetupConfigFilePath
    $k2sConfigFile = Get-k2sConfigFilePath

    $Configs = @(
        $setupJsonFile,
        $k2sConfigFile
    )

    foreach ($config in $Configs) {
        Copy-Item -Path $config -Destination $ConfigCollectionDirectory -Force -ErrorAction SilentlyContinue
    }
}

function Write-HostResourceSection(
    [string] $DumpFilePath,
    [string] $Description,
    [scriptblock] $Command
) {
    try {
        (& $Command) | Out-String -Width 512 | Write-OutputIntoDumpFile -DumpFilePath $DumpFilePath -Description $Description
    }
    catch {
        $message = "[HostDiag] Failed to collect '$Description': $($_.Exception.Message)"
        Write-Log $message
        $message | Write-OutputIntoDumpFile -DumpFilePath $DumpFilePath -Description $Description
    }
}

function Invoke-HostResourceUsageCollection(
    [string] $HostDiagnosticsDir
) {
    Write-Log '[HostDiag] Collecting host CPU, memory, and disk usage...'
    $resourcesFile = Join-Path $HostDiagnosticsDir 'resources.txt'

    Write-HostResourceSection -DumpFilePath $resourcesFile -Description 'Host memory summary (Win32_OperatingSystem)' -Command {
        Get-CimInstance Win32_OperatingSystem | Select-Object `
            @{N = 'TotalVisibleMemory(GB)'; E = { [math]::Round($_.TotalVisibleMemorySize / 1MB, 2) } },
            @{N = 'FreePhysicalMemory(GB)'; E = { [math]::Round($_.FreePhysicalMemory / 1MB, 2) } },
            @{N = 'TotalVirtualMemory(GB)'; E = { [math]::Round($_.TotalVirtualMemorySize / 1MB, 2) } },
            @{N = 'FreeVirtualMemory(GB)'; E = { [math]::Round($_.FreeVirtualMemory / 1MB, 2) } },
            NumberOfProcesses,
            LastBootUpTime
    }

    Write-HostResourceSection -DumpFilePath $resourcesFile -Description 'Host CPU summary (Win32_Processor)' -Command {
        Get-CimInstance Win32_Processor | Select-Object `
            Name,
            NumberOfCores,
            NumberOfLogicalProcessors,
            MaxClockSpeed,
            LoadPercentage
    }

    Write-HostResourceSection -DumpFilePath $resourcesFile -Description 'Host fixed disks (Win32_LogicalDisk)' -Command {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 3" | Select-Object `
            DeviceID,
            VolumeName,
            FileSystem,
            @{N = 'Size(GB)'; E = { [math]::Round($_.Size / 1GB, 2) } },
            @{N = 'FreeSpace(GB)'; E = { [math]::Round($_.FreeSpace / 1GB, 2) } },
            @{N = 'FreeSpace(%)'; E = { if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 2) } else { 0 } } }
    }

    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        Write-HostResourceSection -DumpFilePath $resourcesFile -Description 'Host volumes (Get-Volume)' -Command {
            Get-Volume | Select-Object `
                DriveLetter,
                FileSystemLabel,
                FileSystem,
                HealthStatus,
                OperationalStatus,
                @{N = 'Size(GB)'; E = { [math]::Round($_.Size / 1GB, 2) } },
                @{N = 'SizeRemaining(GB)'; E = { [math]::Round($_.SizeRemaining / 1GB, 2) } }
        }
    }
}

function Invoke-LinuxNodeResourceUsageCollection(
    [string] $NodeDetailsDirectory,
    [string] $NodeName,
    [string] $NodePrompt,
    [scriptblock] $InvokeLinuxCommand
) {
    Write-Log "[NodeDiag] Collecting CPU, memory, and disk usage for '$NodeName'..."

    $linuxResourcesDumpFile = Join-Path $NodeDetailsDirectory "$($NodeName)-resources.txt"
    $resourceCommands = @(
        [PSCustomObject]@{ Description = "$NodePrompt~$ uptime"; Command = 'uptime' },
        [PSCustomObject]@{ Description = "$NodePrompt~$ cat /proc/loadavg"; Command = 'cat /proc/loadavg' },
        [PSCustomObject]@{ Description = "$NodePrompt~$ lscpu"; Command = 'lscpu' },
        [PSCustomObject]@{ Description = "$NodePrompt~$ nproc --all"; Command = 'nproc --all' },
        [PSCustomObject]@{ Description = "$NodePrompt~$ free -h"; Command = 'free -h' },
        [PSCustomObject]@{ Description = "$NodePrompt~$ selected /proc/meminfo"; Command = "grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree):' /proc/meminfo" },
        [PSCustomObject]@{ Description = "$NodePrompt~$ df -hT"; Command = 'df -hT' },
        [PSCustomObject]@{ Description = "$NodePrompt~$ lsblk"; Command = 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT' }
    )

    foreach ($resourceCommand in $resourceCommands) {
        try {
            (& $InvokeLinuxCommand $resourceCommand.Command) | Out-String -Width 250 | Write-OutputIntoDumpFile -DumpFilePath $linuxResourcesDumpFile -Description $resourceCommand.Description
        }
        catch {
            $message = "[NodeDiag] Failed to collect '$($resourceCommand.Description)' for '$NodeName': $($_.Exception.Message)"
            Write-Log $message
            $message | Write-OutputIntoDumpFile -DumpFilePath $linuxResourcesDumpFile -Description $resourceCommand.Description
        }
    }
}

function Invoke-LinuxNodeDetailsCollection(
    [string] $NodeDetailsDirectory,
    [string] $NodeName = '',
    [string] $NodeIpAddress = ''
) {
    $collectFromControlPlane = [string]::IsNullOrWhiteSpace($NodeIpAddress)
    $linuxUserName = Get-DefaultUserNameWorkerNode

    if ($collectFromControlPlane) {
        $NodeName = Get-ConfigControlPlaneNodeHostname
        Write-Log "Node name: $NodeName"
        $isWsl = Get-ConfigWslFlag
        if ($isWsl) {
            $isLinuxVMRunning = Get-IsWslRunning -Name $linuxNodeName
        }
        else {
            $isLinuxVMRunning = Get-IsControlPlaneRunning
        }
        if (-not $isLinuxVMRunning) {
            return
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($NodeName)) {
        Write-Log '[NodeDiag] Skipping Linux node details: missing node name.'
        return
    }

    if (-not $collectFromControlPlane) {
        $nodeConfig = Get-NodeConfig -NodeName $NodeName
        if ($null -ne $nodeConfig -and -not [string]::IsNullOrWhiteSpace($nodeConfig.Username)) {
            $linuxUserName = $nodeConfig.Username
        }

        $sshProbe = Invoke-CmdOnVmViaSSHKey -CmdToExecute 'uname -n' -UserName $linuxUserName -IpAddress $NodeIpAddress -IgnoreErrors
        if (-not $sshProbe.Success) {
            $sshError = ($sshProbe.Output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($sshError)) {
                $sshError = 'SSH key authentication failed or node is unreachable.'
            }

            $skipMessage = "[NodeDiag] Skipping Linux host diagnostics for '$NodeName' ($NodeIpAddress) using user '$linuxUserName': $sshError"
            Write-Log $skipMessage

            $linuxNodeDumpFile = Join-Path $NodeDetailsDirectory "$($NodeName)-node.txt"
            $skipMessage | Write-OutputIntoDumpFile -DumpFilePath $linuxNodeDumpFile -Description "$NodeName host diagnostics status"
            return
        }

        Write-Log "[NodeDiag] Using Linux SSH user '$linuxUserName' for node '$NodeName'."
    }

    $invokeLinuxCommand = {
        param(
            [string] $Command
        )

        if ($collectFromControlPlane) {
            return (Invoke-CmdOnControlPlaneViaSSHKey $Command).Output
        }

        return (Invoke-CmdOnVmViaSSHKey -CmdToExecute $Command -UserName $linuxUserName -IpAddress $NodeIpAddress -IgnoreErrors).Output
    }

    $nodePrompt = if ($collectFromControlPlane) { 'KubeMaster' } else { $NodeName }
    $processDescription = if ($collectFromControlPlane) { 'Kubemaster processes' } else { "$NodeName processes" }
    $systemdDescription = if ($collectFromControlPlane) { 'Kubemaster systemd services' } else { "$NodeName systemd services" }

    $linuxNodeDumpFile = Join-Path $NodeDetailsDirectory "$($NodeName)-node.txt"
    (& $invokeLinuxCommand 'uname -a') | Out-String | Write-OutputIntoDumpFile -DumpFilePath $linuxNodeDumpFile -Description "$nodePrompt~$ uname -a"
    (& $invokeLinuxCommand 'cat /proc/version') | Out-String | Write-OutputIntoDumpFile -DumpFilePath $linuxNodeDumpFile -Description "$nodePrompt~$ cat /proc/version"

    Invoke-LinuxNodeResourceUsageCollection -NodeDetailsDirectory $NodeDetailsDirectory -NodeName $NodeName -NodePrompt $nodePrompt -InvokeLinuxCommand $invokeLinuxCommand

    $linuxProcessesDumpFile = Join-Path $NodeDetailsDirectory "$($NodeName)-processes.txt"
    $rawProcesses = & $invokeLinuxCommand 'ps -eo pid,user,%cpu,%mem,rss,cmd --sort=-%mem'
    $trimmedProcesses = $rawProcesses | ForEach-Object {
        if ($_ -match '^(\s*\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+)(.*)$') {
            $prefix = $Matches[1]
            $cmd = if ($Matches[2].Length -gt 50) { $Matches[2].Substring(0, 50) + '...' } else { $Matches[2] }
            "$prefix$cmd"
        }
        else {
            $_
        }
    }
    $trimmedProcesses | Out-String -Width 250 | Write-OutputIntoDumpFile -DumpFilePath $linuxProcessesDumpFile -Description $processDescription

    $linuxSystemdDumpFile = Join-Path $NodeDetailsDirectory "$($NodeName)-systemd-units.txt"
    $systemdRaw = & $invokeLinuxCommand 'LC_ALL=C SYSTEMD_COLORS=0 systemctl list-units --type=service --all --no-pager --full'
    $systemdClean = $systemdRaw | ForEach-Object { $_ -replace '[^\x00-\x7F]', '*' }
    $systemdLegend = @('', '---', '* = unit not found or failed')
    ($systemdClean + $systemdLegend) | Out-String -Width 250 | Write-OutputIntoDumpFile -DumpFilePath $linuxSystemdDumpFile -Description $systemdDescription
}

function Get-ClusterNodeInfo(
    [string] $NodeName
) {
    $nodeJsonRaw = (Invoke-CmdOnControlPlaneViaSSHKey "kubectl get node $NodeName -o json" -IgnoreErrors).Output | Out-String
    if ([string]::IsNullOrWhiteSpace($nodeJsonRaw)) {
        return $null
    }

    try {
        return $nodeJsonRaw | ConvertFrom-Json
    }
    catch {
        Write-Log "[NodeDiag] Failed to parse node metadata for '$NodeName': $($_.Exception.Message)"
        return $null
    }
}

function Invoke-WindowsNodeDetailsViaSsh(
    [string] $NodeName,
    [string] $NodeIpAddress,
    [string] $NodeDetailsDirectory
) {
    if ([string]::IsNullOrWhiteSpace($NodeIpAddress)) {
        Write-Log "[NodeDiag] Skipping Windows node '$NodeName': missing InternalIP"
        return
    }

    Write-Log "[NodeDiag] Collecting Windows host diagnostics for '$NodeName' ($NodeIpAddress) via SSH..."

    $windowsNodeDumpFile = Join-Path $NodeDetailsDirectory "$($NodeName)-node.txt"
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'powershell -NoProfile -Command "[System.Environment]::OSVersion.ToString()"' -IpAddress $NodeIpAddress -IgnoreErrors).Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $windowsNodeDumpFile -Description "$NodeName~$ [System.Environment]::OSVersion.ToString()"
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'cmd /c ver' -IpAddress $NodeIpAddress -IgnoreErrors).Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $windowsNodeDumpFile -Description "$NodeName~$ cmd /c ver"
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'systeminfo' -IpAddress $NodeIpAddress -IgnoreErrors).Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $windowsNodeDumpFile -Description "$NodeName~$ systeminfo"

    $windowsProcessesDumpFile = Join-Path $NodeDetailsDirectory "$($NodeName)-processes.txt"
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'powershell -NoProfile -Command "Get-Process | Select-Object Id, ProcessName, @{N=\'CPU(s)\'; E={ [math]::Round($_.CPU, 2) }}, @{N=\'Mem(MB)\'; E={ [math]::Round($_.WorkingSet64 / 1MB, 1) }}, Path | Format-Table -AutoSize | Out-String -Width 512"' -IpAddress $NodeIpAddress -IgnoreErrors).Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $windowsProcessesDumpFile -Description "$NodeName processes"
}

function Invoke-AdditionalNodeDetailsCollection(
    [string] $NodeDetailsDirectory,
    [string] $AdditionalNodes
) {
    if ([string]::IsNullOrWhiteSpace($AdditionalNodes)) {
        return
    }

    $selectedNodes = $AdditionalNodes.Split(',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' } | Select-Object -Unique
    if ($selectedNodes.Count -eq 0) {
        return
    }

    $controlPlaneNode = (Get-ConfigControlPlaneNodeHostname).ToLower()
    foreach ($nodeName in $selectedNodes) {
        if ($nodeName -eq $controlPlaneNode) {
            Write-Log "[NodeDiag] Skipping '$nodeName' as it is already collected as control-plane host diagnostics."
            continue
        }

        $nodeInfo = Get-ClusterNodeInfo -NodeName $nodeName
        if ($null -eq $nodeInfo) {
            Write-Log "[NodeDiag] Skipping '$nodeName': unable to resolve node metadata via kubectl."
            continue
        }

        $nodeOs = $nodeInfo.status.nodeInfo.operatingSystem
        $nodeInternalIp = ($nodeInfo.status.addresses | Where-Object { $_.type -eq 'InternalIP' } | Select-Object -First 1).address

        if ($nodeOs -eq 'linux') {
            Invoke-LinuxNodeDetailsCollection -NodeDetailsDirectory $NodeDetailsDirectory -NodeName $nodeName -NodeIpAddress $nodeInternalIp
            continue
        }

        if ($nodeOs -eq 'windows') {
            $localHostName = (hostname).ToLower()
            if ($nodeName -eq $localHostName) {
                Write-Log "[NodeDiag] '$nodeName' matches current host; reusing local host diagnostics collection."
                Invoke-HostDetailsCollection -NodeDetailsDirectory $NodeDetailsDirectory
                Invoke-HostDiagnosticsCollection -HostDiagnosticsDir (Join-Path $NodeDetailsDirectory "$nodeName-host")
            }
            else {
                Invoke-WindowsNodeDetailsViaSsh -NodeName $nodeName -NodeIpAddress $nodeInternalIp -NodeDetailsDirectory $NodeDetailsDirectory
            }
            continue
        }

        Write-Log "[NodeDiag] Skipping '$nodeName': unsupported node OS '$nodeOs'."
    }
}

function Invoke-HostDetailsCollection(
    [string] $NodeDetailsDirectory
) {
    $dumpFile = Join-Path $NodeDetailsDirectory "$(hostname)-node.txt"
    ([System.Environment]::OSVersion).ToString() | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'Host OS Version'
    (Get-Item 'HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion').GetValue('DisplayVersion') | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'Host DisplayVersion'

    if (Test-Path 'C:\Windows\System32\systeminfo.exe' -ErrorAction SilentlyContinue) {
        systeminfo.exe | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'systeminfo.exe'
    }
    else {
        $hotFix = Get-HotFix
        if ($null -ne $hotFix) {
            $hotFix | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'Host HotFix details'
        }
        else {
            '<No hotfix>' | Write-OutputIntoDumpFile -DumpFilePath $dumpFile -Description 'Host HotFix details'
        }
    }

}

function Invoke-ClusterDiagnosticsCollection(
    [string] $ClusterDiagnosticsDir,
    [string] $AdditionalNodes
) {
    Write-Log '[ClusterDiag] Starting cluster diagnostics collection...'

    if (-not (Test-Path $ClusterDiagnosticsDir)) {
        New-Item -ItemType Directory -Path $ClusterDiagnosticsDir -Force | Out-Null
    }

    Write-Log '[ClusterDiag] Collecting pods and namespaces...'
    $podsWide = (Invoke-CmdOnControlPlaneViaSSHKey "kubectl get pods -A -o wide").Output
    $podsFile = Join-Path $ClusterDiagnosticsDir "pods-wide.txt"
    $podsWide | Out-String | Write-OutputIntoDumpFile -DumpFilePath $podsFile -Description "kubectl get pods -A -o wide"

    Write-Log '[ClusterDiag] Parsing pod names and namespaces...'
    $podLines = $podsWide -split "`n" | Select-Object -Skip 1
    foreach ($line in $podLines) {
        $fields = $line -split '\s+'
        if ($fields.Length -ge 2) {
            $namespace = $fields[0]
            $podName = $fields[1]
            $podDir = Join-Path $ClusterDiagnosticsDir "$namespace-$podName"
            if (-not (Test-Path $podDir)) {
                New-Item -ItemType Directory -Path $podDir -Force | Out-Null
            }
            Write-Log "[ClusterDiag] Collecting diagnostics for pod $podName in namespace $namespace..."
            # Describe pod
            (Invoke-CmdOnControlPlaneViaSSHKey "kubectl describe pod $podName -n $namespace").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $podDir "describe.txt") -Description "kubectl describe pod $podName -n $namespace"
            # Logs
            (Invoke-CmdOnControlPlaneViaSSHKey "kubectl logs $podName -n $namespace").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $podDir "logs.txt") -Description "kubectl logs $podName -n $namespace"
            # Previous logs
            $previousLogs = (Invoke-CmdOnControlPlaneViaSSHKey -IgnoreErrors "kubectl logs --previous $podName -n $namespace").Output
            $previousLogs | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $podDir "logs-previous.txt") -Description "kubectl logs --previous $podName -n $namespace"
        }
    }

    Write-Log '[ClusterDiag] Collecting cluster events...'
    (Invoke-CmdOnControlPlaneViaSSHKey "kubectl get events -A").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $ClusterDiagnosticsDir "events.txt") -Description "kubectl get events -A"

    Write-Log '[ClusterDiag] Collecting node descriptions...'
    $nodeNames = [System.Collections.Generic.List[string]]::new()
    $nodeNames.Add('kubemaster')

    $workerNode = (hostname).ToLower()
    if (-not [string]::IsNullOrWhiteSpace($workerNode) -and $workerNode -ne 'kubemaster') {
        $nodeNames.Add($workerNode)
    }

    if (-not [string]::IsNullOrWhiteSpace($AdditionalNodes)) {
        $parsedAdditionalNodes = $AdditionalNodes.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        foreach ($nodeName in $parsedAdditionalNodes) {
            $nodeNames.Add($nodeName)
        }
    }

    $distinctNodeNames = $nodeNames | Select-Object -Unique
    foreach ($nodeName in $distinctNodeNames) {
        Write-Log "[ClusterDiag] Collecting node description for $nodeName..."
        $safeNodeName = $nodeName -replace '[^a-zA-Z0-9._-]', '_'
        $describeNodeFile = Join-Path $ClusterDiagnosticsDir "describe-$safeNodeName.txt"
        (Invoke-CmdOnControlPlaneViaSSHKey "kubectl describe node $nodeName").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $describeNodeFile -Description "kubectl describe node $nodeName"
    }

    Write-Log '[ClusterDiag] Cluster diagnostics collection finished.'
}

function Invoke-HostDiagnosticsCollection(
        [string] $HostDiagnosticsDir
) {
    Write-Log '[HostDiag] Starting host diagnostics collection...'
    if (-not (Test-Path $HostDiagnosticsDir)) {
        New-Item -ItemType Directory -Path $HostDiagnosticsDir -Force | Out-Null
    }
    Write-Log '[HostDiag] Collecting ipconfig /allcompartments...'
    ipconfig /allcompartments | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $HostDiagnosticsDir "ipconfig-allcompartments.txt") -Description "ipconfig /allcompartments"
    Write-Log '[HostDiag] Collecting NetConnectionProfile...'
    Get-NetConnectionProfile | Sort-Object InterfaceAlias -Unique | Out-String | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $HostDiagnosticsDir "netconnectionprofile.txt") -Description "Get-NetConnectionProfile"
    Write-Log '[HostDiag] Collecting MSINFO32...'
    $msinfoFile = Join-Path $HostDiagnosticsDir "$env:COMPUTERNAME`_MSINFO32.NFO"
    Start-Process -FilePath "MSINFO32.exe" -ArgumentList "/nfo $msinfoFile /categories +all" -Wait
    Write-Log '[HostDiag] Collecting running processes...'
    Get-Process | Select-Object Id, ProcessName,
        @{N='CPU(s)'; E={ [math]::Round($_.CPU, 2) }},
        @{N='Mem(MB)'; E={ [math]::Round($_.WorkingSet64 / 1MB, 1) }},
        Path | Format-Table -AutoSize | Out-String -Width 512 | Write-OutputIntoDumpFile -DumpFilePath (Join-Path $HostDiagnosticsDir 'processes.txt') -Description 'Host processes'
    Invoke-HostResourceUsageCollection -HostDiagnosticsDir $HostDiagnosticsDir
    Write-Log '[HostDiag] Host diagnostics collection finished.'
}

Write-Log 'k2s system dump started' -Console

try {
    $dumpDirName = ''
    if ($ZipFileName -eq '') {
        $dumpDirName = "k2s-dump-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMddTHHmmssfff')"
    }
    else {
        $dumpDirName = $ZipFileName
    }

    $logsDir = Get-k2sLogDirectory
    $dumpTargetDir = $logsDir

    $parentTempDir = [System.IO.Path]::GetTempPath()
    $tempDir = Join-Path $parentTempDir $dumpDirName
    $tempLogsDir = Join-Path $tempDir 'logs'
    $tempConfigDir = Join-Path $tempDir 'config\'
    $tempNetworkDir = Join-Path $tempDir 'networking\'
    $hostInfoDir = Join-Path $tempDir 'node\'
    $dumpTargetPath = Join-Path $dumpTargetDir "$dumpDirName.zip"

    # Host general information and node dump
    Write-Log 'Gathering node details..' -Console
    Invoke-HostDetailsCollection -NodeDetailsDirectory $hostInfoDir
    Invoke-LinuxNodeDetailsCollection -NodeDetailsDirectory $hostInfoDir
    Invoke-AdditionalNodeDetailsCollection -NodeDetailsDirectory $hostInfoDir -AdditionalNodes $Nodes

    # Cluster and host diagnostics collection
    $clusterDiagnosticsDir = Join-Path $tempDir 'cluster'
    $hostDiagnosticsDir = Join-Path $tempDir 'host'
    Write-Log 'Gathering cluster diagnostics..' -Console
    Invoke-ClusterDiagnosticsCollection -ClusterDiagnosticsDir $clusterDiagnosticsDir -AdditionalNodes $Nodes
    Write-Log 'Gathering host diagnostics..' -Console
    Invoke-HostDiagnosticsCollection -HostDiagnosticsDir $hostDiagnosticsDir

    # Log Collection
    Write-Log 'Gathering logs..' -Console
    Invoke-k2sLogCollection -LogDirectory:$logsDir -LogCollectionDirectory:$tempLogsDir

    # Config file collection
    Write-Log 'Gathering config files..' -Console
    Invoke-k2sConfigCollection -ConfigCollectionDirectory:$tempConfigDir

    # Network dump
    & $PSScriptRoot\network_dump.ps1 -DumpDir $tempNetworkDir

    # Final dump of logs and cleanup
    Write-Log "Dumping to $dumpTargetDir.." -Console
    Compress-Archive -Path $tempDir -DestinationPath $dumpTargetPath -CompressionLevel Optimal -Force
    Remove-Item -Path $tempDir -Recurse -Force

    Write-Log "Dump created at $dumpTargetPath" -Console
    Write-Log 'k2s system dump finished'

    if ($OpenDumpFolder -eq $true) {
        Write-Log 'Opening the dump folder..' -Console
        Invoke-Item $dumpTargetDir
    }
    else {
        Write-Log 'Skipping opening the dump folder' -Console
    }

    exit 0

}
catch {
    $exceptionString = $_ | Out-String
    Write-Log "Error occurred: $exceptionString" -Error
    exit -1
}


