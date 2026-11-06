# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$pathModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
Import-Module $pathModule, $logModule

<#
.SYNOPSIS
    Starts a given VM
.DESCRIPTION
    Starts a given VM specified by name and waits for the VM to be started, if desired.
.PARAMETER VmName
    Name of the VM to start
.PARAMETER Wait
    If set to TRUE, the function waits for the VM to reach the 'running' state.
.EXAMPLE
    Start-VirtualMachine -VmName "Test-VM"
.EXAMPLE
    Start-VirtualMachine -VmName "Test-VM" -Wait
    Waits for the VM to reach the 'running' state.
.NOTES
    The underlying function thrown an exception when the wait timeout is reached.
#>
function Start-VirtualMachine {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to start.'),
        [Parameter(Mandatory = $false)]
        [Switch]$Wait = $false
    )

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        Write-Log "None or more than one VMs found for name '$VmName', aborting start."
        return
    }

    Write-Log "Starting VM '$VmName' ..."

    $maxRetries = 4
    $retryDelay = 20
    $lastStartError = $null
    
    for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
            Start-VM -Name $VmName -ErrorAction Stop
            Write-Log 'VM started successfully'
            break
        }
        catch {
            $lastStartError = $_
            Write-Log "[VMStart] Failed to start '$VmName' (id: $($private:vm.Id), attempt: $($i + 1)/$maxRetries, error id: $($lastStartError.FullyQualifiedErrorId), category: $($lastStartError.CategoryInfo.Category)): $($lastStartError.Exception.Message)"
            try {
                $memory = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
                Write-Log "Free RAM memory: $($memory.FreePhysicalMemory)"
                Write-Log "Free virtual memory: $($memory.FreeVirtualMemory)"
            }
            catch {
                Write-Log "[VMStart] Failed to collect memory diagnostics for '$VmName': $($_.Exception.Message)"
            }
            Start-Sleep -Seconds $retryDelay
        }
    }
    
    if ($i -eq $maxRetries) {
        $message = "Failed to start VM $VmName after $maxRetries retries. Last Hyper-V error: $($lastStartError.Exception.Message)"
        Write-Log "[VMStart] $message"
        throw [System.InvalidOperationException]::new($message, $lastStartError.Exception)
    }

    if ($Wait -eq $true) {
        Wait-ForDesiredVMState -VmName $VmName -State 'running'
    }

    Write-Log "VM '$VmName' started."
}

<#
.SYNOPSIS
    Stops a given VM
.DESCRIPTION
    Stops a given VM specified by name and waits for the VM to be stopped, if desired.
.PARAMETER VmName
    Name of the VM to stop
.PARAMETER Wait
    If set to TRUE, the function waits for the VM to reach the 'off' state.
.PARAMETER TimeoutInSeconds
    Maximum time to wait for the stop operation and optional state check. Default is 360.
.EXAMPLE
    Stop-VirtualMachine -VmName "Test-VM"
.EXAMPLE
    Stop-VirtualMachine -VmName "Test-VM" -Wait
    Waits for the VM to reach the 'off' state.
.NOTES
    The underlying function thrown an exception when the wait timeout is reached.
#>
function Stop-VirtualMachine {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to stop.'),
        [Parameter(Mandatory = $false)]
        [Switch]$Wait = $false,
        [ValidateRange(1, 3600)]
        [int]$TimeoutInSeconds = 360
    )

    $private:vm = Get-VM -ErrorAction SilentlyContinue | Where-Object Name -eq $VmName

    $vmCount = ($private:vm | Measure-Object).Count
    if ($vmCount -eq 0) {
        Write-Log "[VMStop] VM '$VmName' not found, skipping stop."
        return
    }
    if ($vmCount -gt 1) {
        $message = "[VMStop] More than one VM found for name '$VmName', aborting stop."
        Write-Log $message -Console
        throw $message
    }

    if ($private:vm.State -eq 'Off') {
        Write-Log "[VMStop] VM '$VmName' is already off."
        return
    }

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $stopJob = $null
    Write-Log "[VMStop] Stopping VM '$VmName' (id: $($private:vm.Id), initial state: $($private:vm.State), status: $($private:vm.Status), timeout: ${TimeoutInSeconds}s)."
    try {
        # -Force retains the existing shutdown policy; -AsJob prevents its internal wait from hiding our timeout.
        $stopJob = Stop-VM -Name $VmName -Force -AsJob -WarningAction SilentlyContinue -ErrorAction Stop
        if ($null -eq $stopJob) {
            throw "Hyper-V returned no stop job for VM '$VmName'."
        }
        $remainingSeconds = [int][Math]::Ceiling($TimeoutInSeconds - $timer.Elapsed.TotalSeconds)
        if ($remainingSeconds -le 0 -or $null -eq (Wait-Job -Job $stopJob -Timeout $remainingSeconds -ErrorAction Stop)) {
            throw "VM '$VmName' stop operation exceeded ${TimeoutInSeconds}s. Hyper-V may still be processing the shutdown; no additional TurnOff operation was requested."
        }
        Receive-Job -Job $stopJob -ErrorAction Stop | Out-Null
        if ($stopJob.State -ne 'Completed') {
            throw "VM '$VmName' stop job ended with state '$($stopJob.State)': $($stopJob.JobStateInfo.Reason)"
        }

        if ($Wait -eq $true) {
            $remainingSeconds = [int][Math]::Max(0, [Math]::Floor($TimeoutInSeconds - $timer.Elapsed.TotalSeconds))
            Wait-ForDesiredVMState -VmName $VmName -State 'off' -TimeoutInSeconds $remainingSeconds
        }

        Write-Log "[VMStop] VM '$VmName' stopped after $([Math]::Round($timer.Elapsed.TotalSeconds, 1))s."
    }
    catch {
        $jobState = if ($null -ne $stopJob) { $stopJob.State } else { 'NotCreated' }
        Write-Log "[VMStop] Failed to stop '$VmName' (id: $($private:vm.Id), initial state: $($private:vm.State), job state: $jobState, elapsed: $([Math]::Round($timer.Elapsed.TotalSeconds, 1))s): $($_.Exception.Message)" -Console
        throw
    }
    finally {
        if ($null -ne $stopJob -and $stopJob.State -in @('Completed', 'Failed', 'Stopped')) {
            try {
                Remove-Job -Job $stopJob -ErrorAction Stop
            }
            catch {
                Write-Log "[VMStop] Failed to remove stop job for '$VmName': $($_.Exception.Message)" -Console
            }
        }
        elseif ($null -ne $stopJob) {
            # Removing an unfinished Hyper-V job with -Force can call its blocking StopJob implementation.
            Write-Log "[VMStop] Retaining unfinished stop job $($stopJob.Id) for '$VmName' (state: $($stopJob.State)); Hyper-V may still be processing shutdown." -Console
        }
    }
}

