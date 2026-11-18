# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$pathModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$configModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
Import-Module $logModule, $pathModule, $configModule

function Add-K2sToDefenderExclusion {
    # Stop Microsoft Defender interference with K2s setup
    $kubePath = Get-KubePath
    Add-MpPreference -Exclusionpath "$kubePath" -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess 'k2s.exe', 'vmmem.exe', 'vmcompute.exe', 'containerd.exe', 'kubelet.exe', 'httpproxy.exe', 'dnsproxy.exe', 'kubeadm.exe', 'kube-proxy.exe', 'bridge.exe', 'containerd-shim-runhcs-v1.exe' -ErrorAction SilentlyContinue
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
    Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction SilentlyContinue
}

function Stop-InstallIfDockerDesktopIsRunning {
    if ((Get-Service 'com.docker.service' -ErrorAction SilentlyContinue).Status -eq 'Running') {
        throw 'Docker Desktop is running! Please stop Docker Desktop in order to continue!'
    }
}

<#
.SYNOPSIS
    Enables a specified Windows feature.
.DESCRIPTION
    Enables a specified Windows feature if disabled.
.PARAMETER Name
    The feature name
.OUTPUTS
    TRUE, if it was necessary to enabled it AND a restart is required. Otherwise, FALSE.
.EXAMPLE
    Enable-MissingFeature -Name 'Containers'
#>
function Enable-MissingFeature {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the feature name.')
    )

    $featureState = (Get-WindowsOptionalFeature -Online -FeatureName $Name).State

    if ($featureState -match 'Disabled') {
        Write-Log "WindowsOptionalFeature '$Name' is '$featureState'. Will activate feature..."

        $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart -WarningAction SilentlyContinue -ErrorAction Stop
        if ($null -eq $enableResult) {
            throw "[PREREQ-FAILED] Enabling WindowsOptionalFeature '$Name' returned no result"
        }
        $restartNeeded = [bool]$enableResult.RestartNeeded
        Write-Log "WindowsOptionalFeature '$Name' enabled. Restart needed: $restartNeeded"

        return $restartNeeded
    }

    return $false
}

function Enable-MissingWindowsFeatures($wsl) {
    $restartRequired = $false

    $isServerOS = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName.Contains('Server')

    $features = @('Microsoft-Hyper-V', 'Microsoft-Hyper-V-Management-PowerShell', 'Containers', 'VirtualMachinePlatform')

    if (!$isServerOS) {
        $features += 'Microsoft-Hyper-V-All', 'Microsoft-Hyper-V-Tools-All', 'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Management-Clients', 'Microsoft-Hyper-V-Services'
    }

    foreach ($feature in $features) {
        if (Enable-MissingFeature -Name $feature) {
            $restartRequired = $true
        }
    }

    Write-Log 'Enable windows container version check skip'
    REG ADD 'HKLM\SYSTEM\CurrentControlSet\Control\Windows Containers' /v SkipVersionCheck /t REG_DWORD /d 2 /f

    if ($wsl) {
        Write-Log 'Disable Remote App authentication warning dialog'
        REG ADD 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /V 'AuthenticationLevel' /T REG_DWORD /D '0' /F
    }

    if ($restartRequired) {
        Write-Log '!!! Restart is required. Reason: Changes in WindowsOptionalFeature. Please call install after reboot again. !!! '
        throw '[PREREQ-FAILED] !!! Restart is required. Reason: Changes in WindowsOptionalFeature !!!'
    }
}

function Set-WSL {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [long] $MasterVMMemory = $(throw 'Please specify kubemaster VM memory'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [long] $MasterVMProcessorCount = $(throw 'Please specify kubemaster VM processor count')
    )

    Write-Log 'Disable Remote App authentication warning dialog'
    REG ADD 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /V 'AuthenticationLevel' /T REG_DWORD /D '0' /F

    wsl --shutdown
    wsl --update
    wsl --version

    $wslConfigPath = "$env:USERPROFILE\.wslconfig"
    if (Test-Path -Path $wslConfigPath) {
        Remove-Item $("$wslConfigPath.old") -Force -ErrorAction SilentlyContinue
        Rename-Item -Path $wslConfigPath -NewName '.wslconfig.old' -Force
    }

    $wslConfig = @"
[wsl2]
swap=0
memory=$MasterVMMemory
processors=$MasterVMProcessorCount
localhostForwarding=false
dnsProxy=false
dnsTunneling=false
"@
    $wslConfig | Out-File -FilePath $wslConfigPath
}


