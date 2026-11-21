# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# VM provisioning helper functions for New-K2sPackage.ps1
# Note: These functions require the following to be available in calling script scope:
#   - $EncodeStructuredOutput, $MessageType (CLI output parameters)
#   - $VMMemoryStartupBytes, $VMProcessorCount, $VMDiskSize (VM configuration)
#   - $Proxy (network proxy)
#   - $K8sBinsPath (optional local K8s binaries path)
#   - Imported modules: k2s.infra.module, k2s.node.module, k2s.cluster.module

function New-ProvisionedKubemasterBaseImage($WindowsNodeArtifactsZip, $OutputPath) {
    # Expand windows node artifacts directory.
    # Deploy putty and plink for provisioning.
    if (!(Test-Path $WindowsNodeArtifactsZip)) {
        $errMsg = "$WindowsNodeArtifactsZip not found. It will not be possible to provision base image without plink and pscp tools present in $WindowsNodeArtifactsZip."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-package-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
    try {
        $windowsNodeArtifactsDirectory = "$(Split-Path -Parent $WindowsNodeArtifactsZip)\windowsnode"
        Write-Log "Extract the artifacts from the file '$WindowsNodeArtifactsZip' to the directory '$windowsNodeArtifactsDirectory'..."
        Expand-Archive -LiteralPath $WindowsNodeArtifactsZip -DestinationPath $windowsNodeArtifactsDirectory -Force
        Write-Log '  done'
        # Deploy putty tools
        Write-Log 'Temporarily deploying putty tools...' -Console
        Invoke-DeployPuttytoolsArtifacts $windowsNodeArtifactsDirectory
        # Provision linux node artifacts
        Write-Log 'Create and provision the base image' -Console
        $baseDirectory = $(Split-Path -Path $OutputPath)
        $rootfsPath = "$baseDirectory\$(Get-ControlPlaneOnWslRootfsFileName)"
        if (Test-Path -Path $rootfsPath) {
            Remove-Item -Path $rootfsPath -Force
            Write-Log "Deleted already existing file for WSL support '$rootfsPath'"
        }
        $hostname = Get-ConfigControlPlaneNodeHostname
        $ipAddress = Get-ConfiguredIPControlPlane
        $gatewayIpAddress = Get-ConfiguredKubeSwitchIP
        $loopbackAdapter = Get-L2BridgeName
        $dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
        if ([string]::IsNullOrWhiteSpace($dnsServers)) {
            $dnsServers = '8.8.8.8'
        }

        $controlPlaneNodeCreationParams = @{
            Hostname             = $hostname
            IpAddress            = $ipAddress
            GatewayIpAddress     = $gatewayIpAddress
            DnsServers           = $dnsServers
            VmImageOutputPath    = $OutputPath
            Proxy                = $Proxy
            VMMemoryStartupBytes = $VMMemoryStartupBytes
            VMProcessorCount     = $VMProcessorCount
            VMDiskSize           = $VMDiskSize
        }
        New-VmImageForControlPlaneNode @controlPlaneNodeCreationParams

        if (!(Test-Path -Path $OutputPath)) {
            throw "The file '$OutputPath' was not created"
        }
    }
    finally {
        Write-Log 'Deleting the putty tools...' -Console
        Clear-ProvisioningArtifacts
        Remove-Item -Path "$kubeBinPath\plink.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$kubeBinPath\pscp.exe" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $windowsNodeArtifactsDirectory -Force -Recurse -ErrorAction SilentlyContinue
    }
    if (!(Test-Path $outputPath)) {
        $errMsg = "The provisioned base image is unexpectedly not available as '$outputPath' after build and provisioning stage."

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-package-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
    Write-Log "Provisioned base image available as $OutputPath" -Console
}

function Get-AndZipWindowsNodeArtifacts($outputPath) {
    Write-Log "Download and create zip file with Windows node artifacts for $outputPath with proxy $Proxy" -Console
    $kubernetesVersion = Get-DefaultK8sVersion
    try {
        Invoke-DeployWinArtifacts -KubernetesVersion $kubernetesVersion -Proxy "$Proxy" -K8sBinsPath $K8sBinsPath
    }
    finally {
        Invoke-DownloadsCleanup -DeleteFilesForOfflineInstallation $false
    }

    $pathToTest = $outputPath
    Write-Log "Windows node artifacts should be available as '$pathToTest', testing ..." -Console
    if (![string]::IsNullOrEmpty($pathToTest)) {
        if (!(Test-Path -Path $pathToTest)) {
            $errMsg = "The file '$pathToTest' that shall contain the Windows node artifacts is unexpectedly not available."
            Write-Log "Windows node artifacts should be available as '$pathToTest', throw fatal error" -Console

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code 'build-package-failed' -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $errMsg -Error
            exit 1
        }
    }

    Write-Log "Windows node artifacts available as '$outputPath'" -Console
}