<#
.SYNOPSIS
    Removes a given VM completely
.DESCRIPTION
    Removes a given VM and it's virtual disk if desired.
.PARAMETER VmName
    Name of the VM to remove
.PARAMETER DeleteVirtualDisk
    Indicating whether the VM's virtual disk should be removed as well (default: TRUE).
.EXAMPLE
    Remove-VirtualMachine -VmName "Test-VM"
    Deletes the VM and it's virtual disk
.EXAMPLE
    Remove-VirtualMachine -VmName "Test-VM" -DeleteVirtualDisk $false
    Deletes the VM but not it's virtual disk
#>
function Remove-VirtualMachine {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to remove.'),
        [Parameter()]
        [bool] $DeleteVirtualDisk = $true
    )

    $private:vm = Get-VM -ErrorAction SilentlyContinue | Where-Object Name -eq $VmName

    $vmCount = ($private:vm | Measure-Object).Count
    if ($vmCount -eq 0) {
        Write-Log "VM '$VmName' not found, skipping removal."
        return
    }
    if ($vmCount -gt 1) {
        Write-Log "More than one VM found for name '$VmName', aborting removal."
        return
    }

    if ($DeleteVirtualDisk) {
        Remove-VMSnapshots -Vm $private:vm
    }

    $hardDiskPath = ($private:vm | Select-Object -ExpandProperty HardDrives).Path

    Write-Log "Removing VM '$VmName' ($($private:vm.VMId)) ..."
    Remove-VM -Name $VmName -Force
    Write-Log "VM '$VmName' removed."

    if ($DeleteVirtualDisk) {
        Write-Log "Removing hard disk '$hardDiskPath' ..."

        Remove-Item -Path $hardDiskPath -Force

        Write-Log "Hard disk '$hardDiskPath' removed."
    }
    else {
        Write-Log "Keeping virtual disk '$hardDiskPath'."
    }
}

<#
.SYNOPSIS
    Removes all snapshots of a given VM
.DESCRIPTION
    Removes all snapshots of a given VM and waits for the virtual disks to merge
.PARAMETER Vm
    The VM of which the snapshots shall be removed
.EXAMPLE
    $vm = Get-VM | Where-Object Name -eq "my-VM"
    Remove-VMSnapshots -Vm $vm
#>
function Remove-VMSnapshots {
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [Microsoft.HyperV.PowerShell.VirtualMachine] $Vm = $(throw 'Please specify the VM of which you want to remove the snapshots.')
    )

    Write-Log 'Removing VM snapshots ...'

    Get-VMSnapshot -VMName $Vm.Name | Remove-VMSnapshot

    Write-Log 'Waiting for disks to merge ...'

    while ($Vm.Status -eq 'merging disks') {
        Write-Log '.'

        Start-Sleep -Milliseconds 500
    }

    # give the VM object time to refresh it's virtual disk path property
    Start-Sleep -Milliseconds 500

    Write-Log ''
    Write-Log 'VM snapshots removed.'
}

<#
.SYNOPSIS
    Waits for a given VM to get into a given state.
.DESCRIPTION
    Waits for a given VM to get into a given state. The timeout is configurable.
.PARAMETER VmName
    Name of the VM to wait for
.PARAMETER State
    Desired state
.PARAMETER TimeoutInSeconds
    Timeout in seconds. Default is 360.
.EXAMPLE
    Wait-ForDesiredVMState -VmName 'Test-VM' -State 'off'
    Waits for the VM to be shut down.
.EXAMPLE
    Wait-ForDesiredVMState -VmName 'Test-VM' -TimeoutInSeconds 30 -State 'off'
    Wait max. 30 seconds until the VM must be shut down.
.NOTES
    Throws exception if VM was not found or more than one VMs with the given name exist.
    Throws exception if the desired state is invalid. State names are checked case-insensitive.
#>
function Wait-ForDesiredVMState {
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $VmName = $(throw 'Please specify the VM you want to wait for.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $State = $(throw 'Please specify the desired VM state.'),
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3600)]
        [int]$TimeoutInSeconds = 360
    )

    $secondsIncrement = 1
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    if ([System.Enum]::GetValues([Microsoft.HyperV.PowerShell.VMState]) -notcontains $State) {
        throw "'$State' is an invalid VM state!"
    }

    Write-Log "Waiting for VM '$VmName' to be in state '$State' (timeout: $($TimeoutInSeconds)s) ..."

    $private:vm = Get-VM | Where-Object Name -eq $VmName

    if (($private:vm | Measure-Object).Count -ne 1) {
        throw "None or more than one VMs found for name '$VmName', aborting!"
    }

    while (($private:vm.State -ne $State) -and ($timer.Elapsed.TotalSeconds -lt $TimeoutInSeconds)) {
        Start-Sleep -Seconds $secondsIncrement

        $private:vm = Get-VM | Where-Object Name -eq $VmName
        if (($private:vm | Measure-Object).Count -ne 1) {
            throw "None or more than one VMs found for name '$VmName' while waiting for state '$State'."
        }
        Write-Log "$([int]$timer.Elapsed.TotalSeconds)s.." -Progress
    }

    if ($timer.Elapsed.TotalSeconds -gt 0) {
        Write-Log '.' -Progress
    }

    if ($private:vm.State -ne $State) {
        throw "VM '$VmName' did not reach the desired state '$State' within $($TimeoutInSeconds)s (last state: '$($private:vm.State)', status: '$($private:vm.Status)')."
    }
}