function Test-WindowsPrerequisites(
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting control plane VM (Linux)')]
    [switch] $WSL = $false) {
    Add-K2sToDefenderExclusion
    Stop-InstallIfDockerDesktopIsRunning

    $ReleaseId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    if ($ReleaseId -lt 17763) {
        Write-Log "k2s needs minimal Windows Version 1809, you have $ReleaseId"
        throw "[PREREQ-FAILED] Windows release $ReleaseId not usable"
    }

    if($WSL) {
        Stop-InstallationIfWslNotEnabled
    }
    Enable-MissingWindowsFeatures $([bool]$WSL)
    Stop-InstallationIfHyperVApiAccessFailed
    Test-DefaultSwitch
}

function Get-StorageLocalFolderName{
    $storageLocalDriveFolder= ''
    $storageLocalDriveFolder = Get-ConfiguredstorageLocalDriveFolder;
    return "\\" + $storageLocalDriveFolder ;
}

function Get-StorageLocalDrive {
    $storageLocalDriveLetter = ''

    $usedStorageLocalDriveLetter = Get-ConfigUsedStorageLocalDriveLetter
    if (!([string]::IsNullOrWhiteSpace($usedStorageLocalDriveLetter))) {
        $storageLocalDriveLetter = $usedStorageLocalDriveLetter
    }
    else {
        $configuredStorageLocalDriveLetter = Get-ConfiguredStorageLocalDriveLetter
        $searchAvailableFixedLogicalDrives = {
            $fixedHardDrives = Get-CimInstance -ClassName Win32_DiskDrive | Where-Object { $_.Mediatype -eq 'Fixed hard disk media' }
            $partitionsOnFixedHardDrives = $fixedHardDrives | Foreach-Object { Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID=`"$($_.DeviceID.Replace('\','\\'))`"} WHERE AssocClass = Win32_DiskDriveToDiskPartition" }
            $fixedLogicalDrives = $partitionsOnFixedHardDrives | Foreach-Object { Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID=`"$($_.DeviceID)`"} WHERE AssocClass = Win32_LogicalDiskToPartition" }
            return $fixedLogicalDrives | Sort-Object $_.DeviceID
        }
        if ([string]::IsNullOrWhiteSpace($configuredStorageLocalDriveLetter)) {
            $fixedLogicalDrives = $searchAvailableFixedLogicalDrives.Invoke()
            # no drive letter is configured --> use the local drive with the most space available
            $fixedLogicalDriveWithMostSpaceAvailable = $($fixedLogicalDrives | Sort-Object -Property FreeSpace -Descending | Select-Object -Property DeviceID -First 1).DeviceID
            $storageLocalDriveLetter = $fixedLogicalDriveWithMostSpaceAvailable.Substring(0, 1)
        }
        else {
            if ($configuredStorageLocalDriveLetter -match '^[a-zA-Z]$') {
                $storageLocalDriveLetter = $configuredStorageLocalDriveLetter
                $searchedLogicalDeviceID = $storageLocalDriveLetter + ':'
                $fixedLogicalDrives = $searchAvailableFixedLogicalDrives.Invoke()
                $foundFixedLogicalDrive = $fixedLogicalDrives | Where-Object { $_.DeviceID -eq $searchedLogicalDeviceID }
                if ($null -eq $foundFixedLogicalDrive) {
                    $availableFixedLogicalDrives = (($fixedLogicalDrives | Select-Object -Property DeviceID) | ForEach-Object { $_.DeviceID.Substring(0, 1) }) -join ', '
                    throw "The configured local drive letter '$configuredStorageLocalDriveLetter' is not a local fixed drive or is not available in your system.`nYour available local fixed drives are: $availableFixedLogicalDrives. Please choose one of them."
                }
            }
            else {
                throw "The configured local drive letter '$configuredStorageLocalDriveLetter' is syntactically wrong. Please choose just a valid letter of an available local fixed drive."
            }
        }

        Set-ConfigUsedStorageLocalDriveLetter -Value $storageLocalDriveLetter | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($storageLocalDriveLetter)) {
        throw 'The local drive letter for the storage could not be determined'
    }

    return $storageLocalDriveLetter + ':'
}

<#
.Description
Invoke-DownloadFile download file from internet.
#>
function Invoke-DownloadFile($destination, $source, $forceDownload,
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

    # Windows' bundled curl.exe applies Mark-of-the-Web (Zone.Identifier) via the Attachment
    # Execution Service, same as a browser download would. Harmless for non-executables; for
    # anything later run directly (plink.exe/pscp.exe here - k2s's own SSH/SCP client for
    # every control-plane VM operation), it's what triggers a blocking SmartScreen
    # reputation-check prompt with no interactive user to dismiss it.
    Unblock-File -Path $destination
}

