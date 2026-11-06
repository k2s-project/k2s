# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
Import-Module $infraModule

# Base image

<#
.Description
#TODO Move to infra module if used frequently in linux node
Invoke-DownloadFile download file from internet.
#>
function Invoke-Download($destination, $source, $forceDownload,
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

function Invoke-DownloadLinuxImage {
    param(
        [string]$OutputPath,
        [string]$Proxy = '',
        [string]$TargetDistribution = 'debian13'
    )

    Write-Log "[LinuxImage] Resolving cloud image for distribution '$TargetDistribution'" -Console

    $cloudImage = Get-DistributionCloudImage -OS $TargetDistribution
    $urlRoot = $cloudImage.urlRoot
    $urlFile = $cloudImage.urlFile

    $url = "$urlRoot/$urlFile"
    Write-Log "[LinuxImage] Image URL: $url"

    if (-not $OutputPath) {
        $OutputPath = Get-Item '.\'
    }

    $imgFile = Join-Path $OutputPath $urlFile

    if ([System.IO.File]::Exists($imgFile)) {
        Write-Log "[LinuxImage] File '$imgFile' already exists, skipping download" -Console
    }
    else {
        Write-Log "[LinuxImage] Downloading '$urlFile' to '$OutputPath'" -Console
        Invoke-Download $imgFile $url $false $Proxy
        Write-Log "[LinuxImage] Download completed"

        Write-Log "[LinuxImage] Verifying file integrity (SHA512)..." -Console
        $allHashes = ''

        if ( $Proxy -ne '') {
            Write-Log "Using Proxy $Proxy to download SHA sum from $urlRoot"
            # NOTE: --ssl-no-revoke is still required for VMI proxy due to proxy/cert issues. Remove when fixed.
            $allHashes = curl.exe --retry 3 --connect-timeout 60 --retry-connrefused --silent --disable --fail "$urlRoot/SHA512SUMS" --proxy $Proxy --ssl-no-revoke
        }
        else {
            Write-Log "[LinuxImage] Fetching SHA512SUMS from $urlRoot (no proxy)"
            $allHashes = curl.exe --retry 3 --connect-timeout 60 --retry-connrefused --silent --disable --fail "$urlRoot/SHA512SUMS" --noproxy '*'
        }

        $computedHash = Get-FileHash $imgFile -Algorithm SHA512
        $m = [regex]::Matches($allHashes, "(?<Hash>\w{128})\s\s$urlFile")
        if (-not $m[0]) { throw "[LinuxImage] Cannot find hash for '$urlFile' in SHA512SUMS" }
        $expectedHash = $m[0].Groups['Hash'].Value
        
        Write-Log "[LinuxImage] Expected hash: $expectedHash"
        Write-Log "[LinuxImage] Computed hash: $($computedHash.Hash)"
        
        if ($computedHash.Hash -ne $expectedHash) { 
            throw "[LinuxImage] Integrity check failed for '$imgFile' - hash mismatch" 
        }
        Write-Log "[LinuxImage] Integrity check passed" -Console
    }

    return $imgFile
}


Function New-VhdxFromCloudImage {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$TargetFilePath,
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$DownloadsDirectory,
        [parameter(Mandatory = $false)]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'The Linux distribution identifier (e.g. debian12, debian13).')]
        [string]$TargetDistribution = 'debian13'
    )

    Assert-Path -Path $TargetFilePath -PathType "Leaf" -ShallExist $false | Out-Null
    $pathContainer = $(Split-Path $TargetFilePath)
    Assert-Path -Path $pathContainer -PathType "Container" -ShallExist $true | Out-Null

    Assert-Path -Path $DownloadsDirectory -PathType "Container" -ShallExist $true | Out-Null

    $linuxImage = Get-LinuxImage -Proxy $Proxy -DownloadsDirectory $DownloadsDirectory -TargetDistribution $TargetDistribution | Assert-Path -PathType "Leaf" -ShallExist $true
    $qemuTool = Get-QemuTool -Proxy $Proxy -DownloadsDirectory $DownloadsDirectory | Assert-Path -PathType "Leaf" -ShallExist $true
    $vhdxFile = New-VhdxFile -SourcePath $linuxImage -VhdxPath $TargetFilePath -QemuExePath $qemuTool | Assert-Path -PathType "Leaf" -ShallExist $true
}


