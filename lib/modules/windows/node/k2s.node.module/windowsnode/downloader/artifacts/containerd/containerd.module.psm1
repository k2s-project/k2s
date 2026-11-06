# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
$networkModule = "$PSScriptRoot\..\..\..\network\loopbackadapter.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule, $networkModule

$setupConfigRoot = Get-RootConfigk2s

# containerd
$windowsNode_ContainerdDirectory = 'containerd'
$windowsNode_CrictlDirectory = 'crictl'
$windowsNode_NerdctlDirectory = 'nerdctl'

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath

function Get-CtrExePath {
    return "$kubePath\bin\containerd\ctr.exe"
}

function Invoke-DownloadContainerdArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $containerdDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_ContainerdDirectory"
    $versionContainerd = '2.4.2'
    $compressedContainerdFile = "containerd-$versionContainerd-windows-amd64.tar.gz"
    $compressedFile = "$containerdDownloadsDirectory\$compressedContainerdFile"

    Write-Log "Create folder '$containerdDownloadsDirectory'"
    mkdir $containerdDownloadsDirectory | Out-Null
    Write-Log 'Download containerd'
    Invoke-DownloadFile "$compressedFile" https://github.com/containerd/containerd/releases/download/v$versionContainerd/$compressedContainerdFile $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    cmd /c tar xf `"$compressedFile`" -C `"$containerdDownloadsDirectory`"
    Write-Log '  ...done'
    if (!$?) { throw "unable to extract '$compressedFile'" }
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    $containerdArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_ContainerdDirectory"
    if (Test-Path("$containerdArtifactsDirectory")) {
        Remove-Item -Path "$containerdArtifactsDirectory" -Force -Recurse
    }

    Copy-Item -Path "$containerdDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployContainerdArtifacts($windowsNodeArtifactsDirectory) {
    $containerdArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_ContainerdDirectory"
    if (!(Test-Path "$containerdArtifactsDirectory")) {
        throw "Directory '$containerdArtifactsDirectory' does not exist"
    }
    $containerdTargetDirectory = "$kubeBinPath\containerd"
    if (!(Test-Path "$containerdTargetDirectory")) {
        Write-Log "Create folder '$containerdTargetDirectory'"
        mkdir $containerdTargetDirectory | Out-Null
    }

    $containerdSourceDirectory = "$containerdArtifactsDirectory\bin"
    if (!(Test-Path "$containerdSourceDirectory")) {
        throw "The expected directory '$containerdSourceDirectory' does not exist"
    }
    Write-Log 'Publish containerd artifacts'
    Copy-Item -Path "$containerdSourceDirectory\*.*" -Destination "$containerdTargetDirectory"
}

function Invoke-DownloadCrictlArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $crictlDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_CrictlDirectory"
    $versionCrictl = '1.37.0'

    $compressedCrictlFile = "crictl-v$versionCrictl-windows-amd64.tar.gz"
    $compressedFile = "$crictlDownloadsDirectory\$compressedCrictlFile"

    Write-Log "Create folder '$crictlDownloadsDirectory'"
    mkdir $crictlDownloadsDirectory | Out-Null
    Write-Log 'Download crictl'
    Invoke-DownloadFile "$compressedFile" https://github.com/kubernetes-sigs/cri-tools/releases/download/v$versionCrictl/$compressedCrictlFile $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    cmd /c tar xf `"$compressedFile`" -C `"$crictlDownloadsDirectory`"
    Write-Log '  ...done'
    if (!$?) { throw "unable to extract '$compressedFile'" }
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    $crictlArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_CrictlDirectory"
    if (Test-Path("$crictlArtifactsDirectory")) {
        Remove-Item -Path "$crictlArtifactsDirectory" -Force -Recurse
    }

    Copy-Item -Path "$crictlDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployCrictlArtifacts($windowsNodeArtifactsDirectory) {
    $crictlArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_CrictlDirectory"
    if (!(Test-Path "$crictlArtifactsDirectory")) {
        throw "Directory '$crictlArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish crictl artifacts'
    Copy-Item -Path "$crictlArtifactsDirectory\crictl.exe" -Destination "$kubeBinPath" -Force
}

