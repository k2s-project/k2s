# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeBinPath = Get-KubeBinPath
$setupConfigRoot = Get-RootConfigk2s
# dns proxy
$windowsNode_DnsProxyDirectory = 'dnsproxy'
$markerForAddingAdditionalListenAddresses = '__ADD_LISTEN_ADDRESSES_BELOW_THIS_MARKER__'
$configFile = "$kubeBinPath\dnsproxy.yaml"

function Invoke-DownloadDnsProxyArtifacts($downloadsBaseDirectory, $Proxy) {
    $dnsproxyDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_DnsProxyDirectory"
    $compressedFile = "$dnsproxyDownloadsDirectory\dnsproxy.zip"

    Write-Log "Create folder '$dnsproxyDownloadsDirectory'"
    mkdir $dnsproxyDownloadsDirectory | Out-Null
    Write-Log 'Download dnsproxy'
    Invoke-DownloadFile "$compressedFile" https://github.com/AdguardTeam/dnsproxy/releases/download/v0.86.0/dnsproxy-windows-amd64-v0.86.0.zip $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    $ErrorActionPreference = 'SilentlyContinue'
    tar C `"$dnsproxyDownloadsDirectory`" -xvf `"$compressedFile`" --strip-components 1 windows-amd64/*.exe 2>&1 | % { "$_" }
    $ErrorActionPreference = 'Stop'
    Write-Log '  ...done'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

function Invoke-DeployDnsProxyArtifacts($windowsNodeArtifactsDirectory) {
    $dnsProxyDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_DnsProxyDirectory"
    if (!(Test-Path "$dnsProxyDirectory")) {
        throw "Directory '$dnsProxyDirectory' does not exist"
    }
    Write-Log 'Publish dnsproxy artifacts'
    Copy-Item -Path "$dnsProxyDirectory\*" -Destination "$kubeBinPath" -Recurse -Force
}

function Install-WinDnsProxy {
    param (
        [string[]] $ListenIpAddresses = $(throw 'Argument missing: ListenIpAddresses'),
        [string] $UpstreamIpAddressForCluster = $(throw 'Argument missing: ClusterUpstreamIpAddress'),
        [string[]] $UpstreamIpAddressesForNonCluster = $(throw 'Argument missing: UpstreamIpAddressesForNonCluster')
    )

    Write-Log 'Registering dnsproxy service'
    mkdir -Force (Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'dnsproxy') | Out-Null
    &$kubeBinPath\nssm install dnsproxy $kubeBinPath\dnsproxy.exe
    &$kubeBinPath\nssm set dnsproxy AppDirectory $kubeBinPath | Out-Null

    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $httpProxyUrl = "http://$($windowsHostIpAddress):8181"
    
    $k2sHosts = Get-K2sHosts
    $noProxyValue = $k2sHosts -join ','
    
    # Build environment variables as separate lines for NSSM
    $envVars = "HTTP_PROXY=$httpProxyUrl`r`nHTTPS_PROXY=$httpProxyUrl`r`nNO_PROXY=$noProxyValue"
    &$kubeBinPath\nssm set dnsproxy AppEnvironmentExtra $envVars | Out-Null
    Write-Log "DNS Proxy service configured to use HTTP proxy: $httpProxyUrl with NO_PROXY: $noProxyValue"

    Write-Log 'Creating dnsproxy.yaml (config for dnsproxy.exe)'
    
    $configContent = @"
# To use it within dnsproxy specify the --config-path=/<path-to-config.yaml>
# option.  Any other command-line options specified will override the values
# from the config file.
---
listen-addrs:
# $markerForAddingAdditionalListenAddresses
"@

    $configContent += "`n"
    $ListenIpAddresses | ForEach-Object { $configContent += "$(Format-ListenAddress -IpAddress $_)`n" }
    $configContent += "upstream: `n"
    $configContent += "  - ""[/local/]$UpstreamIpAddressForCluster"" `n"
    $UpstreamIpAddressesForNonCluster | ForEach-Object { $configContent += "  - ""$_"" `n" }

    $configContent | Set-Content "$kubeBinPath\dnsproxy.yaml" -Force

    &$kubeBinPath\nssm set dnsproxy AppParameters " --config-path=\`"$kubeBinPath\dnsproxy.yaml\`" " | Out-Null
    $dnsProxyLogDir = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'dnsproxy'
    if (-not (Test-Path $dnsProxyLogDir)) { mkdir -Force $dnsProxyLogDir | Out-Null }
    &$kubeBinPath\nssm set dnsproxy AppStdout "$dnsProxyLogDir\dnsproxy_stdout.log" | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppStderr "$dnsProxyLogDir\dnsproxy_stderr.log" | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set dnsproxy AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set dnsproxy Start SERVICE_AUTO_START | Out-Null

    New-NetFirewallRule -DisplayName 'K2s open port 53' -Group 'k2s' -Direction Inbound -Action Allow -Protocol UDP -LocalPort 53 | Out-Null
}

function Start-WinDnsProxy {
    Start-ServiceAndSetToAutoStart -Name 'dnsproxy'
}

function Stop-WinDnsProxy {
    Stop-ServiceAndSetToManualStart 'dnsproxy'
}

function Remove-WinDnsProxy {
    Remove-ServiceIfExists 'dnsproxy'
    Remove-NetFirewallRule -DisplayName 'K2s open port 53' -ErrorAction SilentlyContinue | Out-Null
}

function Add-WinDnsProxyListenAddress {
    param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )
    Write-Log "Adding '$IpAddress' to the dnsproxy listen address list"

    $newListenAddress = Format-ListenAddress -IpAddress $IpAddress

    $configContent = Get-Content $configFile
    if (!($configContent.Contains($newListenAddress))) {
        $newConfigContent = $configContent.Replace("$markerForAddingAdditionalListenAddresses", "$markerForAddingAdditionalListenAddresses`r`n$newListenAddress")
        $newConfigContent | Set-Content $configFile -Force
    }

    Restart-WinDnsProxyIfRunning
}

function Remove-WinDnsProxyListenAddress {
    param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )
    Write-Log "Removing '$IpAddress' from the dnsproxy listen address list"

    $entryToDelete = Format-ListenAddress -IpAddress $IpAddress

    $configContent = Get-Content $configFile
    $filteredContent = $configcontent | Where-Object { $_ -ne $entryToDelete }
    $filteredContent | Set-Content $configFile -Force

    Restart-WinDnsProxyIfRunning
}

function Format-ListenAddress {
    param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    return "  - ""$IpAddress"""
}

function Restart-WinDnsProxyIfRunning {
    $serviceStatus = &$kubeBinPath\nssm status dnsproxy
    $isRunning = $($serviceStatus.Contains('SERVICE_RUNNING'))
    if ($isRunning) {
        Write-Log 'dnsproxy is running. Stopping and starting it to apply configuration changes.'
        Stop-WinDnsProxy
        Start-WinDnsProxy
    }
}