Function Get-LinuxImage {
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$DownloadsDirectory,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'The Linux distribution identifier (e.g. debian12, debian13).')]
        [string]$TargetDistribution = 'debian13'
    )
    Assert-Path -Path $DownloadsDirectory -PathType 'Container' -ShallExist $true | Out-Null

    $cloudImage = Get-DistributionCloudImage -OS $TargetDistribution
    $qcow2FileName = $cloudImage.urlFile

    # check if image file already exists under bin directory
    $kubeBinPath = Get-KubeBinPath
    $imgFile = Join-Path $kubeBinPath $qcow2FileName
    if (Test-Path $imgFile) {
        Write-Output $imgFile
        return
    }

    # download directly to bin folder
    $imgFile = Invoke-DownloadLinuxImage -OutputPath $kubeBinPath -Proxy $Proxy -TargetDistribution $TargetDistribution

    Write-Output $imgFile
}

Function Get-QemuTool {
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$DownloadsDirectory,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = ''
    )
    Assert-Path -Path $DownloadsDirectory -PathType "Container" -ShallExist $true | Out-Null

    $qemuTool = Get-QemuExecutable -Proxy $Proxy -OutputDirectory $DownloadsDirectory

    Write-Output $qemuTool
}

Function New-VhdxFile {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$SourcePath,
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$VhdxPath,
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$QemuExePath
    )
    Assert-Path -Path $SourcePath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $VhdxPath -PathType "Leaf" -ShallExist $false | Out-Null
    $pathContainer = $(Split-Path $VhdxPath)
    Assert-Path -Path $pathContainer -PathType "Container" -ShallExist $true | Out-Null
    Assert-Path -Path $QemuExePath -PathType "Leaf" -ShallExist $true | Out-Null

    Invoke-Tool -ToolPath $QemuExePath -Arguments "convert -f qcow2 `"$SourcePath`" -O vhdx -o subformat=dynamic `"$VhdxPath`""
    Assert-Path -Path $VhdxPath -PathType "Leaf" -ShallExist $true | Out-Null

    $VhdxPath
}

Function New-IsoFile {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$IsoFileCreatorToolPath = $(throw 'Parameter missing: IsoFileCreatorToolPath'),

        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern "^.*\.iso$" })]
        [string]$IsoFilePath = $(throw 'Parameter missing: IsoFilePath'),

        [Parameter(Mandatory = $false)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$SourcePath = $(throw 'Parameter missing: SourcePath'),

        [Parameter(Mandatory = $false)]
        [hashtable]$IsoContentParameterValue = $(throw 'Parameter missing: IsoContentParameterValue')
    )
    Assert-Path -Path $IsoFileCreatorToolPath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $IsoFilePath -PathType "Leaf" -ShallExist $false | Out-Null
    $private:workingDirectory = $(Split-Path $IsoFilePath)
    Assert-Path -Path $workingDirectory -PathType "Container" -ShallExist $true | Out-Null

    Assert-Path -Path $SourcePath -PathType "Container" -ShallExist $true | Out-Null

    $private:cloudDataTargetDirectory = "$workingDirectory\cloud-data"
    Assert-Path -Path $cloudDataTargetDirectory -PathType "Container" -ShallExist $false | Out-Null
    New-Item -Path $cloudDataTargetDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null

    $metaDataTemplateFilePath = "$SourcePath\meta-data"
    $networkConfigTemplateFilePath = "$SourcePath\network-config"
    $userDataTemplateFilePath = "$SourcePath\user-data"
    Assert-Path -Path $metaDataTemplateFilePath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $networkConfigTemplateFilePath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $userDataTemplateFilePath -PathType "Leaf" -ShallExist $true | Out-Null

    $metaDataFileContent = Get-Content -Path $metaDataTemplateFilePath -Raw -ErrorAction Stop
    $metaDataConversionTable = @{
        "__INSTANCE_NAME__"=(New-Guid).Guid
        "__LOCAL-HOSTNAME_VALUE__"=$IsoContentParameterValue.Hostname
    }
    Convert-Text -Source $metaDataFileContent -ConversionTable $metaDataConversionTable | Set-Content -Path "$cloudDataTargetDirectory\meta-data" -ErrorAction Stop

    $networkConfigFileContent = Get-Content -Path $networkConfigTemplateFilePath -Raw -ErrorAction Stop
    $networkConfigConversionTable = @{
        "__NETWORK_INTERFACE_NAME__"=$IsoContentParameterValue.NetworkInterfaceName
        "__IP_ADDRESS_VM__"="$($IsoContentParameterValue.IPAddressVM)/24"
        "__IP_ADDRESS_GATEWAY__"=$IsoContentParameterValue.IPAddressGateway
        "__IP_ADDRESSES_DNS_SERVERS__"=$IsoContentParameterValue.IPAddressDnsServers
    }
    Convert-Text -Source $networkConfigFileContent -ConversionTable $networkConfigConversionTable | Set-Content -Path "$cloudDataTargetDirectory\network-config" -ErrorAction Stop

    $userDataFileContent = Get-Content -Path $userDataTemplateFilePath -Raw -ErrorAction Stop
    $userDataConversionTable = @{
        "__LOCAL-HOSTNAME_VALUE__"=$IsoContentParameterValue.Hostname
        "__VM_USER__"=$IsoContentParameterValue.UserName
        "__VM_USER_PWD__"=$IsoContentParameterValue.UserPwd
        "__IP_ADDRESSES_DNS_SERVERS__"=($IsoContentParameterValue.IPAddressDnsServers -replace ",", "\n nameserver ")
    }
    Convert-Text -Source $userDataFileContent -ConversionTable $userDataConversionTable | Set-Content -Path "$cloudDataTargetDirectory\user-data" -ErrorAction Stop

    Invoke-Tool -ToolPath $IsoFileCreatorToolPath -Arguments "-sourceDir `"$cloudDataTargetDirectory`" -targetFilePath `"$IsoFilePath`""

    Assert-Path -Path $IsoFilePath -PathType "Leaf" -ShallExist $true | Out-Null

    $IsoFilePath
}

