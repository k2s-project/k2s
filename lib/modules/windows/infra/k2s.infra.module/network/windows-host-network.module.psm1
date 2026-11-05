# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$logModule = "$PSScriptRoot\..\log\log.module.psm1"

Import-Module $logModule

function Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $physicalInterfaceIndexes = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $ExcludeNetworkInterfaceName | Select-Object -expand 'ifIndex'

    $allDnsIpAddresses = @()

    foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
        $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
        if ($null -eq $interfaceName) {
            Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
        }
        else {
            $configuredDnsServersOnNetworkInterface = (Get-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses)
            $allDnsIpAddresses = $allDnsIpAddresses += $configuredDnsServersOnNetworkInterface
            Write-Log "Found the the network interface '$interfaceName' with the following configured DNS IP addresses: $configuredDnsServersOnNetworkInterface"
        }
    }
    $allDnsIpAddressesWithoutDuplicates = $allDnsIpAddresses | Select-Object -Unique

    $allCommaSeparatedDnsIpAddressesWithoutDuplicates = $allDnsIpAddressesWithoutDuplicates -join ','
    Write-Log "Windows host DNS IP addresses: $allCommaSeparatedDnsIpAddressesWithoutDuplicates"

    return $allCommaSeparatedDnsIpAddressesWithoutDuplicates
}

# function Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost {
#     param (
#         [string]$ExcludeNetworkInterfaceName = ''
#     )

#     $k2sDnsProxyIpAddress = Get-ConfiguredKubeSwitchIP
#     $physicalInterfaceIndexes = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $ExcludeNetworkInterfaceName | Select-Object -expand 'ifIndex'

#     foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
#         $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
#         if ($null -eq $interfaceName) {
#             Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
#         }
#         else {
#             Write-Log "Setting DNSProxy(1) IP address '$k2sDnsProxyIpAddress' as main DNS server for network interface '$interfaceName'"
#             Set-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -ServerAddresses $k2sDnsProxyIpAddress
#         }
#     }
# }

# function Reset-DnsForActivePhysicalInterfacesOnWindowsHost {
#     param (
#         [string]$ExcludeNetworkInterfaceName = ''
#     )

#     $k2sDnsProxyIpAddress = Get-ConfiguredKubeSwitchIP
#     $physicalInterfaceIndexes = Get-DNSClientServerAddress -AddressFamily IPv4 | Where-Object Name -ne $ExcludeNetworkInterfaceName | Where-Object ServerAddresses -contains $k2sDnsProxyIpAddress | Select-Object -expand 'InterfaceIndex'

#     foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
#         $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
#         if ($null -eq $interfaceName) {
#             Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
#         }
#         else {
#             Write-Log "Setting DNSProxy(2) server settings for network interface '$interfaceName' with reset"
#             Set-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -ResetServerAddresses
#         }
#     }

# }

function Get-HostPhysicalIp {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $hostphysicalIp = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'vEthernet' -and $_.Name -ne $ExcludeNetworkInterfaceName } | ForEach-Object { Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue } |  Select-Object -ExpandProperty IPAddress -First 1
    return $hostphysicalIp
}

function Get-HostIpAddressForRemoteIp {
    param (
        [string]$RemoteIpAddress = $(throw 'Argument missing: RemoteIpAddress'),
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $findRouteParams = @{
        RemoteIPAddress = $RemoteIpAddress
        ErrorAction     = 'SilentlyContinue'
    }

    $findNetRouteCommand = Get-Command -Name 'Find-NetRoute' -ErrorAction SilentlyContinue
    if ($null -ne $findNetRouteCommand -and $findNetRouteCommand.Parameters.ContainsKey('AddressFamily')) {
        $findRouteParams.AddressFamily = 'IPv4'
    }

    $route = Find-NetRoute @findRouteParams |
        Where-Object {
            # Keep IPv4 routes only (DestinationPrefix usually looks like 192.168.1.0/24)
            $_.DestinationPrefix -match '^(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}$'
        } |
        Select-Object -First 1
    if ($null -ne $route) {
        $ipOnRouteInterface = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notmatch '^169\.254\.' -and $_.InterfaceAlias -ne $ExcludeNetworkInterfaceName } |
            Select-Object -ExpandProperty IPAddress -First 1

        if (-not [string]::IsNullOrWhiteSpace($ipOnRouteInterface)) {
            return $ipOnRouteInterface
        }
    }

    Write-Log "Could not derive host IP for remote IP '$RemoteIpAddress' from routing table. Falling back to generic host physical IP detection."
    return Get-HostPhysicalIp -ExcludeNetworkInterfaceName $ExcludeNetworkInterfaceName
}

