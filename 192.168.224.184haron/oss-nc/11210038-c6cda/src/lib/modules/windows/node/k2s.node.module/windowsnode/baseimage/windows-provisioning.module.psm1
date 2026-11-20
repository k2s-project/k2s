# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"

Import-Module $infraModule

$kubeBinPath = Get-KubeBinPath
$provisioningTargetDirectory = "$kubeBinPath\provisioning"


function New-WindowsKubenodeBaseImage {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Windows hostname')]
        [string] $Hostname = $(throw("Argument missing: Hostname")),
        [parameter(Mandatory = $false, HelpMessage = 'Windows Image to use')]
        [string] $Image,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [long] $VMDiskSize = 10GB,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Enable if virtio drivers should be added')]
        [switch] $VirtioDrivers,
        [parameter(Mandatory = $false, HelpMessage = 'Generation of the VM, can be 1 or 2')]
        [ValidateRange(1, 2)]
        [int16] $Generation = 2,
        [Parameter(Mandatory = $false)]
        [string]$Edition,
        [parameter(Mandatory = $false, HelpMessage = 'Locale of the Windows Image, ensure the iso supplied has the locale')]
        [string]$Locale = 'en-US',
        [string]$OutputPath = $(throw 'Argument missing: OutputPath')
    )

    if (Test-Path -Path $OutputPath) {
        Write-Log "File '$OutputPath' already existing --> using it."
        return
    }

    # check name
    if ($Hostname.length -gt 15) {
        Write-Log 'Name is to long. It must be less or equal than 15 characters. !'
        throw 'Name check'
    }

    # check edition
    if ($Edition -eq '') {
        $Edition = 'Windows 10 Pro'
    }

    if ([string]::IsNullOrWhiteSpace($Image) -or !(Test-Path -Path $Image)) {
        throw "Missing VM ISO image: $Image"
    }

    # check disk size
    if ($VMDiskSize -lt 20GB) {
        Write-Log 'Disk size must be higher than 20GB !'
        throw 'Disk size check'
    }

    # download virtio image
    $virtioImgFile = ''
    if ( ($VirtioDrivers) ) {
        Write-Log 'Start to download virtio image ...'
        $virtioImgFile = Get-VirtioImage -Proxy "$Proxy"
        Write-Log "Virtio image: $virtioImgFile"
    }

    $hyperVMSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
    $vhdxPath = Join-Path $hyperVMSettings.DefaultVirtualHardDiskPath "$Hostname.vhdx"
    $disklayout = 'UEFI'

    $vmPwd = Get-DefaultTempPwd

    New-VHDXFromWinImage `
        -ImgDir $Image `
        -WinEdition $Edition `
        -ComputerName $Hostname `
        -VMVHDXSizeInBytes $VMDiskSize `
        -VHDXPath $vhdxPath `
        -AdminPwd $vmPwd `
        -Version 'Windows10Professional' `
        -Locale $Locale `
        -AddVirtioDrivers $virtioImgFile `
        -DiskLayout $disklayout

    if (!(Test-Path -path $vhdxPath)) {
        throw "The file '$vhdxPath' was not created"
    }

    Move-Item -Path $vhdxPath -Destination $OutputPath -Force

    if (!(Test-Path -path $OutputPath)) {
        throw "The file '$OutputPath' is not available."
    }
}