function Get-VirtioImage {
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [string]$Proxy = ''
    )
    $urlRoot = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/'
    $urlFile = 'virtio-win.iso'

    $url = "$urlRoot/$urlFile"

    if (-not $OutputPath) {
        $OutputPath = Get-Item '.\'
    }

    $imgFile = Join-Path $OutputPath $urlFile

    if ([System.IO.File]::Exists($imgFile)) {
        Write-Log "File '$imgFile' already exists. Nothing to do."
    }
    else {
        Write-Log "Downloading file '$imgFile'..."

        # Enables TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $client = New-Object System.Net.WebClient

        if ($Proxy -ne '') {
            Write-Log "Using Proxy $Proxy to download $url"
            $webProxy = New-Object System.Net.WebProxy($Proxy)
            $webProxy.UseDefaultCredentials = $true
            $client.Proxy = $webProxy
        }

        $client.DownloadFile($url, $imgFile)
    }

    return $imgFile
}

function New-WinUnattendFile {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdminPwd,

        [Parameter(Mandatory = $true)]
        [string]$WinVersionKey,

        [string]$VMName,

        [string]$FilePath,

        [string]$Locale
    )

    $ErrorActionPreference = 'Stop'

    $winTemplate = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" publicKeyToken="31bf3856ad364e35" processorArchitecture="amd64" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ProductKey></ProductKey>
            <ComputerName></ComputerName>
        </component>
        <component name="Microsoft-Windows-International-Core" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <InputLocale></InputLocale>
            <SystemLocale></SystemLocale>
            <UserLocale></UserLocale>
        </component>
        <component name="Microsoft-Windows-Security-SPP-UX" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipAutoActivation>true</SkipAutoActivation>
        </component>
        <component name="Microsoft-Windows-SQMApi" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <CEIPEnabled>0</CEIPEnabled>
        </component>
        <component name="Microsoft-Windows-Deployment" publicKeyToken="31bf3856ad364e35" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>net user administrator /active:yes</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" processorArchitecture="amd64" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <HideEULAPage>true</HideEULAPage>
                <SkipUserOOBE>true</SkipUserOOBE>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>

            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value></Value>
                    <PlainText>false</PlainText>
                </AdministratorPassword>
            </UserAccounts>
        </component>
    </settings>
</unattend>
'@

    $winXmlFile = [xml]$winTemplate

    if (-not $FilePath) {
        $FilePath = Join-Path $env:TEMP 'unattend.xml'
    }

    if ($VMName) {
        $winXmlFile.unattend.settings[0].component[0].ComputerName = $VMName
    }

    $encodedPassword = [System.Text.Encoding]::Unicode.GetBytes($AdminPwd + 'AdministratorPassword')
    $winXmlFile.unattend.settings[1].component.UserAccounts.AdministratorPassword.Value = [Convert]::ToBase64String($encodedPassword)

    $winXmlFile.unattend.settings[0].component[0].ProductKey = $WinVersionKey

    if ($Locale) {
        $winXmlFile.unattend.settings[0].component[1].InputLocale = $Locale
        $winXmlFile.unattend.settings[0].component[1].SystemLocale = $Locale
        $winXmlFile.unattend.settings[0].component[1].UserLocale = $Locale
    }

    $xmlTextWriter = New-Object System.XMl.XmlTextWriter($FilePath, [System.Text.Encoding]::UTF8)
    $xmlTextWriter.Formatting = [System.Xml.Formatting]::Indented
    $winXmlFile.Save($xmlTextWriter)
    $xmlTextWriter.Dispose()

    return $FilePath
}

function Add-IsoImage([string]$IsoFileName, [scriptblock]$ScriptBlock) {
    $IsoFileName = (Resolve-Path $IsoFileName).Path

    Write-Log "Mounting '$IsoFileName'..."
    $mountedImage = Mount-DiskImage -ImagePath $IsoFileName -StorageType ISO -PassThru
    try {
        $driveLetter = ($mountedImage | Get-Volume).DriveLetter
        Invoke-Command $ScriptBlock -ArgumentList $driveLetter
    }
    finally {
        Write-Log "Dismounting '$IsoFileName'..."
        Dismount-DiskImage -ImagePath $IsoFileName | Out-Null
    }
}

function Add-WindowsImage([string]$ImagePath, [int]$ImageIndex, [string]$VirtioDriveLetter, [scriptblock]$ScriptBlock) {
    $mountPath = Join-Path ([System.IO.Path]::GetTempPath()) 'winmount\'

    Write-Log "Mounting '$ImagePath' ($ImageIndex)..."
    mkdir $mountPath -Force | Out-Null
    Mount-WindowsImage -Path $mountPath -ImagePath $ImagePath -Index $ImageIndex | Out-Null
    try {
        Invoke-Command $ScriptBlock -ArgumentList $mountPath
    }
    finally {
        Write-Log "Dismounting '$ImagePath' ($ImageIndex)..."
        Dismount-WindowsImage -Path $mountPath -Save | Out-Null
    }
}

function Add-DriversToWindowsImage($ImagePath, $ImageIndex, $VirtioDriveLetter) {
    Add-WindowsImage -ImagePath $ImagePath -ImageIndex $ImageIndex -VirtioDriveLetter $VirtioDriveLetter {
        Param($mountPath)

        Write-Log "  Adding driver 'vioscsi'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioscsi\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'NetKVM'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\NetKVM\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'Balloon'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\Balloon\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'pvpanic'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\pvpanic\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'qemupciserial'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\qemupciserial\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'qxldod'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\qxldod\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'vioinput'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioinput\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'viorng'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\viorng\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'vioserial'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\vioserial\w10\amd64" -Recurse -ForceUnsigned

        Write-Log "  Adding driver 'viostor'..."
        Add-WindowsDriver -Path $mountPath -Driver "$($VirtioDriveLetter):\viostor\w10\amd64" -Recurse -ForceUnsigned
    }
}