function Get-ConfiguredK2sSubnets {
    $configModule = "$PSScriptRoot\..\config\config.module.psm1"
    Import-Module $configModule -DisableNameChecking

    $configPath = Get-k2sConfigFilePath
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    return @(
        @{ Name = 'masterNetworkCIDR'; Value = $config.smallsetup.masterNetworkCIDR },
        @{ Name = 'podNetworkCIDR'; Value = $config.smallsetup.podNetworkCIDR },
        @{ Name = 'podNetworkMasterCIDR'; Value = $config.smallsetup.podNetworkMasterCIDR },
        @{ Name = 'podNetworkWorkerCIDR'; Value = $config.smallsetup.podNetworkWorkerCIDR },
        @{ Name = 'servicesCIDR'; Value = $config.smallsetup.servicesCIDR },
        @{ Name = 'servicesCIDRLinux'; Value = $config.smallsetup.servicesCIDRLinux },
        @{ Name = 'servicesCIDRWindows'; Value = $config.smallsetup.servicesCIDRWindows },
        @{ Name = 'loopbackAdapterCIDR'; Value = $config.smallsetup.loopbackAdapterCIDR }
    )
}

function Import-K2sHnsModule {
    $requiredCommands = @('Get-HnsNetwork', 'Remove-HnsNetwork')
    $missingCommands = @($requiredCommands | Where-Object {
        $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue)
    })
    if ($missingCommands.Count -eq 0) {
        return
    }

    $hnsModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\windowsnode\network\hns.module.psm1"
    if (-not (Test-Path -LiteralPath $hnsModule -PathType Leaf)) {
        throw "[PREREQ-FAILED] HNS module not found at '$hnsModule'."
    }

    Import-Module $hnsModule -DisableNameChecking

    $missingCommands = @($requiredCommands | Where-Object {
        $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue)
    })
    if ($missingCommands.Count -gt 0) {
        throw "[PREREQ-FAILED] HNS commands are unavailable after importing '$hnsModule': $($missingCommands -join ', ')."
    }
}

function Remove-K2sDefaultSwitch {
    Import-K2sHnsModule

    $defaultHnsNetworks = @(Get-HnsNetwork -ErrorAction Stop | Where-Object { $_.Name -eq 'Default Switch' })
    $switchRemoved = $false
    foreach ($defaultHnsNetwork in $defaultHnsNetworks) {
        Write-Log "Removing HNS Default Switch network '$($defaultHnsNetwork.Id)'."
        Remove-HnsNetwork -InputObjects $defaultHnsNetwork -ErrorAction Stop
        $switchRemoved = $true
    }

    $defaultVmSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($null -ne $defaultVmSwitch) {
        Write-Log 'Removing remaining Hyper-V Default Switch.'
        try {
            Remove-VMSwitch -Name 'Default Switch' -Force -ErrorAction Stop
            $switchRemoved = $true
        }
        catch {
            if (-not $switchRemoved) {
                throw
            }
            Write-Log "Hyper-V still reports the Default Switch after HNS removal: $_. Continuing with revalidation."
        }
    }

    if (-not $switchRemoved) {
        throw '[PREREQ-FAILED] The conflicting Default Switch could not be found through HNS or Hyper-V for removal.'
    }
}