function Invoke-DownloadNerdctlArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $nerdctlDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_NerdctlDirectory"
    $compressedNerdFile = 'nerdctl-2.4.2-windows-amd64.tar.gz'
    $compressedFile = "$nerdctlDownloadsDirectory\$compressedNerdFile"

    Write-Log "Create folder '$nerdctlDownloadsDirectory'"
    mkdir $nerdctlDownloadsDirectory | Out-Null
    Write-Log 'Download nerdctl'
    Invoke-DownloadFile "$compressedFile" https://github.com/containerd/nerdctl/releases/download/v2.4.2/$compressedNerdFile $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    cmd /c tar xf `"$compressedFile`" -C `"$nerdctlDownloadsDirectory`"
    Write-Log '  ...done'
    if (!$?) { throw "unable to extract $compressedNerdFile" }
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    $nerdctlArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_NerdctlDirectory"
    if (Test-Path("$nerdctlArtifactsDirectory")) {
        Remove-Item -Path "$nerdctlArtifactsDirectory" -Force -Recurse
    }

    Copy-Item -Path "$nerdctlDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployNerdctlArtifacts($windowsNodeArtifactsDirectory) {
    $nerdctlArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_NerdctlDirectory"
    if (!(Test-Path "$nerdctlArtifactsDirectory")) {
        throw "Directory '$nerdctlArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish nerdctl artifacts'
    Copy-Item -Path "$nerdctlArtifactsDirectory\nerdctl.exe" -Destination "$kubeBinPath" -Force
}