function Add-VirtioDrivers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VirtioIsoPath,

        [Parameter(Mandatory = $true)]
        [string]$ImagePath,

        [int]$ImageIndex = 1
    )

    Add-IsoImage -IsoFileName $VirtioIsoPath {
        Param($virtioDriveLetter)

        $virtioInstaller = "$($virtioDriveLetter):\virtio-win-gt-x64.msi"
        $exists = Test-Path $virtioInstaller
        if (-not $exists) {
            throw 'The specified ISO does not appear to be a valid Virtio installation media.'
        }

        Write-Log "Add: $ImagePath with index: $ImageIndex and drive letter: $virtioDriveLetter"
        Add-DriversToWindowsImage -ImagePath $ImagePath -ImageIndex $ImageIndex -VirtioDriveLetter $virtioDriveLetter
    }

}

function Convert-WinImage {
    <#
    .SYNOPSIS
        Minimalistic Script to Create a bootable VHD(X) based on Windows 10 installation media.
        See https://github.com/Microsoft/Virtualization-Documentation/tree/master/hyperv-tools/Convert-WindowsImage

    .EXAMPLE
        .\Convert-WinImage.ps1 -IsoPath D:\foo\install.wim -Edition Professional -DiskLayout UEFI

        This command will create a 40GB dynamically expanding VHD in a WorkingDirectory.
        The VHD will be based on the Professional edition from Source ISO, and will be named automatically.

    .OUTPUTS
        System.IO.FileInfo if PassThru is enabled
    #>
    #Requires -RunAsAdministrator

    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $IsoPath,

        [string[]]
        [ValidateNotNullOrEmpty()]
        $WinEdition,

        [string]
        [ValidateNotNullOrEmpty()]
        $VHDPath,

        [UInt64]
        [ValidateNotNullOrEmpty()]
        [ValidateRange(1GB, 64TB)]
        $SizeBytes = 25GB,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('VHD', 'VHDX', 'AUTO')]
        $VHDFormat = 'AUTO',

        [Parameter(Mandatory = $true)]
        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('BIOS', 'UEFI', 'WindowsToGo')]
        $DiskLayout,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $(Resolve-Path $_) })]
        $UnattendDir,

        [string]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ })]
        $WorkingDir = $pwd,

        [string]
        [ValidateNotNullOrEmpty()]
        $TempDir = $env:Temp,

        [switch]
        $CacheSrc = $false,

        [switch]
        $Passthru
    )

    Begin {
        #Logging Variables
        $scriptName = 'Convert-WinImage'
        $sessionKey = [Guid]::NewGuid().ToString()
        $logDir = "$($TempDir)\$($scriptName)\$($sessionKey)"

        #VHD Limits and Supported Version
        $vhdMaxSize = 2040GB
        $lowestSupportedBuild = 9200

        $winBuildNumber = [int]($(Get-CimInstance -Class Win32_OperatingSystem).BuildNumber)
        $VHDFormat = $VHDFormat.ToUpper()

        Function Run-Exe {
            param([string]$Executable, [string[]]$ExeArgs, [int]$ExpectedExitCode = 0)

            Write-Log "Running EXE $Executable with args: $ExeArgs"
            $exeProc = Start-Process           `
                -FilePath $Executable      `
                -ArgumentList $ExeArgs     `
                -NoNewWindow               `
                -RedirectStandardError "$($TempDir)\$($scriptName)\$($sessionKey)\$($Executable)-StandardError.txt"  `
                -RedirectStandardOutput "$($TempDir)\$($scriptName)\$($sessionKey)\$($Executable)-StandardOutput.txt" `
                -Passthru

            $execHandle = $exeProc.Handle # WORKAROUND!! POWERSHELL BUG https://github.com/PowerShell/PowerShell/issues/20716, Need to cache handle in order to get the exit code.
            $exeProc.WaitForExit()

            Write-Log "Executable Return Code: $($exeProc.ExitCode)."

            if ($exeProc.ExitCode -ne $ExpectedExitCode) {
                throw "$Executable execution failed with code $($exeProc.ExitCode)"
            }
        }

        Function Test-IsNetPath {
            param([string]$Path)

            try {
                $uri = New-Object System.Uri -ArgumentList $Path

                if ($uri.IsUnc) {
                    return $true
                }

                $drive = Get-PSDrive -PSProvider 'FileSystem' -Name ($uri.LocalPath.Substring(0, 1)) -ErrorAction Stop

                if ($drive.Root -like '\\*') {
                    return $true
                }
            }
            catch {
                Write-Error "Invalid path: $_"
            }

            return $false
        }
    }

    Process {

        $vhdDiskNumber = $null
        $openIso = $null
        $wim = $null
        $vhdFinalName = $null
        $vhdFinalPath = $null
        $isoFinalPath = $null
        $tempSource = $null
        $BCDBoot = 'bcdboot.exe'

        Write-Log "Source Path $IsoPath..."

        if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
            try {
                $hyperVEnabled = $((Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V).State -eq 'Enabled')
            }
            catch {
                $hyperVEnabled = $false
            }
        }
        else {
            $hyperVEnabled = $false
        }

        $vhd = @()

        try {
            if (Test-Path $logDir) {
                $null = Remove-Item $logDir -Force -Recurse
            }

            $null = mkdir $logDir -Force

            if (!($winBuildNumber -ge [int]$lowestSupportedBuild)) {
                throw "$scriptName requires Windows 8 or higher."
            }

            if ($VHDFormat -ilike 'AUTO') {
                if ($DiskLayout -eq 'BIOS') {
                    $VHDFormat = 'VHD'
                }
                else {
                    $VHDFormat = 'VHDX'
                }
            }

            if (![string]::IsNullOrEmpty($UnattendDir)) {
                $UnattendDir = (Resolve-Path $UnattendDir).Path
            }

            # We assign smallest supported block size for Dynamic VHD(X)
            $VHDBlockSizeBytes = 1MB

            if ('VHD' -ilike $VHDFormat) {
                if ($SizeBytes -gt $vhdMaxSize) {
                    Write-Warning 'For the VHD file format, the maximum file size is ~2040GB.  We will automatically set size to 2040GB...'
                    $SizeBytes = $vhdMaxSize
                }

                $VHDBlockSizeBytes = 512KB
            }


            if ((![String]::IsNullOrEmpty($VHDPath)) -and (![String]::IsNullOrEmpty($WorkingDir))) {
                if ($WorkingDir -ne $pwd) {
                    Write-Warning 'Ignoring the WorkingDirectory specification. Specifying -VHDPath and -WorkingDirectory at the same time is contradictory!'
                    $WorkingDir = Split-Path $VHDPath -Parent
                }
            }

            if ($VHDPath) {
                $fileExt = ([IO.FileInfo]$VHDPath).Extension
                if (!($fileExt -ilike ".$($VHDFormat)")) {
                    throw "There is a mismatch between the file extensions VHDPath file ext: ($($fileExt.ToUpper())), and VHDFormat: (.$($VHDFormat)). Ensure that they match and try again"
                }
            }

            # Creating a temporary name for the VHD(x). We shall name it at the end of the script.
            if ([String]::IsNullOrEmpty($VHDPath)) {
                $VHDPath = Join-Path $WorkingDir "$($sessionKey).$($VHDFormat.ToLower())"
            }
            else {
                if (![IO.Path]::IsPathRooted($VHDPath)) {
                    $VHDPath = Join-Path $WorkingDir $VHDPath
                }

                $vhdFinalName = Split-Path $VHDPath -Leaf
                $VHDPath = Join-Path (Split-Path $VHDPath -Parent) "$($sessionKey).$($VHDFormat.ToLower())"
            }

            Write-Log "Temporary $VHDFormat path is : $VHDPath"

            # Here if input is an ISO, first mount it and obtain the path to the WIM file.
            if (([IO.FileInfo]$IsoPath).Extension -ilike '.ISO') {
                # If the ISO isn't local, copy it down.
                if (Test-IsNetPath $IsoPath) {
                    Write-Log "Copying ISO $(Split-Path $IsoPath -Leaf) to temp folder..."
                    robocopy $(Split-Path $IsoPath -Parent) $TempDir $(Split-Path $IsoPath -Leaf) | Out-Null
                    $IsoPath = "$($TempDir)\$(Split-Path $IsoPath -Leaf)"

                    $tempSource = $IsoPath
                }

                $isoFinalPath = (Resolve-Path $IsoPath).Path

                Write-Log "Opening ISO $(Split-Path $isoFinalPath -Leaf)..."
                $openIso = Mount-DiskImage -ImagePath $isoFinalPath -StorageType ISO -PassThru
                $openIso = Get-DiskImage -ImagePath $isoFinalPath
                $driveLetter = ($openIso | Get-Volume).DriveLetter

                $IsoPath = "$($driveLetter):\sources\install.wim"

                Write-Log "Looking for $($IsoPath)..."
                if (!(Test-Path $IsoPath)) {
                    throw 'The specified ISO does not appear to be valid Windows installation media.'
                }
            }

            if (Test-IsNetPath $IsoPath) {
                Write-Log "Copying WIM $(Split-Path $IsoPath -Leaf) to temp folder..."
                robocopy $(Split-Path $IsoPath -Parent) $TempDir $(Split-Path $IsoPath -Leaf) | Out-Null
                $IsoPath = "$($TempDir)\$(Split-Path $IsoPath -Leaf)"
                $tempSource = $IsoPath
            }

            $IsoPath = (Resolve-Path $IsoPath).Path

            # Now lets query wim information and obtain the index of targeted image

            Write-Log 'Searching for requested Windows Image in the WIM file'
            $WindowsImage = Get-WindowsImage -ImagePath $IsoPath

            if (-not $WindowsImage -or ($WindowsImage -is [System.Array])) {
                $WinEditionIndex = 0;
                if ([Int32]::TryParse($WinEdition, [ref]$WinEditionIndex)) {
                    $WindowsImage = Get-WindowsImage -ImagePath $IsoPath -Index $WinEditionIndex
                }
                else {
                    $WindowsImage = Get-WindowsImage -ImagePath $IsoPath | Where-Object { $_.ImageName -ilike "*$($WinEdition)" }
                }

                if (-not $WindowsImage) {
                    throw 'Requested windows Image was not found on the WIM file!'
                }

                if ($WindowsImage -is [System.Array]) {
                    Write-Log "WIM file has the following $($WindowsImage.Count) images that match filter *$($WinEdition)"
                    Get-WindowsImage -ImagePath $IsoPath

                    Write-Error 'You must specify an Edition or SKU index, since the WIM has more than one image.'
                    throw "There are more than one images that match ImageName filter *$($WinEdition)"
                }
            }

            $ImageIndex = $WindowsImage[0].ImageIndex

            $wim = Get-WindowsImage -ImagePath $IsoPath -Index $ImageIndex

            if ($null -eq $wim) {
                Write-Error 'The specified edition does not appear to exist in the specified WIM.'
                throw
            }

            Write-Log "Image $($wim.ImageIndex) selected ($($wim.EditionId))..."

            if ($hyperVEnabled) {
                Write-Log 'Creating VHD sparse disk...'
                $newVhd = New-VHD -Path $VHDPath -SizeBytes $SizeBytes -BlockSizeBytes $VHDBlockSizeBytes -Dynamic

                Write-Log "Mounting $VHDFormat and Getting Disk..."
                $vhdDisk = $newVhd | Mount-VHD -PassThru | Get-Disk
                $vhdDiskNumber = $vhdDisk.Number
            }
            else {
                throw 'Convert-WindowsImage only supports Hyper-V based VHD creation.'
            }

            switch ($DiskLayout) {
                'BIOS' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle MBR

                    # Create the Windows/system partition
                    Write-Log 'Creating single partition...'
                    $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -MbrType IFS -IsActive
                    $windowsPartition = $systemPartition

                    Write-Log 'Formatting windows volume...'
                    $systemVolume = Format-Volume -Partition $systemPartition -FileSystem NTFS -Force -Confirm:$false
                    $windowsVolume = $systemVolume
                }

                'UEFI' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle GPT

                    if (($winBuildNumber) -ge 10240) {
                        # Create the system partition.  Create a data partition so we can format it, then change to ESP
                        Write-Log 'Creating EFI system partition...'
                        $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 200MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

                        Write-Log 'Formatting system volume...'
                        $systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false

                        Write-Log 'Setting system partition as ESP...'
                        $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                        $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
                    }
                    else {
                        # Create the system partition
                        Write-Log 'Creating EFI system partition (ESP)...'
                        $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 200MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -AssignDriveLetter

                        Write-Log 'Formatting ESP...'
                        # /Q Quick format, /Y Suppress Prompt, /FS File System
                        $formatArgs = @("$($systemPartition.DriveLetter):", '/FS:FAT32', '/Q', '/Y')

                        Run-Exe -Executable format -ExeArgs $formatArgs
                    }

                    # Create the reserved partition
                    Write-Log 'Creating MSR partition...'
                    New-Partition -DiskNumber $vhdDiskNumber -Size 128MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

                    # Create the Windows partition
                    Write-Log 'Creating windows partition...'
                    $windowsPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

                    Write-Log 'Formatting windows volume...'
                    $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
                }

                'WindowsToGo' {
                    Write-Log 'Initializing disk...'
                    Initialize-Disk -Number $vhdDiskNumber -PartitionStyle MBR

                    Write-Log 'Creating system partition...'
                    $systemPartition = New-Partition -DiskNumber $vhdDiskNumber -Size 350MB -MbrType FAT32 -IsActive

                    Write-Log 'Formatting system volume...'
                    $systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$false

                    Write-Log 'Creating windows partition...'
                    $windowsPartition = New-Partition -DiskNumber $vhdDiskNumber -UseMaximumSize -MbrType IFS

                    Write-Log 'Formatting windows volume...'
                    $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$false
                }
            }

            # Assign drive letter to Windows partition.  This is required for bcdboot.
            $attempts = 1
            $assigned = $false

            do {
                $windowsPartition | Add-PartitionAccessPath -AssignDriveLetter
                $windowsPartition = $windowsPartition | Get-Partition
                if ($windowsPartition.DriveLetter -ne 0) {
                    $assigned = $true
                }
                else {
                    #sleep for up to 10 seconds and retry
                    Get-Random -Minimum 1 -Maximum 10 | Start-Sleep

                    $attempts++
                }
            }
            while ($attempts -le 25 -and -not($assigned))

            if (-not($assigned)) {
                throw 'Unable to get Partition after retry'
            }

            $windowsDrive = $(Get-Partition -Volume $windowsVolume).AccessPaths[0].substring(0, 2)
            Write-Log "Windows path ($windowsDrive) has been assigned."
            Write-Log "Windows path ($windowsDrive) took $attempts attempts to be assigned."

            # Refresh access paths (we have now formatted the volume)
            $systemPartition = $systemPartition | Get-Partition
            $systemDrive = $systemPartition.AccessPaths[0].trimend('\').replace('\?', '??')
            Write-Log "System volume location: $systemDrive"

            # APPLY IMAGE FROM WIM TO THE NEW VHD WHICH IS CREATED

            Write-Log "Applying image in format $VHDFormat. This will take a while..."
            if ((Get-Command Expand-WindowsImage -ErrorAction SilentlyContinue)) {
                Expand-WindowsImage -ApplyPath $windowsDrive -ImagePath $IsoPath -Index $ImageIndex -LogPath "$($logDir)\DismLogs.log" | Out-Null
            }
            else {
                throw 'Image Apply failed! See DismImageApply logs for details'
            }
            Write-Log 'Image was applied successfully. '

            # Copy the unattend file
            if (![string]::IsNullOrEmpty($UnattendDir)) {
                Write-Log "Applying unattend file ($(Split-Path $UnattendDir -Leaf))..."
                Copy-Item -Path $UnattendDir -Destination (Join-Path $windowsDrive 'unattend.xml') -Force
            }

            $wimArchitecture = ($wim | Out-String -Stream | Select-String Architecture | Out-String | ForEach-Object { $_ -replace '.*:', '' }).Trim()
            Write-Log "Win VM Arch found $wimArchitecture ..."

            if (($wimArchitecture -ne 'ARM') -and ($wimArchitecture -ne 'ARM64')) {
                if (Test-Path "$($systemDrive)\boot\bcd") {
                    Write-Log 'Image already has BIOS BCD store...'
                }
                elseif (Test-Path "$($systemDrive)\efi\microsoft\boot\bcd") {
                    Write-Log 'Image already has EFI BCD store...'
                }
                else {
                    Write-Log 'Making image bootable...'
                    # Path to the \Windows on the VHD, Specifies the volume letter of the drive to create the \BOOT folder on.
                    $bcdBootArgs = @("$($windowsDrive)\Windows", "/s $systemDrive", '/v')

                    # Add firmware type option of the target system partition
                    switch ($DiskLayout) {
                        'BIOS' {
                            $bcdBootArgs += '/f BIOS'
                        }

                        'UEFI' {
                            $bcdBootArgs += '/f UEFI'
                        }

                        'WindowsToGo' {
                            if (Test-Path "$($windowsDrive)\Windows\boot\EFI\bootmgfw.efi") {
                                $bcdBootArgs += '/f ALL'
                            }
                        }
                    }

                    Run-Exe -Executable $BCDBoot -ExeArgs $bcdBootArgs

                    if ($DiskLayout -eq 'BIOS') {
                        Write-Log "Fixing the Device ID in the BCD store on $($VHDFormat)..."
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{bootmgr`} device locate")
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{default`} device locate")
                        Run-Exe -Executable 'BCDEDIT.EXE' -ExeArgs ("/store $($systemDrive)\boot\bcd", "/set `{default`} osdevice locate")
                    }
                }

                Write-Log 'Drive is bootable. Cleaning up...'
            }
            else {
                Write-Log 'Image applied. Not bootable.'
            }

            # Remove system partition access path, if necessary
            if ($DiskLayout -eq 'UEFI') {
                $systemPartition | Remove-PartitionAccessPath -AccessPath $systemPartition.AccessPaths[0]
            }

            if ($hyperVEnabled) {
                Write-Log "Dismounting $VHDFormat..."
                Dismount-VHD -Path $VHDPath
            }
            else {
                Write-Log "Closing $VHDFormat..."
                Dismount-DiskImage -ImagePath $VHDPath
            }

            $vhdFinalPath = Join-Path (Split-Path $VHDPath -Parent) $vhdFinalName
            Write-Log "$VHDFormat final path is : $vhdFinalPath"

            if (Test-Path $vhdFinalPath) {
                Write-Log "Deleting pre-existing $VHDFormat : $(Split-Path $vhdFinalPath -Leaf)..."
                Remove-Item -Path $vhdFinalPath -Force
            }

            Write-Log "Renaming $VHDFormat at $VHDPath to $vhdFinalName"
            Rename-Item -Path (Resolve-Path $VHDPath).Path -NewName $vhdFinalName -Force
            $vhd += Get-DiskImage -ImagePath $vhdFinalPath

            $vhdFinalName = $null
        }
        catch {
            Write-Error $_
            Write-Log "Log folder is $logDir"
        }
        finally {
            # If VHD is mounted, unmount it
            if (Test-Path $VHDPath) {
                if ($hyperVEnabled) {
                    if ((Get-VHD -Path $VHDPath).Attached) {
                        Dismount-VHD -Path $VHDPath
                    }
                }
                else {
                    Dismount-DiskImage -ImagePath $VHDPath
                }
            }

            if ($null -ne $openIso) {
                Write-Log 'Closing ISO...'
                Dismount-DiskImage $isoFinalPath
            }

            if (-not $CacheSrc) {
                if ($tempSource -and (Test-Path $tempSource)) {
                    Remove-Item -Path $tempSource -Force
                }
            }

            Write-Log 'Done.'
        }
    }

    End {
        if ($Passthru) {
            return $vhd
        }
    }
}