<#
.Description
Stop-InstallIfNoMandatoryServiceIsRunning checks for mandatory services on the system.
#>
function Stop-InstallIfNoMandatoryServiceIsRunning {
    $hns = Get-Service 'hns' -ErrorAction SilentlyContinue
    if (!$hns) {
        throw '[PREREQ-FAILED] Host Network Service is not running. This is required for Windows containers. Please enable prerequisites for K2s - https://github.com/k2s-project/k2s !'
    }
    $hcs = Get-Service 'vmcompute' -ErrorAction SilentlyContinue
    if (!$hcs) {
        throw '[PREREQ-FAILED] Host Compute Service is not running. This is needed for containers. Please enable prerequisites for K2s - https://github.com/k2s-project/k2s !'
    }
}

function Stop-InstallationIfRequiredCurlVersionNotInstalled {
    try {
        $versionOutput = curl.exe --version
    }
    catch {
        $errorMessage = "[PREREQ-FAILED] The tool 'curl' is not installed. Please install it and add its installation location to the 'PATH' environment variable"
        Write-Log $errorMessage
        throw $errorMessage
    }
    $actualVersionAsString = ($versionOutput -split '\s')[1]
    try {
        $actualVersionParts = ($actualVersionAsString -split '\.') | ForEach-Object { [int]$_ }
        $actualVersion = [Version]::new($actualVersionParts[0], $actualVersionParts[1], $actualVersionParts[2])
    }
    catch {
        $errorMessage = "[PREREQ-FAILED] The version of 'curl' could not be determined because: `n $_"
        Write-Log $errorMessage
        throw $errorMessage
    }

    $minimumRequiredVersion = [Version]'7.71.0'

    if ($actualVersion -lt $minimumRequiredVersion) {
        $errorMessage = ("[PREREQ-FAILED] The installed version of 'curl' ($actualVersionAsString) is not at least the required one ($($minimumRequiredVersion.ToString())).",
            "`n",
            "Call 'curl.exe --version' to check the installed version.",
            "`n",
            "Update 'curl' and add its installation location to the 'PATH' environment variable.")
        Write-Log $errorMessage
        throw $errorMessage
    }
}

function Write-WarningIfRequiredSshVersionNotInstalled {
    try {
        $sshPath = (Get-Command 'ssh.exe').Path
        $majorVersion = (Get-Item $sshPath).VersionInfo.FileVersionRaw.Major
        $fileVersion = (Get-Item $sshPath).VersionInfo.FileVersion
    }
    catch {
        $errorMessage = "[PREREQ-FAILED] The tool 'ssh' is not installed. Please install it and add its installation location to the 'PATH' environment variable"
        Write-Log $errorMessage
        throw $errorMessage
    }

    if ($majorVersion -lt 8) {
        $warnMessage = "[PREREQ-WARNING] The installed version of 'ssh' ($fileVersion) is not at least the required one (major version 8). " `
            + "Call 'ssh.exe -V' to check the installed version. " `
            + "Update 'ssh' and add its installation location to the 'PATH' environment variable to ensure successful cluster installation."

        Write-Log $warnMessage
    }
}