<#
.SYNOPSIS
Checks if Hyper-V Default Switch subnet collides with K2s network configuration.

.DESCRIPTION
Validates that the Hyper-V "Default Switch" (if it exists) does not use
subnet ranges that overlap with the configured K2s network subnets from config.json.
This prevents network routing issues and IP address conflicts. When ResolveConflict
is specified, a conflicting Default Switch is removed and the network is revalidated.

.PARAMETER ResolveConflict
Removes a conflicting Default Switch and revalidates the network.

.PARAMETER MaxAttempts
Maximum number of validation and recovery attempts.

.PARAMETER RetryDelaySeconds
Number of seconds to wait for the network state to settle after removal.

.PARAMETER SwitchObservationSeconds
Maximum time to observe an initially missing Default Switch IPv4 address.
Absent switches are observed only on Windows client hosts, where Windows may
create the Default Switch asynchronously during boot.
An existing switch without an IPv4 address after observation fails validation.

.EXAMPLE
Test-DefaultSwitch

.EXAMPLE
Test-DefaultSwitch -ResolveConflict

.NOTES
Throws an error if a collision is detected and recovery is disabled or unsuccessful.
#>
function Test-DefaultSwitch {
    [CmdletBinding()]
    param(
        [switch]$ResolveConflict,
        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 5,
        [ValidateRange(0, 60)]
        [int]$RetryDelaySeconds = 5,
        [ValidateRange(0, 300)]
        [int]$SwitchObservationSeconds = 0
    )

    $k2sSubnets = @(Get-ConfiguredK2sSubnets)

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "Checking Hyper-V Default Switch for subnet collisions (attempt $attempt/$MaxAttempts)..."

        $defaultSwitchIps = @(Get-NetIPAddress -InterfaceAlias 'vEthernet (Default Switch)' -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        $remainingObservationSeconds = $SwitchObservationSeconds
        if ($defaultSwitchIps.Count -eq 0 -and $remainingObservationSeconds -gt 0) {
            $switchPresent = Test-DefaultSwitchPresent
            if (-not $switchPresent) {
                $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                if ($operatingSystem.ProductType -notin @(1, 2, 3)) {
                    throw '[PREREQ-FAILED] Cannot determine whether this host supports asynchronous Default Switch creation.'
                }
                if ($operatingSystem.ProductType -ne 1) {
                    Write-Log '[DefaultSwitch] No Default Switch found on Windows Server; skipping observation.'
                    return
                }
            }
        }
        while ($defaultSwitchIps.Count -eq 0 -and $remainingObservationSeconds -gt 0) {
            $sleepSeconds = [Math]::Min(5, $remainingObservationSeconds)
            Write-Log "[DefaultSwitch] Waiting for Default Switch IPv4 initialization ($remainingObservationSeconds seconds remaining)."
            Start-Sleep -Seconds $sleepSeconds
            $remainingObservationSeconds -= $sleepSeconds
            $defaultSwitchIps = @(Get-NetIPAddress -InterfaceAlias 'vEthernet (Default Switch)' -AddressFamily IPv4 -ErrorAction SilentlyContinue)
        }
        if ($defaultSwitchIps.Count -eq 0) {
            if (Test-DefaultSwitchPresent) {
                $errorMsg = 'Hyper-V Default Switch exists without an IPv4 address; its subnet cannot be validated. Retry k2s start after Windows networking has initialized.'
                Write-Log "[DefaultSwitch] $errorMsg" -Error
                throw "[PREREQ-FAILED] $errorMsg"
            }
            Write-Log "[DefaultSwitch] No Hyper-V Default Switch found after $SwitchObservationSeconds seconds of observation."
            return
        }

        $conflict = $null
        foreach ($defaultSwitchIp in $defaultSwitchIps) {
            $defaultSwitchSubnet = "$($defaultSwitchIp.IPAddress)/$($defaultSwitchIp.PrefixLength)"
            Write-Log "Found Hyper-V Default Switch with subnet: $defaultSwitchSubnet"

            foreach ($k2sSubnet in $k2sSubnets) {
                if (Test-SubnetOverlap -Subnet1 $defaultSwitchSubnet -Subnet2 $k2sSubnet.Value) {
                    $conflict = [pscustomobject]@{
                        DefaultSwitchSubnet = $defaultSwitchSubnet
                        K2sSubnetName        = $k2sSubnet.Name
                        K2sSubnet            = $k2sSubnet.Value
                    }
                    break
                }
            }

            if ($null -ne $conflict) {
                break
            }
        }

        if ($null -eq $conflict) {
            Write-Log 'No subnet collision detected with Default Switch.'
            return
        }

        $errorMsg = "Hyper-V Default Switch subnet ($($conflict.DefaultSwitchSubnet)) collides with K2s network configuration $($conflict.K2sSubnetName) ($($conflict.K2sSubnet))."
        if (-not $ResolveConflict) {
            $errorMsg += "`nThe Default Switch is automatically created by Hyper-V and conflicts with K2s networking.`n" +
                         "Please remove the Default Switch before installing or starting K2s:`n" +
                         "  Get-HnsNetwork | Where-Object Name -EQ 'Default Switch' | Remove-HnsNetwork"
            Write-Log $errorMsg -Error
            throw "[PREREQ-FAILED] $errorMsg"
        }

        if ($attempt -eq $MaxAttempts) {
            $errorMsg += " Automatic recovery failed after $MaxAttempts attempts."
            Write-Log $errorMsg -Error
            throw "[PREREQ-FAILED] $errorMsg"
        }

        Write-Log "$errorMsg Removing the conflicting Default Switch before K2s networking starts."
        Remove-K2sDefaultSwitch

        if ($RetryDelaySeconds -gt 0) {
            Write-Log "Waiting $RetryDelaySeconds seconds for Default Switch network state to settle."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Test-WslIpv4Subnet {
    param(
        [string]$Cidr,
        [string]$Source
    )

    $address = $null
    if ($Cidr -notmatch '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}/(?:[0-9]|[12][0-9]|3[0-2])$' -or
        -not [System.Net.IPAddress]::TryParse(($Cidr -split '/')[0], [ref]$address)) {
        $message = "[WslNetwork] Cannot validate $Source subnet '$Cidr': expected an IPv4 CIDR."
        Write-Log $message -Error
        throw "[PREREQ-FAILED] $message"
    }
}

function Test-WslNetwork {
    Import-K2sHnsModule

    $k2sSubnets = @(Get-ConfiguredK2sSubnets)
    foreach ($subnet in $k2sSubnets) {
        Test-WslIpv4Subnet -Cidr $subnet.Value -Source "K2s $($subnet.Name)"
    }

    $networks = @(Get-HnsNetwork -ErrorAction Stop | Where-Object { $_.Name -like 'WSL*' })
    if ($networks.Count -eq 0) {
        $message = '[WslNetwork] No WSL HNS network found; its subnet cannot be validated. Allow WSL networking to initialize before retrying.'
        Write-Log $message -Error
        throw "[PREREQ-FAILED] $message"
    }

    $conflicts = @()
    foreach ($network in $networks) {
        $networkSubnets = @(
            if ($null -ne $network.Subnets) {
                $network.Subnets
            }
            foreach ($ipam in $network.Ipams) {
                if ($null -ne $ipam.Subnets) {
                    $ipam.Subnets
                }
            }
        )
        if ($networkSubnets.Count -eq 0) {
            $message = "[WslNetwork] HNS '$($network.Name)' ($($network.Id)) has no inspectable subnets."
            Write-Log $message -Error
            throw "[PREREQ-FAILED] $message"
        }
        foreach ($subnet in $networkSubnets) {
            $cidr = $subnet.AddressPrefix
            Test-WslIpv4Subnet -Cidr $cidr -Source "HNS '$($network.Name)'"
            Write-Log "[WslNetwork] HNS '$($network.Name)' ($($network.Id)): $cidr"
            foreach ($k2sSubnet in $k2sSubnets) {
                if (Test-SubnetOverlap -Subnet1 $cidr -Subnet2 $k2sSubnet.Value) {
                    $overlap = "HNS '$($network.Name)' $cidr overlaps K2s $($k2sSubnet.Name) $($k2sSubnet.Value)"
                    if ($k2sSubnet.Name -in @('podNetworkCIDR', 'servicesCIDR')) {
                        Write-Log "[WslNetwork] WARNING: $overlap. Aggregate overlap alone is not blocking; future allocations may collide." -Console
                    }
                    else {
                        $conflicts += $overlap
                    }
                }
            }
        }
    }

    if ($conflicts.Count -gt 0) {
        $message = "[WslNetwork] $($conflicts -join '; '). Resolve the WSL network overlap before retrying, or use Hyper-V hosting (k2s install without --wsl). Changing only the host adapter IP does not change the HNS subnet. K2s has not removed or renumbered any HNS networks."
        Write-Log $message -Error
        throw "[PREREQ-FAILED] $message"
    }
    Write-Log '[WslNetwork] No overlap with configured control-plane, node pod, service slice, or transit subnets.'
}

function Test-DefaultSwitchPresent {
    $adapter = @(Get-NetAdapter -ErrorAction Stop | Where-Object Name -EQ 'vEthernet (Default Switch)')
    if ($adapter.Count -gt 0) {
        return $true
    }

    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
        try {
            $defaultSwitch = @(Get-VMSwitch -ErrorAction Stop | Where-Object Name -EQ 'Default Switch')
            return ($defaultSwitch.Count -gt 0)
        }
        catch {
            Write-Log "[DefaultSwitch] Hyper-V switch query failed; falling back to adapter detection: $($_.Exception.Message)"
            $adapter = @(Get-NetAdapter -ErrorAction Stop | Where-Object Name -EQ 'vEthernet (Default Switch)')
            return ($adapter.Count -gt 0)
        }
    }

    Write-Log '[DefaultSwitch] Hyper-V switch management is unavailable; no Default Switch adapter found.'
    return $false
}

<#
.SYNOPSIS
Tests if two IP subnets overlap.

.DESCRIPTION
Checks whether two CIDR subnets have overlapping IP address ranges.

.PARAMETER Subnet1
First subnet in CIDR notation (e.g., "172.19.1.5/24")

.PARAMETER Subnet2
Second subnet in CIDR notation (e.g., "172.19.1.0/24")

.OUTPUTS
Returns $true if subnets overlap, $false otherwise.

.EXAMPLE
Test-SubnetOverlap -Subnet1 "172.19.1.5/24" -Subnet2 "172.19.1.0/24"
#>
function Test-SubnetOverlap {
    param(
        [string]$Subnet1,
        [string]$Subnet2
    )
    
    # Parse subnet1
    $parts1 = $Subnet1 -split '/'
    $ip1 = [System.Net.IPAddress]::Parse($parts1[0])
    $prefix1 = [int]$parts1[1]
    
    # Parse subnet2
    $parts2 = $Subnet2 -split '/'
    $ip2 = [System.Net.IPAddress]::Parse($parts2[0])
    $prefix2 = [int]$parts2[1]
    
    # Calculate network addresses
    $mask1 = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix1))
    $mask2 = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix2))
    
    $network1 = [uint32]([System.BitConverter]::ToUInt32($ip1.GetAddressBytes()[3..0], 0)) -band $mask1
    $network2 = [uint32]([System.BitConverter]::ToUInt32($ip2.GetAddressBytes()[3..0], 0)) -band $mask2
    
    # Check if networks overlap - use the smaller prefix to determine overlap
    $minPrefix = [Math]::Min($prefix1, $prefix2)
    $overlapMask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $minPrefix))
    
    return ($network1 -band $overlapMask) -eq ($network2 -band $overlapMask)
}