Function Get-QemuExecutable {
    [CmdletBinding()]
    param(
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [parameter(Mandatory = $true, HelpMessage = 'The directory where the executable will be available.')]
        [string]$OutputDirectory
    )

    # download and make qemu-img.exe available
    $zipFileName = 'qemu-img-win-x64-2_3_0.zip'
    $zipFilePath = Join-Path $OutputDirectory "$zipFileName"
    $url = "https://cloudbase.it/downloads/$zipFileName"
    if (!(Test-Path $zipFilePath)) {
        Write-Log "Start download..."
        Invoke-Download $zipFilePath $url $true $Proxy
        Write-Log "  ...done"
    }
    else {
        Write-Log "Using existing '$zipFilePath'"
    }

    # Extract the archive.
    Write-Log "Extract archive to '$OutputDirectory'"
    Expand-Archive $zipFilePath -DestinationPath $OutputDirectory -Force

    $qemuExePath = Join-Path $OutputDirectory "qemu-img.exe"
    Write-Log "Qemu-img downloaded and available as '$qemuExePath'"

    return $qemuExePath
}

## Virtual Machine

function New-VirtualMachineForBaseImageProvisioning {
	param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VmName,

        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern "^.*\.vhdx$" })]
        [string] $VhdxFilePath,

        [string] $IsoFilePath = $(throw "Argument missing: IsoFilePath"),

        [ValidateScript( { $_ -gt 0 })]
        [long]$VMMemoryStartupBytes,

        [ValidateScript( { $_ -gt 0 })]
        [long]$VMProcessorCount,

        [ValidateScript( { $_ -gt 0 })]
        [uint64]$VMDiskSize
        )

        $useIsoFilePath = (!([string]::IsNullOrWhiteSpace($IsoFilePath)))
        if ($useIsoFilePath) {
            $hasLegalCharactersInPath = Assert-LegalCharactersInPath -Path $IsoFilePath
            if (!$hasLegalCharactersInPath) {
                throw "The file $IsoFilePath contains illegal characters"
            }
            $validIsoPath = Assert-Pattern -Path $IsoFilePath -Pattern "^.*\.iso$"
            if (!$validIsoPath) {
                throw "The file $IsoFilePath does not match the pattern '*.iso'"
            }
            Assert-Path -Path $IsoFilePath -PathType "Leaf" -ShallExist $true | Out-Null
        }

        Assert-Path -Path $VhdxFilePath -PathType "Leaf" -ShallExist $true | Out-Null

	    Write-Log "Create new VM named $VmName"
	    New-VM -Name $VmName -vhdPath $VhdxFilePath -ErrorAction Stop | Write-Log
	    Write-Log "  - set its memory to $VMMemoryStartupBytes"
	    Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false -StartupBytes $VMMemoryStartupBytes -ErrorAction Stop
	    Write-Log "  - set its cpu count to $VMProcessorCount"
	    Set-VMProcessor -VMName $VmName -Count $VMProcessorCount -ErrorAction Stop
	    if ($useIsoFilePath) {
	    	Write-Log "  - set its DVD drive with $IsoFilePath"
	    	Set-VMDvdDrive -VMName $VmName -Path $IsoFilePath -ErrorAction Stop
	    }
	    Write-Log "  - resize it to $VMDiskSize"
	    Resize-VHD -Path $VhdxFilePath -SizeBytes $VMDiskSize -ErrorAction Stop
}