function New-VHDXFromWinImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImgDir,
        [Parameter(Mandatory = $true)]
        [string]$WinEdition,
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        [string]$VHDXPath,
        [Parameter(Mandatory = $true)]
        [uint64]$VMVHDXSizeInBytes,
        [Parameter(Mandatory = $true)]
        [string]$AdminPwd,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Server2019Datacenter', 'Server2019Standard', 'Server2016Datacenter', 'Server2016Standard', 'Windows10Enterprise', 'Windows10Professional', 'Windows81Professional')]
        [string]$Version,
        [string]$Locale = 'en-US',
        [string]$AddVirtioDrivers,
        [ValidateNotNullOrEmpty()]
        [ValidateSet('BIOS', 'UEFI', 'WindowsToGo')]
        [string]$DiskLayout = 'UEFI'
    )

    $ErrorActionPreference = 'Stop'

    if (-not $VHDXPath) {
        # https://stackoverflow.com/a/3040982
        $VHDXPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(".\$($ComputerName).vhdx")
    }

    # Source: https://docs.microsoft.com/en-us/windows-server/get-started/kmsclientkeys
    $key = @{
        'Server2019Datacenter'  = 'WMDGN-G9PQG-XVVXX-R3X43-63DFG'
        'Server2019Standard'    = 'N69G4-B89J2-4G8F4-WWYCC-J464C'
        'Server2016Datacenter'  = 'CB7KF-BWN84-R7R2Y-793K2-8XDDG'
        'Server2016Standard'    = 'WC2BQ-8NRM3-FDDYY-2BFGV-KHKQY'
        'Windows10Enterprise'   = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        'Windows11Enterprise'   = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        'Windows10Professional' = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
        'Windows11Professional' = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
        'Windows81Professional' = 'GCRJD-8NW9H-F2CDX-CCM8D-9D6T9'
    }[$Version]

    # Create unattend.xml
    $unattendPath = $(New-WinUnattendFile -AdminPwd $AdminPwd -WinVersionKey $key -VMName $ComputerName -Locale $Locale)

    # Create VHDX from ISO image
    Write-Log "Creating VHDX from image from $unattendPath"
    Convert-WinImage -IsoPath $ImgDir -WinEdition $WinEdition -VHDPath $vhdxPath -SizeBytes $VMVHDXSizeInBytes -DiskLayout $DiskLayout -UnattendDir $unattendPath

    if ($AddVirtioDrivers) {
        Write-Log "Adding Virtio Drivers from $AddVirtioDrivers"
        Add-VirtioDrivers -VirtioIsoPath $AddVirtioDrivers -ImagePath $VHDXPath
    }

    return $VHDXPath
}