function New-ProvisionedWindowsNodeBaseImage {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Windows hostname')]
        [string] $Hostname = $(throw 'Argument missing: Hostname'),
        [string] $VmName = $(throw 'Argument missing: VmName'),
        [parameter(Mandatory = $false, HelpMessage = 'Windows Image to use')]
        [string] $Image = $(throw 'Argument missing: Image'),
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Windows VM')]
        [long] $WinVMStartUpMemory = $(throw 'Argument missing: WinVMStartUpMemory'),
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [long] $VMDiskSize = $(throw 'Argument missing: VMDiskSize'),
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors of Windows VM')]
        [long] $WinVMProcessorCount = $(throw 'Argument missing: WinVMProcessorCount'),
        [parameter(HelpMessage = 'DNS Addresses')]
        [string] $DnsAddresses = $(throw 'Argument missing: DnsAddresses'),
        [parameter(Mandatory = $false, HelpMessage = 'Windows Image to use')]
        [string] $SwitchName = $(throw 'Argument missing: SwitchName'),
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Enable if virtio drivers should be added')]
        [switch] $VirtioDrivers,
        [parameter(Mandatory = $false, HelpMessage = 'Generation of the VM, can be 1 or 2')]
        [ValidateRange(1, 2)]
        [int16] $Generation = 2,
        [Parameter(Mandatory = $false)]
        [string]$Edition,
        [parameter(Mandatory = $false, HelpMessage = 'Locale of the Windows Image, ensure the iso supplied has the locale')]
        [string]$Locale = 'en-US',
        [string]$OutputPath = $(throw 'Argument missing: OutputPath')
    )

    $inputPath = "$kubeBinPath\Windows-Base.vhdx"
    $inPreparationFileName = "Windows-Kubeworker-Base-in-preparation.vhdx"
    $inPreparationFilePath = "$provisioningTargetDirectory\$inPreparationFileName"
    $preparedFileName = "Windows-Kubeworker-Base-prepared.vhdx"
    $preparedFilePath = "$provisioningTargetDirectory\$preparedFileName"

    if (Test-Path -Path $OutputPath) {
        Write-Log "File '$OutputPath' already existing --> using it."
        return
    }

    New-WindowsKubenodeBaseImage -Hostname $Hostname -Image $Image -VMDiskSize $VMDiskSize -Proxy $Proxy -Edition $Edition -Locale $Locale -OutputPath $inputPath
    if (!(Test-Path -Path $inputPath)) {
        throw "File '$inputPath' does not exist."
    }

    if (Test-Path -Path $provisioningTargetDirectory) {
        Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
    }
    New-Item -Path $provisioningTargetDirectory -Type Directory 

    $vhdxPath = $inPreparationFilePath

    Move-Item -Path $inputPath -Destination $vhdxPath -Force

    $virtualMachine = New-VM -Name $VmName -Generation $Generation -MemoryStartupBytes $WinVMStartUpMemory -VHDPath $vhdxPath -SwitchName $SwitchName

    $virtualMachine | Set-VMProcessor -Count $WinVMProcessorCount
    $virtualMachine | Set-VMMemory -DynamicMemoryEnabled:$false

    $virtualMachine | Get-VMIntegrationService | Where-Object { $_ -is [Microsoft.HyperV.PowerShell.GuestServiceInterfaceComponent] } | Enable-VMIntegrationService -Passthru

    $command = Get-Command Set-VM
    if ($command.Parameters.AutomaticCheckpointsEnabled) {
        $virtualMachine | Set-VM -AutomaticCheckpointsEnabled $false
    }

    Write-Log 'Starting VM and waiting for heartbeat...'
    Start-VirtualMachineAndWaitForHeartbeat -Name $VmName

    $session1 = Open-RemoteSession -VMName $VmName -VmPwd 'admin'

    Stop-InstallationIfRequiredCurlVersionNotInstalled -Session $session1

    Invoke-Command -Session $session1 {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -WarningAction silentlyContinue
        Enable-WindowsOptionalFeature -Online -FeatureName containers -All -NoRestart -WarningAction silentlyContinue
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -WarningAction silentlyContinue
    }

    $GatewayIpAddress = Get-ConfiguredKubeSwitchIP
    Set-VmIPAddress -PSSession $session1 -IPAddr '172.19.1.254' -DefaultGatewayIpAddr $GatewayIpAddress -DnsAddr $DnsAddresses -MaskPrefixLength 24

    # get current timezone
    $timezone = tzutil /g
    Write-Log "Host time zone '$timezone' .."

    Write-Log 'Sync time zone of VM with host'
    Invoke-Command -Session $session1 {
        #Set timezone in VM
        tzutil /s $using:timezone
        Write-Output "Completed setting time zone: $using:timezone"
    }

    Invoke-Command -Session $session1 {
        Write-Output 'Check Host machine Keyboard layout ...'
        Add-Type -AssemblyName System.Windows.Forms
        $lang = [System.Windows.Forms.InputLanguage]::CurrentInputLanguage
        Write-Output "Found Keyboard on Host: '$($lang.LayoutName)' ..."
        if ( $lang.LayoutName -eq 'German') {
            $langList = Get-WinUserLanguageList
            # Remove the default US keyboard
            $langList[0].InputMethodTips.Clear()
            # Add the German keyboard
            $langList[0].InputMethodTips.Add('0409:00000407')
            # Force the changes
            Set-WinUserLanguageList $langList -Force

            # Add the English keyboard after forcing German keyboard layout
            $langList[0].InputMethodTips.Add('0409:00000409')
            # Force the changes again
            Set-WinUserLanguageList $langList -Force
        }
    }

    # Set-VmIPAddress -PSSession $session1 -IPAddr '172.19.1.101' -DefaultGatewayIpAddr '172.19.1.1' -DnsAddr '8.8.8.8' -MaskPrefixLength 24

    Invoke-Command -Session $session1 -WarningAction SilentlyContinue {
        Write-Output 'Change network policy'
        Get-NetConnectionprofile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    }

    # install other components needed in VM
    Invoke-Command -Session $session1 -WarningAction SilentlyContinue {
        Write-Output 'Install choco and additional packages ...'

        $attempts = 0
        $MaxAttempts = 3
        $RetryIntervalInSeconds = 5

        while ($attempts -lt $MaxAttempts) {
            try {

                Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072

                if ($using:Proxy) {
                    Write-Output 'Installing choco using Proxy ...'
                    [system.net.webrequest]::defaultwebproxy = New-Object system.net.webproxy($using:Proxy)
                    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) 3>&1
                    choco config set proxy $using:Proxy
                }
                else {
                    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) 3>&1
                }
                break
            }
            catch {
                Write-Output "Attempt $($attempts + 1) failed with error: $($_.Exception.Message)"
                $attempts++

                if ($attempts -eq $MaxAttempts) {
                    throw "Unable to download chocolatey, error: $_"
                }

                Start-Sleep -Seconds $RetryIntervalInSeconds
            }
        }

    }

    Invoke-Command -Session $session1 -ErrorAction SilentlyContinue {
        choco feature enable -n=allowGlobalConfirmation | Out-Null
        choco feature enable -n=logWithoutColor | Out-Null
        choco feature disable -n=logValidationResultsOnWarnings | Out-Null
        choco feature disable -n=showDownloadProgress | Out-Null
        choco feature disable -n=showNonElevatedWarnings | Out-Null
    }

    Invoke-Command -Session $session1 -ErrorAction SilentlyContinue {

        Write-Output 'Install open ssh'
        choco install openssh --pre | Out-Null
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Group 'k2s' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        &powershell 'C:\Program` Files\OpenSSH-Win64\install-sshd.ps1' | Out-Null

        Write-Output 'Install Powershell 7'
        choco install powershell-core --version=7.3.4 -Force
    }

    Write-Output 'Choco packages done'

    Invoke-Command -Session $session1 -ErrorAction SilentlyContinue {
        Write-Output 'Add nuget as package provider. Add the default repository (i.e. PSGallery)'
        $pkgProviderVersion = '2.8.5.201 '

        if ($using:Proxy) {
            Install-PackageProvider -Name NuGet -MinimumVersion $pkgProviderVersion -Force -Proxy $using:Proxy
            Register-PSRepository -Default -Proxy $using:Proxy
        } else {
            Install-PackageProvider -Name NuGet -MinimumVersion $pkgProviderVersion -Force
            Register-PSRepository -Default
        }
    }

    $pr = ''
    if ( $Proxy ) { $pr = $Proxy.Replace('http://', '') }
    # $NoProxy = "localhost,..."
    Invoke-Command -Session $session1 {
        Write-Output 'Proxy settings, network discovery off'
        if ($using:Proxy) {
            Write-Output "Simple proxy: $using:pr"
            netsh winhttp set proxy proxy-server=$using:pr bypass-list="<local>"
            $RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            Set-ItemProperty -Path $RegKey ProxyEnable -Value 1 -Verbose -ErrorAction Stop
            Set-ItemProperty -Path $RegKey ProxyServer -Value $using:pr -verbose -ErrorAction Stop
        }

        # network discovery off
        reg ADD HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff /f

        # Stop automatic updates
        reg Add 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' /V 'NoAutoUpdate' /T REG_DWORD /D '1' /F

        # enable RDP
        Write-Output 'Enable RDP'
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name 'fDenyTSConnections' -value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

        # enable inbound ICMP v4
        Write-Output 'Enable inbound ICMP v4'
        $currentIcmpPingRule = Get-NetFirewallRule | Where-Object { $_.DisplayName -eq 'Virtual Machine Monitoring (Echo Request - ICMPv4-In)' }
        if ($null -ne $currentIcmpPingRule) {
            $currentIcmpPingRule | Enable-NetFirewallRule
        }
    }

    Write-Log 'Restart VM'
    Stop-VM -Name $VmName -Force

    Start-VM -Name $VmName

    $session2 = Open-RemoteSession -VmName $VmName -VmPwd 'admin'

    Invoke-Command -Session $session2 -WarningAction SilentlyContinue {
        Set-Service -Name sshd -StartupType Automatic
        Start-Service sshd

        if ($using:Proxy -ne "") {
            pwsh -Command "`$ENV:HTTPS_PROXY='$using:Proxy';Install-Module -Name Microsoft.PowerShell.RemotingTools -Force -Confirm:`$false"
        } else {
            pwsh -Command "Install-Module -Name Microsoft.PowerShell.RemotingTools -Force -Confirm:`$false"
        }

        REG ADD 'HKLM\SYSTEM\CurrentControlSet\Control\Windows Containers' /v SkipVersionCheck /t REG_DWORD /d 2 /f
    }

    Invoke-Command -Session $session2 -WarningAction SilentlyContinue {
        $networkAdapters = ((Get-PnpDevice -class net).Where{$_.FriendlyName -like "*Microsoft Hyper-V Network Adapter*"}).InstanceID
        foreach($n in $networkAdapters) { 
            Start-Process -FilePath pnputil.exe -ArgumentList @("/remove-device", "`"$n`"") -Wait 
        }
    }

    Stop-VirtualMachine -VmName $VmName -Wait
    Remove-VM -Name $VmName -Force
    
    Rename-Item -Path $vhdxPath -NewName $preparedFilePath
    Move-Item -Path $preparedFilePath -Destination $OutputPath -Force

    Remove-Item -Path $provisioningTargetDirectory -Recurse -Force

    # all done
    Write-Log "All steps done, the provisioned base image can be found under '$OutputPath'."
}

function Stop-InstallationIfRequiredCurlVersionNotInstalled {
    param (
        $Session = $(throw "Argument missing: Session")
    )

    try {
        Invoke-Command -Session $session -ErrorAction SilentlyContinue {
            try {
                $versionOutput = curl.exe --version
            }
            catch {
                $errorMessage = "The tool 'curl' is not installed. Please install it and add its installation location to the 'PATH' environment variable"
                throw $errorMessage
            }
            $actualVersionAsString = ($versionOutput -split '\s')[1]
            try {
                $actualVersionParts = ($actualVersionAsString -split '\.') | ForEach-Object { [int]$_ }
                $actualVersion = [Version]::new($actualVersionParts[0], $actualVersionParts[1], $actualVersionParts[2])
            }
            catch {
                $errorMessage = "The version of 'curl' could not be determined because: `n $_"
                throw $errorMessage
            }
    
            $minimumRequiredVersion = [Version]"7.71.0"
    
            if ($actualVersion -lt $minimumRequiredVersion) {
                $errorMessage = ("The installed version of 'curl' ($actualVersionAsString) is not at least the required one ($($minimumRequiredVersion.ToString())).",
                "`n",
                "Call 'curl.exe --version' to check the installed version.",
                "`n",
                "Update 'curl' and add its installation location to the 'PATH' environment variable.")
                throw $errorMessage
            }
        } 
    }
    catch {
        Write-Log $_
        throw
    }
    
}

Export-ModuleMember -Function New-ProvisionedWindowsNodeBaseImage