<#
.SYNOPSIS
Removes the VM used for provisioning
.DESCRIPTION
If the VM is found by using its name it is first disconnected from the Switch and afterwards deleted.
The given vhdx file is also deleted if existing.
.PARAMETER VmName
The name of the VM.
.PARAMETER VhdxFilePath
The full path to the vhdx file that was used with the VM.
#>
Function Remove-VirtualMachineForBaseImageProvisioning {
	param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VmName = $(throw "Argument missing: VmName"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VhdxFilePath = $(throw "Argument missing: VhdxFilePath")
    )

    Disconnect-VmFromSwitch -VmName $VmName

    Write-Log "Removing the VM $VmName"
    $vm = Get-VM -ErrorAction SilentlyContinue | Where-Object Name -Like $VmName
    if ($vm -ne $null) {
        Remove-VM -Name $VmName -Force
    }

    if (Test-Path $VhdxFilePath) {
        Remove-Item -Path $VhdxFilePath -Force
    }
}

function Connect-VmToSwitch {
	param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VmName = $(throw "Argument missing: VmName"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $SwitchName = $(throw "Argument missing: SwitchName")
        )

	Write-Log "Connect VM '$VmName' to the switch $SwitchName"
	Connect-VMNetworkAdapter -VmName $VmName -SwitchName $SwitchName -ErrorAction Stop
}

function Disconnect-VmFromSwitch {
	param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $VmName = $(throw "Argument missing: VmName")
        )

	Write-Log "Disconnect VM '$VmName' from switch"
    $vmFound = Get-VM -ErrorAction SilentlyContinue | Where-Object Name -eq $VmName | Select-Object -ExpandProperty VmName
    if ($null -ne $vmFound) {
	    Disconnect-VMNetworkAdapter -VmName $VmName -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
Starts a VM using its name.
.DESCRIPTION
The VM with the given name is started and awaited until it sends two heartbeats.
If the heartbeat is not received within the timeout, the VM is restarted and the wait is retried.
.PARAMETER Name
The name of the VM.
.PARAMETER HeartbeatTimeoutSeconds
The timeout in seconds to wait for each heartbeat (default: 120).
.PARAMETER MaxRetries
The maximum number of restart attempts if heartbeat is not received (default: 3).
#>
function Start-VirtualMachineAndWaitForHeartbeat {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $Name = $(throw "Argument missing: Name"),
        [int] $HeartbeatTimeoutSeconds = 120,
        [int] $MaxRetries = 3
        )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if ($attempt -gt 1) {
            Write-Log "[Heartbeat] Attempt $attempt of $MaxRetries - Restarting VM '$Name'..."
            Stop-VirtualMachine -VmName $Name -Wait
            Start-Sleep -Seconds 3
        }
        
        Start-VirtualMachine -VmName $Name

        Write-Log "[Heartbeat] Waiting for VM '$Name' to send first heartbeat (timeout: ${HeartbeatTimeoutSeconds}s)..."
        $firstHeartbeat = Wait-ForVMHeartbeatWithTimeout -VmName $Name -TimeoutSeconds $HeartbeatTimeoutSeconds
        
        if (-not $firstHeartbeat) {
            Write-Log "[Heartbeat] Timeout waiting for first heartbeat from VM '$Name'" -Error
            continue
        }
        
        Write-Log "[Heartbeat] First heartbeat received. Waiting for second heartbeat..."
        $secondHeartbeat = Wait-ForVMHeartbeatWithTimeout -VmName $Name -TimeoutSeconds $HeartbeatTimeoutSeconds
        
        if (-not $secondHeartbeat) {
            Write-Log "[Heartbeat] Timeout waiting for second heartbeat from VM '$Name'" -Error
            continue
        }
        
        Write-Log "[Heartbeat] VM '$Name' started successfully (attempt $attempt)"
        return
    }

    throw "Failed to receive heartbeat from VM '$Name' after $MaxRetries attempts"
}