function New-VMFromWinImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImgDir,
        [Parameter(Mandatory = $true)]
        [string]$WinEdition,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Server2019Datacenter', 'Server2019Standard', 'Server2016Datacenter', 'Server2016Standard', 'Windows10Enterprise', 'Windows10Professional', 'Windows81Professional')]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [int64]$VMMemoryInBytes,
        [switch]$EnableDynamicMemory,
        [int64]$VMProcessorCount = 2,
        [Parameter(Mandatory = $true)]
        [uint64]$VMVHDXSizeInBytes,
        [Parameter(Mandatory = $true)]
        [string]$AdminPwd,
        [string]$VMMacAddress,
        [string]$AddVirtioDrivers,
        [string]$VMSwitchName = 'VMSwitch',
        [string]$Locale = 'en-US',
        [ValidateRange(1, 2)]
        [int16]$Generation = 2
    )

    $ErrorActionPreference = 'Stop'

    # Requires administrative privileges for below operations (Get-CimInstance)
    #Get Hyper-V Service Settings
    $hyperVMSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData

    $vhdxPath = Join-Path $hyperVMSettings.DefaultVirtualHardDiskPath "$Name.vhdx"

    # Create VHDX from ISO image
    $disklayout = 'UEFI'
    if ( $Generation -eq 1 ) {
        $disklayout = 'BIOS'
        $vhdxPath = Join-Path $hyperVMSettings.DefaultVirtualHardDiskPath "$Name.vhd"
    }

    Write-Log "Using generation $Generation with disk layout $disklayout"
    New-VHDXFromWinImage `
        -ImgDir $ImgDir `
        -WinEdition $WinEdition `
        -ComputerName $Name `
        -VMVHDXSizeInBytes $VMVHDXSizeInBytes `
        -VHDXPath $vhdxPath `
        -AdminPwd $AdminPwd `
        -Version $Version `
        -Locale $Locale `
        -AddVirtioDrivers $AddVirtioDrivers `
        -DiskLayout $disklayout

    Write-Log "Creating VM in Hyper-V: $Name from VHDPath: $vhdxPath and attaching to switch: $VMSwitchName"
    $virtualMachine = New-VM -Name $Name -Generation $Generation -MemoryStartupBytes $VMMemoryInBytes -VHDPath $vhdxPath -SwitchName $VMSwitchName

    $virtualMachine | Set-VMProcessor -Count $VMProcessorCount
    $virtualMachine | Set-VMMemory -DynamicMemoryEnabled:$EnableDynamicMemory.IsPresent

    $virtualMachine | Get-VMIntegrationService | Where-Object { $_ -is [Microsoft.HyperV.PowerShell.GuestServiceInterfaceComponent] } | Enable-VMIntegrationService -Passthru

    if ($VMMacAddress) {
        $virtualMachine | Set-VMNetworkAdapter -StaticMacAddress ($VMMacAddress -replace ':', '')
    }

    $command = Get-Command Set-VM
    if ($command.Parameters.AutomaticCheckpointsEnabled) {
        # We need to disable automatic checkpoints
        $virtualMachine | Set-VM -AutomaticCheckpointsEnabled $false
    }

    #Start VM and wait for heartbeat
    Write-Log 'Starting VM and waiting for heartbeat...'
    Start-VirtualMachineAndWaitForHeartbeat -Name $Name

    Write-Log 'All done in Creation of VM from Windows Image!'
}

