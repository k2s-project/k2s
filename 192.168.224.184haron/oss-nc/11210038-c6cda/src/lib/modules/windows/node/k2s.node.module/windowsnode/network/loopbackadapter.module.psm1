# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$configModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule, $pathModule, $configModule

$defaultLoopbackAdapterName = 'Loopbackk2s'
$kubeBinPath = Get-KubeBinPath
$devgonPath = "$kubeBinPath\devgon.exe"

$setupConfigRoot = Get-RootConfigk2s

$loopbackAdapterIp = $setupConfigRoot.psobject.properties['loopback'].value
$loopbackAdapterGateway = $setupConfigRoot.psobject.properties['loopbackGateway'].value
$loopbackAdapterCIDR = $setupConfigRoot.psobject.properties['loopbackAdapterCIDR'].value

<#
.SYNOPSIS
    Name of the adapter configured to carry the l2 bridge, empty if none.
.DESCRIPTION
    Empty for the default setup, which builds the l2 bridge on a dedicated loopback
    adapter so that K2s does not take over the NIC of the Windows host. A node that
    is a dedicated VM, such as the managed Windows worker of a native Linux host,
    configures its own Ethernet adapter instead and has no loopback adapter at all.
#>
function Get-L2BridgeAdapterOverride {
    $name = Get-ConfigL2BridgeAdapterName
    if ([string]::IsNullOrWhiteSpace($name)) {
        return ''
    }
    return $name.Trim()
}

function New-DefaultLoopbackAdapter {
    $overrideAdapter = Get-L2BridgeAdapterOverride
    if ($overrideAdapter) {
        Write-Log "L2 bridge is configured on adapter '$overrideAdapter', skipping loopback adapter creation"
        return
    }
    New-LoopbackAdapter -Name $defaultLoopbackAdapterName -DevConExe $devgonPath | Out-Null
    $AdapterName = Get-L2BridgeName
    Set-LoopbackAdapterProperties -Name $AdapterName -IPAddress $loopbackAdapterIp -Gateway $loopbackAdapterGateway
}

function Enable-LoopbackAdapter {
    $overrideAdapter = Get-L2BridgeAdapterOverride
    if ($overrideAdapter) {
        Write-Log "L2 bridge is configured on adapter '$overrideAdapter', no loopback adapter to enable"
        return
    }
    $AdapterName = Get-L2BridgeName
    Write-Log "Enabling network adapter $AdapterName"
    Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue
    Set-LoopbackAdapterProperties -Name $AdapterName -IPAddress $loopbackAdapterIp -Gateway $loopbackAdapterGateway
}

function Disable-LoopbackAdapter {
    $overrideAdapter = Get-L2BridgeAdapterOverride
    if ($overrideAdapter) {
        Write-Log "L2 bridge is configured on adapter '$overrideAdapter', no loopback adapter to disable"
        return
    }
    $AdapterName = Get-L2BridgeName
    Write-Log "Disabling network adapter $AdapterName"
    Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue
}

function Uninstall-LoopbackAdapter {
    $overrideAdapter = Get-L2BridgeAdapterOverride
    if ($overrideAdapter) {
        Write-Log "L2 bridge is configured on adapter '$overrideAdapter', no loopback adapter to uninstall"
        return
    }
    $AdapterName = Get-L2BridgeName
    Write-Log "Uninstalling network adapter $AdapterName"
    Remove-LoopbackAdapter -Name $AdapterName -DevConExe $devgonPath
}

function Get-LoopbackAdapterIP {
    return $loopbackAdapterIp
}

function Get-LoopbackAdapterGateway {
    return $loopbackAdapterGateway
}

function Get-LoopbackAdapterCIDR {
    return $loopbackAdapterCIDR
}