<#
.SYNOPSIS
Gets all subnets from physical network interfaces (LAN and WiFi).

.DESCRIPTION
Retrieves the list of IPv4 subnets configured on physical network adapters
that are currently up. This includes Ethernet (LAN) and WiFi interfaces,
but excludes virtual adapters (vEthernet, loopback, etc.).

.PARAMETER ExcludeNetworkInterfaceName
Optional name of a network interface to exclude from the results.

.OUTPUTS
Returns an array of objects with InterfaceName, IPAddress, PrefixLength, and CIDR properties.

.EXAMPLE
Get-PhysicalNetworkSubnets
#>
function Get-PhysicalNetworkSubnets {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $subnets = @()
    
    # Get physical adapters that are up (Ethernet, Wi-Fi, etc.)
    $physicalAdapters = Get-NetAdapter -Physical | Where-Object { 
        $_.Status -eq 'Up' -and 
        $_.Name -ne $ExcludeNetworkInterfaceName 
    }

    foreach ($adapter in $physicalAdapters) {
        $ipAddresses = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notmatch '^169\.254\.' }
        
        foreach ($ipAddr in $ipAddresses) {
            # Calculate network address for CIDR notation
            $ip = [System.Net.IPAddress]::Parse($ipAddr.IPAddress)
            $prefix = $ipAddr.PrefixLength
            $mask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix))
            $networkInt = [uint32]([System.BitConverter]::ToUInt32($ip.GetAddressBytes()[3..0], 0)) -band $mask
            $networkBytes = [System.BitConverter]::GetBytes($networkInt)[3..0]
            $networkAddress = [System.Net.IPAddress]::new($networkBytes)
            
            $subnets += [PSCustomObject]@{
                InterfaceName = $adapter.Name
                InterfaceType = $adapter.InterfaceDescription
                IPAddress     = $ipAddr.IPAddress
                PrefixLength  = $prefix
                CIDR          = "$($networkAddress.ToString())/$prefix"
            }
        }
    }

    return $subnets
}

