# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$logModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule

$configModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
Import-Module $configModule

$proxyConfigFp = "C:\ProgramData\k2s\proxy.conf"
$noProxyBaselineFp = "C:\ProgramData\k2s\no_proxy.baseline"

class ProxyConfig {
    [string] $HttpProxy
    [string] $HttpsProxy
    [string[]] $NoProxy
}

<#
.SYNOPSIS
Gets K2s specific hosts and subnets that should be included in NO_PROXY configuration.

.DESCRIPTION
Returns an array of K2s specific hosts, IP addresses, and subnets that should be excluded from proxy usage.
This includes cluster IPs, control plane IPs, and other K2s infrastructure endpoints.

.NOTES
This function is used by various Windows services to ensure they can communicate directly with K2s components
without going through the proxy.
#>
function Get-K2sHosts {
    $k2sHosts = @()
    
    $k2sHosts += @('localhost', '127.0.0.1', '::1')
    
    $ipControlPlane = Get-ConfiguredIPControlPlane
    if ([string]::IsNullOrWhiteSpace($ipControlPlane)) {
        throw "Control Plane IP is not configured. Unable to determine K2s hosts for proxy configuration."
    }
    $k2sHosts += $ipControlPlane
    
    $clusterCIDR = Get-ConfiguredClusterCIDR
    if ([string]::IsNullOrWhiteSpace($clusterCIDR)) {
        throw "Cluster CIDR is not configured. Unable to determine K2s hosts for proxy configuration."
    }
    $k2sHosts += $clusterCIDR
    
    $clusterCIDRServices = Get-ConfiguredClusterCIDRServices
    if ([string]::IsNullOrWhiteSpace($clusterCIDRServices)) {
        throw "Cluster Service CIDR is not configured. Unable to determine K2s hosts for proxy configuration."
    }
    $k2sHosts += $clusterCIDRServices
       
    $k2sHosts += @('.local', '.cluster.local')
    
    $k2sHosts = $k2sHosts | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique
    
    return $k2sHosts
}

