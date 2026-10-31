# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0


$infraModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$provisioningModule = "$PSScriptRoot\..\baseimage\provisioning.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"
Import-Module $infraModule, $provisioningModule, $vmModule

$kubernetesVersion = Get-DefaultK8sVersion

$controlPlaneUserName = Get-DefaultUserNameControlPlane
$controlPlaneIpAddress = Get-ConfiguredIPControlPlane
$wslConfigurationFilePath = '/etc/wsl.conf'
$offlineK2sDebPackagesDirectory = 'apt-offline-k2s'
$kubernetesDebPackagesDirectory = 'kubernetes'
$buildahDebPackagesDirectory = 'buildah'

$binPath = Get-KubeBinPath
$directoryOfLinuxNodeArtifactsOnWindowsHost = "$binPath\linuxnode"
$baseDirectoryOfKubenodeDebPackagesOnWindowsHost = "$directoryOfLinuxNodeArtifactsOnWindowsHost\packages"
$directoryOfKubenodeImagesOnWindowsHost = "$directoryOfLinuxNodeArtifactsOnWindowsHost\images"

$linuxNodeArtifactsZipFileName = 'LinuxNodeArtifacts.zip'
$pathOfLinuxNodeArtifactsPackageOnWindowsHost = "$binPath\$linuxNodeArtifactsZipFileName"

function Get-KubenodeNoProxy {
    $entries = @(
        'localhost',
        '127.0.0.1',
        '::1',
        '.local',
        '.cluster.local',
        '.svc',
        (Get-ConfiguredIPControlPlane),
        (Get-ConfiguredKubeSwitchIP),
        (Get-ConfiguredClusterCIDR),
        (Get-ConfiguredClusterCIDRServices),
        (Get-ConfiguredKubeDnsServiceIP)
    )

    return (($entries | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ',')
}

Function Assert-GeneralComputerPrerequisites {
    Param(
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    Write-Log 'Checking if the hostname contains only allowed characters...'
    $hostnameResult = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'hostname' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries 3 -Timeout 3
    if (-not $hostnameResult.Success) {
        throw "Could not retrieve the hostname of the computer with IP '$IpAddress': SSH command 'hostname' failed after retrying. Output: $($hostnameResult.Output)"
    }
    [string]$hostname = $hostnameResult.Output
    if ([string]::IsNullOrWhiteSpace($hostname) -eq $true) {
        throw "The hostname of the computer with IP '$IpAddress' could not be retrieved."
    }
    $hasHostnameUppercaseChars = [regex]::IsMatch($hostname, '[^a-z]+')
    if ($hasHostnameUppercaseChars) {
        throw "The hostname '$hostname' of the computer reachable on IP '$IpAddress' contains not allowed characters. " +
        'Only a hostname that follows the pattern [a-z] is allowed.'
    }
    else {
        Write-Log ' ...done'
    }
}

Function Set-UpComputerBeforeProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [parameter(Mandatory = $false)]
        [string] $Proxy = '',
        [string] $InstalledDistribution = 'debian13'
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd
    if ( $Proxy -ne '' ) {
        Write-Log "Setting proxy '$Proxy'"
        $linuxScriptDir = Get-LinuxScriptPath -InstalledDistribution $InstalledDistribution -InstallationPath $installationPath
        $setProxyScript = "$linuxScriptDir\setproxy.sh"
        
        Invoke-RemoteScript -LocalScriptPath $setProxyScript `
                            -UserName $UserName `
                            -IpAddress $IpAddress `
                            -UserPwd $UserPwd `
                            -Arguments @($Proxy) `
                            -CleanupAfterExecution `
                            -Retries 3
        
        Write-Log "Proxy configuration completed" -Console
    }

    if (![string]::IsNullOrWhiteSpace($UserPwd)) {
        Write-Log 'Retrieve hostname'
        [string]$hostname = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'hostname' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output
        if ([string]::IsNullOrWhiteSpace($hostname) -eq $true) {
            throw "The hostname of the computer with IP '$IpAddress' could not be retrieved."
        }
        
        Write-Log "Add hostname '$hostname' to /etc/hosts"
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo sed -i 's/\tlocalhost/\tlocalhost $hostname/g' /etc/hosts" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output
    }
}

Function Set-UpComputerAfterProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    Write-Log 'Copying some dotfiles to remote computer ...'
    CopyDotFile -SourcePath "$PSScriptRoot\..\common\dotfiles\" -DotFile '.inputrc' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\..\common\dotfiles\" -DotFile '.bash_kubectl' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\..\common\dotfiles\" -DotFile '.bash_docker' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
    CopyDotFile -SourcePath "$PSScriptRoot\..\common\dotfiles\" -DotFile '.bash_aliases' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd

    Write-Log 'Set time zone in VM to UTC (will be updated to host timezone on first start)...'
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo timedatectl set-timezone UTC' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd).Output | Write-Log

    Write-Log 'Enable hushlogin...'
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'touch ~/.hushlogin' -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd).Output | Write-Log
}

Function Set-KubernetesAptRepository {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = '',
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $K8sVersion = $(throw 'Argument missing: K8sVersion')
    )
    $remoteUser = "$UserName@$IpAddress"
    
    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: Command'),
            [switch]$IgnoreErrors = $false, [string]$RepairCmd = $null, [uint16]$Retries = 0
        )
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        }
        else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd" -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        }
    }
    Write-Log 'Prepare for Kubernetes installation'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gpg' -Retries 2 -RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install'

    Write-Log 'Install curl'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes curl' -Retries 2 -RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install'


    # we need major and minor for apt keys
    $proxyToAdd = ''
    if ($Proxy -ne '') {
        $proxyToAdd = " --Proxy $Proxy"
    }
    $pkgShortK8sVersion = $K8sVersion.Substring(0, $K8sVersion.lastIndexOf('.'))
    $kubernetesPublicKeyFilePath = '/tmp/kubernetes.key'
    $kubernetesAptKeyFilePath = '/usr/share/keyrings/kubernetes-apt-keyring.gpg'
    &$executeRemoteCommand "sudo rm -f $kubernetesPublicKeyFilePath" -Retries 2 
    &$executeRemoteCommand "sudo rm -f $kubernetesAptKeyFilePath" -Retries 2 
    &$executeRemoteCommand "sudo curl --retry 3 --retry-all-errors -fsSL https://pkgs.k8s.io/core:/stable:/$pkgShortK8sVersion/deb/Release.key$proxyToAdd -o $kubernetesPublicKeyFilePath" -IgnoreErrors 
    &$executeRemoteCommand "sudo gpg --dearmor -o $kubernetesAptKeyFilePath $kubernetesPublicKeyFilePath" -IgnoreErrors
    &$executeRemoteCommand "echo 'deb [signed-by=$kubernetesAptKeyFilePath] https://pkgs.k8s.io/core:/stable:/$pkgShortK8sVersion/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list" 
    &$executeRemoteCommand "sudo rm -f $kubernetesPublicKeyFilePath" -IgnoreErrors

    # package location for cri-o
    $crioPublicKeyFilePath = '/tmp/crio.key'
    $crioAptKeyFilePath = '/usr/share/keyrings/cri-o-apt-keyring.gpg'
    &$executeRemoteCommand "sudo rm -f $crioPublicKeyFilePath" -Retries 2 
    &$executeRemoteCommand "sudo rm -f $crioAptKeyFilePath" -Retries 2 
    &$executeRemoteCommand "sudo curl --retry 3 --retry-all-errors -fsSL https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$pkgShortK8sVersion/deb/Release.key$proxyToAdd -o $crioPublicKeyFilePath" -IgnoreErrors
    &$executeRemoteCommand "sudo gpg --dearmor -o $crioAptKeyFilePath $crioPublicKeyFilePath" -IgnoreErrors
    &$executeRemoteCommand "echo 'deb [signed-by=$crioAptKeyFilePath] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$pkgShortK8sVersion/deb/ /' | sudo tee /etc/apt/sources.list.d/cri-o.list" 
    &$executeRemoteCommand "sudo rm -f $crioPublicKeyFilePath" -IgnoreErrors 

    # update apt information
    &$executeRemoteCommand 'sudo apt-get update' -Retries 2 -RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install'
}

Function Get-KubernetesArtifactsFromInternet {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = '',
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $K8sVersion = $(throw 'Argument missing: K8sVersion'),
        [string] $TargetPath = $(throw 'Argument missing: TargetPath'),
        [string] $InstalledDistribution = $(throw 'Argument missing: InstalledDistribution')    
    )
    # Copy ZScaler certificate if needed
    Write-Log "Copying ZScaler Root CA certificate to computer with IP '$IpAddress'"
    $zScalerCertificateSourcePath = "$(Get-KubePath)\lib\modules\windows\node\k2s.node.module\linuxnode\setup\certificate\ZScalerRootCA.crt"
    $zScalerCertificateTargetPath = '/tmp/ZScalerRootCA.crt'
    if ([string]::IsNullOrWhiteSpace($UserPwd)) {
        Copy-ToRemoteComputerViaSshKey -Source $zScalerCertificateSourcePath -Target $zScalerCertificateTargetPath -UserName $UserName -IpAddress $IpAddress
    }
    else {
        Copy-ToRemoteComputerViaUserAndPwd -Source $zScalerCertificateSourcePath -Target $zScalerCertificateTargetPath -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
    }

    # Copy and execute the shell script
    Write-Log "Downloading Kubernetes artifacts for $InstalledDistribution"
    $scriptSourcePath ="$(Get-LinuxScriptPath -InstalledDistribution $InstalledDistribution)\download-k8s-packages.sh"
    
    Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $UserName `
                        -IpAddress $IpAddress `
                        -UserPwd $UserPwd `
                        -Arguments @($TargetPath, $K8sVersion, $Proxy) `
                        -CleanupAfterExecution `
                        -Retries 2
    
    Write-Log 'Kubernetes artifacts downloaded successfully'
}

Function Add-KubernetesArtifactsToRemoteComputer {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = '',
        [string] $SourcePath = $(throw 'Argument missing: SourcePath'),
        [string] $TargetPath = $(throw 'Argument missing: TargetPath'),
        [string] $InstalledDistribution = $(throw 'Argument missing: InstalledDistribution')
    )

    #binPath\linuxnode\packages\debian12\ kubernetes
    $debPackagesSourcePath = "$SourcePath\$kubernetesDebPackagesDirectory"
    
    if (Test-Path -Path $debPackagesSourcePath) {
        Copy-DebPackagesFromWindowsHostToRemoteComputer -UserName $UserName -IpAddress $IpAddress -SourcePath $debPackagesSourcePath -TargetPath $TargetPath
    }
    else {
        Get-KubernetesArtifactsFromInternet -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -K8sVersion $kubernetesVersion -TargetPath $TargetPath -InstalledDistribution $InstalledDistribution
    }
}

Function Add-BuildahArtifactsToRemoteComputer {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $SourcePath = $(throw 'Argument missing: SourcePath'),
        [string] $TargetPath = $(throw 'Argument missing: TargetPath'),
        [string] $InstalledDistribution = $(throw 'Argument missing: InstalledDistribution')
    )

    $debPackagesSourcePath = "$SourcePath\$buildahDebPackagesDirectory"
    
    if (Test-Path -Path $debPackagesSourcePath) {
        Copy-DebPackagesFromWindowsHostToRemoteComputer -UserName $UserName -IpAddress $IpAddress -SourcePath $debPackagesSourcePath -TargetPath $TargetPath
    }
    else {
        Get-BuildahDebPackagesFromInternet -UserName $userName -IpAddress $IpAddress -TargetPath $TargetPath -InstalledDistribution $InstalledDistribution
    }
}

Function Get-OfflineK2sDebPackagesPath {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName')
    )
    return "/home/$UserName/$offlineK2sDebPackagesDirectory"
}

Function Get-KubernetesDebPackagesPath {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName')
    )
    $basePath = Get-OfflineK2sDebPackagesPath -UserName $UserName
    return "$basePath/$kubernetesDebPackagesDirectory"
}

Function Get-BuildahDebPackagesPath {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName')
    )
    $basePath = Get-OfflineK2sDebPackagesPath -UserName $UserName
    return "$basePath/$buildahDebPackagesDirectory"
}

Function Get-InstalledDistribution {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $remoteUser = "$UserName@$IpAddress"

    $executeRemoteCommand = { 
        param(
            $Command = $(throw 'Argument missing: Command'), 
            [switch]$IgnoreErrors = $false, [string]$RepairCmd = $null, [uint16]$Retries = 0
        )
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            $commandOutput = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $Command -UserName $UserName -IpAddress $IpAddress -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output
        }
        else {
            $commandOutput = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd" -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output
        }

        return $commandOutput
    }

    $distributionName = &$executeRemoteCommand -Command "lsb_release -i | cut -d ':' -f 2 | tr -d '[:blank:]'"
    if ([string]::IsNullOrWhiteSpace($distributionName)) {
        throw "Cannot get the distribution name from the computer with IP '$IpAddress'"
    }
    $distributionReleaseNumber = &$executeRemoteCommand -Command "lsb_release -r | cut -d ':' -f 2 | tr -d '[:blank:]'"
    if ([string]::IsNullOrWhiteSpace($distributionReleaseNumber)) {
        throw "Cannot get the distribution release number from the computer with IP '$IpAddress'"
    }
    
    $installedDistribution = "$distributionName$distributionReleaseNumber".ToLower()
    
    return $installedDistribution
}



Function Copy-DebPackagesFromControlPlaneToWindowsHost {
    param (
        [string] $TargetPath = $(throw 'Argument missing: TargetPath')
    )
    $windowsHostTargetPath = $TargetPath

    if (Test-Path -Path $windowsHostTargetPath) {
        Write-Log "The path '$windowsHostTargetPath' with deb packages from the control plane already exists --> its content will not be overwritten"
    }
    else {
        $kubenodeSourcePath = Get-OfflineK2sDebPackagesPath -UserName $controlPlaneUserName
        Write-Log "Checking the existence of path '$kubenodeSourcePath' in the control plane node"
        $sourcePathExistenceCheckOutput = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "ls $kubenodeSourcePath" -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress -IgnoreErrors).Output
        
        if ($sourcePathExistenceCheckOutput.Contains('No such file or directory')) {
            Write-Log "The path '$kubenodeSourcePath' does not exist in control plane node --> no deb packages will be copied to the Windows host."
        }
        else {
            Write-Log "Deb packages will be copied from the control plane node ('$kubenodeSourcePath') to the Windows host ('$windowsHostTargetPath')"
            New-Item -Path $windowsHostTargetPath -ItemType Directory -Force -ErrorAction Stop | Out-Null

            Copy-FromRemoteComputerViaSSHKey -Source "$kubenodeSourcePath/*" -Target $windowsHostTargetPath -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress
        }
    }
}


Function Copy-DebPackagesFromWindowsHostToRemoteComputer {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $SourcePath = $(throw 'Argument missing: SourcePath'), 
        [string] $TargetPath = $(throw 'Argument missing: TargetPath')
    )

    if (!(Test-Path -Path $SourcePath)) {
        throw "The path '$SourcePath' does not exist."
    } 

    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -f /tmp/*.deb' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "[ -d $TargetPath ] && rm -rf $TargetPath; mkdir -p $TargetPath" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    $allPackageFiles = $(Get-Item -Path "$SourcePath\*.deb" | Select-Object -ExpandProperty 'FullName')
    $allPackageFiles | ForEach-Object { Copy-ToRemoteComputerViaSshKey -Source "$_" -Target '/tmp' -UserName $UserName -IpAddress $IpAddress }
    
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "cd /tmp; sudo find -name \`"*.deb\`" -exec sudo mv {} $TargetPath ';'" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
}

Function Install-KubernetesArtifacts {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = '',
        [string] $SourcePath = $(throw 'Argument missing: SourcePath'),
        [string] $InstalledDistribution = 'debian13'
    )

    $token = Get-RegistryToken
    $isWsl = if (Get-ConfigWslFlag) { 'true' } else { 'false' }
    $noProxy = Get-KubenodeNoProxy

    Write-Log "[InstallK8s] Installing Kubernetes artifacts on '$IpAddress' from '$SourcePath'"
    Write-Log "[InstallK8s] WSL support: $isWsl"

    $scriptSourcePath = "$(Get-LinuxScriptPath -InstalledDistribution $InstalledDistribution)\install-k8s-packages.sh"

    Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $UserName `
                        -IpAddress $IpAddress `
                        -UserPwd $UserPwd `
                        -Arguments @($SourcePath, $Proxy, $token, $isWsl, $noProxy, 'false') `
                        -CleanupAfterExecution `
                        -Retries 2

    Write-Log '[InstallK8s] Kubernetes artifacts installation completed'
}