function New-VMSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$AdminPwd,
        [Parameter()]
        [string]$DomainName,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 1800,
        [Parameter(Mandatory = $false)]
        [switch]$NoLog = $false
    )

    if ($DomainName) {
        $userName = "$DomainName\administrator"
    }
    else {
        $userName = 'administrator'
    }

    $pass = ConvertTo-SecureString $AdminPwd -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($userName, $pass)
    $secondsIncrement = 5
    $elapsedSeconds = 0

    if ($NoLog -ne $true) {
        Write-Log "Waiting for connection with VM: '$VMName' (timeout: $($TimeoutInSeconds)s) ..."
    }

    do {
        $result = New-PSSession -VMName $VMName -Credential $cred -ErrorAction SilentlyContinue

        if (-not $result) {
            Start-Sleep -Seconds $secondsIncrement
            $elapsedSeconds += $secondsIncrement

            if ($NoLog -ne $true) {
                Write-Log "$($elapsedSeconds)s.. " -Progress
            }
        }
    } while (-not $result -and $elapsedSeconds -lt $TimeoutInSeconds)

    if ($elapsedSeconds -gt 0 -and $NoLog -ne $true) {
        Write-Log '.'
    }

    return $result

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

    if ($NoLog -ne $true) {
        Write-Log "Connecting to VM '$VmName' ..."
    }

    $session = New-VMSession -VMName $VmName -AdminPwd $VmPwd -TimeoutInSeconds $TimeoutInSeconds -NoLog:$NoLog

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

    if ($NoLog -ne $true) {
        Write-Log "Connecting to '$Hostname' ..."
    }

    $session = New-VMSessionViaSSHKey -Hostname $Hostname -KeyFilePath $KeyFilePath -TimeoutInSeconds $TimeoutInSeconds -NoLog:$NoLog

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