function ConvertTo-NoProxyList {
    param (
        [AllowNull()]
        [object[]]$Entries
    )

    if ($null -eq $Entries -or $Entries.Count -eq 0) {
        return @()
    }

    return $Entries |
        ForEach-Object { $_ } |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { ![string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
}

function Save-NoProxyBaseline {
    param (
        [AllowNull()]
        [string]$NoProxyValue
    )

    if (Test-Path -Path $noProxyBaselineFp) {
        return
    }

    $baselineDirectory = Split-Path -Path $noProxyBaselineFp -Parent
    if (!(Test-Path -Path $baselineDirectory)) {
        New-Item -ItemType Directory -Path $baselineDirectory | Out-Null
    }

    $baseline = ConvertTo-NoProxyList -Entries @($NoProxyValue)
    $baseline -join ',' | Set-Content -Path $noProxyBaselineFp
}

function Get-NoProxyBaseline {
    if (!(Test-Path -Path $noProxyBaselineFp)) {
        return $null
    }

    return ConvertTo-NoProxyList -Entries @((Get-Content -Path $noProxyBaselineFp -Raw))
}

function Remove-NoProxyBaseline {
    if (Test-Path -Path $noProxyBaselineFp) {
        Remove-Item -Path $noProxyBaselineFp -Force
    }
}

<#
.SYNOPSIS
Gets whether proxy settings are configured for the user in Windows.

.DESCRIPTION
When Proxy settings are configured for the User in Windows, the enabled status is checked in the registry key
HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyEnable

If ProxyEnable is set to 1, the proxy settings are enabled. In this case, the function returns true.
If ProxyEnable is set to 0, the proxy settings are enabled. In this case, the function returns false.
#>
function Get-ProxyEnabledStatusFromWindowsSettings {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        
    if ($reg.ProxyEnable -eq '1') {
        return $true
    }

    return $false
}

<#
.SYNOPSIS
Gets the configured proxy server for the user in Windows. Should be called only when Proxy is enabled. 

.DESCRIPTION
When proxy settings are configured for the user in Windows, the proxy server is configured in the registry key
HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyServer
#>
function Get-ProxyServerFromWindowsSettings {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

    $proxyServer = $reg.ProxyServer
    if ($null -ne $proxyServer -and !($proxyServer | Select-String -Pattern 'http://')) {
        $proxyServer = 'http://' + $proxyServer
    }

    return $proxyServer
}

<#
.SYNOPSIS
Gets the configured proxy overrides for the user in windows. Proxy overrides are the hosts for which the requests must not
be forwarded to the proxy. Should be called only when Proxy is enabled.

.DESCRIPTION
When proxy settings are configured for the user in Windows, the proxy overrides are configured in the registry key
HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ProxyOverrides
#>
function Get-ProxyOverrideFromWindowsSettings {
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxyOverrides = $reg.ProxyOverride -replace ";", ","
    return $proxyOverrides
}

<#
.SYNOPSIS
Identifies the proxy server to be used. 
If $Proxy is specified, then no identification is done.     
If $Proxy is not specified, then the proxy settings are fetched from registry. Based on the registry keys, the appropriate proxy server
to be used is returned.
#>
function Get-OrUpdateProxyServer ([string]$Proxy) {
    if ($Proxy -eq '') {
        Write-Log 'Determining if proxy is configured by the user in Windows Proxy settings.' -Console
        $proxyEnabledStatus = Get-ProxyEnabledStatusFromWindowsSettings
        if ($proxyEnabledStatus) {
            $Proxy = Get-ProxyServerFromWindowsSettings
            Write-Log "Configured proxy server in Windows Proxy settings: $Proxy" -Console
        }
        else {
            Write-Log 'No proxy configured in Windows Proxy Settings.' -Console
        }
    }
    return $Proxy
}

<#
.SYNOPSIS
Creates the k2s proxy configuration file at C:\ProgramData\k2s\proxy.conf. 
This method must be invoked during the installation of k2s. 

.DESCRIPTION
When this function is called during the installation of k2s, it identifies the relevant proxy configuration and writes them into the configuration file.
If the function parameters are specified, then they have precedence over proxy settings in windows.
#>
function New-ProxyConfig {
    param(
        [string] $Proxy,
        [string[]] $NoProxy
    )

    # If $Proxy and $NoProxy are empty, get values from the Windows registry
    if ([string]::IsNullOrWhiteSpace($Proxy)) {
        Write-Log 'Determining if proxy is configured by the user in Windows Proxy settings.' -Console
        $proxyEnabledStatus = Get-ProxyEnabledStatusFromWindowsSettings
        if ($proxyEnabledStatus) {
            $Proxy = Get-ProxyServerFromWindowsSettings
            if ($null -eq $NoProxy -or $NoProxy.Count -eq 0) {
                $windowsProxyOverrides = Get-ProxyOverrideFromWindowsSettings
                if (![string]::IsNullOrWhiteSpace($windowsProxyOverrides)) {
                    $NoProxy = $windowsProxyOverrides -split ','
                }
            }
            Write-Log "Configured proxy server in Windows Proxy settings: Proxy: $Proxy, ProxyOverrides: $($NoProxy -join ',')" -Console
        }
        else {
            Write-Log 'No proxy configured in Windows Proxy Settings.' -Console
        }
    }

    # Ensure the directory exists
    $configFileDirectory = Split-Path -Path $proxyConfigFp -Parent
    if (!(Test-Path -Path $configFileDirectory)) {
        New-Item -ItemType Directory -Path $configFileDirectory | Out-Null
    }

    # Create or overwrite the config file
    New-Item -ItemType File -Path $proxyConfigFp -Force | Out-Null

    # Write the proxy settings to the config file
    $NoProxyString = if ($null -ne $NoProxy -and $NoProxy.Count -gt 0) { $NoProxy -join ',' } else { '' }
    Add-Content -Path $proxyConfigFp -Value "http_proxy=$Proxy"
    Add-Content -Path $proxyConfigFp -Value "https_proxy=$Proxy"
    Add-Content -Path $proxyConfigFp -Value "no_proxy=$NoProxyString"

    return $Proxy
}

<#
.SYNOPSIS
Gets the proxy configuration object.

.DESCRIPTION
When the function is invoked, the proxy configuration object is created by reading the proxy configuration file located at 
C:\ProgramData\k2s\proxy.conf

If the proxy configuration file is not found, then an error is thrown. Hence, this method must be invoked after New-ProxyConfig is invoked.
#>
function Get-ProxyConfig {
    $httpProxy = ""
    $httpsProxy = ""
    $noProxy = ""

    # Check if the config file exists
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    Get-Content "$proxyConfigFp" | ForEach-Object {
        $line = $_
        switch -regex ($line) {
            "http_proxy=" { $httpProxy = (($_ -replace "http_proxy=", "") -replace '"', '') -replace "'",""}
            "https_proxy=" { $httpsProxy = (($_ -replace "https_proxy=", "") -replace '"', '') -replace "'",""}
            "no_proxy=" { $noProxy = (($_ -replace "no_proxy=", "") -replace '"', '') -replace "'",""}
        }
    }

    $noProxyList = if ($noProxy -eq "") { @() } else { $noProxy -split ',' }

    return [ProxyConfig]@{
        HttpProxy = $httpProxy; 
        HttpsProxy = $httpsProxy; 
        NoProxy = [string[]]$noProxyList
    }
}

<#
.SYNOPSIS
Sets the proxy server configuration.

.DESCRIPTION
This function allows you to set the proxy server configuration by providing the HTTP and HTTPS proxy server addresses.
When a proxy is set, K2s specific hosts (localhost, cluster IPs, CIDRs, .local, .cluster.local) are automatically
added to the no_proxy configuration to ensure K2s components can communicate directly without going through the proxy.
If the configuration file does not exist at the specified path, an error will be thrown.

.PARAMETER Proxy
The HTTP/HTTPS proxy server address to be set.

.EXAMPLE
Set-ProxyServer -Proxy "http://proxy.example.com:8080"
Sets the HTTP and HTTPS proxy server addresses to "http://proxy.example.com:8080" and automatically adds K2s hosts to no_proxy.
#>
function Set-ProxyServer {
    param (
        [string]$Proxy
    )

    # Check if the config file exists
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    # Read the existing configuration
    $proxyConfig = Get-ProxyConfig

    # Update the proxy settings
    if ($Proxy) {
        $proxyConfig.HttpProxy = $Proxy
        $proxyConfig.HttpsProxy = $Proxy
        
        # Add K2s hosts to NoProxy to ensure K2s components can communicate directly
        $k2sHosts = Get-K2sHosts
        $allNoProxyHosts = @()
        if ($proxyConfig.NoProxy.Count -gt 0) {
            $allNoProxyHosts += $proxyConfig.NoProxy
        }
        $allNoProxyHosts += $k2sHosts
        $proxyConfig.NoProxy = $allNoProxyHosts | Sort-Object -Unique
    }

    # Prepare the new content for the config file
    $newContent = @(
        "http_proxy='$($proxyConfig.HttpProxy)'"
        "https_proxy='$($proxyConfig.HttpsProxy)'"
        "no_proxy='$($proxyConfig.NoProxy -join ",")'"
    )

    # Write the updated configuration back to the file
    $newContent | Set-Content -Path $proxyConfigFp
}

<#
.SYNOPSIS
Adds entries to the NoProxy array in the proxy configuration file.

.DESCRIPTION
The Add-NoProxyEntry function reads the existing proxy configuration, adds the specified entries to the NoProxy array if they do not already exist, and writes the updated configuration back to the proxy configuration file.

.PARAMETER Entries
The entries to add to the NoProxy array.

.EXAMPLE
Add-NoProxyEntry -Entries "example.com"
Adds "example.com" to the NoProxy array in the proxy configuration file.

.EXAMPLE
Add-NoProxyEntry -Entries "example.com", "anotherdomain.com"
Adds "example.com" and "anotherdomain.com" to the NoProxy array in the proxy configuration file.
#>
function Add-NoProxyEntry {
    param (
        [string[]]$Entries
    )

    # Check if the config file exists
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    # Read the existing configuration
    $proxyConfig = Get-ProxyConfig

    # Add new entries to the NoProxy array
    foreach ($entry in $Entries) {
        if (-not ($proxyConfig.NoProxy -contains $entry)) {
            $proxyConfig.NoProxy += $entry
        }
    }

    # Prepare the new content for the config file
    $newContent = @(
        "http_proxy=$($proxyConfig.HttpProxy)"
        "https_proxy=$($proxyConfig.HttpsProxy)"
        "no_proxy=$($proxyConfig.NoProxy -join ",")"
    )

    # Write the updated configuration back to the file
    $newContent | Set-Content -Path $proxyConfigFp
}

<#
.SYNOPSIS
Removes entries from the NoProxy array in the proxy configuration file.

.DESCRIPTION
The Remove-NoProxyEntry function reads the existing proxy configuration, removes the specified entries from the NoProxy array, and writes the updated configuration back to the proxy configuration file.

.PARAMETER Entries
The entries to remove from the NoProxy array.

.EXAMPLE
Remove-NoProxyEntry -Entries "example.com"
Removes "example.com" from the NoProxy array in the proxy configuration file.

.EXAMPLE
Remove-NoProxyEntry -Entries "example.com", "anotherdomain.com"
Removes "example.com" and "anotherdomain.com" from the NoProxy array in the proxy configuration file.

#>
function Remove-NoProxyEntry {
    param (
        [string[]]$Entries
    )

    # Check if the config file exists
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    # Read the existing configuration
    $proxyConfig = Get-ProxyConfig

    # Remove entries from the NoProxy array
    foreach ($entry in $Entries) {
        $proxyConfig.NoProxy = $proxyConfig.NoProxy | Where-Object { $_ -ne $entry }
    }

    # Prepare the new content for the config file
    $newContent = @(
        "http_proxy=$($proxyConfig.HttpProxy)"
        "https_proxy=$($proxyConfig.HttpsProxy)"
        "no_proxy=$($proxyConfig.NoProxy -join ",")"
    )

    # Write the updated configuration back to the file
    $newContent | Set-Content -Path $proxyConfigFp
}

<#
.SYNOPSIS
Reset the proxy configuration by setting all entries to empty.

.DESCRIPTION
The Reset-ProxyConfig function sets the HttpProxy, HttpsProxy, and NoProxy entries in the proxy configuration file to empty values. This effectively resets the proxy configuration to a default state with no proxy settings.

.NOTES
The function checks if the proxy configuration file exists before attempting to reset the configuration.
The proxy configuration file path is hardcoded as C:\ProgramData\k2s\proxy.conf.

.EXAMPLE
Reset-ProxyConfig
Resets the proxy configuration by setting all entries to empty.
#>
function Reset-ProxyConfig {
    if (!(Test-Path -Path $proxyConfigFp)) {
        throw "Config file not found at path: $proxyConfigFp"
    }

    $newContent = @(
        "http_proxy="
        "https_proxy="
        "no_proxy="
    )

    $newContent | Set-Content -Path $proxyConfigFp
}

<#
.SYNOPSIS
Validates that HTTP_PROXY, HTTPS_PROXY and NO_PROXY environment variables are consistently configured.

.DESCRIPTION
Validates the proxy environment variables in both Process and Machine contexts according to these rules:
  1. Either NONE of HTTP_PROXY, HTTPS_PROXY, NO_PROXY are defined, or ALL of them are defined.
  2. If NO_PROXY is defined, it MUST contain all K2s internal hosts (cluster IPs, CIDRs, etc.).

If any rule is violated, all violations are collected and thrown as a single exception.

.EXAMPLE
Test-ProxyEnvVarsConfiguration  # throws on misconfiguration
#>
function Test-ProxyEnvVarsConfiguration {
    $violations = [System.Collections.Generic.List[string]]::new()

    foreach ($scope in @('Process', 'Machine')) {
        $httpProxy  = Get-HttpProxyEnvVar  -scope $scope
        $httpsProxy = Get-HttpsProxyEnvVar -scope $scope
        $noProxy    = Get-NoProxyEnvVar    -scope $scope

        $httpProxySet  = ![string]::IsNullOrWhiteSpace($httpProxy)
        $httpsProxySet = ![string]::IsNullOrWhiteSpace($httpsProxy)
        $noProxySet    = ![string]::IsNullOrWhiteSpace($noProxy)

        $anySet = $httpProxySet -or $httpsProxySet -or $noProxySet
        $allSet = $httpProxySet -and $httpsProxySet -and $noProxySet

        if ($anySet -and -not $allSet) {
            $missing = @()
            if (-not $httpProxySet)  { $missing += 'HTTP_PROXY' }
            if (-not $httpsProxySet) { $missing += 'HTTPS_PROXY' }
            if (-not $noProxySet)    { $missing += 'NO_PROXY' }

            $violations.Add("[$scope] Inconsistent proxy environment: $($missing -join ', ') are not set while others are. Either define all of HTTP_PROXY, HTTPS_PROXY and NO_PROXY or none of them.")
        }

        if ($noProxySet) {
            $noProxyEntries = $noProxy -split ',' | ForEach-Object { $_.Trim() }
            $k2sHosts = Get-K2sHosts
            $missingHosts = $k2sHosts | Where-Object { $_ -notin $noProxyEntries }

            if ($missingHosts.Count -gt 0) {
                $violations.Add("[$scope] NO_PROXY is missing required K2s hosts: $($missingHosts -join ', '). These hosts must be excluded from the proxy to allow K2s cluster communication.")
            }
        }
    }

    if ($violations.Count -gt 0) {
        throw "[ProxyValidation] Invalid proxy environment variable configuration:`n$($violations -join "`n")"
    }
}

function Get-NoProxyEnvVar([string]$scope) {
    $value = [Environment]::GetEnvironmentVariable('NO_PROXY', $scope)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable('no_proxy', $scope)
    }
    return $value
}

function Get-HttpProxyEnvVar([string]$scope) {
    $value = [Environment]::GetEnvironmentVariable('HTTP_PROXY', $scope)
    if ([string]::IsNullOrWhiteSpace($value)) { 
        $value = [Environment]::GetEnvironmentVariable('http_proxy', $scope) 
    }
    return $value
}

function Get-HttpsProxyEnvVar([string]$scope) {
    $value = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', $scope)
    if ([string]::IsNullOrWhiteSpace($value)) { 
        $value = [Environment]::GetEnvironmentVariable('https_proxy', $scope) 
    }
    return $value
}

<#
.SYNOPSIS
Set K2s specific hosts and subnets in NO_PROXY environment variable

.DESCRIPTION
Set K2s specific hosts and subnets in NO_PROXY environment variable. This allows all executables using
NO_PROXY environment variable to communicate with K2s parts.

.NOTES
The function checks if the NO_PROXY environment variable is defined. In that case, the K2s hosts and subnets are added
#>
function Add-K2sHostsToNoProxyEnvVar() {
    $noProxyEnvVar = Get-NoProxyEnvVar -scope 'Machine'
    $k2sHosts = Get-K2sHosts

    if (![string]::IsNullOrWhiteSpace($noProxyEnvVar)) {
        Save-NoProxyBaseline -NoProxyValue $noProxyEnvVar

        $noProxyList = ConvertTo-NoProxyList -Entries @($noProxyEnvVar, $k2sHosts)
        $updatedNoProxyEnvVar = $noProxyList -join ","
        [Environment]::SetEnvironmentVariable("NO_PROXY", $updatedNoProxyEnvVar, "Process")
        [Environment]::SetEnvironmentVariable("NO_PROXY", $updatedNoProxyEnvVar, "Machine")
    }    
}

<#
.SYNOPSIS
Removes K2s specific hosts and subnets from NO_PROXY environment variable.

.DESCRIPTION
Removes K2s specific hosts and subnets from NO_PROXY environment variable.
#>
function Remove-K2sHostsFromNoProxyEnvVar() {
    $noProxyEnvVar = Get-NoProxyEnvVar -scope 'Machine'
    $k2sHosts = Get-K2sHosts

    if (![string]::IsNullOrWhiteSpace($noProxyEnvVar)) {
        $noProxyBaseline = Get-NoProxyBaseline
        if ($null -eq $noProxyBaseline) {
            Write-Log '[Proxy] NO_PROXY baseline not found. Keeping machine NO_PROXY unchanged.' -Console
            return
        }

        $noProxyList = ConvertTo-NoProxyList -Entries @($noProxyEnvVar)
        $k2sAddedHosts = $k2sHosts | Where-Object { $_ -notin $noProxyBaseline }
        $noProxyList = $noProxyList | Where-Object { $_ -notin $k2sAddedHosts }
        $updatedNoProxyEnvVar = $noProxyList -join ","
        [Environment]::SetEnvironmentVariable("NO_PROXY", $updatedNoProxyEnvVar, "Process")
        [Environment]::SetEnvironmentVariable("NO_PROXY", $updatedNoProxyEnvVar, "Machine")
    }

    Remove-NoProxyBaseline
}

Export-ModuleMember -Function Get-OrUpdateProxyServer,
                              New-ProxyConfig, 
                              Get-ProxyConfig,
                              Set-ProxyServer, 
                              Add-NoProxyEntry, 
                              Remove-NoProxyEntry, 
                              Reset-ProxyConfig,
                              Add-K2sHostsToNoProxyEnvVar,
                              Remove-K2sHostsFromNoProxyEnvVar,
                              Get-K2sHosts,
                              Test-ProxyEnvVarsConfiguration