Function Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost {
    param (
        [string] $TargetPath = $(throw 'Argument missing: TargetPath'),
        [string] $K8sVersion = $kubernetesVersion
    )

    if ([string]::IsNullOrWhiteSpace($K8sVersion)) {
        throw 'K8sVersion is required but was not provided and $kubernetesVersion is not set.'
    }

    $executeRemoteCommand = { 
        param(
            [string] $Command = $(throw 'Argument missing: Command'), 
            [switch] $ReturnCommandOutput = $false,
            [switch] $IgnoreErrors = $false, 
            [string] $RepairCmd = $null, 
            [uint16] $Retries = 0
        )
        $commandOutput = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $Command -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress -RepairCmd $RepairCmd -Retries $Retries -IgnoreErrors:$IgnoreErrors)

        if ($ReturnCommandOutput) {
            return $commandOutput
        }
        else {
            $commandOutput.Output | Write-Log
        }
    }
  
    $imagesPath = $TargetPath

    if (Test-Path -Path $imagesPath) {
        Write-Log "The path '$imagesPath' with container images already exists --> its content will not be overwritten"
    }
    else {
        New-Item -Path $imagesPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        
        $kubeadmImagesCmd = "sudo kubeadm config images list --kubernetes-version $K8sVersion | grep -E '^[^[:space:]]+/[^[:space:]]+:[^[:space:]]+$'"
        $cmdExecutionResult = $(&$executeRemoteCommand -Command $kubeadmImagesCmd -ReturnCommandOutput)

        if (!$cmdExecutionResult.Success) {
            throw "Could not retrieve kubeadm image list for Kubernetes version '$K8sVersion' from control plane"
        }
        $imageRefsToExport = @($cmdExecutionResult.Output | ForEach-Object { $_.Trim() } | Where-Object { ![string]::IsNullOrWhiteSpace($_) })

        $retrieveAdditionalImagesCmd = 'sudo crictl images | grep -e "docker.io/flannel" | grep -v "\<none\>" | awk ''{ print $1":"$2 }'''
        $additionalImagesResult = $(&$executeRemoteCommand -Command $retrieveAdditionalImagesCmd -ReturnCommandOutput -IgnoreErrors)
        if ($additionalImagesResult.Success) {
            $imageRefsToExport += @($additionalImagesResult.Output | ForEach-Object { $_.Trim() } | Where-Object { ![string]::IsNullOrWhiteSpace($_) })
        }

        $imageRefsToExport = @($imageRefsToExport | Select-Object -Unique)
        Write-Host $imageRefsToExport
        
        if (@($imageRefsToExport).Count -eq 0) {
            throw "No kubeadm or flannel images could be found in the control plane."
        }

        foreach ($imageFullName in $imageRefsToExport) {
            $finalExportPath = "$imagesPath/$($imageFullName.Replace('/','_').Replace(':', '__')).tar"

            $targetFilePath = "/tmp/$($imageFullName.Replace('/','_').Replace(':', '__')).tar"
            &$executeRemoteCommand "sudo buildah push ${imageFullName} oci-archive:${targetFilePath}:${imageFullName} 2>&1"
            Copy-FromRemoteComputerViaSSHKey -Source $targetFilePath -Target $finalExportPath -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress
            
            &$executeRemoteCommand "sudo rm -f ${targetFilePath}"
        } 
    }
}

Function Copy-KubernetesImagesFromControlPlaneToRemoteComputer {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $executeRemoteCommandOnRemoteComputer = { 
        param(
            $command = $(throw 'Argument missing: Command'), 
            [switch]$IgnoreErrors = $false, [string]$RepairCmd = $null, [uint16]$Retries = 0
        )
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output | Write-Log
    }

    $imagesPath = $directoryOfKubenodeImagesOnWindowsHost

    Write-Log 'Copy container images from the control plane node to the Windows host' 
    Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost -TargetPath $imagesPath

    if (Test-Path -Path $imagesPath) {
        Write-Log "Copy container images from Windows host to the computer with IP address '$IpAddress'"
        Get-Item -path "$imagesPath\*.tar" | Select-Object -ExpandProperty 'FullName' | ForEach-Object {
            Copy-ToRemoteComputerViaSshKey -Source $_ -Target '/tmp/import.tar' -UserName $UserName -IpAddress $IpAddress
            &$executeRemoteCommandOnRemoteComputer 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1'
            &$executeRemoteCommandOnRemoteComputer 'cd /tmp && sudo rm -rf import.tar'
        }
    }
    else {
        Write-Log "The path '$imagesPath' with container images from the control plane does not exist --> no offline installation possible."
    }
}

Function Remove-KubernetesArtifacts {
    param (
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: Command'),
            [switch]$IgnoreErrors = $false, [string]$RepairCmd = $null, [uint16]$Retries = 0
        )
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output | Write-Log
    }

    &$executeRemoteCommand 'sudo systemctl stop kubelet'
    &$executeRemoteCommand 'sudo systemctl disable kubelet'

    &$executeRemoteCommand 'sudo systemctl stop crio'
    &$executeRemoteCommand 'sudo systemctl disable crio'

    &$executeRemoteCommand 'sudo systemctl daemon-reload'

    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive dpkg -P kubeadm' 
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive dpkg -P kubectl' 
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive dpkg -P kubelet' 
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive dpkg -P cri-tools' 

    &$executeRemoteCommand 'sudo rm -f /etc/containers/registries.conf'
    &$executeRemoteCommand 'sudo sh -c ''for f in /etc/containers/registries.conf.d/*.conf; do [ -f "$f" ] || continue; if grep -q "^[[:space:]]*\[\[registry\.mirror\]\]" "$f"; then rm -f "$f"; fi; done'''
    &$executeRemoteCommand 'sudo rm -f /etc/cni/net.d/100-crio-bridge.conf'
    &$executeRemoteCommand 'sudo rm -drf /root/.config/containers'
    &$executeRemoteCommand 'sudo rm -drf /etc/systemd/system/crio.service.d'
    &$executeRemoteCommand 'sudo rm -f /etc/crictl.yaml'

    &$executeRemoteCommand "sudo rm -f $crioAptKeyFilePath"
    &$executeRemoteCommand 'sudo rm -f /etc/apt/sources.list.d/cri-o.list'

    &$executeRemoteCommand "sudo rm -f $kubernetesAptKeyFilePath"
    &$executeRemoteCommand 'sudo rm -f /etc/apt/sources.list.d/kubernetes.list'

    &$executeRemoteCommand 'sudo rm -drf /etc/kubernetes'
    &$executeRemoteCommand 'sudo rm -drf /etc/crio'

    &$executeRemoteCommand 'sudo rm -fr /var/lib/crio/*'

    &$executeRemoteCommand 'sudo rm -f /etc/sysctl.d/k8s.conf'
    &$executeRemoteCommand 'sudo rm -f /etc/modules-load.d/k8s.conf'
    &$executeRemoteCommand 'sudo sysctl --system'
    &$executeRemoteCommand 'sudo rm -f /etc/apt/apt.conf.d/95k2s-proxy'

    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive dpkg -P cri-o' 
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive dpkg -P buildah' 

    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y'
}

