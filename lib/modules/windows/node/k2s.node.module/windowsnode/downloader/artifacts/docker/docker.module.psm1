# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
$servicesModule = "$PSScriptRoot\..\..\..\services\services.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule, $servicesModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath

# docker
$windowsNode_DockerDirectory = 'docker'

function Invoke-DownloadDockerArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $dockerDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_DockerDirectory"
    $DockerVersion = '29.9.3'
    $compressedDockerFile = 'docker-' + $DockerVersion + '.zip'
    $compressedFile = "$dockerDownloadsDirectory\$compressedDockerFile"

    $url = 'https://download.docker.com/win/static/stable/x86_64/' + $compressedDockerFile

    Write-Log "Create folder '$dockerDownloadsDirectory'"
    mkdir $dockerDownloadsDirectory | Out-Null
    Write-Log 'Download docker'
    Write-Log "Fetching $url (approx. 130 MB)...."
    Invoke-DownloadFile "$compressedFile" $url $true $Proxy
    Expand-Archive "$compressedFile" -DestinationPath "$dockerDownloadsDirectory" -Force
    Write-Log '  ...done'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    $dockerArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_DockerDirectory"

    if (Test-Path("$dockerArtifactsDirectory")) {
        Remove-Item -Path "$dockerArtifactsDirectory" -Force -Recurse
    }

    Copy-Item -Path "$dockerDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployDockerArtifacts($windowsNodeArtifactsDirectory) {
    $dockerDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_DockerDirectory\docker"
    if (!(Test-Path "$dockerDirectory")) {
        throw "Directory '$dockerDirectory' does not exist"
    }
    Write-Log 'Publish docker artifacts'
    Copy-Item -Path "$dockerDirectory\" -Destination "$kubeBinPath" -Force -Recurse
}

function Install-WinDocker {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Start docker daemon and keep running')]
        [switch] $AutoStart = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Proxy to use')]
        [string] $Proxy = ''
    )

    $WinBuildEnabled = Get-ConfigWinBuildEnabledFlag
    if ($WinBuildEnabled) {
        Write-Log 'docker is installed from K2s already, nothing to do.'
        return
    }

    if ((Get-Service 'docker' -ErrorAction SilentlyContinue)) {
        Write-Log 'Found existing dockerd service, nothing to do'
        return
    }

    if (Get-Service docker -ErrorAction SilentlyContinue) {
        Write-Log 'Stop docker service'
        Stop-Service docker
    }


    # Register the Docker daemon as a service.
    $serviceName = 'docker'
    if (!(Get-Service $serviceName -ErrorAction SilentlyContinue)) {
        Write-Log 'Register the docker daemon as a service'
        $storageLocalDrive = Get-StorageLocalDrive
        mkdir -force "$storageLocalDrive\docker" | Out-Null

        # &"$kubeBinPath\docker\dockerd" --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --register-service
        # &"$kubeBinPath\docker\dockerd" --log-level debug  -H fd:// --containerd="\\\\.\\pipe\\containerd-containerd" --register-service

        $target = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'dockerd'
        Remove-Item -Path $target -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
        mkdir $target -ErrorAction SilentlyContinue | Out-Null
        &$kubeBinPath\nssm install docker $kubePath\bin\docker\dockerd.exe
        &$kubeBinPath\nssm set docker AppDirectory $kubePath\bin\docker | Out-Null
        &$kubeBinPath\nssm set docker AppParameters --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --log-level debug | Out-Null
        &$kubeBinPath\nssm set docker AppStdout "$target\dockerd_stdout.log" | Out-Null
        &$kubeBinPath\nssm set docker AppStderr "$target\dockerd_stderr.log" | Out-Null
        &$kubeBinPath\nssm set docker AppStdoutCreationDisposition 4 | Out-Null
        &$kubeBinPath\nssm set docker AppStderrCreationDisposition 4 | Out-Null
        &$kubeBinPath\nssm set docker AppRotateFiles 1 | Out-Null
        &$kubeBinPath\nssm set docker AppRotateOnline 1 | Out-Null
        &$kubeBinPath\nssm set docker AppRotateSeconds 0 | Out-Null
        &$kubeBinPath\nssm set docker AppRotateBytes 500000 | Out-Null


        if ($Proxy -eq '') {
            # If not present get proxy from configuration
            $kubeSwitchIP = Get-ConfiguredKubeSwitchIP
            $Proxy = "http://$($kubeSwitchIP):8181"
        }

        if ( $Proxy -ne '' ) {
            Write-Log("Setting proxy for docker: $Proxy")
            
            $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
            $httpProxyUrl = "http://$($windowsHostIpAddress):8181"
            
            $k2sHosts = Get-K2sHosts
            $allNoProxyHosts = @()
            $allNoProxyHosts += $k2sHosts
            
            $ipControlPlane = Get-ConfiguredIPControlPlane
            $clusterCIDR = Get-ConfiguredClusterCIDR
            $clusterCIDRServices = Get-ConfiguredClusterCIDRServices
            $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
            
            $allNoProxyHosts += @("localhost", $ipControlPlane, "10.81.0.0/16", $clusterCIDR, $clusterCIDRServices, $ipControlPlaneCIDR, ".local")
            $uniqueNoProxyHosts = $allNoProxyHosts | Sort-Object -Unique
            $NoProxy = $uniqueNoProxyHosts -join ','
            
            # Build environment variables as separate lines for NSSM
            $envVars = "HTTP_PROXY=$httpProxyUrl`r`nHTTPS_PROXY=$httpProxyUrl`r`nNO_PROXY=$NoProxy"
            &$kubeBinPath\nssm set docker AppEnvironmentExtra $envVars | Out-Null
            Write-Log "Docker service configured to use HTTP proxy: $httpProxyUrl with NO_PROXY: $NoProxy"
            &$kubeBinPath\nssm get docker AppEnvironmentExtra
        }
    }

    # check nssm
    $nssm = Get-Command 'nssm.exe' -ErrorAction SilentlyContinue
    if ($AutoStart) {
        if ($nssm) {
            &nssm set $serviceName Start SERVICE_AUTO_START 2>&1 | Out-Null
        }
        else {
            &$kubeBinPath\nssm set $serviceName Start SERVICE_AUTO_START 2>&1 | Out-Null
        }
    }
    else {
        if ($nssm) {
            &nssm set $serviceName Start SERVICE_DEMAND_START 2>&1 | Out-Null
        }
        else {
            &$kubeBinPath\nssm set $serviceName Start SERVICE_DEMAND_START 2>&1 | Out-Null
        }
    }

    # Start the Docker service, if wanted
    if ($AutoStart) {
        Write-Log "Starting '$serviceName' service"
        Start-Service $serviceName -WarningAction SilentlyContinue
    }

    # update metric for NAT interface
    $ipindex2 = Get-NetIPInterface | Where-Object InterfaceAlias -Like '*nat*' | Select-Object -expand 'ifIndex'
    if ($null -ne $ipindex2) {
        Set-NetIPInterface -InterfaceIndex $ipindex2 -InterfaceMetric 6000
    }

    Set-ConfigWinBuildEnabledFlag -Value $([bool]$true)

    Write-Log 'Docker Install Finished'
}