<#
.SYNOPSIS
Waits for a VM heartbeat with a timeout.
.DESCRIPTION
Waits for the VM to send a heartbeat signal within the specified timeout.
.PARAMETER VmName
The name of the VM.
.PARAMETER TimeoutSeconds
The timeout in seconds to wait for the heartbeat.
.RETURNS
$true if heartbeat received, $false if timeout.
#>
function Wait-ForVMHeartbeatWithTimeout {
    param (
        [string] $VmName = $(throw "Argument missing: VmName"),
        [int] $TimeoutSeconds = 120
    )
    
    $job = Start-Job -ScriptBlock {
        param($vmName)
        Wait-VM -Name $vmName -For Heartbeat
        return $true
    } -ArgumentList $VmName
    
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    
    if ($null -eq $completed) {
        # Timeout reached
        Stop-Job -Job $job
        Remove-Job -Job $job -Force
        return $false
    }
    
    $result = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    return $result
}

<#
.SYNOPSIS
Creates a VM that has the OS debian cloud.
.DESCRIPTION
It creates a VM that uses a vhdx file having the OS debian cloud and attaches it to an iso file for cloud init on first start.
.PARAMETER VirtualMachineParams
A hashtable containing the parameters used for the VM. The needed keys are:
- VmName: the name of the VM
- VhdxName: the vhdx file name
- VMMemoryStartupBytes: the amount of startup bytes
- VMProcessorCount: the amount of CPU cores
- VMDiskSize: the size of the disk

.PARAMETER NetworkParams
A hashtable containing the parameters used for networking. The needed keys are:
- Proxy: the HTTP proxy to use
- SwitchName: the name of the switch to connect the VM
- HostIpAddress: the IP address of the Windows host
- HostIpPrefixLength: the prefix length of the host IP
- NatName: the name of the NAT
- NatIpAddress: the IP address of the NAT

.PARAMETER IsoFileParams
A hashtable containing the parameters used for creating the iso file. The needed keys are:
- IsoFileCreatorToolPath: the full path to the tool used for iso file creation
- IsoFileName: the name of the iso file
- SourcePath: the path to the sources that will be part of the iso file
- Hostname: the hostname that will have the VM
- NetworkInterfaceName: the name of the network adapter inside the VM
- IPAddressVM: the IP address of the VM
- IPAddressGateway: the gateway IP address that the VM will use
- UserName: the user name to log in into the VM
- UserPwd: the user password to log in into the VM