Function Get-BuildahDebPackagesFromInternet {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$Proxy = '',
        [string]$TargetPath = $(throw 'Argument missing: TargetPath'),
        [string]$InstalledDistribution = 'debian13'
    )

    Write-Log '[BuildahPkg] Downloading buildah packages'

    $scriptSourcePath = "$(Get-LinuxScriptPath -InstalledDistribution $InstalledDistribution)\download-buildah-packages.sh"

    Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $UserName `
                        -IpAddress $IpAddress `
                        -UserPwd $UserPwd `
                        -Arguments @($TargetPath, $Proxy) `
                        -CleanupAfterExecution `
                        -Retries 2

    Write-Log '[BuildahPkg] Finished downloading buildah packages'
}

Function Install-BuildahDebPackages {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$SourcePath = $(throw 'Argument missing: SourcePath'),
        [string]$InstalledDistribution = 'debian13'
    )

    Write-Log '[BuildahInstall] Installing buildah packages'

    $scriptSourcePath = "$(Get-LinuxScriptPath -InstalledDistribution $InstalledDistribution)\install-buildah-packages.sh"

    Invoke-RemoteScript -LocalScriptPath $scriptSourcePath `
                        -UserName $UserName `
                        -IpAddress $IpAddress `
                        -UserPwd $UserPwd `
                        -Arguments @($SourcePath) `
                        -CleanupAfterExecution `
                        -Retries 2

    Write-Log '[BuildahInstall] Finished installing buildah packages'
}

function Assert-ProvisioningCommandResult {
    param (
        [pscustomobject]$Result,
        [string]$RemoteUser,
        [switch]$IgnoreErrors
    )

    $Result.Output | Write-Log
    if (!$Result.Success -and !$IgnoreErrors) {
        throw "[Provision] Remote provisioning command failed on '$RemoteUser'. See command output above."
    }
}

<#
.SYNOPSIS
Installs tools into the VM.
.DESCRIPTION
Installs the following tool:
- buildah (container image creation tool)
.PARAMETER UserName
The user name to log in into the VM.
.PARAMETER UserPwd
The password to use to log in into the VM.
.PARAMETER IpAddress
The IP address of the VM.
.PARAMETER Proxy
The proxy to use.
#>
Function Install-Tools {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = ''
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { 
        param(
            $Command = $(throw 'Argument missing: Command'), 
            [switch]$IgnoreErrors = $false, [string]$RepairCmd = $null, [uint16]$Retries = 0
        )
        $result = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd -IgnoreErrors:$IgnoreErrors -RepairCmd $RepairCmd -Retries $Retries
        Assert-ProvisioningCommandResult -Result $result -RemoteUser $remoteUser -IgnoreErrors:$IgnoreErrors
    }

    Write-Log 'Start installing tools in the Linux VM'

    $buildahDebPackagesPath = Get-BuildahDebPackagesPath -UserName $controlPlaneUserName
    Get-BuildahDebPackagesFromInternet -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress -TargetPath $buildahDebPackagesPath
    Install-BuildahDebPackages -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress -SourcePath $buildahDebPackagesPath

    # Verify buildah is installed and working
    &$executeRemoteCommand 'sudo buildah -v'

    # Ensure hwclock is available to keep time-sync behavior aligned with Debian 12 images
    # Debian 13 cloud images may require util-linux-extra for hwclock.
    &$executeRemoteCommand "if ! sudo sh -c 'command -v hwclock >/dev/null 2>&1 || [ -x /usr/sbin/hwclock ] || [ -x /sbin/hwclock ]'; then sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes util-linux util-linux-extra; fi 2>&1"
    Write-Log '[TimeSync] Verifying hwclock installation'
    &$executeRemoteCommand "if sudo sh -c 'command -v hwclock >/dev/null 2>&1 || [ -x /usr/sbin/hwclock ] || [ -x /sbin/hwclock ]'; then echo '[TimeSync] hwclock installed at:'; sudo sh -c 'command -v hwclock || ls -l /usr/sbin/hwclock /sbin/hwclock 2>/dev/null'; sudo hwclock --version; else echo '[TimeSync] hwclock not installed'; fi 2>&1"
    
    # Clean up any unnecessary packages
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -qq --yes'

    # Temporary fix for [master] not recognized in buildah 1.22.3, we comment the section as this is only specific to container engine
    # Issue is fixed in buildah 1.26 but exists in experimental stage
    #&$executeRemoteCommand "sudo sed -i 's/\[machine/#&/' /usr/share/containers/containers.conf"

    if ($Proxy -ne '') {
        &$executeRemoteCommand 'echo [engine] | sudo tee -a /etc/containers/containers.conf'
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            &$executeRemoteCommand "echo env = [\""https_proxy=$Proxy\""] | sudo tee -a /etc/containers/containers.conf"
        }
        else {
            &$executeRemoteCommand "echo env = [\\\""https_proxy=$Proxy\\\""] | sudo tee -a /etc/containers/containers.conf"
        }
    }

    $token = Get-RegistryToken
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        $jsonConfig = @{
            'auths' = @{
                'shsk2s.azurecr.io' = @{
                    'auth' = "$token"
                }
            }
        }
    }
    else {
        $jsonConfig = @{
            '"auths"' = @{
                '"shsk2s.azurecr.io"' = @{
                    '"auth"' = """$token"""
                }
            }
        }
    }

    $jsonString = ConvertTo-Json -InputObject $jsonConfig
    &$executeRemoteCommand "echo -e '$jsonString' | sudo tee /tmp/auth.json" | Out-Null
    &$executeRemoteCommand 'sudo mkdir -p /root/.config/containers'
    &$executeRemoteCommand 'sudo mv /tmp/auth.json /root/.config/containers/auth.json'

    Write-Log 'Need to update registry conf file which is added as part of buildah installation'
    # Encode the TOML payload so Windows native argument parsing cannot strip its quotes.
    $registryConfig = "unqualified-search-registries = [`"docker.io`", `"quay.io`"]`n"
    $registryConfigEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($registryConfig))
    &$executeRemoteCommand "if ! grep -q '^[[:space:]]*unqualified-search-registries[[:space:]]*=' /etc/containers/registries.conf 2>/dev/null; then echo '$registryConfigEncoded' | base64 -d | sudo tee -a /etc/containers/registries.conf; fi"
    # restart crio after updating registry.conf
    &$executeRemoteCommand 'sudo systemctl daemon-reload'
    &$executeRemoteCommand 'if ! sudo systemctl restart crio; then sudo systemctl status crio --no-pager -l; sudo journalctl -u crio -b --no-pager -n 100; exit 1; fi'
    &$executeRemoteCommand 'sudo crictl --runtime-endpoint unix:///var/run/crio/crio.sock info'

    Install-CliToolsOnKubeMaster -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress

    Write-Log 'Finished installing tools in Linux'

}

function Install-DnsServer {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $Command = $(throw 'Argument missing: Command'),
            [switch]$IgnoreErrors = $false,
            [string]$RepairCmd = $null,
            [uint16]$Retries = 0
        )
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries $Retries -RepairCmd $RepairCmd -IgnoreErrors:$IgnoreErrors).Output | Write-Log
    }

    Write-Log 'Remove existing DNS server'
    &$executeRemoteCommand 'sudo systemctl disable systemd-resolved' 
    &$executeRemoteCommand 'sudo systemctl stop systemd-resolved' 

    Write-Log 'Install custom DNS server'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsutils --yes' -Retries 2 -RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install'
    &$executeRemoteCommand 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsmasq --yes' -Retries 2 -RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install'

    Write-Log 'Stop custom DNS server'
    &$executeRemoteCommand 'sudo systemctl stop dnsmasq'
}

function Get-FlannelImages {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
        $result = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
        Assert-ProvisioningCommandResult -Result $result -RemoteUser $remoteUser
    }

    Write-Log 'Get images used by flannel'

    &$executeRemoteCommand 'sudo crictl pull docker.io/flannel/flannel-cni-plugin:v1.9.1-flannel3'
    &$executeRemoteCommand 'sudo crictl pull docker.io/flannel/flannel:v0.28.10'
}

<#
.SYNOPSIS
    Downloads NVIDIA Container Toolkit packages for GPU support.
.DESCRIPTION
    Sets up the NVIDIA apt repository on the remote Linux machine and downloads
    the NVIDIA Container Toolkit packages (libnvidia-container, nvidia-container-toolkit, etc.)
    to the specified target path. These packages enable GPU container workloads.
.PARAMETER UserName
    The user name to log in into the VM.
.PARAMETER UserPwd
    The password to use to log in into the VM.
.PARAMETER IpAddress
    The IP address of the VM.
.PARAMETER Proxy
    Optional HTTP proxy to use for package downloads.
.PARAMETER TargetPath
    Remote path where downloaded .deb packages will be stored.
#>
function Get-NvidiaGpuDebPackagesFromInternet {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$Proxy = '',
        [string]$TargetPath = $(throw 'Argument missing: TargetPath')
    )
    $remoteUser = "$UserName@$IpAddress"

    Write-Log '[GpuPkg] Downloading NVIDIA Container Toolkit packages'

    $aptProxyConfigured = $false
    $curlProxy = ''
    if (![string]::IsNullOrWhiteSpace($Proxy)) {
        $curlProxy = "-x $Proxy"
        Write-Log "[GpuPkg] Configuring apt proxy: $Proxy"
        $aptProxyConf = "Acquire::http::Proxy `"$Proxy`";`nAcquire::https::Proxy `"$Proxy`";`n"
        $aptProxyConfBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($aptProxyConf))
        $aptProxyCmd = "echo '$aptProxyConfBase64' | base64 -d | sudo tee /etc/apt/apt.conf.d/95k2s-proxy"
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $aptProxyCmd -RemoteUser $remoteUser -RemoteUserPwd $UserPwd -IgnoreErrors).Output | Write-Log
        $aptProxyConfigured = $true
    }

    try {
        # Add NVIDIA Container Toolkit repository
        $repoSetupCmd = "curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey $curlProxy | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list $curlProxy | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
        Write-Log '[GpuPkg] Setting up NVIDIA repository...'
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $repoSetupCmd -RemoteUser $remoteUser -RemoteUserPwd $UserPwd -IgnoreErrors).Output | Write-Log

        $updateCmd = 'sudo apt-get update'
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $updateCmd -RemoteUser $remoteUser -RemoteUserPwd $UserPwd -IgnoreErrors).Output | Write-Log

        # Create target directory
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "mkdir -p $TargetPath && cd $TargetPath && sudo chown -R _apt:root ." -RemoteUser $remoteUser -RemoteUserPwd $UserPwd).Output | Write-Log

        $gpuPackages = @('libnvidia-container1', 'libnvidia-container-tools', 'nvidia-container-toolkit-base', 'nvidia-container-runtime', 'nvidia-container-toolkit')
        foreach ($pkg in $gpuPackages) {
            Write-Log "[GpuPkg] Downloading GPU package: $pkg"
            # Download the package
            $downloadCmd = "cd $TargetPath && sudo apt-get download $pkg 2>&1"
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $downloadCmd -RemoteUser $remoteUser -RemoteUserPwd $UserPwd -IgnoreErrors).Output | Write-Log
            
            # Download dependencies
            $depsCmd = "cd $TargetPath && sudo DEBIAN_FRONTEND=noninteractive apt-get --reinstall install -y --no-install-recommends --no-install-suggests --simulate ./${pkg}*.deb 2>/dev/null | grep 'Inst ' | cut -d ' ' -f 2 | sort -u | xargs -r sudo apt-get download 2>&1 || true"
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $depsCmd -RemoteUser $remoteUser -RemoteUserPwd $UserPwd -IgnoreErrors).Output | Write-Log
        }

        $remoteGpuDebCount = (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "ls -1 $TargetPath/*.deb 2>/dev/null | wc -l" -RemoteUser $remoteUser -RemoteUserPwd $UserPwd -IgnoreErrors).Output
        Write-Log "[GpuPkg] GPU packages downloaded: $($remoteGpuDebCount.Trim())"
        Write-Log '[GpuPkg] Finished downloading NVIDIA Container Toolkit packages'
    }
    finally {
        if ($aptProxyConfigured) {
            Write-Log '[GpuPkg] Removing temporary apt proxy configuration (/etc/apt/apt.conf.d/95k2s-proxy)'
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo rm -f /etc/apt/apt.conf.d/95k2s-proxy' -RemoteUser $remoteUser -RemoteUserPwd $UserPwd -IgnoreErrors).Output | Write-Log
        }
    }
}

<#
.SYNOPSIS
    Pulls GPU container images (NVIDIA device plugin, DCGM exporter).
.DESCRIPTION
    Pulls the container images required for GPU workloads in Kubernetes:
    - NVIDIA device plugin: Exposes GPUs to the Kubernetes scheduler
    - DCGM exporter: Exports GPU metrics (optional, may not work on all setups)
.PARAMETER UserName
    The user name to log in into the VM.
.PARAMETER UserPwd
    The password to use to log in into the VM.
.PARAMETER IpAddress
    The IP address of the VM.
#>
function Get-GpuContainerImages {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$Proxy = ''
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    # Resolve manifest path relative to this module's location
    $repoRoot = (Get-Item -Path $PSScriptRoot).Parent.Parent.Parent.Parent.Parent.Parent.Parent.FullName
    $manifestPath = Join-Path -Path $repoRoot -ChildPath 'addons\gpu-node\addon.manifest.yaml'
    
    if (!(Test-Path -Path $manifestPath)) {
        throw "[GpuImg] GPU addon manifest not found at: $manifestPath"
    }
    
    $manifestContent = Get-Content -Path $manifestPath -Raw
    if ([string]::IsNullOrWhiteSpace($manifestContent)) {
        throw "[GpuImg] GPU addon manifest is empty: $manifestPath"
    }
    
    $images = @([regex]::Matches($manifestContent, 'nvcr\.io/nvidia/[A-Za-z0-9_./-]+:[A-Za-z0-9_.-]+') | ForEach-Object { $_.Value } | Select-Object -Unique)

    if ($images.Count -eq 0) {
        Write-Log '[GpuImg] No NVIDIA container images found in addon manifest (GPU addon may not be updated)' -Console
        return
    }
    
    $devicePluginVersion = ($images | Where-Object { $_ -match '^nvcr\.io/nvidia/k8s-device-plugin:' } | Select-Object -First 1) -replace '^.*:', ''
    $dcgmExporterVersion = ($images | Where-Object { $_ -match '^nvcr\.io/nvidia/k8s/dcgm-exporter:' } | Select-Object -First 1) -replace '^.*:', ''

    Write-Log "[GpuImg] k8s-device-plugin version from addon manifest: $devicePluginVersion"
    Write-Log "[GpuImg] dcgm-exporter version from addon manifest: $dcgmExporterVersion"
    Write-Log "[GpuImg] Pulling GPU container images from addon manifest: $($images -join ', ')"

    foreach ($image in $images) {
        if (![string]::IsNullOrWhiteSpace($Proxy)) {
            # Normalize proxy URL - strip existing scheme and ensure http:// prefix
            $proxyHost = $Proxy -replace '^https?://', ''
            &$executeRemoteCommand "sudo HTTPS_PROXY=http://$proxyHost HTTP_PROXY=http://$proxyHost buildah pull '$image'"
        } else {
            &$executeRemoteCommand "sudo buildah pull '$image'"
        }
    }

    Write-Log '[GpuImg] Finished pulling GPU container images'
}