<#
.SYNOPSIS
Tests if an IP address belongs to any physical network interface subnet.

.DESCRIPTION
Validates that the given IP address is within the subnet range of a physical 
network adapter (LAN or WiFi). This is used to ensure external nodes are 
reachable via standard network infrastructure.

.PARAMETER IpAddress
The IP address to validate.

.PARAMETER ExcludeNetworkInterfaceName
Optional name of a network interface to exclude from validation.

.OUTPUTS
Returns $true if the IP is in a physical subnet, $false otherwise.

.EXAMPLE
Test-IpInPhysicalSubnet -IpAddress "192.168.1.100"
#>
function Test-IpInPhysicalSubnet {
    param (
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $physicalSubnets = Get-PhysicalNetworkSubnets -ExcludeNetworkInterfaceName $ExcludeNetworkInterfaceName
    
    if ($physicalSubnets.Count -eq 0) {
        Write-Log "Warning: No physical network interfaces found" -Console
        return $false
    }

    # Create a CIDR for the target IP (using /32 for exact match testing)
    $targetCIDR = "$IpAddress/32"
    
    foreach ($subnet in $physicalSubnets) {
        if (Test-SubnetOverlap -Subnet1 $targetCIDR -Subnet2 $subnet.CIDR) {
            Write-Log "IP '$IpAddress' is within physical subnet '$($subnet.CIDR)' on interface '$($subnet.InterfaceName)'" -Console
            return $true
        }
    }

    return $false
}


Export-ModuleMember -Function Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost, Get-HostPhysicalIp, Get-HostIpAddressForRemoteIp, Test-DefaultSwitch, Test-WslNetwork, Get-PhysicalNetworkSubnets, Test-IpInPhysicalSubnet
# Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost, Reset-DnsForActivePhysicalInterfacesOnWindowsHost