.PARAMETER WorkingDirectoriesParams
A hashtable containing the directories that will be used. The needed keys are:
- DownloadsDirectory: the full path of the directory where the artifacts downloaded from the internet will be stored.
- ProvisioningDirectory: the full path of the directory where the artifacts used during provisioning will be stored.
#>
Function New-LinuxCloudBasedVirtualMachine {
    Param (
        [Hashtable]$VirtualMachineParams,
        [Hashtable]$NetworkParams,
        [Hashtable]$IsoFileParams,
        [Hashtable]$WorkingDirectoriesParams,
        [parameter(Mandatory = $false, HelpMessage = 'The Linux distribution identifier (e.g. debian12, debian13).')]
        [string]$TargetDistribution = 'debian13'
    )
    $vmName = $VirtualMachineParams.VmName
    $inProvisioningVhdxName = $VirtualMachineParams.VhdxName
    $VMMemoryStartupBytes=$VirtualMachineParams.VMMemoryStartupBytes
    $VMProcessorCount=$VirtualMachineParams.VMProcessorCount
    $VMDiskSize=$VirtualMachineParams.VMDiskSize

    $Proxy = $NetworkParams.Proxy
    $SwitchName=$NetworkParams.SwitchName
    $HostIpAddress=$NetworkParams.HostIpAddress
    $HostIpPrefixLength=$NetworkParams.HostIpPrefixLength
    $NatName=$NetworkParams.NatName
    $NatIpAddress=$NetworkParams.NatIpAddress
    $dnsEntries = $NetworkParams.DnsIpAddresses
    $ReuseExistingSwitch = [bool]$NetworkParams.ReuseExistingSwitch
    $IsoFileCreatorToolPath = $IsoFileParams.IsoFileCreatorToolPath
    $IsoFileName = $IsoFileParams.IsoFileName
    $IsoContentTemplateSourcePath = $IsoFileParams.SourcePath
    $Hostname=$IsoFileParams.Hostname
    $NetworkInterfaceName=$IsoFileParams.NetworkInterfaceName
    $IPAddressVM=$IsoFileParams.IPAddressVM
    $IPAddressGateway=$IsoFileParams.IPAddressGateway
    $UserName=$IsoFileParams.UserName
    $UserPwd=$IsoFileParams.UserPwd

    $downloadsFolder = $WorkingDirectoriesParams.DownloadsDirectory
    $provisioningFolder = $WorkingDirectoriesParams.ProvisioningDirectory

    $inProvisioningVhdxPath = "$provisioningFolder\$inProvisioningVhdxName"

    $vm = Get-VM | Where-Object Name -Like $vmName

    Write-Log "Ensure not existence of VM $vmName"
    if ($null -ne $vm) {
    	Stop-VirtualMachine -VmName $vm -Wait
    	Remove-VirtualMachineForBaseImageProvisioning -Name $vmName -VhdxFilePath $inProvisioningVhdxPath
    }

    Write-Log "Ensure existence of directory $downloadsFolder"
    New-Folder $downloadsFolder | Out-Null

    Write-Log "Ensure existence of directory '$provisioningFolder'"
    New-Folder $provisioningFolder | Out-Null

    Write-Log "Create the base vhdx"
    New-VhdxFromCloudImage -Proxy $Proxy -TargetFilePath $inProvisioningVhdxPath -DownloadsDirectory $downloadsFolder -TargetDistribution $TargetDistribution

    Write-Log "Create the iso file"
    $isoContentParameterValues = [hashtable]@{
                                            Hostname=$Hostname
                                            NetworkInterfaceName=$NetworkInterfaceName
                                            IPAddressVM=$IPAddressVM
                                            IPAddressGateway=$IPAddressGateway
                                            IPAddressDnsServers=$dnsEntries
                                            UserName=$UserName
                                            UserPwd=$UserPwd
                                            }
    $isoFilePath = New-IsoFile -IsoFileCreatorToolPath $IsoFileCreatorToolPath `
                                -IsoFilePath "$provisioningFolder\$IsoFileName" `
                                -SourcePath $IsoContentTemplateSourcePath `
                                -IsoContentParameterValue $isoContentParameterValues
    $vmParams = @{
        "VmName"=$vmName
        "VhdxFilePath"=$inProvisioningVhdxPath
        "IsoFilePath"=$isoFilePath
        "VMMemoryStartupBytes"=$VMMemoryStartupBytes
        "VMProcessorCount"=$VMProcessorCount
        "VMDiskSize"=$VMDiskSize
    }
    New-VirtualMachineForBaseImageProvisioning @vmParams

    $vm = Get-VM -Name $vmName
    if ($vm -eq $null) {
        throw "The VM '$vmName' was not created."
    }

    Write-Log "Setup the network for provisioning the VM"

   if ($ReuseExistingSwitch) {
        Write-Log "Reusing existing switch '$SwitchName' for provisioning VM '$vmName'" -Console
        Write-Log "Attach the VM to existing network switch '$SwitchName'" -Console
        Connect-VmToSwitch -VmName $vmName -SwitchName $SwitchName
    }
    else {
        Remove-NetworkForProvisioning -SwitchName $SwitchName -NatName $NatName
        $networkParams = @{
            "SwitchName"=$SwitchName
            "HostIpAddress"=$HostIpAddress
            "HostIpPrefixLength"=$HostIpPrefixLength
            "NatName"=$NatName
            "NatIpAddress"=$NatIpAddress
        }
        try {
            New-NetworkForProvisioning @networkParams

            Write-Log "Attach the VM to a network switch"
            Connect-VmToSwitch -VmName $vmName -SwitchName $SwitchName
        }
        catch {
            Write-Log "[Provisioning] Network setup failed, cleaning up: $_"
            Remove-NetworkForProvisioning -SwitchName $SwitchName -NatName $NatName
            throw
        }
}

}

<#
.SYNOPSIS
Stops a VM using its name.
.DESCRIPTION
The VM with the given name is stopped and awaited until its associated .avhdx file disappears from the file system.
The check for the file is done every 5 seconds for at most 30 times.
.PARAMETER Name
The name of the VM.
#>
function Stop-VirtualMachineForBaseImageProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string] $Name = $(throw "Argument missing: Name")
    )
    $virtualMachine = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $virtualMachine -and $virtualMachine.State -ne "Off") {
        Stop-VM -Name $Name

        $waitingTimeInSeconds = 5
        $maxWaitingTimeInSeconds = 60 * 6
        $elapsedTimeInSeconds = 0
        while (((Get-VMHardDiskDrive -VMName $Name).Path.Contains(".avhdx")) -and ($elapsedTimeInSeconds -lt $maxWaitingTimeInSeconds)) {
            Start-Sleep -Seconds $waitingTimeInSeconds
            $elapsedTimeInSeconds += $waitingTimeInSeconds
            Write-Log "Waiting since $elapsedTimeInSeconds seconds for VM to stop."
        }
        if ($virtualMachine.State -ne "Off") {
            throw "The VM '$Name' could not be stopped in $maxWaitingTimeInSeconds seconds."
        }
    }
}

## Security

<#
.SYNOPSIS
Removes an ssh key from the 'knownhosts' file
.DESCRIPTION
Using the given IP address the corresponding entry is deleted from the file 'knownhosts'
.PARAMETER IpAddress
The IP address to look for and delete from the file.
#>
Function Remove-SshKeyFromKnownHostsFile {
    param (
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    ssh-keygen.exe -R $IpAddress 2>&1 | ForEach-Object { "$_" } | Write-Log
}

## Network for provisioning

function New-NetworkForProvisioning {
    Param(
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$SwitchName = $(throw "Argument missing: SwitchName"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$HostIpAddress = $(throw "Argument missing: HostIpAddress"),
        [ValidateRange(0,32)]
        [uint16]$HostIpPrefixLength = $(throw "Argument missing: HostIpPrefixLength"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$NatName = $(throw "Argument missing: NatName"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$NatIpAddress = $(throw "Argument missing: NatIpAddress")
    )

    $switchAlias = "vEthernet ($SwitchName)"
    $maxRetries = 3
    $retryDelaySeconds = 5

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-Log "[Provisioning] Create internal switch '$SwitchName' (attempt $attempt of $maxRetries)"
            New-VMSwitch -Name $SwitchName -SwitchType Internal -ErrorAction Stop | Out-Null

            # allow Windows networking stack to register the virtual adapter
            Start-Sleep -Seconds 2

            Wait-ForNetIpInterface -SwitchName $switchAlias

            # switch and interface are available
            Write-Log "[Provisioning] VMSwitch '$SwitchName' created and interface '$switchAlias' is ready"
            break
        }
        catch {
            Write-Log "[Provisioning] Attempt $attempt failed: $_"

            # clean up partially-created switch before retrying
            $sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
            if ($sw) {
                Write-Log "[Provisioning] Removing partially-created switch '$SwitchName' before retry ..."
                Remove-VMSwitch -Name $SwitchName -Force
            }

            if ($attempt -ge $maxRetries) {
                throw "[Provisioning] Failed to create switch '$SwitchName' and wait for interface after $maxRetries attempts. Last error: $_"
            }

            Write-Log "[Provisioning] Retrying in $retryDelaySeconds seconds ..."
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }

    New-NetIPAddress -IPAddress $HostIpAddress -PrefixLength $HostIpPrefixLength -InterfaceAlias $switchAlias | Write-Log
    Write-Log "Added IP address '$HostIpAddress' to network interface named '$switchAlias'"

    $address = "$NatIpAddress/$HostIpPrefixLength"
    $nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if( $nat ) { Remove-NetNat -Name $NatName -Confirm:$False -ErrorAction SilentlyContinue }
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $address -ErrorAction SilentlyContinue | Write-Log
    Write-Log "Created NetNat '$NatName' with address '$address'"
}

<#
.SYNOPSIS
Removes the network components used by the VM.
.DESCRIPTION
Removes the network components used by the VM.
.PARAMETER SwitchName
The name of the switch used by the VM.
.PARAMETER NatName
The name of the used NAT device.
#>
function Remove-NetworkForProvisioning {
    Param(
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$SwitchName = $(throw "Argument missing: SwitchName"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$NatName = $(throw "Argument missing: NatName")
    )

	Write-Log "Removing NetNat '$NatName' if existing"
	Get-NetNat | Where-Object Name -Like $NatName | Remove-NetNat -Confirm:$false

	Write-Log "Removing VMSwitch '$SwitchName' if existing"
	Get-VMSwitch | Where-Object Name -Like $SwitchName | Select-Object -ExpandProperty Name | Remove-VMSwitch -Force
}

## HELPERS

Function Convert-Text {
    param (
        [string]$Source = $(throw "Argument missing: Source"),
        [hashtable]$ConversionTable = $(throw "Argument missing: ConversionTable")
    )
    $convertedSource = $Source
    foreach ($item in $ConversionTable.GetEnumerator() )
    {
        $convertedSource = $convertedSource -replace $item.Name,$item.Value
    }
    $convertedSource
}

Function Invoke-Tool {
    param (
        [string]$ToolPath = $(throw "Argument missing: ToolPath"),
        [string]$Arguments
    )

    $output = $(Start-Process -FilePath $ToolPath -ArgumentList $Arguments  -WindowStyle Hidden -Wait 2>&1 )

    if ($LASTEXITCODE -ne 0) {
        Write-Log $output
        throw "Tool '$ToolPath' returned code '$LASTEXITCODE'."
    }
}

Function New-Folder {
    param (
        [Parameter(Mandatory = $false, ValueFromPipeline=$true)]
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [string]$Path
    )

    $pathAlreadyExists = Test-Path $Path -ErrorAction Stop
    if (!$pathAlreadyExists) {
    	New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    [PSCustomObject]@{
        Path = $Path
        Existed = $pathAlreadyExists
    }
}

<#
.SYNOPSIS
Copies a vhdx file from a source to a target location.
.DESCRIPTION
Copies a vhdx file from a source to a target location.
.PARAMETER SourceFilePath
The full path of the source vhdx file.
.PARAMETER TargetPath
The full path of the vhdx file after being copied.
#>
Function Copy-VhdxFile {
    param (
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern ".*\.vhdx$" })]
        [string] $SourceFilePath = $(throw "Argument missing: SourceFilePath"),

        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern ".*\.vhdx$" })]
        [string] $TargetPath = $(throw "Argument missing: TargetPath")
    )
    Assert-Path -Path $SourceFilePath -PathType "Leaf" -ShallExist $true | Out-Null
    Assert-Path -Path $TargetPath -PathType "Leaf" -ShallExist $false | Out-Null
    Assert-Path -Path (Split-Path $TargetPath) -PathType "Container" -ShallExist $true | Out-Null

    Copy-Item -Path $SourceFilePath -Destination $TargetPath -Force -ErrorAction Stop | Out-Null
}

Export-ModuleMember -Function Remove-VirtualMachineForBaseImageProvisioning, 
Start-VirtualMachineAndWaitForHeartbeat, 
Wait-ForVMHeartbeatWithTimeout, 
New-LinuxCloudBasedVirtualMachine, 
Stop-VirtualMachineForBaseImageProvisioning, 
Remove-SshKeyFromKnownHostsFile, 
Remove-NetworkForProvisioning, 
Copy-VhdxFile, 
New-VirtualMachineForBaseImageProvisioning, 
New-NetworkForProvisioning