function Get-ClusterIPWebhookImages {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
        $result = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
        Assert-ProvisioningCommandResult -Result $result -RemoteUser $remoteUser
    }

    Write-Log 'Get images used by clusterip-webhook'

    &$executeRemoteCommand 'sudo crictl pull shsk2s.azurecr.io/clusterip-webhook:v1.3.13'
}

function AddRegistryMirrors {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    Write-Log 'Add mirrors for registry from config.json'
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command')) 
        $result = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
        Assert-ProvisioningCommandResult -Result $result -RemoteUser $remoteUser
    }

    Write-Log "Add mirrors to registry for VM with ip address: $IpAddress"
    $mirrorRegistries = Get-MirrorRegistries
    if ($null -eq $mirrorRegistries -or @($mirrorRegistries).Count -eq 0) {
        Write-Log "[RegistryMirror] No mirrorRegistries configured in config.json, skipping mirror setup on VM $IpAddress."
        return
    }

    &$executeRemoteCommand 'mkdir -p /etc/containers/registries.conf.d'
    foreach ($registry in $mirrorRegistries) {
        $Name = $registry.registry
        $Mirror = $registry.mirror
        $fileName = $Name -replace ':', ''
        &$executeRemoteCommand "echo -e `'[[registry]]\nlocation=\""$Name\""\ninsecure=true`' | sudo tee /etc/containers/registries.conf.d/$fileName.conf"
        &$executeRemoteCommand "echo -e `'[[registry.mirror]]\nlocation=\""$Mirror\""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf.d/$fileName.conf" 
    } 
    &$executeRemoteCommand 'sudo systemctl daemon-reload'
    &$executeRemoteCommand 'if ! sudo systemctl restart crio; then sudo systemctl reset-failed crio; if ! sudo systemctl restart crio; then sudo systemctl status crio --no-pager -l; sudo journalctl -u crio -b --no-pager -n 100; exit 1; fi; fi'
}

function Get-KubernetesImages {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $K8sVersion = $(throw 'Argument missing: K8sVersion')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command')) 
        $result = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser $remoteUser -RemoteUserPwd $remoteUserPwd
        Assert-ProvisioningCommandResult -Result $result -RemoteUser $remoteUser
    }

    Write-Log 'Pull images used by K8s'
    &$executeRemoteCommand "sudo kubeadm config images pull --kubernetes-version $K8sVersion" 
}

function Set-Nameserver {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($Command = $(throw 'Argument missing: Command'))
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    Write-Log 'Set nameserver'
    # DNS
    &$executeRemoteCommand 'sudo chattr -i /etc/resolv.conf'
    &$executeRemoteCommand 'sudo rm -f /etc/resolv.conf'
    &$executeRemoteCommand 'echo nameserver 172.19.1.100 | sudo tee /etc/resolv.conf'
}

<#
.SYNOPSIS
Adds a configuration file that is used when creating the support for WSL integration.
.DESCRIPTION
Creates a configuration file populated with needed information that is used to support the integration into WSL.
.PARAMETER UserName
The user name to log in into the VM.
.PARAMETER UserPwd
The password to use to log in into the VM.
.PARAMETER IpAddress
The IP address of the VM.
#>
Function Add-SupportForWSL {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($command = $(throw 'Argument missing: Command'))
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    # WSL2 config
    Write-Log 'Configure WSL2'
    &$executeRemoteCommand "sudo touch $wslConfigurationFilePath"
    &$executeRemoteCommand "echo [automount] | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo enabled = false | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo -e 'mountFsTab = false\n' | sudo tee -a $wslConfigurationFilePath"

    &$executeRemoteCommand "echo [interop] | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo enabled = false | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo -e 'appendWindowsPath = false\n' | sudo tee -a $wslConfigurationFilePath"

    &$executeRemoteCommand "echo [user] | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo -e 'default = __USERNAME__\n' | sudo tee -a $wslConfigurationFilePath"

    &$executeRemoteCommand "echo [network] | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo generateHosts = false | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo generateResolvConf = false | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo hostname = __HOSTNAME__ | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo | sudo tee -a $wslConfigurationFilePath"

    &$executeRemoteCommand "echo [boot] | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo systemd = true | sudo tee -a $wslConfigurationFilePath"
    &$executeRemoteCommand "echo 'command = sudo ifconfig __INTERFACE_NAME__ __IP_ADDRESS__ && sudo ifconfig __INTERFACE_NAME__ netmask __NETWORK_MASK__ && sudo route add default gw __GATEWAY_IP_ADDRESS__' | sudo tee -a $wslConfigurationFilePath"
}

function Edit-SupportForWSL {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$Hostname = $(throw 'Argument missing: Hostname'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$NetworkInterfaceName = $(throw 'Argument missing: NetworkInterfaceName'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$NetworkMask = $(throw 'Argument missing: NetworkMask'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$GatewayIpAddress = $(throw 'Argument missing: GatewayIpAddress')
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($command = $(throw 'Argument missing: Command'))
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
    }

    Write-Log 'Edit WSL2 support'
    &$executeRemoteCommand "sudo sed -i `"s/__USERNAME__/$UserName/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__HOSTNAME__/$Hostname/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__IP_ADDRESS__/$IpAddress/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__INTERFACE_NAME__/$NetworkInterfaceName/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__NETWORK_MASK__/$NetworkMask/g`" $wslConfigurationFilePath"
    &$executeRemoteCommand "sudo sed -i `"s/__GATEWAY_IP_ADDRESS__/$GatewayIpAddress/g`" $wslConfigurationFilePath"
}

<#
.SYNOPSIS
Sets up a VM to act as master node.
.DESCRIPTION
An accessible VM with already installed Kubernetes artifacts is configured to act as master node.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the VM.
.PARAMETER K8sVersion
The Kubernetes version to use.
.PARAMETER ClusterCIDR
The Kubernetes pod network CIDR.
.PARAMETER ClusterCIDR_Services
The Kubernetes service network CIDR.
.PARAMETER KubeDnsServiceIP
The IP address of the DNS service inside the Kubernetes cluster.
.PARAMETER IP_NextHop
The IP address of the Windows host reachable from the VM
.PARAMETER NetworkInterfaceName
The name of the network interface of the VM.
.PARAMETER NetworkInterfaceCni0IP_Master
The IP address of the the cni network interface in the VM.
.PARAMETER Hook
A script block that will get executed at the end of the set-up process (can be used for e.g. to install custom tools).
#>

Function Deploy-ClusterIPWebhook {
    param(
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ScriptBlock]$ExecuteRemoteCommand = $(throw 'Argument missing: ExecuteRemoteCommand')
    )

    $manifestDir = (Resolve-Path "$PSScriptRoot\..\..\..\..\..\..\manifests\clusterip-webhook").Path
    $remoteDir = '/tmp/clusterip-webhook'
    $remoteUserPwd = $UserPwd

    Write-Log '[ClusterIP-Webhook] Deploying clusterip-webhook components' -Console

    &$ExecuteRemoteCommand "mkdir -p $remoteDir"

    $manifestFiles = @(
        'namespace.yaml',
        'rbac.yaml',
        'webhook-config.yaml',
        'deployment.yaml'
    )

    foreach ($file in $manifestFiles) {
        $localPath = Join-Path $manifestDir $file
        Write-Log "[ClusterIP-Webhook] Copying $file to master node"
        if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
            Copy-ToRemoteComputerViaSshKey -Source $localPath -Target "$remoteDir/$file" -UserName $UserName -IpAddress $IpAddress
        }
        else {
            Copy-ToRemoteComputerViaUserAndPwd -Source $localPath -Target "$remoteDir/$file" -UserName $UserName -UserPwd $remoteUserPwd -IpAddress $IpAddress
        }
    }

    Write-Log '[ClusterIP-Webhook] Waiting for node to be ready before deploying webhook'
    &$ExecuteRemoteCommand 'kubectl wait --for=condition=Ready node --all --timeout=120s' -Retries 3

    Write-Log '[ClusterIP-Webhook] Applying namespace and RBAC'
    &$ExecuteRemoteCommand "kubectl apply -f $remoteDir/namespace.yaml" -Retries 3
    &$ExecuteRemoteCommand "kubectl apply -f $remoteDir/rbac.yaml" -Retries 3

    # Only create webhook config if it doesn't exist yet.
    # On upgrade, re-applying would reset the caBundle to empty, causing TLS
    # errors until the init container re-patches it (race condition).
    Write-Log '[ClusterIP-Webhook] Checking MutatingWebhookConfiguration'
    &$ExecuteRemoteCommand 'kubectl get mutatingwebhookconfiguration k2s-webhook' -IgnoreErrors
    if ($LASTEXITCODE -ne 0) {
        Write-Log '[ClusterIP-Webhook] Creating MutatingWebhookConfiguration'
        &$ExecuteRemoteCommand "kubectl apply -f $remoteDir/webhook-config.yaml" -Retries 3
    } else {
        Write-Log '[ClusterIP-Webhook] MutatingWebhookConfiguration already exists — skipping to preserve caBundle'
    }

    Write-Log '[ClusterIP-Webhook] Applying Deployment and Service'
    &$ExecuteRemoteCommand "kubectl apply -f $remoteDir/deployment.yaml" -Retries 3

    Write-Log '[ClusterIP-Webhook] Waiting for webhook deployment to be ready'
    &$ExecuteRemoteCommand 'kubectl rollout status deployment/clusterip-webhook -n k2s-webhook --timeout=120s' -Retries 3

    &$ExecuteRemoteCommand "rm -rf $remoteDir" -IgnoreErrors

    Write-Log '[ClusterIP-Webhook] ClusterIP webhook deployed successfully' -Console
}

function Set-K2sLinuxKubeletOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string] $EffectiveInstallConfigPath,
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [string] $UserPwd = '',
        [Parameter(Mandatory = $true)]
        [string] $IpAddress
    )

    $content = Get-K2sKubeletOverrideContent -EffectiveInstallConfigPath $EffectiveInstallConfigPath -Role 'linuxControlPlane'
    $targetPath = '/etc/kubernetes/kubelet.conf.d/20-k2s-install-config.conf'
    $managedHeader = '# This file is managed by K2s. Do not edit.'
    $managedHeaderEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($managedHeader))

    if ([string]::IsNullOrEmpty($content)) {
        $removeCommand = "set -e; sudo mkdir -p /etc/kubernetes/kubelet.conf.d; target='$targetPath'; if sudo test -e `$target || sudo test -L `$target; then if ! sudo test -f `$target || sudo test -L `$target; then echo 'Refusing to remove non-regular kubelet drop-in collision' >&2; exit 42; fi; firstLineEncoded=`$(sudo head -n 1 `$target | tr -d '\r\n' | base64 -w0); if [ x`$firstLineEncoded != x$managedHeaderEncoded ]; then echo 'Refusing to remove unmanaged kubelet drop-in' >&2; exit 42; fi; sudo rm -f -- `$target; if sudo systemctl is-active --quiet kubelet; then sudo systemctl restart kubelet; fi; fi"
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            $removeResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $removeCommand -UserName $UserName -IpAddress $IpAddress -NoLog
        }
        else {
            $removeResult = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $removeCommand -RemoteUser "$UserName@$IpAddress" -RemoteUserPwd $UserPwd -NoLog
        }
        if (-not $removeResult.Success) {
            throw "Failed to remove Linux control-plane kubelet override at '$targetPath': $($removeResult.Output)"
        }
        return
    }

    $localPath = Join-Path $env:TEMP ('20-k2s-install-config.' + [guid]::NewGuid().ToString('N') + '.conf')
    $remotePath = '/tmp/' + [System.IO.Path]::GetFileName($localPath)
    try {
        [System.IO.File]::WriteAllText($localPath, $content, [System.Text.UTF8Encoding]::new($false))
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            Copy-ToRemoteComputerViaSshKey -Source $localPath -Target $remotePath -UserName $UserName -IpAddress $IpAddress
        }
        else {
            Copy-ToRemoteComputerViaUserAndPwd -Source $localPath -Target $remotePath -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
        }

        $applyCommand = "set -e; source='$remotePath'; target='$targetPath'; targetTemp='${targetPath}.tmp'; trap 'sudo rm -f -- `"`$source`" `"`$targetTemp`"' EXIT; if sudo test -e `$target || sudo test -L `$target; then if ! sudo test -f `$target || sudo test -L `$target; then echo 'Refusing to replace non-regular kubelet drop-in collision' >&2; exit 42; fi; firstLineEncoded=`$(sudo head -n 1 `$target | tr -d '\r\n' | base64 -w0); if [ x`$firstLineEncoded != x$managedHeaderEncoded ]; then echo 'Refusing to replace unmanaged kubelet drop-in' >&2; exit 42; fi; if sudo cmp -s `$source `$target; then exit 0; fi; fi; sudo mkdir -p /etc/kubernetes/kubelet.conf.d; sudo cp `$source `$targetTemp; sudo chmod 0644 `$targetTemp; sudo mv -f `$targetTemp `$target; if sudo systemctl is-active --quiet kubelet; then sudo systemctl restart kubelet; fi"
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            $applyResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $applyCommand -UserName $UserName -IpAddress $IpAddress -NoLog
        }
        else {
            $applyResult = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $applyCommand -RemoteUser "$UserName@$IpAddress" -RemoteUserPwd $UserPwd -NoLog
        }
        if (-not $applyResult.Success) {
            throw "Failed to apply Linux control-plane kubelet override at '$targetPath': $($applyResult.Output)"
        }
    }
    finally {
        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
    }
}