function Set-RootPathForImagesInConfig($tomlPath) {
   
    $template = $tomlPath + '.template'
    if (Test-Path $template) {
        $storageLocalFolder = Get-StorageLocalFolderName                
        $storageLocalDrive = Get-StorageLocalDrive
        Write-Log 'StorageLocalDrive is '
        Write-Log $storageLocalDrive
        $storageLocalDriveWithFolderName = $storageLocalDrive + $storageLocalFolder        
        Write-Log "StorageLocalDriveWithFolderName is '$storageLocalDriveWithFolderName'"
        $formattedPath = $storageLocalDriveWithFolderName.Replace('\', '\\')
        (Get-Content -path $template -Raw) -replace '%BEST-DRIVE%', $formattedPath | Set-Content -Path $tomlPath
    }    
}

function Set-InstallationDirectory($tomlPath) {
    if (!(Test-Path $tomlPath)) {
        throw "File '$tomlPath' not found"
    }
    $formattedInstallationDirectory = $kubePath.Replace('\', '\\');
    (Get-Content -path $tomlPath -Raw) -replace '%INSTALLATION_DIRECTORY%', $formattedInstallationDirectory | Set-Content -Path $tomlPath
}

function Set-UserTokenForRegistryInConfig($tomlPath) {
    $token = Get-RegistryToken
    (Get-Content -path $tomlPath -Raw) -replace '%CONTAINERD_TOKEN%', $token | Set-Content -Path $tomlPath

    # nerdctl (default refers to .docker/config.json)
    $jsonConfig = @{
        auths = @{
            'shsk2s.azurecr.io' = @{
                auth = $token
            }
        }
    }

    $jsonString = ConvertTo-Json -InputObject $jsonConfig
    New-Item -Path "$env:userprofile\.docker\config.json" -ItemType File -Force | Out-Null
    $jsonString | Set-Content -Path "$env:userprofile\.docker\config.json"
}

function Uninstall-WinContainerd {
    param(
        $ShallowUninstallation = $false
    )
    Write-Log 'Stop service containerd'
    Stop-Service containerd -ErrorAction SilentlyContinue
    Write-Log 'Unregister service'
    # &$kubePath\containerd\containerd.exe --unregister-service
    Remove-ServiceIfExists 'containerd'

    Remove-Item -Path "$kubePath\containerd\config.toml" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\containerd\flannel-l2bridge.conf" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\containerd\cni" -Recurse -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$kubePath\cfg\containerd\config.toml" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\cfg\containerd\flannel-l2bridge.conf" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\cfg\containerd\cni" -Recurse -Force -ErrorAction SilentlyContinue

    if (!$ShallowUninstallation) {
        Remove-Item -Path "$kubePath\containerd\*.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\containerd\*.zip" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\containerd\*.tar.gz" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\containerd\root" -Force -Recurse -ErrorAction SilentlyContinue

        Remove-Item -Path "$kubePath\bin\containerd\*.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\bin\containerd\*.zip" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\bin\containerd\*.tar.gz" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubePath\cfg\containerd\root" -Force -Recurse -ErrorAction SilentlyContinue

        Remove-Item -Path "$kubeBinPath\containerd" -Force -Recurse -ErrorAction SilentlyContinue
    }

    # system prune
    # crictl rmi --prune
}

function Install-WinContainerd {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Will skip setting up networking which is required only for cluster purposes')]
        [bool] $SkipNetworkingSetup = $false,
        $WindowsNodeArtifactsDirectory,
        [string] $PodSubnetworkNumber = '1'
    )

    Write-Log 'First uninstall containerd service if existent'
    Uninstall-WinContainerd -ShallowUninstallation $true

    Write-Log 'Start publishing containerd artifacts'
    Invoke-DeployContainerdArtifacts $WindowsNodeArtifactsDirectory
    Invoke-DeployCrictlArtifacts $WindowsNodeArtifactsDirectory
    Invoke-DeployNerdctlArtifacts $WindowsNodeArtifactsDirectory
    Write-Log 'Finished publishing containerd artifacts'

    Write-Log 'Creating crictl.yaml (config for crictl.exe)'
    @'
runtime-endpoint: npipe://./pipe/containerd-containerd
image-endpoint: npipe://./pipe/containerd-containerd
timeout: 30
#debug: true
'@ | Set-Content "$kubePath\bin\crictl.yaml" -Force

    # install the network plugins
    # $plfile = 'windows-container-networking-cni-amd64-v0.3.0.zip'
    # if (!(Test-Path "$kubePath\containerd\$plfile")) {
    #     DownloadFile $kubePath\containerd\$plfile https://github.com/microsoft/windows-container-networking/releases/download/v0.3.0/$plfile
    # }
    # powershell Expand-Archive $kubePath\containerd\$plfile -DestinationPath $kubePath\cni\bin -Force
    # if (!$?) { throw "unable to extract $plfile" }
    #Remove-Item -Path $kubePath\containerd\$plfile -Force -Recurse -ErrorAction SilentlyContinue

    if ( !($SkipNetworkingSetup)) {
        # replace local ip in cni template config
        Write-Log 'Create CNI config file'
        mkdir "$kubePath\cfg\containerd\cni\conf" -ErrorAction SilentlyContinue | Out-Null
        Copy-Item "$kubePath\cfg\containerd\flannel-l2bridge.conf.template" "$kubePath\cfg\containerd\flannel-l2bridge.conf" -Force

        $adapterName = Get-L2BridgeName
        Write-Log "Using network adapter '$adapterName'"
        $ipaddresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $adapterName)
        if (!$ipaddresses) {
            throw 'No IP address found which can be used for setting up K2s Setup !'
        }
        $ipaddress = $ipaddresses[0] | Select-Object -ExpandProperty IPAddress
        Write-Log "Using local IP $ipaddress for setup of CNI"

        $nameServers = Get-Content "$kubePath\cfg\containerd\flannel-l2bridge.conf" | Select-String 'NAME.SERVERS' | Select-Object -ExpandProperty Line
        if ( $nameServers ) {
            $configuredNameservers = ''
            $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber
            $kubeDnsServiceIP = $setupConfigRoot.psobject.properties['kubeDnsServiceIP'].value

            $clusterCIDRNextHop | ForEach-Object { $configuredNameservers += "                                ""$_"",`n" }
            $kubeDnsServiceIP | ForEach-Object { $configuredNameservers += "                                ""$_""" }

            $content = Get-Content "$kubePath\cfg\containerd\flannel-l2bridge.conf"
            $content | ForEach-Object { $_ -replace $nameServers, $configuredNameservers } | Set-Content "$kubePath\cfg\containerd\flannel-l2bridge.conf"
        }

        $natExceptions = Get-Content "$kubePath\cfg\containerd\flannel-l2bridge.conf" | Select-String 'NAT.EXCEPTIONS' | Select-Object -ExpandProperty Line
        if ( $natExceptions ) {

            $configuredExceptions = ''
            $clusterCIDRNatExceptions = $setupConfigRoot.psobject.properties['clusterCIDRNatExceptions'].value

            $clusterCIDRNatExceptions | ForEach-Object { $configuredExceptions += "                            ""$_"",`n" }
            $content = Get-Content "$kubePath\cfg\containerd\flannel-l2bridge.conf"
            $network2 = $ipaddress.Remove($ipaddress.LastIndexOf('.')) + '.0'
            $network2 = "                            ""$network2/24"""

            if ($configuredExceptions -ne '') {
                $configuredExceptions += $network2
            }
            else {
                $configuredExceptions = $network2
            }

            $content | ForEach-Object { $_ -replace $natExceptions, $configuredExceptions } | Set-Content "$kubePath\cfg\containerd\flannel-l2bridge.conf"
        }
        Move-Item -Path "$kubePath\cfg\containerd\flannel-l2bridge.conf" -Destination "$kubePath\cfg\containerd\cni\conf" -ErrorAction SilentlyContinue
    }
    # register and start containerd
    Write-Log 'Register service and start containerd service'
    Set-RootPathForImagesInConfig "$kubePath\cfg\containerd\config.toml" | Out-Null
    Set-InstallationDirectory "$kubePath\cfg\containerd\config.toml" | Out-Null
    Set-UserTokenForRegistryInConfig "$kubePath\cfg\containerd\config.toml" | Out-Null


    $target = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'containerd'
    Remove-Item -Path $target -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
    mkdir $target -ErrorAction SilentlyContinue | Out-Null
    &$kubeBinPath\nssm install containerd $kubePath\bin\containerd\containerd.exe *>&1 | ForEach-Object { $_.Trim() }
    &$kubeBinPath\nssm set containerd AppDirectory $kubePath\bin\containerd | Out-Null
    &$kubeBinPath\nssm set containerd AppParameters "--log-file=\`"$target\logs.log\`" --config \`"$kubePath\cfg\containerd\config.toml\`"" | Out-Null
    &$kubeBinPath\nssm set containerd AppStdout "$target\containerd_stdout.log" | Out-Null
    &$kubeBinPath\nssm set containerd AppStderr "$target\containerd_stderr.log" | Out-Null
    &$kubeBinPath\nssm set containerd AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set containerd AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set containerd AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set containerd AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set containerd AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set containerd AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set containerd Start SERVICE_AUTO_START | Out-Null

    Write-Log "Proxy to use with containerd: '$Proxy'"
    
    if ( $Proxy -ne '' ) {
        $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
        $httpProxyUrl = "http://$($windowsHostIpAddress):8181"

        $k2sHosts = Get-K2sHosts
        $allNoProxyHosts = @()
        $allNoProxyHosts += $k2sHosts
        $noProxyValue = $allNoProxyHosts -join ','
        # Build environment variables as separate lines for NSSM
        $envVars = "HTTP_PROXY=$httpProxyUrl`r`nHTTPS_PROXY=$httpProxyUrl`r`nNO_PROXY=$noProxyValue"
        &$kubeBinPath\nssm set containerd AppEnvironmentExtra $envVars | Out-Null
        Write-Log "Containerd service configured to use HTTP proxy: $httpProxyUrl with NO_PROXY: $noProxyValue"
    } else {
        $k2sHosts = Get-K2sHosts
        $noProxyValue = $k2sHosts -join ','
        &$kubeBinPath\nssm set containerd AppEnvironmentExtra "NO_PROXY=$noProxyValue" | Out-Null
        Write-Log "Containerd service configured with NO_PROXY: $noProxyValue"
    }

    # add firewall entries (else firewall will keep your CPU busy)
    Write-Log 'Adding firewall rules for containerd'
    New-NetFirewallRule -DisplayName 'Containerd' -Group 'k2s' -Direction Inbound -Action Allow -Program "$kubePath\bin\containerd\containerd.exe" -Enabled True | Out-Null
    New-NetFirewallRule -DisplayName 'Containerd-Shim' -Group 'k2s' -Direction Inbound -Action Allow -Program "$kubePath\bin\containerd\containerd-shim-runhcs-v1.exe" -Enabled True | Out-Null

    # start containerd service
    Start-Service containerd -WarningAction SilentlyContinue

    # ensure service is running
    $expectedServiceStatus = 'SERVICE_RUNNING'
    Write-Log "Waiting until service 'containerd' has status '$expectedServiceStatus'"
    $retryNumber = 0
    $maxAmountOfRetries = 3
    $waitTimeInSeconds = 2
    $serviceIsRunning = $false
    while ($retryNumber -lt $maxAmountOfRetries) {
        $serviceStatus = (&$kubeBinPath\nssm status containerd)
        if ($serviceStatus -eq "$expectedServiceStatus") {
            $serviceIsRunning = $true
            break;
        }
        $retryNumber++
        Start-Sleep -Seconds $waitTimeInSeconds
        $totalWaitingTime = $waitTimeInSeconds * $retryNumber
        Write-Log "Waiting since $totalWaitingTime seconds for service 'containerd' to be in status '$expectedServiceStatus' (current status: $serviceStatus)"
    }
    if (!$serviceIsRunning) {
        throw "Service 'containerd' is not running."
    }
    Write-Log "Service 'containerd' has status '$expectedServiceStatus'"
    
    # Wait for containerd named pipe to be ready
    Write-Log 'Waiting for containerd pipe to be ready...'
    $pipeReadyRetries = 0
    $maxPipeRetries = 10
    $pipeWaitSeconds = 1
    $pipeReady = $false
    
    while ($pipeReadyRetries -lt $maxPipeRetries) {
        # Test pipe accessibility using nerdctl version command (lightweight check)
        $testResult = & $kubeBinPath\nerdctl.exe version 2>&1
        if ($LASTEXITCODE -eq 0) {
            $pipeReady = $true
            Write-Log 'Containerd pipe is ready'
            break
        }
        
        $pipeReadyRetries++
        $totalPipeWaitTime = $pipeWaitSeconds * $pipeReadyRetries
        Write-Log "Waiting for containerd pipe to be accessible ($totalPipeWaitTime seconds elapsed, attempt $pipeReadyRetries/$maxPipeRetries)"
        Start-Sleep -Seconds $pipeWaitSeconds
    }
    
    if (!$pipeReady) {
        Write-Log 'WARNING: Containerd pipe not ready after maximum retries, proceeding anyway' -Console
    }
}