function New-VMSessionViaSSHKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hostname,
        [Parameter(Mandatory = $true)]
        [string]$KeyFilePath,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 1800,
        [Parameter(Mandatory = $false)]
        [switch]$NoLog = $false
    )

    $secondsIncrement = 5
    $elapsedSeconds = 0

    if ($NoLog -ne $true) {
        Write-Log "Waiting for connection with Hostname: '$Hostname' (timeout: $($TimeoutInSeconds)s) ..."
    }

    do {
        $result = New-PSSession -Hostname $Hostname -KeyFilePath $KeyFilePath -ErrorAction SilentlyContinue

        if (-not $result) {
            Start-Sleep -Seconds $secondsIncrement
            $elapsedSeconds += $secondsIncrement

            if ($NoLog -ne $true) {
                Write-Log "$($elapsedSeconds)s..<<<"
            }
        }
    } while (-not $result -and $elapsedSeconds -lt $TimeoutInSeconds)

    if ($elapsedSeconds -gt 0 -and $NoLog -ne $true) {
        Write-Log '.'
    }

    return $result
}

function Set-VmIPAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession[]]$PSSession,

        [parameter(HelpMessage = 'DNS Addresses')]
        [string]$DnsAddr = $(throw 'Argument missing: DnsAddr'),

        [Parameter(Mandatory = $true)]
        [string]$IPAddr,

        [Parameter(Mandatory = $true)]
        [byte]$MaskPrefixLength,

        [Parameter(Mandatory = $true)]
        [string]$DefaultGatewayIpAddr
    )

    $ErrorActionPreference = 'Stop'

    Invoke-Command -Session $PSSession {
        Remove-NetRoute -NextHop $using:DefaultGatewayIpAddr -Confirm:$false -ErrorAction SilentlyContinue
        $network = 'Ethernet'
        $neta = Get-NetAdapter $network       # Use the exact adapter name for multi-adapter VMs

        Write-Output 'Remove old ip address'
        $neta | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false

        # New-NetIPAddress may fail for certain scenarios (e.g. PrefixLength = 32). Using netsh instead.
        Write-Output 'Set new ip address'
        $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $using:MaskPrefixLength) -shr (32 - $using:MaskPrefixLength))
        netsh interface ipv4 set address name="$($neta.InterfaceAlias)" static $using:IPAddr $mask.IPAddressToString $using:DefaultGatewayIpAddr

        Write-Output 'Disable DHCP'
        $neta | Set-NetIPInterface -Dhcp Disabled

        Write-Output "Setting DNSProxy(5) servers: $($using:DnsAddr)"
        $neta | Set-DnsClientServerAddress -Addresses $($DnsAddr -split ',')
    }

}

function Get-DefaultWinVMKey {
    $sshConfigDir = Get-SshConfigDir
    $windowsVMKey = $sshConfigDir + "\windowsvm\$(Get-SSHKeyFileName)"

    return $windowsVMKey
}

Export-ModuleMember Start-VirtualMachine, Stop-VirtualMachine,
Remove-VirtualMachine,
Open-RemoteSession,
Set-VmIPAddress,
Open-RemoteSessionViaSSHKey, 
Get-DefaultWinVMKey,
New-VHDXFromWinImage