Function Set-UpMasterNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$NodeName = $(throw 'Argument missing: NodeName'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $K8sVersion = $(throw 'Argument missing: K8sVersion'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $ClusterCIDR = $(throw 'Argument missing: ClusterCIDR'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $ClusterCIDR_Services = $(throw 'Argument missing: ClusterCIDR_Services'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $KubeDnsServiceIP = $(throw 'Argument missing: KubeDnsServiceIP'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string] $IP_NextHop = $(throw 'Argument missing: IP_NextHop'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $NetworkInterfaceName = $(throw 'Argument missing: NetworkInterfaceName'),
        [ScriptBlock] $Hook = $(throw 'Argument missing: Hook'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $ClusterName = $(throw 'Argument missing: ClusterName'),
        [switch] $ForceOnlineInstallation = $false,
        [Parameter(Mandatory = $true)]
        [string] $EffectiveInstallConfigPath
    )

    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: Command'),
            [uint16]$Retries = 0,
            [switch]$IgnoreErrors = $false
        )
        if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -Retries $Retries -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        }
        else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries $Retries -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        }
    }    

    Write-Log "Start setting up computer '$IpAddress' as master node"

    &$executeRemoteCommand 'sudo systemctl start crio' -IgnoreErrors

    $initConfig = @"
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "$IpAddress"
nodeRegistration:
  kubeletExtraArgs:
    - name: "config-dir"
      value: "/etc/kubernetes/kubelet.conf.d"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  serviceSubnet: "$ClusterCIDR_Services"
  podSubnet: "$ClusterCIDR"
kubernetesVersion: "$K8sVersion"
clusterName: "$ClusterName"
controllerManager:
  extraArgs:
    - name: leader-elect-lease-duration
      value: "30s"
    - name: leader-elect-renew-deadline
      value: "20s"
scheduler:
  extraArgs:
    - name: leader-elect-lease-duration
      value: "30s"
    - name: leader-elect-renew-deadline
      value: "20s"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failCgroupV1: false
"@

    # Pre-pull Kubernetes images with retries to isolate network issues from kubeadm init
    if ($ForceOnlineInstallation) {
        Write-Log "[KubeInit] Pre-pulling Kubernetes images for version $K8sVersion" -Console
        if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
            $prePullResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo kubeadm config images pull --kubernetes-version $K8sVersion" -UserName $UserName -IpAddress $IpAddress -Retries 3 -Timeout 30
        }
        else {
            $prePullResult = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo kubeadm config images pull --kubernetes-version $K8sVersion" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries 3 -Timeout 30
        }
        $prePullResult.Output | Write-Log
        if (-not $prePullResult.Success) {
            throw '[KubeInit] Pre-pulling Kubernetes images failed after retries. Check proxy settings and network connectivity to container registry (registry.k8s.io).'
        }
    }
    else {
        Write-Log "[KubeInit] Skipping image pre-pull (offline install - images already included in base image)" -Console
    }

    Set-K2sLinuxKubeletOverride -EffectiveInstallConfigPath $EffectiveInstallConfigPath -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress

    &$executeRemoteCommand 'mkdir -p ~/tmp/kubeadm-init'
    &$executeRemoteCommand "echo '$initConfig' | sudo tee ~/tmp/kubeadm-init/kubeadm-init.yaml"    

    # Run kubeadm init with retry (kubeadm reset between attempts to clean up partial state)
    $initCmd = 'sudo kubeadm init --config ~/tmp/kubeadm-init/kubeadm-init.yaml --ignore-preflight-errors=SystemVerification'
    $resetCmd = 'sudo kubeadm reset --force'
    Write-Log '[KubeInit] Initializing Kubernetes control plane' -Console
    if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
        $initResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $initCmd -UserName $UserName -IpAddress $IpAddress -Retries 1 -Timeout 30 -RepairCmd $resetCmd
    }
    else {
        $initResult = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $initCmd -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -Retries 1 -Timeout 30
    }
    $initResult.Output | Write-Log
    if (-not $initResult.Success) {
        &$executeRemoteCommand 'rm -rf ~/tmp/kubeadm-init' -IgnoreErrors
        throw "[KubeInit] kubeadm init failed after retries. Check proxy settings and network connectivity to container registry (registry.k8s.io)."
    }

    &$executeRemoteCommand 'rm -rf ~/tmp/kubeadm-init'

    Write-Log 'Copy K8s config file to user profile'
    &$executeRemoteCommand 'mkdir -p ~/.kube'
    &$executeRemoteCommand 'chmod 755 ~/.kube'
    &$executeRemoteCommand 'sudo cp /etc/kubernetes/admin.conf ~/.kube/config'
    &$executeRemoteCommand "sudo chown $UserName ~/.kube/config"
    &$executeRemoteCommand 'kubectl get nodes'

    Write-Log 'Scale down coredns to 1 replicas'
    &$executeRemoteCommand 'kubectl scale deployment coredns -n kube-system --replicas=1'

    Write-Log 'Configure custom DNS server'
    # add more interfaces to listen on
    &$executeRemoteCommand "echo server=/cluster.local/$KubeDnsServiceIP | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand "echo server=$IP_NextHop@$NetworkInterfaceName | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand "echo interface=$NetworkInterfaceName | sudo tee -a /etc/dnsmasq.conf"
    &$executeRemoteCommand 'echo interface=cni0 | sudo tee -a /etc/dnsmasq.conf'
    &$executeRemoteCommand 'echo interface=lo | sudo tee -a /etc/dnsmasq.conf'

    Write-Log 'Restart custom DNS server'
    &$executeRemoteCommand 'sudo systemctl restart dnsmasq'

    # import etcd certificates as k8s secrets, so that coredns can access etcd
    &$executeRemoteCommand 'sudo mkdir etcd'
    &$executeRemoteCommand 'sudo cp /etc/kubernetes/pki/etcd/* etcd/'
    &$executeRemoteCommand 'sudo chmod 444 etcd/*'
    &$executeRemoteCommand 'kubectl create secret -n kube-system tls etcd-ca --cert=etcd/ca.crt --key=etcd/ca.key'
    &$executeRemoteCommand 'kubectl create secret -n kube-system tls etcd-client-for-core-dns --cert=etcd/healthcheck-client.crt --key=etcd/healthcheck-client.key'
    &$executeRemoteCommand 'sudo rm -r etcd'

    # update coredns configmap kubernetes plugin to fallthrough for all zones
    &$executeRemoteCommand "kubectl get configmap coredns -n kube-system -o yaml | sed 's/fallthrough\ in-addr.arpa\ ip6.arpa/fallthrough/1' | kubectl apply -f -" -IgnoreErrors

    # change core-dns to serve the cluster.local zone from the etcd plugin as fallback
    &$executeRemoteCommand "kubectl get configmap coredns -n kube-system -o yaml | sed '/^\s*prometheus :9153/i\        etcd cluster.local {\n            path /skydns\n            endpoint https://${IpAddress}:2379\n            tls /etc/kubernetes/pki/etcd-client/tls.crt /etc/kubernetes/pki/etcd-client/tls.key /etc/kubernetes/pki/etcd-ca/tls.crt\n        }' | kubectl apply -f -" -Retries 3

    # mount the certificate secrets in coredns, so it can read them
    &$executeRemoteCommand 'kubectl wait --for=condition=available deployment/coredns -n kube-system --timeout=60s' -IgnoreErrors
    &$executeRemoteCommand "kubectl get deployment coredns -n kube-system -o yaml | sed '/^\s*\- configMap:/i\      - name: etcd-ca-cert\n        secret:\n          secretName: etcd-ca\n      - name: etcd-client-cert\n        secret:\n          secretName: etcd-client-for-core-dns' | kubectl apply -f -" -Retries 3
    &$executeRemoteCommand 'kubectl scale deployment coredns -n kube-system --replicas=1' -Retries 3
    &$executeRemoteCommand 'kubectl wait --for=condition=available deployment/coredns -n kube-system --timeout=60s' -IgnoreErrors
    &$executeRemoteCommand "kubectl get deployment coredns -n kube-system -o yaml | sed '/^\s*\- mountPath: \/etc\/coredns/i\        - mountPath: /etc/kubernetes/pki/etcd-ca\n          name: etcd-ca-cert\n        - mountPath: /etc/kubernetes/pki/etcd-client\n          name: etcd-client-cert' | kubectl apply -f -" -Retries 3

    # change core-dns to have predefined host mapping for DNS resolution
    &$executeRemoteCommand "kubectl get configmap coredns -n kube-system -o yaml | sed '/^\s*cache 30/i\        hosts {\n         $IpAddress k2s.cluster.local\n         fallthrough\n        }' | kubectl apply -f -" -Retries 3

    Write-Log 'Initialize Flannel'
    Add-FlannelPluginToMasterNode -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -PodNetworkCIDR $ClusterCIDR

    $getPodCidrOutput = Get-AssignedPodNetworkCIDR -NodeName $NodeName -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
    if ($getPodCidrOutput.Success) {
        $fullPodCIDR = $getPodCidrOutput.PodNetworkCIDR
        Write-Log "Retrieved pod network CIDR: '$fullPodCIDR'"
        
        $slashIndex = $fullPodCIDR.IndexOf('/')
        if ($slashIndex -le 0) {
            throw "Invalid pod network CIDR format: '$fullPodCIDR'. Expected format with slash (e.g., 172.20.0.0/24)"
        }
        
        $assignedPodNetworkCIDR = $fullPodCIDR.Substring(0, $slashIndex)
        Write-Log "Extracted pod network IP: '$assignedPodNetworkCIDR'"
        
        $lastDotIndex = $assignedPodNetworkCIDR.lastIndexOf('.')
        if ($lastDotIndex -le 0) {
            throw "Invalid pod network IP format: '$assignedPodNetworkCIDR'. Expected dotted notation (e.g., 172.20.0.0)"
        }
        
        $networkInterfaceCni0IP = "$($assignedPodNetworkCIDR.Substring(0, $lastDotIndex)).1"
        Write-Log "Calculated cni0 interface IP: '$networkInterfaceCni0IP'"
    }
    else {
        throw "Cannot obtain pod network information from node '$NodeName'"
    }

    Write-Log 'Add DNS resolution rules to K8s DNS component'
    # change config map to forward all non cluster DNS request to proxy (dnsmasq) running on master
    &$executeRemoteCommand "kubectl get configmap/coredns -n kube-system -o yaml | sed -e 's|forward . /etc/resolv.conf|forward . $networkInterfaceCni0IP|' | kubectl apply -f -" -IgnoreErrors


    Write-Log 'Deploy ClusterIP mutating webhook'
    Deploy-ClusterIPWebhook -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -ExecuteRemoteCommand $executeRemoteCommand

    Write-Log 'Run setup hook'
    &$Hook
    Write-Log 'Setup hook finished'

    Write-Log 'Redirect to localhost IP address for DNS resolution'
    &$executeRemoteCommand 'sudo chattr -i /etc/resolv.conf'
    &$executeRemoteCommand "echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf"

    Write-Log 'Finished setting up Linux computer as master'
}

Function Set-UpWorkerNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ScriptBlock] $Hook = $(throw 'Argument missing: Hook')
    )

    Write-Log "Start setting up computer '$IpAddress' as worker node"

    Write-Log 'Run setup hook'
    &$Hook
    Write-Log 'Setup hook finished'

    Write-Log 'Finished setting up Linux computer for being used as worker node'
}