function Get-L2BridgeName {
    $overrideAdapter = Get-L2BridgeAdapterOverride
    if ($overrideAdapter) {
        return $overrideAdapter
    }
    # Find the newly added Loopback Adapter
    $Adapter = Get-NetAdapter  | Where-Object { ($_.InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*') }
    # check for zero or multiple entries
    if (!$Adapter) {
        # return the default name
        Write-Log "No Loopback Adapter found, returning default name: $defaultLoopbackAdapterName"
        return $defaultLoopbackAdapterName
    } # if
    if ($Adapter.Count -gt 1) {
        Throw 'More than one Loopback Adapter was found, this is an inconsistency on the system.'
    } # if
    # return the name of the first adapter
    return $Adapter.Name
}

function Get-DevgonExePath {
    return $devgonPath
}

function Invoke-LoopbackDeviceCommand {
    param(
        [string]$DevConExe,
        [string[]]$Parameters
    )

    $command = Get-Command -Name $DevConExe -CommandType Application -ErrorAction Stop
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Preserve native stderr as diagnostic output instead of terminating before exit-code capture.
        $ErrorActionPreference = 'Continue'
        $output = & $command.Source @Parameters 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($line in $output) {
        Write-Log "[LoopbackAdapter] Device installer: $line"
    }
    Write-Log "[LoopbackAdapter] Device command '$($Parameters[0])' exited with code $exitCode"
    if ($exitCode -ne 0) {
        throw "Loopback device command '$($Parameters[0])' failed with exit code ${exitCode}: $($output -join ' ')"
    }
}

function Wait-LoopbackAdapterCount {
    param(
        [ValidateSet(0, 1)]
        [int]$ExpectedCount,
        [ValidateRange(1, 61)]
        [int]$MaxAttempts = 31,
        [ValidateRange(1, 10)]
        [int]$DelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $adapters = @(Get-NetAdapter -ErrorAction Stop |
            Where-Object InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*')
        if ($adapters.Count -eq $ExpectedCount) {
            if ($ExpectedCount -eq 1) {
                Write-Log "[LoopbackAdapter] Discovered adapter '$($adapters[0].Name)' ($($adapters[0].PnPDeviceID)) on attempt $attempt/$MaxAttempts"
                return $adapters[0]
            }
            return
        }
        if ($ExpectedCount -eq 1 -and $adapters.Count -gt 1) {
            throw "More than one Loopback Adapter was found, this is an inconsistency on the system: $($adapters.Name -join ', ')"
        }
        Write-Log "[LoopbackAdapter] Waiting for adapter count $ExpectedCount; found $($adapters.Count) on attempt $attempt/$MaxAttempts"
        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    $message = "Loopback adapter discovery timed out after $MaxAttempts queries (poll delay ${DelaySeconds}s): expected $ExpectedCount, found $($adapters.Count). Devices: $($adapters.Name -join ', '). See device installer output in k2s.log and C:\Windows\INF\setupapi.dev.log."
    Write-Log "[LoopbackAdapter] $message" -Console
    throw $message
}

function New-LoopbackAdapter {
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    [CmdLetBinding()]
    param
    (
        [Parameter(
            Mandatory = $true,
            Position = 0)]
        [string]
        $Name,

        [string]
        $DevConExe
    )

    Write-Log "Creating new loopback adapter '$Name'"

    # Check for the existing Loopback Adapter
    $Adapter = Get-NetAdapter `
        -Name $Name `
        -ErrorAction SilentlyContinue

    # Is the loopback adapter installed?
    if ($Adapter) {
        return $Adapter
    } # if

    Write-Log 'First remove all existing LoopbackAdapters'
    $existingAdapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object -Property InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*')
    foreach ($existingAdapter in $existingAdapters) {
        Remove-LoopbackAdapter -Name $existingAdapter.Name -DevConExe $DevConExe
    }
    if ($existingAdapters.Count -gt 0) {
        Wait-LoopbackAdapterCount -ExpectedCount 0
    }

    Invoke-LoopbackDeviceCommand -DevConExe $DevConExe -Parameters @('install', '-p', "$($ENV:SystemRoot)\inf\netloop.inf", '-i', '*MSLOOP')
    $Adapter = Wait-LoopbackAdapterCount -ExpectedCount 1

    # Rename the new Loopback adapter
    Set-NewNameForLoopbackAdapter -Adapter $Adapter

    # get the newly renamed adapter
    $NewName = Get-L2BridgeName

    # Set the metric to 254
    Set-NetIPInterface `
        -InterfaceAlias $NewName `
        -InterfaceMetric 254 `
        -ErrorAction Stop

    # Pull the newly named adapter (to be safe)
    $Adapter = Get-NetAdapter `
        -Name $NewName `
        -ErrorAction Stop

    Return $Adapter
} # function New-LoopbackAdapter

function Remove-LoopbackAdapter {
    [CmdLetBinding()]
    param
    (
        [Parameter(Position = 0)]
        [string]
        $Name,

        [string]
        $DevConExe,

        [switch]
        $Force
    )

    Write-Log "Removing loopback adapter '$Name'"

    # Check for the existing Loopback Adapter
    $Adapter = Get-NetAdapter `
        -Name $Name `
        -ErrorAction SilentlyContinue

    # Is the loopback adapter installed?
    if (!$Adapter) {
        Write-Log "No loopback adapter '$Name' found to remove."
        return
    }

    # Is the adapter Loopback adapter?
    if ($Adapter.InterfaceDescription -notlike 'Microsoft KM-TEST Loopback Adapter*') {
        # Not a loopback adapter - don't uninstall this!
        Throw "Network Adapter $Name is not a Microsoft KM-TEST Loopback Adapter."
    } # if

    Invoke-LoopbackDeviceCommand -DevConExe $DevConExe -Parameters @('remove', '-i', "$($Adapter.PnPDeviceID)")
} # function Remove-LoopbackAdapter

function Test-LoopbackAdapterIPAddress {
    param (
        [Parameter()]
        [string] $Name,
        [Parameter()]
        [string] $ExpectedIPAddress
    )

    $currentAddresses = Get-NetIPAddress -InterfaceAlias "$Name" -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($null -eq $currentAddresses) {
        return $false
    }

    foreach ($addr in $currentAddresses) {
        if ($addr.IPAddress -eq $ExpectedIPAddress) {
            return $true
        }
    }
    return $false
}

function Confirm-LoopbackAdapterIP {
    <#
    .SYNOPSIS
    Verifies loopback adapter has the correct IP address and corrects it if needed.
    .DESCRIPTION
    Checks if the loopback adapter has the expected static IP address. If the IP is wrong
    (e.g., APIPA 169.254.x.x address), it removes existing IPs and re-applies the static IP.
    This should be called right before starting flanneld service.
    .NOTES
    After an external switch is created, the IP is on vEthernet (AdapterName) not the base adapter.
    This function checks both adapters and operates on the correct one.
    Throws an exception if the IP cannot be corrected after retries.
    #>
    $overrideAdapter = Get-L2BridgeAdapterOverride
    if ($overrideAdapter) {
        # The l2 bridge sits on a real NIC that carries the node's own address. Forcing
        # the loopback IP onto it would drop that address and cut the node off.
        Write-Log "[LoopbackAdapter] L2 bridge is configured on adapter '$overrideAdapter', skipping loopback IP verification"
        return
    }
    $baseAdapterName = Get-L2BridgeName
    $vEthernetAdapterName = "vEthernet ($baseAdapterName)"
    $expectedIP = $loopbackAdapterIp
    $gateway = $loopbackAdapterGateway
    $prefixLength = 24
    $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $prefixLength) -shr (32 - $prefixLength))

    # Determine which adapter to check - vEthernet adapter if external switch exists, otherwise base adapter
    $vEthernetAdapter = Get-NetAdapter -Name $vEthernetAdapterName -ErrorAction SilentlyContinue
    if ($null -ne $vEthernetAdapter) {
        $adapterName = $vEthernetAdapterName
        Write-Log "[LoopbackAdapter] External switch detected, checking vEthernet adapter '$adapterName'"
    } else {
        $adapterName = $baseAdapterName
        Write-Log "[LoopbackAdapter] No external switch, checking base adapter '$adapterName'"
    }

    Write-Log "[LoopbackAdapter] Verifying IP address on adapter '$adapterName' before flanneld start..."

    # Check if IP is already correct
    if (Test-LoopbackAdapterIPAddress -Name $adapterName -ExpectedIPAddress $expectedIP) {
        Write-Log "[LoopbackAdapter] IP address $expectedIP verified successfully on adapter '$adapterName'"
        return
    }

    # Log current addresses for diagnostics
    $currentAddresses = Get-NetIPAddress -InterfaceAlias "$adapterName" -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($null -ne $currentAddresses) {
        foreach ($addr in $currentAddresses) {
            if ($addr.IPAddress -like "169.254.*") {
                Write-Log "[LoopbackAdapter] WARNING: APIPA address detected: $($addr.IPAddress)" -Console
            } else {
                Write-Log "[LoopbackAdapter] Current IP address: $($addr.IPAddress)"
            }
        }
    } else {
        Write-Log "[LoopbackAdapter] No IPv4 addresses currently assigned"
    }

    Write-Log "[LoopbackAdapter] IP address mismatch detected, correcting..."

    # Remove existing IPv4 addresses (including APIPA) before setting static IP
    $currentAddresses | ForEach-Object {
        Write-Log "[LoopbackAdapter] Removing existing IP address: $($_.IPAddress)"
        Remove-NetIPAddress -InterfaceAlias $adapterName -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Apply static IP using netsh
    Write-Log "[LoopbackAdapter] Setting static IP address $expectedIP..."
    netsh interface ipv4 set address name="$adapterName" static $expectedIP $($mask.IPAddressToString) $gateway

    # Brief wait for networking stack
    Start-Sleep -Seconds 1

    # Verify the IP was applied
    if (Test-LoopbackAdapterIPAddress -Name $adapterName -ExpectedIPAddress $expectedIP) {
        Write-Log "[LoopbackAdapter] IP address $expectedIP successfully corrected on adapter '$adapterName'"
        return
    }

    # If still not correct, throw exception
    throw "[LoopbackAdapter] Failed to configure IP $expectedIP on adapter '$adapterName'. Flanneld cannot start with incorrect IP."
}

function Set-LoopbackAdapterProperties {
    param (
        [Parameter()]
        [string] $Name,
        [Parameter()]
        [string] $IPAddress,
        [Parameter()]
        [string] $Gateway
    )

    $maxRetries = 3
    $retryDelaySeconds = 3
    $stabilizationDelaySeconds = 1
    $prefixLength = 24
    $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $prefixLength) -shr (32 - $prefixLength))

    $if = Get-NetIPInterface -InterfaceAlias "$Name" -ErrorAction SilentlyContinue
    if( $if ) {
        Set-NetIPInterface -InterfaceAlias "$Name" -Dhcp Disabled

        $ipConfigured = $false
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            if ($attempt -gt 1) {
                Write-Log "[LoopbackAdapter] Waiting $retryDelaySeconds seconds before retry..."
                Start-Sleep -Seconds $retryDelaySeconds
            }

            Write-Log "[LoopbackAdapter] Setting IP address (attempt $attempt of $maxRetries)..."
            netsh interface ipv4 set address name="$Name" static $IPAddress $mask.IPAddressToString $Gateway

            # Wait for Windows networking stack to apply the IP
            Start-Sleep -Seconds $stabilizationDelaySeconds

            # Verify IP was applied correctly
            if (Test-LoopbackAdapterIPAddress -Name $Name -ExpectedIPAddress $IPAddress) {
                Write-Log "[LoopbackAdapter] Loopback Adapter $Name configured with IP: $IPAddress, mask: $($mask.IPAddressToString), gateway: $Gateway (attempt $attempt)"
                $ipConfigured = $true
                break
            }
            else {
                Write-Log "[LoopbackAdapter] IP verification failed on attempt $attempt of $maxRetries"
            }
        }

        if (-not $ipConfigured) {
            Write-Log "[LoopbackAdapter] Failed to configure IP $IPAddress on adapter $Name after $maxRetries attempts" -Error
            return
        }

        # enable forwarding
        netsh int ipv4 set int "$Name" forwarding=enabled | Out-Null
        # reset DNS settings
        Set-DnsClient -InterfaceAlias "$Name" -ResetConnectionSpecificSuffix -RegisterThisConnectionsAddress $false
    }
    else {
        Write-Log "[LoopbackAdapter] No loopback adapter '$Name' found to configure."
    }
}

function Set-LoopbackAdapterExtendedProperties {
    param (
        [Parameter()]
        [string] $AdapterName,
        [Parameter()]
        [string] $DnsServers
    )
    $adapterName = $AdapterName
    Write-Log 'Figuring out IPv4DefaultGateway'
    $if = Get-NetIPConfiguration -InterfaceAlias "$adapterName" -ErrorAction SilentlyContinue 2>&1 | Out-Null
    $gw = Get-LoopbackAdapterGateway
    if ( $if ) {
        $gw = $if.IPv4DefaultGateway.NextHop
        Write-Log "Gateway found (from interface '$adapterName'): $gw"
    }
    Write-Log "The following gateway IP address will be used: $gw"
    $loopbackAdapterIfIndex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex' -First 1
    $loopbackAdapterAlias = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'InterfaceAlias' -First 1
    if ($null -eq $loopbackAdapterIfIndex -or $null -eq $loopbackAdapterAlias) {
        Write-Log 'Unable to find the loopback adapter' -Error
        Write-Log 'Found following interfaces:'
        Get-NetIPInterface | Write-Log
        throw 'Unable to find the loopback adapter'
    }    
    Write-Log "Found Loopback adapter with Alias: '$loopbackAdapterAlias' and ifIndex: '$loopbackAdapterIfIndex'"
    $ipAddressForLoopbackAdapter = Get-LoopbackAdapterIP
    if (Get-L2BridgeAdapterOverride) {
        # The l2 bridge is on a real NIC carrying the node's own address. Imposing the
        # loopback adapter's IP and gateway here would cut the node off the network.
        $currentIp = Get-NetIPAddress -InterfaceIndex $loopbackAdapterIfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress -First 1
        if ($currentIp) { $ipAddressForLoopbackAdapter = $currentIp }
        $currentGateway = Get-NetRoute -InterfaceIndex $loopbackAdapterIfIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NextHop -First 1
        if ($currentGateway) { $gw = $currentGateway }
        Write-Log "Keeping the adapter's own IP '$ipAddressForLoopbackAdapter' and gateway '$gw'"
    }
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -Dhcp Disabled  | Out-Null
    $dnsServersAsArray = $DnsServers -split ','
    Set-IPAddressAndDnsClientServerAddress -IPAddress $ipAddressForLoopbackAdapter -DefaultGateway $gw -Index $loopbackAdapterIfIndex -DnsAddresses $dnsServersAsArray
    # Removed, not at the end of start cmd
    # Set-InterfacePrivate -InterfaceAlias "$loopbackAdapterAlias"
    Set-DnsClient -InterfaceIndex $loopbackAdapterIfIndex -RegisterThisConnectionsAddress $false | Out-Null
    netsh int ipv4 set int "$loopbackAdapterAlias" forwarding=enabled | Out-Null
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -InterfaceMetric 102  | Out-Null
}

function Set-NewNameForLoopbackAdapter {
    param (
        [Parameter()]
        [object] $Adapter
    )    
    # start with the default name
    $NewName = $defaultLoopbackAdapterName
    # if that default name does not work, then use a next name $defaultLoopbackAdapterName + '1'
    $iMaxLoops = 5
    for ($i = 0; $i -lt $iMaxLoops; $i++) {
        if ($i -gt 0) {
            # if the default name does not work, then use a next name $defaultLoopbackAdapterName + '1'
            $NewName = "$defaultLoopbackAdapterName$i"
            Write-Log "Trying to rename Loopback Adapter to '$NewName'"
        } else {
            $NewName = $defaultLoopbackAdapterName
            Write-Log "Trying to rename Loopback Adapter to '$defaultLoopbackAdapterName'"
        }  

        # try to rename the Loopback Adapter
        try {
            $Adapter | Rename-NetAdapter -NewName $NewName -ErrorAction Stop
        }
        catch {
            Write-Log "Renaming Loopback Adapter to '$NewName' failed: $($_.Exception.Message)"
            Write-Debug "Will try to rename it to the next name."
            # if the rename fails, then try the next name
            continue
        }
        # if the rename was successful, then break the loop
        Write-Log "Renaming Loopback Adapter to '$NewName' was successful."
        break
    }
}

function Set-PrivateNetworkProfileForLoopbackAdapter {
    $adapterName = Get-L2BridgeName
    $loopbackAdapterAlias = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'InterfaceAlias' -First 1
    Set-InterfacePrivate -InterfaceAlias "$loopbackAdapterAlias"
}

Export-ModuleMember New-LoopbackAdapter
Export-ModuleMember Remove-LoopbackAdapter
Export-ModuleMember Set-LoopbackAdapterProperties, Get-LoopbackAdapterIP,
Get-LoopbackAdapterGateway, Get-LoopbackAdapterCIDR, New-DefaultLoopbackAdapter, Get-L2BridgeName,
Enable-LoopbackAdapter, Disable-LoopbackAdapter, Uninstall-LoopbackAdapter, Get-DevgonExePath, Set-LoopbackAdapterExtendedProperties,
Set-NewNameForLoopbackAdapter, Set-PrivateNetworkProfileForLoopbackAdapter, Confirm-LoopbackAdapterIP,
Get-L2BridgeAdapterOverride