function Uninstall-WinDocker {
    param(
        $ShallowUninstallation = $false
    )
    $serviceWasRemoved = $false
    $dockerDir = "$kubeBinPath\docker"
    $dockerExe = "$dockerDir\docker.exe"

    $WinBuildEnabled = Get-ConfigWinBuildEnabledFlag

    if ((Test-Path $dockerExe) -and $($WinBuildEnabled)) {
        if (Get-Service 'docker' -ErrorAction SilentlyContinue) {
            # only remove docker service if it is not from DockerDesktop
            Stop-ServiceProcess 'docker' 'dockerd'
            Write-Log 'Unregistering service: docker (dockerd.exe)'
            &"$kubeBinPath\docker\dockerd" --unregister-service
            Start-Sleep 3
            $i = 0
            while (Get-Service 'docker' -ErrorAction SilentlyContinue) {
                $i++
                if ($i -ge 20) {
                    Write-Log 'trying to forcefully stop dockerd.exe'
                    Stop-ServiceProcess 'docker' 'dockerd'
                    sc.exe delete 'docker' -ErrorAction SilentlyContinue 2>&1 | Out-Null
                }
                Start-Sleep 1
            }
            $serviceWasRemoved = $true
        }

        $dockerConfigDir = Get-ConfiguredDockerConfigDir
        if (Test-Path $dockerConfigDir) {
            $newName = $dockerConfigDir + '_' + $( Get-Date -Format yyyy-MM-dd_HHmmss )
            Write-Log "Saving: $dockerConfigDir to $newName"
            Rename-Item $dockerConfigDir -NewName $newName
            Write-Log "Removing: $dockerConfigDir"
            Remove-Item $dockerConfigDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ((Get-Service 'docker' -ErrorAction SilentlyContinue) -and !$serviceWasRemoved) {
        # only remove docker service if it is not from DockerDesktop
        Write-Log 'Removing service: docker'
        Stop-Service -Force -Name 'docker' | Out-Null
        sc.exe delete 'docker' | Out-Null

        # remove registry key which could remain from different docker installs
        Remove-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\docker' -ErrorAction SilentlyContinue
    }

    if (!$ShallowUninstallation) {
        Remove-Item -Path "$kubePath\smallsetup\docker*.zip" -Force -ErrorAction SilentlyContinue

        Write-Log "Removing: $dockerDir"
        Remove-Item $dockerDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember Invoke-DownloadDockerArtifacts, Invoke-DeployDockerArtifacts, Install-WinDocker, Uninstall-WinDocker