Function Add-FlannelPluginToMasterNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $PodNetworkCIDR = $(throw 'Argument missing: PodNetworkCIDR')
    )

    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $fileName = 'flannel.yml'

    $executeRemoteCommand = { param($command = $(throw 'Argument missing: Command'))
        if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$IgnoreErrors).Output | Write-Log
        }
        else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output | Write-Log
        }
    }

    $waitUntilContainerNetworkPluginIsRunning = {
        $iteration = 0
        while ($true) {
            $iteration++
            # try to apply the flannel resources
            $command = 'kubectl rollout status daemonset -n kube-flannel kube-flannel-ds --timeout 60s'
            if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
                $result = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$IgnoreErrors).Output
            }
            else {
                $result = (Invoke-CmdOnControlPlaneViaUserAndPwd $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd").Output
            }
            if ($result -match 'successfully') {
                break;
            }
            if ($iteration -eq 25) {
                Write-Log 'Flannel CNI could not be set up, aborting...'
                throw 'Unable to get the CNI plugin Flannel running !'
            }
            if ($iteration -ge 3 ) {
                Write-Log 'Flannel CNI not yet available, waiting for it...'
                $x3 = $iteration % 3 -eq 0
                if ( $x3 ) {
                    &$executeRemoteCommand 'sudo systemctl restart kubelet'
                }
                &$executeRemoteCommand "sudo kubectl apply -f ~/$fileName"
            }
            Start-Sleep 2
        }
        if ($iteration -eq 1) {
            Write-Log 'Flannel CNI running, no waiting needed'
        }
        else {
            Write-Log 'Flannel CNI now running correctly'
        }
    }

    Write-Log 'Change default forward policy'
    &$executeRemoteCommand 'sudo iptables --policy FORWARD ACCEPT'

    Write-Log 'Prepare Flannel configuration file'
    $NetworkAddress = "      ""Network"": ""$PodNetworkCIDR"","
    $NetworkName = '      "name": "cbr0",'
    $NetworkType = '        "Type": "host-gw"'

    $configurationFile = "$PSScriptRoot\containernetwork\masternode\$fileName"
    Copy-Item "$PSScriptRoot\containernetwork\masternode\flannel.template.yml" "$configurationFile" -Force
    $lineNetworkName = Get-Content "$configurationFile" | Select-String NETWORK.NAME | Select-Object -ExpandProperty Line
    if ( $lineNetworkName ) {
        $content = Get-Content "$configurationFile"
        $content | ForEach-Object { $_ -replace $lineNetworkName, $NetworkName } | Set-Content "$configurationFile"
    }
    $lineNetworkType = Get-Content "$configurationFile" | Select-String NETWORK.TYPE | Select-Object -ExpandProperty Line
    if ( $lineNetworkType ) {
        $content = Get-Content "$configurationFile"
        $content | ForEach-Object { $_ -replace $lineNetworkType, $NetworkType } | Set-Content "$configurationFile"
    }
    $lineNetworkAddress = Get-Content "$configurationFile" | Select-String NETWORK.ADDRESS | Select-Object -ExpandProperty Line
    if ( $lineNetworkAddress ) {
        $content = Get-Content "$configurationFile"
        $content | ForEach-Object { $_ -replace $lineNetworkAddress, $NetworkAddress } | Set-Content "$configurationFile"
    }
    Write-Log 'Copy Flannel configuration file to computer'
    $target = "/home/$UserName"
    if ([string]::IsNullOrWhiteSpace($remoteUserPwd)) {
        Copy-ToRemoteComputerViaSshKey -Source "$configurationFile" -Target $target -UserName $UserName -IpAddress $IpAddress
    }
    else {
        Copy-ToRemoteComputerViaUserAndPwd -Source "$configurationFile" -Target $target -UserName $UserName -UserPwd $remoteUserPwd -IpAddress $IpAddress
    }

    Write-Log 'Apply flannel configuration file on computer'
    &$executeRemoteCommand "kubectl apply -f ~/$fileName"

    &$waitUntilContainerNetworkPluginIsRunning

}

<#
.SYNOPSIS
Sets up a Linux VM to be used as a cluster node.
.DESCRIPTION
Provisions a Linux VM with the needed Kubernetes artifacts in order to be used as a cluster node.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the VM.
.PARAMETER K8sVersion
The CRI-O version to use.
.PARAMETER Proxy
The proxy to use.
#>
Function New-KubernetesNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string] $K8sVersion = $(throw 'Argument missing: K8sVersion'),
        [string]$Proxy = ''
    )

    Assert-GeneralComputerPrerequisites -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd

    Write-Log "Prepare the computer $IpAddress for provisioning"
    Set-UpComputerBeforeProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd -Proxy $Proxy

    Set-UpComputerWithSpecificOsBeforeProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log "Finished preparation of computer $IpAddress for provisioning"

    Write-Log "Start provisioning the computer $IpAddress"
    $debPackagesPath = Get-KubernetesDebPackagesPath -UserName $controlPlaneUserName
    Get-KubernetesArtifactsFromInternet -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd -Proxy $Proxy -K8sVersion $K8sVersion -TargetPath $debPackagesPath -InstalledDistribution 'debian13'
    Install-KubernetesArtifacts -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd -Proxy $Proxy -SourcePath $debPackagesPath -InstalledDistribution 'debian13'

    Write-Log "Finalize preparation of the computer $IpAddress after provisioning"
    Set-UpComputerWithSpecificOsAfterProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log 'Linux VM is now prepared to be used as master node'

    Set-UpComputerAfterProvisioning -IpAddress $IpAddress -UserName $userName -UserPwd $userPwd
    Write-Log "Finished provisioning the computer $IpAddress"
}

function Get-KubenodeBaseFileName {
    return 'Kubenode-Base.vhdx'
}


# Installs the bundled Linux CLI tools (currently helm, yq and krew) into /usr/local/bin of the
# control-plane VM. Runs at base-image build time, so the tools are baked into the base image and
# offline installations require no downloads. Krew is deployed as 'kubectl-krew' so that
# 'kubectl krew' works. To add a further tool, extend scripts\install-cli-tools.sh - no change to
# this function is required.
function Install-CliToolsOnKubeMaster
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $true)]
        [string]$UserPwd,
        [Parameter(Mandatory = $true)]
        [string]$IpAddress
    )
    $scriptName = 'install-cli-tools.sh'
    $localScriptPath = "$PSScriptRoot\scripts\$scriptName"
    $remoteScriptPath = "/home/$UserName/$scriptName"
    if ( [string]::IsNullOrWhiteSpace($UserPwd))
    {
        Copy-ToRemoteComputerViaSshKey -Source $localScriptPath -Target $remoteScriptPath -UserName $UserName -IpAddress $IpAddress
    }
    else
    {
        Copy-ToRemoteComputerViaUserAndPwd -Source $localScriptPath -Target $remoteScriptPath -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
    }
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo chmod +x $remoteScriptPath" -RemoteUser "$UserName@$IpAddress" -RemoteUserPwd $UserPwd).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo sed -i 's/\r$//' $remoteScriptPath" -RemoteUser "$UserName@$IpAddress" -RemoteUserPwd $UserPwd).Output | Write-Log
    $installResult = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo $remoteScriptPath" -RemoteUser "$UserName@$IpAddress" -RemoteUserPwd $UserPwd
    $installResult.Output | Write-Log
    if (-not $installResult.Success) {
        Write-Log "[InstallCliTools] WARNING: $scriptName failed on $IpAddress. The Linux CLI tools (helm/yq/krew) may not be available. Check network connectivity and proxy settings." -Console
    }
    else {
        Write-Log "[InstallCliTools] $scriptName copied and executed successfully on $IpAddress"
    }
}

function Set-HypervDynamicMemory
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $false)]
        [string]$UserPwd = "",
        [Parameter(Mandatory = $true)]
        [string]$IpAddress,
        [Parameter(Mandatory = $false)]
        [bool]$EnableDynamicMemory = $false
    )

    if (-not $EnableDynamicMemory) {
        Write-Log "Dynamic memory not enabled, skipping Hyper-V dynamic memory configuration"
        return
    }

    Write-Log "Configuring Hyper-V Dynamic Memory support on control-plane node..."

    $localScriptPath = "$PSScriptRoot\..\..\..\..\..\scripts\windows\host\system\configure-hyperv-dynamic-memory.sh"
    $remoteScriptPath = "/home/$UserName/configure-hyperv-dynamic-memory.sh"

    if (-not (Test-Path $localScriptPath)) {
        Write-Log "Warning: Hyper-V dynamic memory configuration script not found at: $localScriptPath"
        Write-Log "Skipping dynamic memory configuration"
        return
    }

    try {
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            Copy-ToRemoteComputerViaSshKey -Source $localScriptPath -Target $remoteScriptPath -UserName $UserName -IpAddress $IpAddress
        }
        else {
            Copy-ToRemoteComputerViaUserAndPwd -Source $localScriptPath -Target $remoteScriptPath -UserName $UserName -UserPwd $UserPwd -IpAddress $IpAddress
        }

        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo chmod +x $remoteScriptPath" -RemoteUser "$UserName@$IpAddress" -RemoteUserPwd $UserPwd).Output | Write-Log
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo sed -i 's/\r$//' $remoteScriptPath" -RemoteUser "$UserName@$IpAddress" -RemoteUserPwd $UserPwd).Output | Write-Log

        Write-Log "Executing Hyper-V dynamic memory configuration script on VM..."
        (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo $remoteScriptPath" -RemoteUser "$UserName@$IpAddress" -RemoteUserPwd $UserPwd -Timeout 180).Output | Write-Log

        Write-Log "Hyper-V dynamic memory configuration completed successfully"
    }
    catch {
        Write-Log "Warning: Failed to configure Hyper-V dynamic memory: $_"
        Write-Log "VM will continue with static memory configuration"
    }
}

function New-VmImageForKubernetesNode {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared base image.')]
        [string] $VmImageOutputPath = $(throw 'Argument missing: VmImageOutputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [string]$DnsIpAddresses = $(throw 'Argument missing: DnsIpAddresses'),
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize
    )

    $vmIpAddress = Get-VmIpForProvisioningKubeNode
    $vmUserName = Get-DefaultUserNameKubeNode
    $vmUserPwd = Get-DefaultUserPwdKubeNode

    $setUpKubenode = {
        $addToKubeNode = {
            AddRegistryMirrors -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd
            Get-KubernetesImages -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd -K8sVersion $kubernetesVersion
            Install-DnsServer -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd
            Install-Tools -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd -Proxy $Proxy
            Get-FlannelImages -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd
            Get-ClusterIPWebhookImages -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd
            Add-SupportForWSL -IpAddress $vmIpAddress -UserName $vmUserName -UserPwd $vmUserPwd
        }

        $kubeNodeParameters = @{
            IpAddress  = $vmIpAddress
            UserName   = $vmUserName
            UserPwd    = $vmUserPwd
            Proxy      = $Proxy
            K8sVersion = $kubernetesVersion
        }

        New-KubernetesNode @kubeNodeParameters

        &$addToKubeNode
    }

    $kubenodeBaseImageCreationParams = @{
        Proxy                = $Proxy
        DnsIpAddresses       = $DnsIpAddresses
        Hook                 = $setUpKubenode
        OutputPath           = $VmImageOutputPath
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount     = $VMProcessorCount
        VMDiskSize           = $VMDiskSize
    }

    New-KubenodeBaseImage @kubenodeBaseImageCreationParams
}

function New-VmImageForControlPlaneNode {
    param (
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$DnsServers = $(throw 'Argument missing: DnsServers'),
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared base image.')]
        [string] $VmImageOutputPath = $(throw 'Argument missing: VmImageOutputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Enable Dynamic Memory')]
        [bool]$EnableDynamicMemory = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false
    )

    $kubenodeBaseImagePath = "$(Split-Path $VmImageOutputPath)\$(Get-KubenodeBaseFileName)"

    $isKubenodeBaseImageAlreadyAvailable = (Test-Path $kubenodeBaseImagePath)
    $isOnlineInstallation = (!$isKubenodeBaseImageAlreadyAvailable -or $ForceOnlineInstallation)

    if ($isOnlineInstallation -and $isKubenodeBaseImageAlreadyAvailable) {
        Remove-Item -Path $kubenodeBaseImagePath -Force
    }

    if (!(Test-Path -Path $kubenodeBaseImagePath)) {
        $vmImageForKubernetesNodeCreationParams = @{
            Proxy                = $Proxy
            DnsIpAddresses       = $DnsServers
            VmImageOutputPath    = $kubenodeBaseImagePath
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
            VMDiskSize           = $VMDiskSize
        }
        New-VmImageForKubernetesNode @vmImageForKubernetesNodeCreationParams
    }

    $vmUserName = Get-DefaultUserNameKubeNode
    $vmUserPwd = Get-DefaultUserPwdKubeNode
    $vmNetworkInterfaceName = Get-NetworkInterfaceName

    $setUpAsMasterNode = {
        $supportForWSLParams = @{
            UserName             = $vmUserName
            UserPwd              = $vmUserPwd
            Hostname             = $Hostname
            IpAddress            = $IpAddress
            NetworkInterfaceName = $(Get-NetworkInterfaceName)
            NetworkMask          = '255.255.255.0'
            GatewayIpAddress     = $GatewayIpAddress
        }
        Edit-SupportForWSL @supportForWSLParams

        if ($EnableDynamicMemory) {
            $dynamicMemoryParams = @{
                UserName              = $vmUserName
                UserPwd               = $vmUserPwd
                IpAddress             = $IpAddress
                EnableDynamicMemory   = $EnableDynamicMemory
            }
            Set-HypervDynamicMemory @dynamicMemoryParams
        }
    }

    $kubemasterCreationParams = @{
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount     = $VMProcessorCount
        VMDiskSize           = $VMDiskSize
        Hostname             = $Hostname
        IpAddress            = $IpAddress
        InterfaceName        = $vmNetworkInterfaceName
        DnsServers           = $DnsServers
        GatewayIpAddress     = $GatewayIpAddress
        InputPath            = $kubenodeBaseImagePath
        OutputPath           = $VmImageOutputPath
        Hook                 = $setUpAsMasterNode
    }
    New-KubemasterBaseImage @kubemasterCreationParams

    if ($DeleteFilesForOfflineInstallation) {
        Remove-Item -Path $kubenodeBaseImagePath -Force
    }
}