function Add-K2sAppLockerRules {
    # apply rules only if applocker is active
    # if applocker will be activated in future, then the policy from \cfg\applocker\applockerrules.xml needs to be applied manually
    $ServiceName = 'appidsvc'
    $svcstatus = $(Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
    if ($svcstatus -eq 'Running') {
        $kubePath = Get-KubePath
        $appLockerRules = $kubePath + '\cfg\applocker\applockerrules.xml'
        Write-Log "Adding AppLocker rules from $appLockerRules"
        Set-AppLockerPolicy -XmlPolicy $appLockerRules -Merge
    }
}

function Remove-K2sAppLockerRules {
    $AppLockerPolicyFile = "$Env:Temp\CurrentAppLockerRules.xml"
    [xml]$AppLockerPolicy = Get-AppLockerPolicy -Xml -Local
    $node = $AppLockerPolicy.SelectSingleNode("//AppLockerPolicy/RuleCollection/FilePathRule[@Id='0bf9e8e6-42cf-41cc-8737-68c788984e0d']")
    if($null -ne $node)
    {
       Write-Log "Removing AppLocker rule"
       [void]$node.ParentNode.RemoveChild($node)
       $AppLockerPolicy.Save($AppLockerPolicyFile)
       Set-AppLockerPolicy -XmlPolicy $AppLockerPolicyFile
       Remove-Item $AppLockerPolicyFile -Force
    }
}

<#
.SYNOPSIS
    Removes event log sources whose message files are located in the K2s installation folder.
.DESCRIPTION
    Removing a service does not remove its event log source registration under
    'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application'. nssm, for example, registers the source 'nssm'
    with the K2s copy of nssm.exe as message file whenever a service is installed or started.
    The Windows Event Log service loads the message files of registered sources and keeps them open,
    so a stale registration keeps a handle on a file in the installation folder after uninstall.
    Removing the registration prevents new handles; a handle that is already open is released when the
    Event Log service restarts, e.g. on the next reboot.
.PARAMETER InstallationPath
    K2s installation folder
.EXAMPLE
    Remove-K2sEventLogSources -InstallationPath 'C:\k'
#>
function Remove-K2sEventLogSources {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $InstallationPath = $(throw 'Please provide the installation path.')
    )
    $installationFolder = $InstallationPath.TrimEnd('\') + '\'
    if ($installationFolder -match '^[a-zA-Z]:\\$') {
        # every source with a message file on that drive would match
        Write-Log "Skipping removal of event log sources, installation path '$InstallationPath' is a drive root"
        return
    }
    $messageFileProperties = 'EventMessageFile', 'CategoryMessageFile', 'ParameterMessageFile'

    Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application' -ErrorAction SilentlyContinue | ForEach-Object {
        $source = $_
        $properties = Get-ItemProperty -Path $source.PSPath -ErrorAction SilentlyContinue
        $messageFiles = foreach ($property in $messageFileProperties) {
            # a message file property may contain a semicolon-separated list of files
            "$($properties.$property)" -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')) }
        }
        $installedMessageFile = $messageFiles | Where-Object { $_.StartsWith($installationFolder, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if (!$installedMessageFile) {
            return
        }

        Write-Log "Removing event log source '$($source.PSChildName)' with message file '$installedMessageFile'"
        try {
            Remove-Item -Path $source.PSPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Log "Failed to remove event log source '$($source.PSChildName)': $($_.Exception.Message)"
        }
    }
}

<#
.DESCRIPTION
    Verifies if  Hyper-V PowerShell module can be loaded,
    and whether calling Get-VM succeeds. Throws on error if the module cannot be loaded or Get-VM API is inaccessible.
#>
function Stop-InstallationIfHyperVApiAccessFailed {
    try {
        Import-Module Hyper-V -ErrorAction Stop
        Get-VM -ErrorAction Stop
        Write-Log "Hyper-V API accessible(Get-VM success)."
    }
    catch {
        throw "[PREREQ-FAILED] Hyper-V API is not accessible. Restart is required. Reason: Changes in WindowsOptionalFeature. Please call install after reboot again. Error: $($_.Exception.Message)"
    }
}

<#
.DESCRIPTION
    Verifies if WSL is  installed or enabled, Does not throw if it is enabled.
#>
function Stop-InstallationIfWslNotEnabled {
    if (-not (Get-WindowsOptionalFeatureStatus -Name 'Microsoft-Windows-Subsystem-Linux')) {
        throw "[PREREQ-FAILED] WSL is not enabled. Please enable 'Microsoft-Windows-Subsystem-Linux' and then call install after reboot again."
    }
    Write-Log 'WSL is enabled.'
}

function Get-WindowsOptionalFeatureStatus {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the feature name.')
    )
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop
        if ($null -eq $feature -or $feature.State -ne 'Enabled') {
            Write-Log "[PREREQ-FAILED] '$Name' feature is not installed or enabled."
            return $false
        }
        return $true
    }
    catch {
        Write-Log "[PREREQ-FAILED] Failed to query feature '$Name': $($_.Exception.Message)"
        return $false
    }
}



Export-ModuleMember -Function Add-K2sToDefenderExclusion,
Test-WindowsPrerequisites,
Set-WSL,
Get-StorageLocalDrive,
Get-StorageLocalFolderName,
Invoke-DownloadFile,
Stop-InstallIfNoMandatoryServiceIsRunning,
Stop-InstallationIfRequiredCurlVersionNotInstalled,
Write-WarningIfRequiredSshVersionNotInstalled,
Add-K2sAppLockerRules,
Remove-K2sAppLockerRules,
Remove-K2sEventLogSources
