# SPDX-FileCopyrightText: © 2024 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath
$kubeToolsPath = Get-KubeToolsPath


# kubetools
$windowsNode_KubetoolsDirectory = 'kubetools'
$windowsNode_KubeletExe = 'kubelet.exe'
$windowsNode_KubeadmExe = 'kubeadm.exe'
$windowsNode_KubeproxyExe = 'kube-proxy.exe'
$windowsNode_KubectlExe = 'kubectl.exe'
$systemDefaultDriveLetter = Get-SystemDriveLetter

$kubeletConfigDir = $systemDefaultDriveLetter + ':\var\lib\kubelet'

function Get-KubeletConfigDir {
    return $kubeletConfigDir
}

function Invoke-DownloadKubetoolsArtifacts($downloadsBaseDirectory, $KubernetesVersion, $Proxy, $K8sBinsPath) {
    $kubetoolsDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_KubetoolsDirectory"

    Write-Log "Create folder '$kubetoolsDownloadsDirectory'"
    mkdir $kubetoolsDownloadsDirectory | Out-Null

    if ($K8sBinsPath -ne '') {
        Copy-LocalBuildsOfKubeTools -K8sBinsPath $K8sBinsPath -Destination $kubetoolsDownloadsDirectory
        return
    }

    if (!$KubernetesVersion.StartsWith('v')) {
        $KubernetesVersion = 'v' + $KubernetesVersion
    }

    Write-Log 'Download kubelet'
    Invoke-DownloadFile "$kubetoolsDownloadsDirectory\$windowsNode_KubeletExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$windowsNode_KubeletExe $true $Proxy
    Write-Log 'Download kubeadm'
    Invoke-DownloadFile "$kubetoolsDownloadsDirectory\$windowsNode_KubeadmExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$windowsNode_KubeadmExe $true $Proxy
    Write-Log 'Download kubeproxy'
    Invoke-DownloadFile "$kubetoolsDownloadsDirectory\$windowsNode_KubeproxyExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$windowsNode_KubeproxyExe $true $Proxy
    Write-Log 'Download kubectl'
    Invoke-DownloadKubectl -Destination "$kubetoolsDownloadsDirectory\$windowsNode_KubectlExe" -KubernetesVersion $KubernetesVersion -Proxy "$Proxy"
}

function Invoke-DownloadKubectl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$KubernetesVersion,
        [Parameter(Mandatory = $false)]
        [string]$Proxy
    )

    Invoke-DownloadFile "$Destination" https://dl.k8s.io/release/$KubernetesVersion/bin/windows/amd64/$windowsNode_KubectlExe $true $Proxy
}