function New-LinuxVmImageForWorkerNode {
    param (
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$DnsServers,
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared base image.')]
        [string] $VmImageOutputPath = $(throw 'Argument missing: VmImageOutputPath'),
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false
    )

    $kubenodeBaseImagePath = "$(Split-Path $VmImageOutputPath)\$(Get-KubenodeBaseFileName)"

    $isKubenodeBaseImageAlreadyAvailable = (Test-Path $kubenodeBaseImagePath)
    $isOnlineInstallation = (!$isKubenodeBaseImageAlreadyAvailable -or $ForceOnlineInstallation)

    if ($isOnlineInstallation -and $isKubenodeBaseImageAlreadyAvailable) {
        Remove-Item -Path $kubenodeBaseImagePath -Force
    }

    if (!(Test-Path -Path $kubenodeBaseImagePath)) {
        $vmImageForKubernetesNodeCreationParams = @{
            Proxy                = $Proxy
            DnsIpAddresses       = $DnsServers
            VmImageOutputPath    = $kubenodeBaseImagePath
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
            VMDiskSize           = $VMDiskSize
        }
        New-VmImageForKubernetesNode @vmImageForKubernetesNodeCreationParams
    }

    $vmUserName = Get-DefaultUserNameKubeNode
    $vmUserPwd = Get-DefaultUserPwdKubeNode
    $vmNetworkInterfaceName = Get-NetworkInterfaceName

    $remoteUser = "$vmUserName@$IpAddress"
    $remoteUserPwd = $vmUserPwd

    $setUpAsWorkerNode = {
        $executeInWorkerNode = {
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo systemctl stop dnsmasq; sudo systemctl disable dnsmasq' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute 'sudo chattr -i /etc/resolv.conf' -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
            (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "echo nameserver $(Get-ConfiguredIPControlPlane) | sudo tee /etc/resolv.conf" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
        }

        $workerNodeParams = @{
            IpAddress = $IpAddress
            UserName  = $vmUserName
            UserPwd   = $vmUserPwd
            Hook      = $executeInWorkerNode
        }
        Set-UpWorkerNode @workerNodeParams
    }

    $kubeworkerCreationParams = @{
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount     = $VMProcessorCount
        VMDiskSize           = $VMDiskSize
        Hostname             = $Hostname
        IpAddress            = $IpAddress
        InterfaceName        = $vmNetworkInterfaceName
        DnsServers           = $DnsServers
        GatewayIpAddress     = $GatewayIpAddress
        InputPath            = $kubenodeBaseImagePath
        OutputPath           = $VmImageOutputPath
        Hook                 = $setUpAsWorkerNode
    }
    New-KubeworkerBaseImage @kubeworkerCreationParams

    if ($DeleteFilesForOfflineInstallation) {
        Remove-Item -Path $kubenodeBaseImagePath -Force
    }

}

<#
.Description
CopyDotFile copy dot files for bash processing to master VM.
#>
function CopyDotFile($SourcePath, $DotFile,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUser,
    [Parameter(Mandatory = $false)]
    [string]$RemoteUserPwd) {
    Write-Log "copying $SourcePath$DotFile to VM..."
    $source = "$SourcePath$DotFile"
    if (Test-Path($source)) {
        $target = "$DotFile.temp"
        $userName = $RemoteUser.Substring(0, $RemoteUser.IndexOf('@'))
        Copy-ToControlPlaneViaUserAndPwd -Source $source -Target $target
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sed 's/\r//g' $DotFile.temp > ~/$DotFile" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo chown -R $userName ~/$DotFile" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaUserAndPwd "rm $DotFile.temp" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
    }
}

<#
.Description
InstallAptPackages install apt package to master VM.
#>
function InstallAptPackages {
    param (
        [Parameter(Mandatory)]
        [string] $FriendlyName,
        [Parameter(Mandatory)]
        [string] $Packages,
        [Parameter(Mandatory = $false)]
        [string] $TestExecutable = '',
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $UserPwd = '',
        [string] $IpAddress = $(throw 'Argument missing: IpAddress')
    )

    $remoteUser = "$UserName@$IpAddress"

    Write-Log "installing needed apt packages for $FriendlyName..."
    $installCmd = "sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes --allow-change-held-packages --fix-missing $Packages"
    $repairCmd = 'sudo apt --fix-broken install'
    if ([string]::IsNullOrWhiteSpace($UserPwd)) {
        (Invoke-CmdOnVmViaSSHKey $installCmd -Retries 2 -Timeout 2 -UserName $UserName -IpAddress $IpAddress -RepairCmd $repairCmd).Output | Write-Log
    }
    else {
        (Invoke-CmdOnControlPlaneViaUserAndPwd $installCmd -Retries 2 -Timeout 2 -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd" -RepairCmd $repairCmd).Output | Write-Log
    }

    if ($TestExecutable -ne '') {
        $testCmd = "which $TestExecutable"
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            $exeInstalled = (Invoke-CmdOnVmViaSSHKey $testCmd -UserName $UserName -IpAddress $IpAddress).Output
        }
        else {
            $exeInstalled = (Invoke-CmdOnControlPlaneViaUserAndPwd $testCmd -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd").Output
        }
        if (!($exeInstalled -match "/bin/$TestExecutable")) {
            throw "'$FriendlyName' was not installed correctly"
        }
    }
}

<#
.Description
AddAptRepo add repository for apt in master VM.
#>
function AddAptRepo {
    param (
        [Parameter(Mandatory = $false)]
        [string]$RepoKeyUrl = '',
        [Parameter(Mandatory)]
        [string]$RepoDebString,
        [Parameter(Mandatory = $false)]
        [string]$ProxyApt = '',
        [Parameter(Mandatory = $false)]
        [string]$RemoteUser,
        [Parameter(Mandatory = $false)]
        [string]$RemoteUserPwd
    )
    Write-Log "adding apt-repository '$RepoDebString' with proxy '$ProxyApt' from '$RepoKeyUrl'"
    if ($RepoKeyUrl -ne '') {
        if ($ProxyApt -ne '') {
            (Invoke-CmdOnControlPlaneViaUserAndPwd "curl --retry 3 --retry-connrefused -s  $RepoKeyUrl --proxy $ProxyApt | sudo apt-key add - 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
        }
        else {
            (Invoke-CmdOnControlPlaneViaUserAndPwd "curl --retry 3 --retry-connrefused -fsSL $RepoKeyUrl | sudo apt-key add - 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
        }
        if ($LASTEXITCODE -ne 0) { throw "adding repo '$RepoDebString' failed. Aborting." }
    }
    (Invoke-CmdOnControlPlaneViaUserAndPwd "sudo add-apt-repository '$RepoDebString' 2>&1" -RemoteUser "$RemoteUser" -RemoteUserPwd "$RemoteUserPwd").Output | Write-Log
    if ($LASTEXITCODE -ne 0) { throw "adding repo '$RepoDebString' failed. Aborting." }
}

function Import-SpecificDistroSettingsModule {
    param (
        [string] $ModulePath = $(throw 'Argument missing: ModulePath')
    )
    Import-Module $ModulePath
}

function Remove-VmImageForControlPlaneNode {
    Clear-ProvisioningArtifacts
}

function New-WslRootfsForControlPlaneNode {
    param (
        [string] $VmImageInputPath = $(throw 'Argument missing: VmImageInputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the prepared rootfs file.')]
        [string] $RootfsFileOutputPath = $(throw 'Argument missing: RootfsFileOutputPath'),
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize
    )

    $kubenodeBaseImagePath = "$(Split-Path $VmImageInputPath)\$(Get-KubenodeBaseFileName)"

    if (!(Test-Path -Path $kubenodeBaseImagePath)) {
        $vmImageForKubernetesNodeCreationParams = @{
            VmImageOutputPath    = $kubenodeBaseImagePath
            Proxy                = $Proxy
            VMDiskSize           = $VMDiskSize
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
        }
        New-VmImageForKubernetesNode @vmImageForKubernetesNodeCreationParams
    }

    $vhdxToRootfsCreationParams = @{
        KubenodeBaseImagePath = $kubenodeBaseImagePath
        SourceVhdxPath        = $VmImageInputPath
        TargetRootfsFilePath  = $RootfsFileOutputPath
        VMDiskSize            = $VMDiskSize
        VMMemoryStartupBytes  = $VMMemoryStartupBytes
        VMProcessorCount      = $VMProcessorCount
    }
    Convert-VhdxToRootfs @vhdxToRootfsCreationParams
}

function Invoke-CmdOnVmWithSSHPwd {
    param (
        [string]$Command = $(throw 'Argument missing: Command'),
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [Parameter(Mandatory = $false)]
        [string]$UserPwd,
        [Parameter(Mandatory = $false)]
        [uint16]$ExecutionTimeoutSeconds = 0,
        [Parameter(Mandatory = $false)]
        [switch]$IgnoreErrors = $false,
        [Parameter(Mandatory = $false)]
        [uint16]$Retries = 0
    )
    # Dispatches via password auth (plink.exe) when UserPwd is provided, SSH key auth (ssh.exe) otherwise.
    # ExecutionTimeoutSeconds only applies to the SSH key path.
    if (![string]::IsNullOrWhiteSpace($UserPwd)) {
        $remoteUser = "$UserName@$IpAddress"
        return Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser $remoteUser -RemoteUserPwd $UserPwd -IgnoreErrors:$IgnoreErrors -Retries $Retries
    }
    else {
        return Invoke-CmdOnVmViaSSHKey -CmdToExecute $Command -UserName $UserName -IpAddress $IpAddress -ExecutionTimeoutSeconds $ExecutionTimeoutSeconds -IgnoreErrors:$IgnoreErrors -Retries $Retries
    }
}

function Set-ProxySettingsOnKubenode {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [AllowEmptyString()]
        [string] $ProxySettings,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName')

    )

    Set-ProxySettingsForApt -ProxySettings $ProxySettings -IpAddress $IpAddress -UserName $UserName
    Set-ProxySettingsForContainerRuntime -ProxySettings $ProxySettings -IpAddress $IpAddress -UserName $UserName
    Set-ProxySettingsForContainers -ProxySettings $ProxySettings -IpAddress $IpAddress -UserName $UserName

    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl daemon-reload' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl restart crio' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
}

function Remove-ProxySettingsOnKubenode {
    param (
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [Parameter(Mandatory = $false)]
        [string] $UserPwd,
        [Parameter(Mandatory = $false)]
        [uint16]$CommandExecutionTimeoutSeconds = 0
    )

    $proxySettings = ''
    Set-ProxySettingsForApt -ProxySettings $proxySettings -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -CommandExecutionTimeoutSeconds $CommandExecutionTimeoutSeconds
    Set-ProxySettingsForContainerRuntime -ProxySettings $proxySettings -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -CommandExecutionTimeoutSeconds $CommandExecutionTimeoutSeconds
    Set-ProxySettingsForContainers -ProxySettings $proxySettings -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -CommandExecutionTimeoutSeconds $CommandExecutionTimeoutSeconds

    (Invoke-CmdOnVmWithSSHPwd -Command 'sudo systemctl daemon-reload' -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -ExecutionTimeoutSeconds $CommandExecutionTimeoutSeconds).Output | Write-Log
    (Invoke-CmdOnVmWithSSHPwd -Command 'sudo systemctl restart crio' -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -ExecutionTimeoutSeconds $CommandExecutionTimeoutSeconds).Output | Write-Log
}

function Set-ProxySettingsForApt {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [AllowEmptyString()]
        [string] $ProxySettings,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [Parameter(Mandatory = $false)]
        [string] $UserPwd,
        [Parameter(Mandatory = $false)]
        [uint16]$CommandExecutionTimeoutSeconds = 0

    )

    $removeProxySettings = [string]::IsNullOrWhiteSpace($ProxySettings)
    if ($removeProxySettings) {
        Write-Log 'The passed proxy settings are null, empty or contains only white spaces --> eventually set proxy settings will be removed'
    }

    # packages
    if ($removeProxySettings) {
        Write-Log 'Delete proxy settings for package tool'
        (Invoke-CmdOnVmWithSSHPwd -Command 'sudo rm -f /etc/apt/apt.conf.d/proxy.conf' -UserName $UserName -IpAddress $IpAddress -UserPwd $UserPwd -ExecutionTimeoutSeconds $CommandExecutionTimeoutSeconds).Output | Write-Log
    }
    else {
        Write-Log 'Set proxy settings for package tool'
        (Invoke-CmdOnVmViaSSHKey 'sudo touch /etc/apt/apt.conf.d/proxy.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            (Invoke-CmdOnVmViaSSHKey "echo Acquire::http::Proxy \""$ProxySettings\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }
        else {
            (Invoke-CmdOnVmViaSSHKey "echo Acquire::http::Proxy \\\""$ProxySettings\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }
    }
}

function Set-ProxySettingsForContainerRuntime {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [AllowEmptyString()]
        [string] $ProxySettings,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [Parameter(Mandatory = $false)]
        [string] $UserPwd,
        [Parameter(Mandatory = $false)]
        [uint16]$CommandExecutionTimeoutSeconds = 0

    )

    $removeProxySettings = [string]::IsNullOrWhiteSpace($ProxySettings)
    if ($removeProxySettings) {
        Write-Log 'The passed proxy settings are null, empty or contains only white spaces --> eventually set proxy settings will be removed'
    }

    # Container runtime
    if ($removeProxySettings) {
        Write-Log 'Delete proxy settings for container runtime'
        (Invoke-CmdOnVmWithSSHPwd -Command 'sudo rm -fr /etc/systemd/system/crio.service.d' -UserName $UserName -IpAddress $IpAddress -UserPwd $UserPwd -ExecutionTimeoutSeconds $CommandExecutionTimeoutSeconds).Output | Write-Log
    }
    else {
        Write-Log 'Set proxy settings for container runtime'
        (Invoke-CmdOnVmViaSSHKey 'sudo mkdir -p /etc/systemd/system/crio.service.d' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey 'sudo touch /etc/systemd/system/crio.service.d/http-proxy.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey 'echo [Service] | sudo tee /etc/systemd/system/crio.service.d/http-proxy.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'HTTP_PROXY=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'HTTPS_PROXY=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'http_proxy=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'https_proxy=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey "echo Environment=\'no_proxy=.local\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    }
}

function Set-ProxySettingsForContainers {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [AllowEmptyString()]
        [string] $ProxySettings,
        [Parameter(Mandatory = $false)]
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [Parameter(Mandatory = $false)]
        [string] $UserPwd,
        [Parameter(Mandatory = $false)]
        [uint16]$CommandExecutionTimeoutSeconds = 0

    )

    $removeProxySettings = [string]::IsNullOrWhiteSpace($ProxySettings)
    if ($removeProxySettings) {
        Write-Log 'The passed proxy settings are null, empty or contains only white spaces --> eventually set proxy settings will be removed'
    }

    # Containers
    if ($removeProxySettings) {
        Write-Log 'Delete proxy settings for containers'
        (Invoke-CmdOnVmWithSSHPwd -Command 'sudo rm -f /etc/containers/containers.conf' -UserName $UserName -IpAddress $IpAddress -UserPwd $UserPwd -ExecutionTimeoutSeconds $CommandExecutionTimeoutSeconds).Output | Write-Log
    }
    else {
        Write-Log 'Set proxy settings for containers'
        (Invoke-CmdOnVmViaSSHKey 'echo [engine] | sudo tee /etc/containers/containers.conf' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            (Invoke-CmdOnVmViaSSHKey "echo env = [\""https_proxy=$ProxySettings\""] | sudo tee -a /etc/containers/containers.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }
        else {
            (Invoke-CmdOnVmViaSSHKey "echo env = [\\\""https_proxy=$ProxySettings\\\""] | sudo tee -a /etc/containers/containers.conf" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
        }
    }
}

function Get-BaseDirectoryOfKubenodeDebPackagesOnWindowsHost {
    return $baseDirectoryOfKubenodeDebPackagesOnWindowsHost
}

function Get-DirectoryOfKubenodeImagesOnWindowsHost {
    return $directoryOfKubenodeImagesOnWindowsHost
}

function Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost {
    return $directoryOfLinuxNodeArtifactsOnWindowsHost
}

function Get-PathOfLinuxNodeArtifactsPackageOnWindowsHost {
    return $pathOfLinuxNodeArtifactsPackageOnWindowsHost
}

function Update-CoreDNSConfigurationviaSSH {
    Write-Log 'Correct CoreDNS configuration on cluster'
    $UserName = Get-DefaultUserNameKubeNode
    $IpAddress = Get-ConfiguredIPControlPlane
    $executeRemoteCommand = {
        param(
            $command = $(throw 'Argument missing: Command'),
            [uint16]$Retries = 0,
            [switch]$IgnoreErrors = $false
        )
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $command -UserName $UserName -IpAddress $IpAddress -Retries $Retries -IgnoreErrors:$IgnoreErrors).Output | Write-Log
    }

    # exchange securitycontext for coredns to allow it to run on port 53
    &$executeRemoteCommand "kubectl get deployment coredns -n kube-system -o yaml | sed '/^\s*securityContext: {}/c\      securityContext:\n        sysctls:\n        - name: net.ipv4.ip_unprivileged_port_start\n          value: `"`"53`"`"' | kubectl apply -f -"

}

function Get-LinuxScriptPath {
    param (
        [string]$InstalledDistribution='debian13'
    )
    $installationPath = Get-KubePath
    # Map OS to script filename
    $osScriptMap = @{
        'debian12'   = "$installationPath\cfg\nodeextension\debian12\scripts"
        'debian13'   = "$installationPath\cfg\nodeextension\debian13\scripts"
    }
    # Get base script name from OS
    $scriptPath = $osScriptMap[$InstalledDistribution]
    if (!$scriptPath) {
        throw "Unsupported OS for proxy setup: $InstalledDistribution"
    }
    if (!(Test-Path $scriptPath)) {
        throw "Proxy setup script not found: $scriptPath"
    }
    return $scriptPath
}

function Invoke-RemoteScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LocalScriptPath,
        
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        
        [Parameter(Mandatory = $true)]
        [string]$IpAddress,
        
        [string]$UserPwd = '',
        
        [string[]]$Arguments = @(),
        
        [switch]$CleanupAfterExecution,
        
        [uint16]$Retries = 3,

        # Opt-in flag (currently used by the Ceph storage addon) that adds a start marker,
        # per-line output logging and an execution-duration line. Left off by default so all
        # other callers keep their original single 'Script output:' log line behavior.
        [switch]$DetailedLogging
    )
    
    # Generate remote script path (always /tmp), using the original script filename
    $RemoteScriptPath = "/tmp/$(Split-Path -Leaf $LocalScriptPath)"
    
    if (!(Test-Path $LocalScriptPath)) {
        throw "Local script not found: $LocalScriptPath"
    }
    
    Write-Log "Copying script to remote: $RemoteScriptPath"
    
    # Copy script to remote - use password auth if available (e.g. fresh VM not yet having the SSH key),
    # otherwise fall back to SSH key (e.g. control-plane or already-provisioned node).
    if (![string]::IsNullOrWhiteSpace($UserPwd)) {
        Copy-ToRemoteComputerViaUserAndPwd -Source $LocalScriptPath -Target $RemoteScriptPath -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd
    } else {
        Copy-ToRemoteComputerViaSshKey -Source $LocalScriptPath -Target $RemoteScriptPath -UserName $UserName -IpAddress $IpAddress
    }
    
    # Build command with arguments
    $argumentString = if ($Arguments.Count -gt 0) { 
        "'$($Arguments -join "' '")'" 
    } else { 
        "" 
    }
    
    Write-Log "Executing remote script: $RemoteScriptPath $argumentString"
    
    # Make executable and run (supports both SSH key and password auth for command execution)
    $remoteUser = "$UserName@$IpAddress"
    $executeRemoteCommand = {
        param($Command)

        $execution = $null
        if ([string]::IsNullOrWhiteSpace($UserPwd)) {
            $execution = Invoke-CmdOnVmViaSSHKey -CmdToExecute $Command -UserName $UserName -IpAddress $IpAddress -Retries $Retries
        }
        else {
            $execution = Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute $Command -RemoteUser "$remoteUser" -RemoteUserPwd "$UserPwd" -Retries $Retries
        }

        if (-not $execution.Success) {
            $executionOutput = ($execution.Output | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($executionOutput)) {
                throw "Remote command failed: $Command"
            }

            throw "Remote command failed: $Command`n$executionOutput"
        }

        return $execution.Output
    }
    
    # Strip Windows CRLF line endings (\r) before executing - scripts copied from Windows
    # may have \r\n endings which cause bash to fail finding the interpreter in the shebang line.
    &$executeRemoteCommand "sed -i 's/\r//' $RemoteScriptPath" | Out-Null

    if ($DetailedLogging) {
        $scriptLeafName = Split-Path -Leaf $RemoteScriptPath
        Write-Log "[RemoteScript:$scriptLeafName] Execution started"
        $remoteExecStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = &$executeRemoteCommand "chmod +x $RemoteScriptPath && $RemoteScriptPath $argumentString"

        $remoteExecStopwatch.Stop()

        # Log the captured remote output line-by-line so each line becomes its own timestamped log
        # entry (far easier to read and correlate than the single bulk 'Script output:' line).
        # NOTE: the remote command's stdout is only available after the script returns, so these
        # timestamps reflect log-write time on the Windows host, not the instant each line was produced
        # on the remote node. The '[RemoteScript:<name>] completed in <n>s' line below is therefore the
        # authoritative measure of how long the remote step actually took.
        $remoteOutputLines = ($result | Out-String) -split "`n" | ForEach-Object { $_.TrimEnd("`r") }
        $hasRemoteOutput = $false
        foreach ($remoteLine in $remoteOutputLines) {
            if (-not [string]::IsNullOrWhiteSpace($remoteLine)) {
                Write-Log "[RemoteScript:$scriptLeafName] $remoteLine"
                $hasRemoteOutput = $true
            }
        }
        if (-not $hasRemoteOutput) {
            Write-Log "[RemoteScript:$scriptLeafName] (no output)"
        }

        Write-Log "[RemoteScript:$scriptLeafName] completed in $([math]::Round($remoteExecStopwatch.Elapsed.TotalSeconds, 1))s"
    }
    else {
        $result = &$executeRemoteCommand "chmod +x $RemoteScriptPath && $RemoteScriptPath $argumentString"

        Write-Log "Script output: $result"
    }
    
    # Cleanup
    if ($CleanupAfterExecution) {
        Write-Log "Cleaning up remote script: $RemoteScriptPath"
        &$executeRemoteCommand "rm $RemoteScriptPath"
    }
    
    return $result
}

