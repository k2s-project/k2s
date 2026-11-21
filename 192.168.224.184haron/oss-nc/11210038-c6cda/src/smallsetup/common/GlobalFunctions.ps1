# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# load global settings
&$PSScriptRoot\GlobalVariables.ps1

$infraModule = "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
Import-Module $infraModule

# GlobalFunctions.ps1
#   reuse methods over multiple scripts

<#
.Description
ExecCmdMaster executes cmd on master.
#>
function ExecCmdMaster(
    [Parameter(Mandatory = $false)]
    $CmdToExecute,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [switch]$UsePwd = $false,
    [Parameter(Mandatory = $false)]
    [uint16]$Retries = 0,
    [Parameter(Mandatory = $false)]
    [uint16]$Timeout = 2,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUser = $global:Remote_Master,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd = $global:VMPwd,
    [Parameter(HelpMessage = 'When executing ssh.exe in nested environment[host=>VM=>VM], -n flag should not be used.')]
    [switch]$Nested = $false,
    [Parameter(Mandatory = $false, HelpMessage = 'text that gets logged instead of the original command that contains potentially sensitive data')]
    [string]$CmdLogReplacement,
    [Parameter(Mandatory = $false, HelpMessage = 'repair comd for the case first run did not work out')]
    [string]$RepairCmd = $null) {
    $cmdLogText = $CmdToExecute
    if ($CmdLogReplacement) {
        $cmdLogText = $CmdLogReplacement
    }

    if (!$NoLog) {
        Write-Log "cmd: $cmdLogText, retries: $Retries, timeout: $Timeout sec, ignore err: $IgnoreErrors, nested: $nested"
    }
    $Stoploop = $false
    [uint16]$Retrycount = 1
    do {
        try {
            if ($UsePwd) {
                &"$global:SshExe" -ssh -4 $RemoteUser -pw $RemoteUserPwd -no-antispoof $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
            }
            else {
                if ($Nested) {
                    ssh.exe -o StrictHostKeyChecking=no -i $global:LinuxVMKey $RemoteUser $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                }
                else {
                    ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $RemoteUser $CmdToExecute 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                }
            }
            if ($LASTEXITCODE -ne 0 -and !$IgnoreErrors) { throw "Error occurred while executing command '$cmdLogText' (exit code: '$LASTEXITCODE')" }
            $Stoploop = $true
        }
        catch {
            Write-Log $_
            if ($Retrycount -gt $Retries) {
                $Stoploop = $true
            }
            else {
                Write-Log "cmd: $cmdLogText will be retried.."
                # try to repair the cmd
                if ( ($null -ne $RepairCmd) -and !$UsePwd -and !$IgnoreErrors) {
                    Write-Log "Executing repair cmd: $RepairCmd"
                    if ($Nested) {
                        ssh.exe -o StrictHostKeyChecking=no -i $global:LinuxVMKey $RemoteUser $RepairCmd 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                    }
                    else {
                        ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $RemoteUser $RepairCmd 2>&1 | ForEach-Object { Write-Log $_ -Console -Raw }
                    }
                }
                Start-Sleep -Seconds $Timeout
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false)
}

<#
.Description
Copy-FromToMaster copies files to master.
#>
function Copy-FromToMaster($Source, $Target,
    [Parameter(Mandatory = $false)]
    [switch]$IgnoreErrors = $false,
    [Parameter(Mandatory = $false)]
    [switch]$UsePwd = $false,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd = $global:VMPwd) {
    Write-Log "copy: $Source to: $Target IgnoreErrors: $IgnoreErrors"
    $error.Clear()
    if ($UsePwd) {
        echo yes | &"$global:ScpExe" -ssh -4 -q -r -pw $RemoteUserPwd "$Source" "$Target" 2>&1 | ForEach-Object { "$_" }
    }
    else {
        if ($Target.Contains($global:Remote_Master)) {
            # copy to master
            $leaf = Split-Path $Source -leaf
            if ($(Test-Path $Source) -and (Get-Item $Source) -is [System.IO.DirectoryInfo] -and $leaf -ne "*") {
                # is directory
                ExecCmdMaster "sudo rm -rf /tmp/copy.tar"
                $folder = Split-Path $Source -Leaf
                tar.exe -cf "$env:TEMP\copy.tar" -C $Source .
                scp.exe -o StrictHostKeyChecking=no -i $global:LinuxVMKey "$env:temp\copy.tar" $($global:Remote_Master + ':/tmp') 2>&1 | ForEach-Object { "$_" }
                $targetDirectory = $Target -replace "${global:Remote_Master}:", ''
                ExecCmdMaster "mkdir -p $targetDirectory/$folder"
                ExecCmdMaster "tar -xf /tmp/copy.tar -C $targetDirectory/$folder"
                ExecCmdMaster "sudo rm -rf /tmp/copy.tar"
                Remove-Item -Path "$env:temp\copy.tar" -Force -ErrorAction SilentlyContinue
            } else {
                scp.exe -o StrictHostKeyChecking=no -r -i $global:LinuxVMKey "$Source" "$Target" 2>&1 | ForEach-Object { "$_" }
            }
        } elseif ($Source.Contains($global:Remote_Master)){
            # copy from master
            $sourceDirectory = $Source -replace "${global:Remote_Master}:", ''
            ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master "[ -d '$sourceDirectory' ]"
            if ($?) {
                # is directory
                ExecCmdMaster "sudo rm -rf /tmp/copy.tar"
                $folder = Split-Path $sourceDirectory -Leaf
                ExecCmdMaster "sudo tar -cf /tmp/copy.tar -C $sourceDirectory ."
                scp.exe -o StrictHostKeyChecking=no -i $global:LinuxVMKey $($global:Remote_Master + ':/tmp/copy.tar') "$env:temp\copy.tar" 2>&1 | ForEach-Object { "$_" }
                New-Item -Path "$Target\$folder" -ItemType Directory | Out-Null
                tar.exe -xf "$env:temp\copy.tar" -C "$Target\$folder"
                ExecCmdMaster "sudo rm -rf /tmp/copy.tar"
                Remove-Item -Path "$env:temp\copy.tar" -Force -ErrorAction SilentlyContinue
            } else {
                scp.exe -o StrictHostKeyChecking=no -r -i $global:LinuxVMKey "$Source" "$Target" 2>&1 | ForEach-Object { "$_" }
            }
        }
    }

    if ($error.Count -gt 0 -and !$IgnoreErrors) { throw "Copying $Source to $Target failed! " + $error }
}


<#
.Description
DownloadFile download file from internet.
#>
function DownloadFile($destination, $source, $forceDownload,
    [parameter(Mandatory = $false)]
    [string] $ProxyToUse = $Proxy) {
    if ((Test-Path $destination) -and (!$forceDownload)) {
        Write-Log "using existing $destination"
        return
    }
    if ( $ProxyToUse -ne '' ) {
        Write-Log "Downloading '$source' to '$destination' with proxy: $ProxyToUse"
        # NOTE: --ssl-no-revoke is still required for VMI proxy due to proxy/cert issues. Remove when fixed.
        curl.exe --retry 5 --connect-timeout 60 --retry-all-errors --retry-delay 60 --silent --disable --fail -Lo $destination $source --proxy $ProxyToUse --ssl-no-revoke #ignore server certificate error for cloudbase.it
    }
    else {
        Write-Log "Downloading '$source' to '$destination' (no proxy)"
        curl.exe --retry 5 --connect-timeout 60 --retry-all-errors --retry-delay 60 --silent --disable --fail -Lo $destination $source --noproxy '*'
    }

    if (!$?) {
        if ($ErrorActionPreference -eq 'Stop') {
            #If Stop is the ErrorActionPreference from the caller then Write-Error throws an exception which is not logged in k2s.log file.
            #So we need to write a warning to capture Download failed information in the log file.
            Write-Warning "Download '$source' failed"
        }
        Write-Error "Download '$source' failed"
        exit 1
    }
}


<#
.SYNOPSIS
    Creates a specified directory if not existing.
.DESCRIPTION
    Creates a specified directory if not existing.
.EXAMPLE
    New-DirectoryIfNotExisting -Path 'c:\temp-dir'
    New-DirectoryIfNotExisting 'c:\temp-dir'
    'c:\temp-dir' | New-DirectoryIfNotExisting
.PARAMETER Path
    Directory path
.NOTES
    Function supports pipelines ('Path')
#>
function New-DirectoryIfNotExisting {
    param (
        [Parameter(ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    if (!(Test-Path $Path)) {
        Write-Log "Directory '$Path' not existing, creating it ..."

        New-Item -Path $Path -ItemType Directory | Out-Null

        Write-Log "Directory '$Path' created."
    }
    else {
        Write-Log "Directory '$Path' already existing."
    }
}

<#
.SYNOPSIS
    Writes a key-value pair to a given JSON file.
.DESCRIPTION
    Writes a key-value pair to a given JSON file.
.EXAMPLE
    Set-ConfigValue -Path "config.json" -Key 'version' -Value '123'
.PARAMETER Path
    Path to config JSON file
.PARAMETER Key
    Property key
.PARAMETER Value
    Property value
.NOTES
    Config file must contain valid JSON.
    Only top-level properties are set.
    Existing properties with the same key get overwritten.
    If the config file does not exist, it will be created.
#>
function Set-ConfigValue {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = $(throw 'Please provide the config file path.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Key = $(throw 'Please provide the config key.'),
        [Parameter()]
        [object] $Value = $(throw 'Please provide the config value.')
    )

    if (Test-Path $Path) {
        $json = $(Get-Content $Path -Raw | ConvertFrom-Json)
    }
    else {
        Split-Path -parent $Path | New-DirectoryIfNotExisting

        $json = @{ }
    }

    $json | Add-Member -Name $Key -Value $Value -MemberType NoteProperty -Force

    $json | ConvertTo-Json -Depth 32 | Set-Content -Force $Path # default object depth appears to be 2
}

<#
.SYNOPSIS
    Retrieves the specified config value from a given JSON file.
.DESCRIPTION
    Retrieves the specified config value from a given JSON file.
.EXAMPLE
    $version = Get-ConfigValue -Path "config.json" -Key 'version'
.PARAMETER Path
    Path to config JSON file
.PARAMETER Key
    Property key
.OUTPUTS
    The property value if existing; otherwise null
.NOTES
    Config file must contain valid JSON.
    Only top-level properties are read.
    If the property exists with null value, null will be returned (same as if the property did not exist).
    If the config file does not exist, null will be returned.
#>
function Get-ConfigValue {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Path = $(throw 'Please provide the config file path.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Key = $(throw 'Please provide the config key.')
    )

    if (!(Test-Path $Path)) {
        return
    }

    return $(Get-Content $Path -Raw | ConvertFrom-Json).$Key
}




<#
.SYNOPSIS
    Opens a remote session to the specified VM.
.DESCRIPTION
    Opens a remote session to the specified VM. Throws on error.
.EXAMPLE
    $session = Open-RemoteSession -VmName 'MyVm' -VmPwd 'my secret password'
.PARAMETER VmName
    Name of the VM to connect to
.PARAMETER VmPwd
    Password of the VM user (user 'administrator' is currently hard-coded)
.PARAMETER TimeoutInSeconds
    Connection timeout
.PARAMETER DoNotThrowOnTimeout
    Writes an error to error output instead of throwing an exception
.PARAMETER NoLog
    Suppresses any output if set
.OUTPUTS
    The session object
.NOTES
    This method will throw an error, if the connection could not be established within a certain amount of time.
#>
function Open-RemoteSession {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please provide the name of the VM.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmPwd = $(throw 'Please provide the VM user password.'),
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 1800,
        [Parameter(Mandatory = $false)]
        [switch]$DoNotThrowOnTimeout = $false,
        [Parameter(Mandatory = $false)]
        [switch]$NoLog = $false
    )

    if (!$global:KubernetesPath) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    if ($NoLog -ne $true) {
        Write-Log "Connecting to VM '$VmName' ..."
    }

    $session = &"$global:KubernetesPath\smallsetup\common\vmtools\New-VMSession.ps1" -VMName $VmName -AdministratorPassword $VmPwd -TimeoutInSeconds $TimeoutInSeconds -NoLog:$NoLog

    if (! $session ) {
        $errorMessage = "No session to VM '$VmName' possible."

        if ($DoNotThrowOnTimeout -eq $true -and $NoLog -ne $true) {
            Write-Error $errorMessage
        }
        else { throw $errorMessage }
    }

    if ($NoLog -ne $true) {
        Write-Log "Connected to VM '$VmName'."
    }

    return $session
}

function Open-RemoteSessionViaSSHKey {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Hostname = $(throw 'Please provide the hostname.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $KeyFilePath = $(throw 'Please provide the path of ssh key.'),
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 1800,
        [Parameter(Mandatory = $false)]
        [switch]$DoNotThrowOnTimeout = $false,
        [Parameter(Mandatory = $false)]
        [switch]$NoLog = $false
    )

    if ($PSVersionTable.PSVersion.Major -le 5) {
        throw 'Remote session via ssh key pair is only available in Powershell version > 5.1'
    }

    if (!$global:KubernetesPath) {
        throw "The calling script must include the file 'GlobalVariables.ps1' first!"
    }

    if ($NoLog -ne $true) {
        Write-Log "Connecting to '$Hostname' ..."
    }

    $session = &"$global:KubernetesPath\smallsetup\common\vmtools\New-VMSessionViaSSHKey.ps1" -Hostname $Hostname -KeyFilePath $KeyFilePath -TimeoutInSeconds $TimeoutInSeconds -NoLog:$NoLog

    if (! $session ) {
        $errorMessage = "No session to '$Hostname' possible."

        if ($DoNotThrowOnTimeout -eq $true -and $NoLog -ne $true) {
            Write-Error $errorMessage
        }
        else { throw $errorMessage }
    }

    if ($NoLog -ne $true) {
        Write-Log "Connected to '$Hostname'."
    }

    return $session
}



function CreateExternalSwitch {
    param (
        [Parameter()]
        [string] $adapterName
    )

    $found = Get-HNSNetwork | ? Name -Like "$global:L2BridgeSwitchName"
    if ( $found ) {
        Write-Log "L2 bridge network switch name: $global:L2BridgeSwitchName already exists"
        return
    }

    $nic = Get-NetIPAddress -InterfaceAlias $adapterName -ErrorAction SilentlyContinue
    if ($nic) {
        $ipaddress = $nic.IPv4Address
        $dhcp = $nic.PrefixOrigin
        Write-Log "Using card: '$adapterName' with $ipaddress and $dhcp"
    }
    else {
        Write-Log 'FAILURE: no NIC found which is appropriate !'
        throw 'Fatal: no network interface found which works for K2s Setup!'
    }

    # get DNS server from NIC
    $dnsServers = @(Get-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4)
    $adr = $('8.8.8.8', '8.8.4.4')
    if ( $dnsServers) {
        if ($dnsServers.ServerAddresses) {
            $adr = $dnsServers.ServerAddresses
        }
    }
    Write-Log "DNS servers found: '$adr'"
    # build string for DNS server
    $dnsserver = $($adr -join ',')

    # start of external switch
    Write-Log "Create l2 bridge network with subnet: $global:ClusterCIDR_Host, switch name: $global:L2BridgeSwitchName, DNS server: $dnsserver, gateway: $global:ClusterCIDR_Gateway, NAT exceptions: $global:ClusterCIDR_NatExceptions, adapter name: $adapterName"
    $netResult = New-HnsNetwork -Type 'L2Bridge' -Name "$global:L2BridgeSwitchName" -AdapterName "$adapterName" -AddressPrefix "$global:ClusterCIDR_Host" -Gateway "$global:ClusterCIDR_Gateway" -DNSServer "$dnserver"
    Write-Log $netResult

    # create endpoint
    $cbr0 = Get-HnsNetwork | Where-Object -FilterScript { $_.Name -EQ "$global:L2BridgeSwitchName" }
    if ( $null -Eq $cbr0 ) {
        throw 'No l2 bridge found. Please do a stopk8s ans start from scratch !'
    }

    $endpointname = $global:L2BridgeSwitchName + '_ep'
    $hnsEndpoint = New-HnsEndpoint -NetworkId $cbr0.ID -Name $endpointname -IPAddress $global:ClusterCIDR_NextHop -Verbose -EnableOutboundNat -OutboundNatExceptions $global:ClusterCIDR_NatExceptions
    if ($null -Eq $hnsEndpoint) {
        throw 'Not able to create a endpoint. Please do a stopk8s and restart again. Aborting.'
    }

    Attach-HnsHostEndpoint -EndpointID $hnsEndpoint.Id -CompartmentID 1
    $iname = "vEthernet ($endpointname)"
    netsh int ipv4 set int $iname for=en | Out-Null
    #netsh int ipv4 add neighbors $iname $global:ClusterCIDR_Gateway '00-01-e8-8b-2e-4b' | Out-Null
}

function RemoveExternalSwitch () {
    Write-Log "Remove l2 bridge network switch name: $global:L2BridgeSwitchName"
    Get-HnsNetwork | Where-Object Name -Like "$global:L2BridgeSwitchName" | Remove-HnsNetwork -ErrorAction SilentlyContinue
}


function Get-ControlPlaneNodeHostname () {
    $hostname = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_ControlPlaneNodeHostname
    return $hostname
}



function Get-StorageLocalDrive() {
    $storageLocalDriveLetter = ''

    $usedStorageLocalDriveLetter = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_UsedStorageLocalDriveLetter
    if (!([string]::IsNullOrWhiteSpace($usedStorageLocalDriveLetter))) {
        $storageLocalDriveLetter = $usedStorageLocalDriveLetter
    }
    else {
        $searchAvailableFixedLogicalDrives = {
            $fixedHardDrives = Get-WmiObject -ClassName Win32_DiskDrive | Where-Object { $_.Mediatype -eq 'Fixed hard disk media' }
            $partitionsOnFixedHardDrives = $fixedHardDrives | Foreach-Object { Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($_.DeviceID.Replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition" }
            $fixedLogicalDrives = $partitionsOnFixedHardDrives | Foreach-Object { Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($_.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition" }
            return $fixedLogicalDrives | Sort-Object $_.DeviceID
        }
        if ([string]::IsNullOrWhiteSpace($global:ConfiguredStorageLocalDriveLetter)) {
            $fixedLogicalDrives = $searchAvailableFixedLogicalDrives.Invoke()
            # no drive letter is configured --> use the local drive with the most space available
            $fixedLogicalDriveWithMostSpaceAvailable = $($fixedLogicalDrives | Sort-Object -Property FreeSpace -Descending | Select-Object -Property DeviceID -First 1).DeviceID
            $storageLocalDriveLetter = $fixedLogicalDriveWithMostSpaceAvailable.Substring(0, 1)
        }
        else {
            if ($global:ConfiguredStorageLocalDriveLetter -match '^[a-zA-Z]$') {
                $storageLocalDriveLetter = $global:ConfiguredStorageLocalDriveLetter
                $searchedLogicalDeviceID = $storageLocalDriveLetter + ':'
                $fixedLogicalDrives = $searchAvailableFixedLogicalDrives.Invoke()
                $foundFixedLogicalDrive = $fixedLogicalDrives | Where-Object { $_.DeviceID -eq $searchedLogicalDeviceID }
                if ($null -eq $foundFixedLogicalDrive) {
                    $availableFixedLogicalDrives = (($fixedLogicalDrives | Select-Object -Property DeviceID) | ForEach-Object { $_.DeviceID.Substring(0, 1) }) -join ', '
                    throw "The configured local drive letter '$global:ConfiguredStorageLocalDriveLetter' is not a local fixed drive or is not available in your system.`nYour available local fixed drives are: $availableFixedLogicalDrives. Please choose one of them."
                }
            }
            else {
                throw "The configured local drive letter '$global:ConfiguredStorageLocalDriveLetter' is syntactically wrong. Please choose just a valid letter of an available local fixed drive."
            }
        }

        Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_UsedStorageLocalDriveLetter -Value $storageLocalDriveLetter | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($storageLocalDriveLetter)) {
        throw 'The local drive letter for the storage could not be determined'
    }

    return $storageLocalDriveLetter + ':'
}