function Invoke-DeployKubetoolsArtifacts($windowsNodeArtifactsDirectory) {
    $kubetoolsArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_KubetoolsDirectory"
    if (!(Test-Path "$kubetoolsArtifactsDirectory")) {
        throw "Directory '$kubetoolsArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish kubelet'
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubeletExe" -Destination "$kubeToolsPath" -Force
    Write-Log 'Publish kubeadm'
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubeadmExe" -Destination "$kubeToolsPath" -Force
    Write-Log 'Publish kubeproxy'
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubeproxyExe" -Destination "$kubeToolsPath" -Force
    Invoke-DeployKubetoolKubectl $windowsNodeArtifactsDirectory
}

function Invoke-DeployKubetoolKubectl($windowsNodeArtifactsDirectory) {
    $kubetoolsArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_KubetoolsDirectory"
    if (!(Test-Path "$kubetoolsArtifactsDirectory")) {
        throw "Directory '$kubetoolsArtifactsDirectory' does not exist"
    }
    Write-Log 'Publish kubectl'
    $targetPath = "$kubeToolsPath"
    if (!(Test-Path -Path $targetPath)) {
        New-Item -Path $targetPath -ItemType Directory
    }
    Copy-Item -Path "$kubetoolsArtifactsDirectory\$windowsNode_KubectlExe" -Destination "$kubeToolsPath" -Force
}

function Install-WinKubelet {
    Write-Log 'Registering kubelet service'
    mkdir -Force (Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'kubelet') | Out-Null

    mkdir -force "$kubeletConfigDir\etc" | Out-Null
    mkdir -force "$kubeletConfigDir\etc\kubernetes" | Out-Null
    mkdir -force "$kubeletConfigDir\etc\kubernetes\manifests" | Out-Null
    mkdir -force "$($systemDefaultDriveLetter):\etc\kubernetes\pki" | Out-Null
    mkdir -force "$($systemDefaultDriveLetter):\etc\kubernetes\kubelet.conf.d" | Out-Null
    Copy-Item -force "$kubePath\smallsetup\kubeadm-flags.env" $kubeletConfigDir

    # Deploy default kubelet drop-in config (enforceNodeAllocatable disabled for Windows)
    $defaultDropIn = "$kubePath\smallsetup\common\00-k2s-defaults.conf"
    if (Test-Path $defaultDropIn) {
        Copy-Item -Force $defaultDropIn "$($systemDefaultDriveLetter):\etc\kubernetes\kubelet.conf.d\00-k2s-defaults.conf"
    }

    if (!(Test-Path "$kubeletConfigDir\etc\kubernetes\pki")) {
        New-Item -path "$kubeletConfigDir\etc\kubernetes\pki" -type SymbolicLink -value "$($systemDefaultDriveLetter):\etc\kubernetes\pki\" | Out-Null
    }

    $powershell = (Get-Command powershell).Source
    $powershellArgs = '-ExecutionPolicy Bypass -NoProfile'
    $startKubeletScript = 'StartKubelet.ps1'
    $startKubeletScriptPath = "$kubePath\smallsetup\common\$startKubeletScript"

    $StartKubeletFileContent = 'Set-Location $PSScriptRoot
    $FileContent = Get-Content -Path "' + ($systemDefaultDriveLetter) + ':\var\lib\kubelet\kubeadm-flags.env"
    $global:KubeletArgs = $FileContent.Trim("KUBELET_KUBEADM_ARGS=`"")
    $hn = ($(hostname)).ToLower()
    $cmd = "' + "&'$kubeToolsPath\kubelet.exe'" + ' $global:KubeletArgs --root-dir=' + ($systemDefaultDriveLetter) + ':\var\lib\kubelet --cert-dir=' + ($systemDefaultDriveLetter) + ':\var\lib\kubelet\pki --config=' + ($systemDefaultDriveLetter) + ':\var\lib\kubelet\config.yaml --config-dir=' + ($systemDefaultDriveLetter) + ':\etc\kubernetes\kubelet.conf.d --bootstrap-kubeconfig=' + ($systemDefaultDriveLetter) + ':\etc\kubernetes\bootstrap-kubelet.conf --kubeconfig=' + "'$kubePath\config'" + ' --hostname-override=$hn "

    Invoke-Expression $cmd'

    Set-Content -Path $startKubeletScriptPath -Value $StartKubeletFileContent

    &$kubeBinPath\nssm install kubelet $powershell
    &$kubeBinPath\nssm set kubelet AppParameters "$powershellArgs \`"Invoke-Command {&'$startKubeletScriptPath'}\`"" | Out-Null
    &$kubeBinPath\nssm set kubelet DependOnService containerd | Out-Null
    
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $httpProxyUrl = "http://$($windowsHostIpAddress):8181"
    
    
    $k2sHosts = Get-K2sHosts
    $noProxyValue = $k2sHosts -join ','
    
    # Build environment variables as separate lines for NSSM
    $envVars = "HTTP_PROXY=$httpProxyUrl`r`nHTTPS_PROXY=$httpProxyUrl`r`nNO_PROXY=$noProxyValue"
    &$kubeBinPath\nssm set kubelet AppEnvironmentExtra $envVars | Out-Null
    Write-Log "Kubelet service configured to use HTTP proxy: $httpProxyUrl with NO_PROXY: $noProxyValue"
    
    $kubeletLogDir = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'kubelet'
    if (-not (Test-Path $kubeletLogDir)) { mkdir -Force $kubeletLogDir | Out-Null }
    &$kubeBinPath\nssm set kubelet AppStdout "$kubeletLogDir\kubelet_stdout.log" | Out-Null
    &$kubeBinPath\nssm set kubelet AppStderr "$kubeletLogDir\kubelet_stderr.log" | Out-Null
    &$kubeBinPath\nssm set kubelet AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set kubelet AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set kubelet AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set kubelet AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set kubelet AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set kubelet AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set kubelet Start SERVICE_AUTO_START | Out-Null
}

function Install-WinKubeProxy {
    Write-Log 'Registering kubeproxy service'
    $kubeProxyLogDir = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath 'kubeproxy'
    mkdir -force $kubeProxyLogDir | Out-Null

    &$kubeBinPath\nssm install kubeproxy "$kubeToolsPath\kube-proxy.exe"
    &$kubeBinPath\nssm set kubeproxy AppDirectory "$kubeToolsPath" | Out-Null
    $hn = ($(hostname)).ToLower()
    &$kubeBinPath\nssm set kubeproxy AppParameters "--proxy-mode=kernelspace --hostname-override=$hn --kubeconfig=\`"$kubePath\config\`" --enable-dsr=false " | Out-Null
    
    # Configure kube-proxy to use HTTP proxy service for external requests
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $httpProxyUrl = "http://$($windowsHostIpAddress):8181"
    
    # Get K2s hosts for no-proxy configuration
    $k2sHosts = Get-K2sHosts
    $noProxyValue = $k2sHosts -join ','
    
    # Set proxy environment variables for kube-proxy service
    # Build environment variables as separate lines for NSSM
    $envVars = "KUBE_NETWORK=cbr0`r`nHTTP_PROXY=$httpProxyUrl`r`nHTTPS_PROXY=$httpProxyUrl`r`nNO_PROXY=$noProxyValue"
    &$kubeBinPath\nssm set kubeproxy AppEnvironmentExtra $envVars | Out-Null
    Write-Log "Kube-proxy service configured to use HTTP proxy: $httpProxyUrl with NO_PROXY: $noProxyValue"
    
    &$kubeBinPath\nssm set kubeproxy DependOnService kubelet | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppStdout "$kubeProxyLogDir\kubeproxy_stdout.log" | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppStderr "$kubeProxyLogDir\kubeproxy_stderr.log" | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppStdoutCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppStderrCreationDisposition 4 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppRotateFiles 1 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppRotateOnline 1 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppRotateSeconds 0 | Out-Null
    &$kubeBinPath\nssm set kubeproxy AppRotateBytes 500000 | Out-Null
    &$kubeBinPath\nssm set kubeproxy Start SERVICE_AUTO_START | Out-Null
}

function Copy-LocalBuildsOfKubeTools {
    Param (
        [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
        [string] $K8sBinsPath = '',
        [parameter(Mandatory = $false, HelpMessage = 'The destination path where to copy Kubernetes binaries')]
        [string] $Destination = ''
    )

    if (!$(Test-Path $K8sBinsPath)) {
        Write-Log "No local Kubernetes binary folder '$K8sBinsPath' found"
        return
    }

    $kubetools = @($windowsNode_KubeletExe, $windowsNode_KubeadmExe, $windowsNode_KubeproxyExe, $windowsNode_KubectlExe)

    $kubetools | ForEach-Object {
        $toolPath = Join-Path $K8sBinsPath $_
        if ($(Test-Path $toolPath)) {
            Write-Log "Found local build of '$_' at '$toolPath'"
            Write-Log "Copying '$toolPath' to '$Destination'"
            Copy-Item $toolPath -Destination $Destination -Force
        }
    }
}

function Compress-WindowsNodeArtifactsWithLocalKubeTools {
    Param (
        [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
        [string] $K8sBinsPath = ''
    )

    $windowsNodeArtifactsZipFilePath = Get-WindowsNodeArtifactsZipFilePath
    $windowsArtifactsDirectory = Get-WindowsArtifactsDirectory
    $kubeToolsDirectory = $(Join-Path $windowsArtifactsDirectory $windowsNode_KubetoolsDirectory)

    Expand-Archive -LiteralPath $windowsNodeArtifactsZipFilePath -DestinationPath $windowsArtifactsDirectory

    Copy-LocalBuildsOfKubeTools -K8sBinsPath $K8sBinsPath -Destination $kubeToolsDirectory

    Write-Log 'Create compressed file with artifacts for the Windows node with local builds of Kubernetes binaries'
    Compress-Archive -Path "$windowsArtifactsDirectory\*" -DestinationPath "$windowsNodeArtifactsZipFilePath" -Force

    Remove-Item $windowsArtifactsDirectory -Force -Recurse
}

Export-ModuleMember -Function *