function Get-KubernetesPackageCachePath {
    <#
    .SYNOPSIS
    Returns the path where Kubernetes packages are cached on Windows.
    
    .DESCRIPTION
    This path is used to cache packages downloaded on Windows before they're
    copied to Linux VMs. If packages exist here, they are automatically used
    instead of downloading them on the Linux VM (offline scenario).
    
    .EXAMPLE
    $cachePath = Get-KubernetesPackageCachePath
    #>
    return $baseDirectoryOfKubenodeDebPackagesOnWindowsHost
}

function Get-BuildahPackageCachePath {
    <#
    .SYNOPSIS
    Returns the path where buildah packages are cached on Windows.
    #>
    return (Join-Path (Get-KubernetesPackageCachePath) $buildahDebPackagesDirectory)
}

Export-ModuleMember -Function New-VmImageForControlPlaneNode,
New-LinuxVmImageForWorkerNode,
Get-KubernetesArtifactsFromInternet,
Get-BuildahDebPackagesFromInternet,
Remove-VmImageForControlPlaneNode,
Import-SpecificDistroSettingsModule,
New-WslRootfsForControlPlaneNode,
Set-ProxySettingsOnKubenode,
Remove-ProxySettingsOnKubenode,
Get-KubenodeBaseFileName,
Install-KubernetesArtifacts,
Remove-KubernetesArtifacts,
Copy-KubernetesImagesFromControlPlaneToRemoteComputer,
Add-KubernetesArtifactsToRemoteComputer,
Get-KubernetesImages,
Get-FlannelImages,
Get-NvidiaGpuDebPackagesFromInternet,
Get-GpuContainerImages,
Get-KubernetesDebPackagesPath,
Get-BuildahDebPackagesPath,
Add-BuildahArtifactsToRemoteComputer,
Install-BuildahDebPackages,
Set-UpComputerBeforeProvisioning,
Copy-DebPackagesFromControlPlaneToWindowsHost,
Get-InstalledDistribution,
Get-BaseDirectoryOfKubenodeDebPackagesOnWindowsHost,
Get-DirectoryOfKubenodeImagesOnWindowsHost,
Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost,
Get-PathOfLinuxNodeArtifactsPackageOnWindowsHost,
Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost,
Update-CoreDNSConfigurationviaSSH,
Set-K2sLinuxKubeletOverride,
Set-UpMasterNode,
Set-HypervDynamicMemory,
Get-LinuxScriptPath,
Invoke-RemoteScript,
Get-KubernetesPackageCachePath,
Get-BuildahPackageCachePath
