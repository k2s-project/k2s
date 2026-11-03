# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables GPU support for KubeMaster or selected Linux worker nodes.

.DESCRIPTION
The "gpu-node" addon enables GPU scheduling by deploying the NVIDIA device plugin.
Without --node, it configures KubeMaster for GPU access.
With --node, it targets only the specified cluster node(s).

#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'Number of time-slicing replicas per GPU (1 = exclusive access, >1 = shared GPU)')]
    [ValidateRange(1, 16)]
    [int] $TimeSlices = 1,
    [parameter(Mandatory = $false, HelpMessage = 'Optional comma-separated list of cluster node names to enable gpu-node on. If not specified, the KubeMaster node will be configured for GPU access.')]
    [string] $Node,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$linuxNodeModule = "$PSScriptRoot/../../lib/modules/windows/node/k2s.node.module/linuxnode/vm/vm.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $linuxNodeModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'gpu-node' })) -eq $true) {
    $errMsg = "Addon 'gpu-node' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

# Optional node-targeted mode: target only explicitly listed nodes.
if ($null -ne $Config -and $null -ne $Config.Node -and ![string]::IsNullOrWhiteSpace([string]$Config.Node)) {
    $Node = [string]$Config.Node
}

$targetNodes = @()
if (![string]::IsNullOrWhiteSpace($Node)) {
    $targetNodes = @(
        $Node -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { ![string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

$controlPlaneNodeName = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'node-role.kubernetes.io/control-plane', '-o', 'jsonpath={.items[0].metadata.name}').Output
$additionalGpuLabelNodes = @()

if ($targetNodes.Count -gt 0) {
    foreach ($targetNode in $targetNodes) {
        if ([string]::IsNullOrWhiteSpace((Invoke-Kubectl -Params 'get', 'node', $targetNode, '--ignore-not-found', '-o', 'name').Output)) {
            $errMsg = "Node '$targetNode' was not found in the cluster."
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
            Write-Log $errMsg -Error
            exit 1
        }

        $nodeOs = (Invoke-Kubectl -Params 'get', 'node', $targetNode, '-o', 'jsonpath={.status.nodeInfo.operatingSystem}').Output
        if ($nodeOs -ne 'linux') {
            $errMsg = "Node '$targetNode' has OS '$nodeOs'. gpu-node can only target Linux nodes."
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
            Write-Log $errMsg -Error
            exit 1
        }
    }

    $controlPlaneTargeted = $targetNodes -contains $controlPlaneNodeName

    if ($controlPlaneTargeted) {
        $additionalGpuLabelNodes = @($targetNodes | Where-Object { $_ -ne $controlPlaneNodeName })
        if ($additionalGpuLabelNodes.Count -gt 0) {
            Write-Log "[gpu-node] Control plane node '$controlPlaneNodeName' is included in --node. Running full KubeMaster GPU setup and also targeting: $($additionalGpuLabelNodes -join ', ')" -Console
        }
        else {
            Write-Log "[gpu-node] Control plane node '$controlPlaneNodeName' is included in --node. Running full KubeMaster GPU setup." -Console
        }
    }
    else {
        Write-Log "[gpu-node] Node-targeted mode enabled for node(s): $($targetNodes -join ', ')" -Console

        Wait-ForAPIServer

        if ($TimeSlices -gt 1) {
            Write-Log "[gpu-node] Configuring GPU time-slicing (replicas: $TimeSlices)" -Console
            $timeSlicingTemplate = Get-Content -Path "$PSScriptRoot\manifests\time-slicing-config.yaml" -Raw
            $timeSlicingResolved = $timeSlicingTemplate -replace '__TIME_SLICES__', $TimeSlices
            $tmpConfigMap = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString() + '.yaml')
            $timeSlicingResolved | Set-Content -Path $tmpConfigMap -Encoding UTF8
            (Invoke-Kubectl -Params 'apply', '-f', $tmpConfigMap).Output | Write-Log
            Remove-Item $tmpConfigMap -Force -ErrorAction SilentlyContinue
        }
        else {
            (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\time-slicing-config-default.yaml").Output | Write-Log
        }

        foreach ($targetNode in $targetNodes) {
            Write-Log "[gpu-node] Labeling node '$targetNode' with gpu=true and accelerator=nvidia" -Console
            (Invoke-Kubectl -Params 'label', 'node', $targetNode, 'gpu=true', 'accelerator=nvidia', '--overwrite').Output | Write-Log
        }

        Write-Log 'Installing Nvidia Device Plugin' -Console
        (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\nvidia-device-plugin.yaml").Output | Write-Log

        $kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'nvidia-device-plugin', '-n', 'gpu-node', '--timeout', '180s')
        Write-Log $kubectlCmd.Output
        if (!$kubectlCmd.Success) {
            $errMsg = 'Nvidia device plugin could not be started!'
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $errMsg -Error
            exit 1
        }

        foreach ($targetNode in $targetNodes) {
            Write-Log "[gpu-node] Waiting for nvidia.com/gpu registration on node '$targetNode'..."
            $gpuRegistered = $false
            for ($i = 0; $i -lt 30; $i++) {
                $gpuCount = (Invoke-Kubectl -Params 'get', 'node', $targetNode, '-o', "jsonpath={.status.allocatable['nvidia\.com/gpu']}").Output
                if (![string]::IsNullOrWhiteSpace($gpuCount) -and $gpuCount -match '^\d+$' -and [int]$gpuCount -gt 0) {
                    $gpuRegistered = $true
                    Write-Log "[gpu-node] Node '$targetNode' registered nvidia.com/gpu with $gpuCount slot(s) allocatable" -Console
                    break
                }
                Start-Sleep -Seconds 2
            }

            if (!$gpuRegistered) {
                $errMsg = "Node '$targetNode' did not register nvidia.com/gpu within 60s. Ensure NVIDIA drivers and container toolkit are configured on that worker node."
                if ($EncodeStructuredOutput -eq $true) {
                    $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                    return
                }
                Write-Log $errMsg -Error
                exit 1
            }
        }

        Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'gpu-node' })

        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $null }
        }

        return
    }
}

if ($targetNodes.Count -eq 0) {
    Write-Log '[gpu-node] No --node specified. Enabling gpu-node on KubeMaster by default.' -Console
}

Write-Log 'Checking Nvidia driver installation' -Console

$WSL = Get-ConfigWslFlag
$kubeSwitchIp = Get-ConfiguredKubeSwitchIP
$tunnelProc = $null
$sshErrFile = $null

# Resolve WSL GPU translation library directory.
# Newer WSL 2.x (shipped as a Store app) places libdxcore.so under
# 'C:\Program Files\WSL\lib', while older versions used
# 'C:\Windows\System32\lxss\lib'. NVIDIA driver files (libcuda.so,
# libnvidia-*.so, nvidia-smi, etc.) are always installed into lxss\lib.
$wslLibDir = $null
$nvidiaLibDir = 'C:\Windows\System32\lxss\lib'
if (Test-Path -Path 'C:\Program Files\WSL\lib\libdxcore.so') {
    $wslLibDir = 'C:\Program Files\WSL\lib'
}
elseif (Test-Path -Path "$nvidiaLibDir\libdxcore.so") {
    $wslLibDir = $nvidiaLibDir
}

if ($null -eq $wslLibDir) {
    $errMsg = "The WSL GPU paravirtualization library (libdxcore.so) was not found.`n" +
        "This file is provided by the WSL infrastructure (not the NVIDIA driver).`n" +
        "Please ensure both are installed:`n" +
        "  1. WSL:          wsl --install --no-distribution`n" +
        "  2. NVIDIA driver: https://www.nvidia.com/Download/index.aspx`n" +
        'After installation, reboot the machine before enabling this addon.'

    if ($WSL) {
        $errMsg += "`nAfter installation you also need to reinstall the cluster for the changes to take effect."
    }

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log "[gpu-node] WSL lib directory resolved to: $wslLibDir" -Console

$nvidiaDriverDirectory = $null
if (!$WSL) {
    $nvidiaVideoControllers = @(Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' })
    $installedDisplayDriver = $nvidiaVideoControllers | ForEach-Object { $_.InstalledDisplayDrivers } | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $installedDisplayDriverFile = if (![string]::IsNullOrWhiteSpace($installedDisplayDriver)) {
        ($installedDisplayDriver -split ',') | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    }

    if ($nvidiaVideoControllers.Count -eq 0 -or [string]::IsNullOrWhiteSpace($installedDisplayDriverFile)) {
        $errMsg = "No NVIDIA GPU with installed display driver was detected on this Windows host.`n" +
            "The gpu-node addon requires a supported NVIDIA GPU and WSL-compatible NVIDIA drivers.`n" +
            "Install the NVIDIA driver from https://www.nvidia.com/Download/index.aspx on a machine with NVIDIA hardware, reboot, and try again."

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    $nvidiaDriverDirectory = Split-Path $installedDisplayDriverFile
    if ([string]::IsNullOrWhiteSpace($nvidiaDriverDirectory) -or !(Test-Path -Path $nvidiaDriverDirectory)) {
        $errMsg = "NVIDIA driver metadata was found, but the driver directory could not be resolved: '$installedDisplayDriverFile'.`n" +
            'Reinstall the NVIDIA driver, reboot the machine, and try enabling the gpu-node addon again.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    if (!(Test-Path -Path (Join-Path $nvidiaLibDir 'nvidia-smi'))) {
        $errMsg = "NVIDIA WSL driver files were not found in '$nvidiaLibDir'.`n" +
            "The gpu-node addon requires NVIDIA's WSL driver components, including nvidia-smi.`n" +
            'Reinstall a WSL-compatible NVIDIA driver, reboot the machine, and try enabling the gpu-node addon again.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
}

if ($WSL) {
    $success = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute '[ -f /usr/lib/wsl/lib/libdxcore.so ]').Success
    if (!$success) {
        $errMsg = "It seems that the needed Nvidia drivers are not installed.`n" `
            + "Please install them from the following URL: https://www.nvidia.com/Download/index.aspx`n"`
            + 'After Nvidia driver installation you need to reinstall the cluster for the changes to take effect.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }

    $success = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute '/usr/lib/wsl/lib/nvidia-smi').Success
    if (!$success) {
        $errMsg = "It seems that the needed Nvidia drivers are not installed correctly.`n" `
            + "If you recently updated your NVIDIA drivers, restart the cluster first to refresh the WSL2 GPU libraries:`n" `
            + "  k2s stop ; k2s start`n" `
            + 'Otherwise, please reinstall Nvidia drivers and cluster and try again.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    # Re-ensure the k2s gateway IP is assigned so the HTTP proxy is reachable.
    $wslAdapter = Get-NetAdapter -Name 'vEthernet (WSL*)' -ErrorAction SilentlyContinue -IncludeHidden
    if ($wslAdapter) {
        $existingAddresses = (Get-NetIPAddress -InterfaceIndex $wslAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        if ($existingAddresses -notcontains $kubeSwitchIp) {
            Write-Log "[gpu-node] WSL switch lost k2s IP ($kubeSwitchIp) - reassigning to ensure proxy reachability" -Console
            foreach ($addr in $existingAddresses) {
                Remove-NetIPAddress -InterfaceIndex $wslAdapter.ifIndex -IPAddress $addr -Confirm:$false -ErrorAction SilentlyContinue
            }
            New-NetIPAddress -IPAddress $kubeSwitchIp -PrefixLength 24 -InterfaceAlias $wslAdapter.Name -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 2  # allow ARP/routing to settle
        }
        else {
            Write-Log "[gpu-node] WSL switch IP $kubeSwitchIp verified"
        }
    }
    else {
        Write-Log '[gpu-node] WARNING: vEthernet (WSL*) adapter not found - proxy-based download may fail' -Console
    }

    # SSH reverse tunnel so the Linux VM can reach httpproxy for apt/buildah.
    Write-Log '[gpu-node] Releasing port 8181 in Linux VM if held by a stale sshd tunnel'
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
        'pid=$(sudo ss -tlnp | grep '':8181'' | grep -o ''pid=[0-9][0-9]*'' | head -1 | cut -d= -f2); if [ -n "$pid" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = "sshd" ]; then sudo kill "$pid" 2>/dev/null; fi; true' `
        -IgnoreErrors).Output | Write-Log
    Start-Sleep -Seconds 1

    $portCheck = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'ss -tlnp | grep '':8181'' || echo ''[gpu-node] port 8181 is free''' -IgnoreErrors).Output
    Write-Log "[gpu-node] port 8181 status after cleanup: $portCheck"

    Write-Log '[gpu-node] Establishing SSH reverse proxy tunnel' -Console
    $sshKey = Get-SSHKeyControlPlane
    $ipControlPlane = Get-ConfiguredIPControlPlane
    $tunnelArgs = '-N', '-o', 'StrictHostKeyChecking=no', '-o', 'ExitOnForwardFailure=yes', `
        '-o', 'ServerAliveInterval=10', '-i', $sshKey, `
        '-R', "8181:${kubeSwitchIp}:8181", "remote@${ipControlPlane}"
    $sshErrFile = [System.IO.Path]::GetTempFileName()
    $tunnelProc = Start-Process -FilePath 'ssh.exe' -ArgumentList $tunnelArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardError $sshErrFile
    Start-Sleep -Seconds 2
    if ($tunnelProc.HasExited) {
        $sshErrText = if (Test-Path $sshErrFile) { (Get-Content $sshErrFile -Raw).Trim() } else { '' }
        Write-Log "[gpu-node] WARNING: SSH reverse tunnel exited (code $($tunnelProc.ExitCode)) - proxy-based downloads may fail" -Console
        if ($sshErrText) { Write-Log "[gpu-node] SSH error output: $sshErrText" -Console }
        $tunnelProc = $null
    } else {
        Write-Log "[gpu-node] SSH reverse tunnel started (PID $($tunnelProc.Id))"
        # Redirect apt proxy to tunnel; restored in finally block.
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
            "sudo sed -i 's|${kubeSwitchIp}:8181|127.0.0.1:8181|g' /etc/apt/apt.conf.d/proxy.conf 2>/dev/null; true" `
            -IgnoreErrors).Output | Write-Log
        Write-Log '[gpu-node] apt proxy temporarily redirected to 127.0.0.1:8181 via SSH tunnel'
    }
}
else {    
    # Reconfigure KubeMaster
    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
    Write-Log "Configuring $controlPlaneNodeName VM"
    Write-Log "Stopping VM $controlPlaneNodeName"
    Stop-VM -Name $controlPlaneNodeName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
    }

    if (Get-VMGpuPartitionAdapter -VMName $controlPlaneNodeName -ErrorAction SilentlyContinue) {
        Remove-VMGpuPartitionAdapter -VMName $controlPlaneNodeName
    }
    Set-VM -GuestControlledCacheTypes $true -VMName $controlPlaneNodeName
    Set-VM -LowMemoryMappedIoSpace 3Gb -VMName $controlPlaneNodeName
    Set-VM -HighMemoryMappedIoSpace 32Gb -VMName $controlPlaneNodeName
    Add-VMGpuPartitionAdapter -VMName $controlPlaneNodeName
    Write-Log "Start VM $controlPlaneNodeName"
    Start-VM -Name $controlPlaneNodeName
    # for the next steps we need ssh access, so let's wait for ssh
    Wait-ForSSHConnectionToLinuxVMViaSshKey

    Write-Log 'Copying drivers' -Console

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .nvidiadrivers/lib').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .nvidiadrivers/drivers').Output | Write-Log

    # Copy NVIDIA driver files from lxss\lib (always present after driver install).
    Copy-ToControlPlaneViaSSHKey "$nvidiaLibDir\*" '.nvidiadrivers/lib'
    # If WSL's libdxcore.so lives in a separate directory (newer WSL 2.x),
    # copy those files too so the VM has the complete GPU-PV stack.
    if ($wslLibDir -ne $nvidiaLibDir) {
        Write-Log "[gpu-node] Merging WSL GPU libs from '$wslLibDir'" -Console
        Copy-ToControlPlaneViaSSHKey "$wslLibDir\*" '.nvidiadrivers/lib'
    }
    Copy-ToControlPlaneViaSSHKey $nvidiaDriverDirectory '.nvidiadrivers/drivers'

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /usr/lib/wsl').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -p /usr/lib/wsl/lib').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo cp -r .nvidiadrivers/* /usr/lib/wsl').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chmod 555 /usr/lib/wsl/lib/*').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chown -R root:root /usr/lib/wsl').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo '/usr/lib/wsl/lib' | sudo tee /etc/ld.so.conf.d/ld.wsl.conf").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo ldconfig 2>&1' -IgnoreErrors).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo 'export PATH=`$PATH:/usr/lib/wsl/lib' | sudo tee /etc/profile.d/wsl.sh").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chmod +x /etc/profile.d/wsl.sh').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf .nvidiadrivers').Output | Write-Log

    # Verify nvidia-smi is accessible at the expected path used by the device plugin liveness probe
    $smiCheck = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'ls /usr/lib/wsl/lib/nvidia-smi')
    if (!$smiCheck.Success) {
        $errMsg = 'nvidia-smi verification failed: File not found at /usr/lib/wsl/lib/nvidia-smi. Ensure NVIDIA drivers are correctly installed on the Windows host before enabling this addon.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    # Apply WSL2 Kernel
    Write-Log 'Changing linux kernel' -Console
    $microsoftStandardWSL2 = 'shsk2s.azurecr.io/microsoft-standard-wsl2:6.18.58.1'
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .microsoft-standard-wsl2').Output | Write-Log
    $command = "container=`$(sudo buildah from $microsoftStandardWSL2 2> /dev/null)  && mountpoint=`$(sudo buildah mount `$container) && sudo find `$mountpoint -iname *.deb | xargs sudo cp -t .microsoft-standard-wsl2 && sudo buildah unmount `$container && sudo buildah rm `$container > /dev/null 2>&1"
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $command).Output | Write-Log
    $count = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'ls -1 .microsoft-standard-wsl2/*.deb 2>/dev/null | wc -l').Output
    if ($count -eq '0') {
        $errMsg = "$microsoftStandardWSL2 could not be pulled!"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'cd .microsoft-standard-wsl2 && sudo dpkg -i *.deb 2>&1').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf .microsoft-standard-wsl2').Output | Write-Log

    # change linux kernel
    $prefix = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux-advanced.*\' /boot/grub/grub.cfg | tr -d `"\'`"").Output
    $kernel = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -io \'gnulinux.*microsoft-standard-wsl2.*\' /boot/grub/grub.cfg | head -1 | tr -d `"\'`"").Output
    if ([string]::IsNullOrWhiteSpace($kernel)) {
        $errMsg = 'Could not locate microsoft-standard-WSL2 kernel entry in /boot/grub/grub.cfg. The kernel package was installed but GRUB did not register it as expected. Re-run the enable or inspect grub.cfg manually on the VM.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sed -i `"s/GRUB_DEFAULT=.*/GRUB_DEFAULT=\'${prefix}\>${kernel}\'/g`" /etc/default/grub").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo update-grub 2>&1' -IgnoreErrors).Output | Write-Log

    # Restart KubeMaster
    Write-Log "Stopping VM $controlPlaneNodeName"
    Stop-VM -Name $controlPlaneNodeName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
    }
    Write-Log "Start VM $controlPlaneNodeName"
    Start-VM -Name $controlPlaneNodeName
    # for the next steps we need ssh access, so let's wait for ssh
    Wait-ForSSHConnectionToLinuxVMViaSshKey
}

# Install Nvidia container toolkit
Write-Log 'Installing Nvidia Container Toolkit' -Console

$offlineWorkflowMsg = "To resolve, use the offline workflow:`n" `
    + "  1. On a machine with internet access: k2s addons export gpu-node -d <export-dir>`n" `
    + "  2. Transfer the exported .oci.tar file to the restricted host`n" `
    + "  3. On the restricted host: k2s addons import gpu-node -f <path-to-oci-tar>`n" `
    + '  4. Then run: k2s addons enable gpu-node'

# NOTE: 'exit' inside a try-block does NOT trigger finally in PowerShell.
# Use $installFailed + return so finally always runs, then exit after the try/finally.
$installFailed = $false
try {
    # Remove any previously corrupted source list from a failed run
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list').Output | Write-Log
    # Remove stale package directories that have no .deb files (left over from a failed run)
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'find .gpu-node -maxdepth 1 -mindepth 1 -type d -exec sh -c ''ls "$1"/*.deb >/dev/null 2>&1 || rm -rf "$1"'' _ {} \; 2>/dev/null' -IgnoreErrors).Output | Write-Log

    if (!(Get-DebianPackageAvailableOffline -addon 'gpu-node' -package 'nvidia-container-toolkit')) {
        $httpProxy = if ($WSL) { '127.0.0.1:8181' } else { "${kubeSwitchIp}:8181" }
        $command = "curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -x $httpProxy | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -x $httpProxy | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
        $repoSetupResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $command)
        $repoSetupResult.Output | Write-Log
        if (!$repoSetupResult.Success) {
            $errMsg = "Failed to set up NVIDIA container toolkit apt repository via proxy ($httpProxy).`n" `
                + "This usually means the host has no internet access or the K2s HTTP proxy is not reachable.`n" `
                + $offlineWorkflowMsg

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $errMsg -Error
            $installFailed = $true
            return
        }

        $updateResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get update')
        $updateResult.Output | Write-Log
        if (!$updateResult.Success) {
            Write-Log '[gpu-node] apt-get update failed after adding NVIDIA repository, installation may fail' -Console
        }
    }
    Install-DebianPackages -addon 'gpu-node' -packages 'libnvidia-container1', 'libnvidia-container-tools', 'nvidia-container-runtime', 'nvidia-container-toolkit'

    # Verify NVIDIA container toolkit was installed successfully
    $verifyResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q "^ii"')
    if (!$verifyResult.Success) {
        $errMsg = "NVIDIA container toolkit packages could not be installed.`n" `
            + $offlineWorkflowMsg

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        $installFailed = $true
        return
    }

    # Pre-pull images via buildah while the SSH tunnel is active.
    # buildah shares /var/lib/containers/storage with CRI-O, so images are immediately available.
    if ($WSL -and $null -ne $tunnelProc -and !$tunnelProc.HasExited) {
        Write-Log '[gpu-node] Pre-pulling images via SSH tunnel (buildah)' -Console

        $images = @(
            'nvcr.io/nvidia/k8s-device-plugin:v0.20.1'
            'nvcr.io/nvidia/k8s/dcgm-exporter:4.5.2-4.8.1-ubi9'
        )
        foreach ($image in $images) {
            Write-Log "[gpu-node] Pre-pulling image via SSH tunnel: $image" -Console

            # Skip if already present in CRI-O image store
            $alreadyPresent = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 5 -CmdToExecute `
                "sudo crictl inspecti '$image' >/dev/null 2>&1 && echo present || echo missing" `
                -IgnoreErrors).Output
            if ($alreadyPresent -match 'present') {
                Write-Log "[gpu-node] Image already present, skipping pre-pull: $image"
                continue
            }

            $prePullResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 600 -CmdToExecute `
                "sudo HTTPS_PROXY=http://127.0.0.1:8181 HTTP_PROXY=http://127.0.0.1:8181 buildah pull '$image' 2>&1" `
                -IgnoreErrors)
            $prePullResult.Output | Write-Log
            if (!$prePullResult.Success) {
                Write-Log "[gpu-node] WARNING: Pre-pull of $image failed - deployment may stall waiting for image" -Console
            } else {
                Write-Log "[gpu-node] Pre-pull succeeded: $image"
            }
        }
    }
} finally {
    if ($null -ne $tunnelProc) {
        # Always restore apt proxy — it was redirected when the tunnel started.
        Write-Log "[gpu-node] Restoring apt proxy config to ${kubeSwitchIp}:8181"
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
            "sudo sed -i 's|127.0.0.1:8181|${kubeSwitchIp}:8181|g' /etc/apt/apt.conf.d/proxy.conf 2>/dev/null; true" `
            -IgnoreErrors).Output | Write-Log
        if (!$tunnelProc.HasExited) {
            Write-Log "[gpu-node] Stopping SSH reverse proxy tunnel (PID $($tunnelProc.Id))"
            Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
        }
        $tunnelProc = $null
    }
    if ($null -ne $sshErrFile -and (Test-Path $sshErrFile)) {
        Remove-Item $sshErrFile -Force -ErrorAction SilentlyContinue
    }
}
if ($installFailed) { exit 1 }

# Remove legacy OCI hook — GPU injection now uses CDI (cdi-annotations strategy).
# nvidia-container-toolkit packages are still needed for CRI-O CDI container edits.
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json').Output | Write-Log


Wait-ForAPIServer

if ($TimeSlices -gt 1) {
    # Apply time-slicing ConfigMap (replicas >= 2) before the DaemonSet so the pod can mount it immediately.
    Write-Log "[gpu-node] Configuring GPU time-slicing (replicas: $TimeSlices)" -Console
    $timeSlicingTemplate = Get-Content -Path "$PSScriptRoot\manifests\time-slicing-config.yaml" -Raw
    $timeSlicingResolved = $timeSlicingTemplate -replace '__TIME_SLICES__', $TimeSlices
    $tmpConfigMap = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.Guid]::NewGuid().ToString() + '.yaml')
    $timeSlicingResolved | Set-Content -Path $tmpConfigMap -Encoding UTF8
    (Invoke-Kubectl -Params 'apply', '-f', $tmpConfigMap).Output | Write-Log
    Remove-Item $tmpConfigMap -Force -ErrorAction SilentlyContinue
} else {
    # Apply default ConfigMap (no sharing section — exclusive GPU access per pod).
    (Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\time-slicing-config-default.yaml").Output | Write-Log
}

# Label the node BEFORE deploying the device plugin, so the DaemonSet can schedule pods.
# The device plugin DaemonSet has nodeSelector: gpu=true
$labelNodeName = if ($WSL) { Get-ConfigControlPlaneNodeHostname } else { $controlPlaneNodeName }
Write-Log "[gpu-node] Labeling node '$labelNodeName' with gpu=true and accelerator=nvidia" -Console
(Invoke-Kubectl -Params 'label', 'node', $labelNodeName, 'gpu=true', 'accelerator=nvidia', '--overwrite').Output | Write-Log

foreach ($targetNode in $additionalGpuLabelNodes) {
    Write-Log "[gpu-node] Labeling additional targeted node '$targetNode' with gpu=true and accelerator=nvidia" -Console
    (Invoke-Kubectl -Params 'label', 'node', $targetNode, 'gpu=true', 'accelerator=nvidia', '--overwrite').Output | Write-Log
}

# Apply Nvidia device plugin — ConfigMap content determines time-slicing behavior.
Write-Log 'Installing Nvidia Device Plugin' -Console
(Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\nvidia-device-plugin.yaml").Output | Write-Log

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'nvidia-device-plugin', '-n', 'gpu-node', '--timeout', '180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Nvidia device plugin could not be started!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# Wait for the device plugin to register nvidia.com/gpu with kubelet (takes a few seconds after pod start).
Write-Log '[gpu-node] Waiting for nvidia.com/gpu to be registered with kubelet...'
$gpuCheckNode = if ($WSL) { Get-ConfigControlPlaneNodeHostname } else { $controlPlaneNodeName }
$nodesToVerify = @($gpuCheckNode) + $additionalGpuLabelNodes | Select-Object -Unique
foreach ($nodeToVerify in $nodesToVerify) {
    $gpuRegistered = $false
    for ($i = 0; $i -lt 30; $i++) {
        $gpuCount = (Invoke-Kubectl -Params 'get', 'node', $nodeToVerify, '-o', "jsonpath={.status.allocatable['nvidia\.com/gpu']}").Output
        if (![string]::IsNullOrWhiteSpace($gpuCount) -and $gpuCount -match '^\d+$' -and [int]$gpuCount -gt 0) {
            $gpuRegistered = $true
            Write-Log "[gpu-node] Node '$nodeToVerify' registered nvidia.com/gpu: $gpuCount slot(s) allocatable" -Console
            break
        }
        Start-Sleep -Seconds 2
    }
    if (!$gpuRegistered) {
        $errMsg = "Nvidia device plugin started but node '$nodeToVerify' did not register nvidia.com/gpu within 60s. Ensure GPU drivers/container toolkit are configured for that node."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

# DCGM-Exporter is NOT deployed. It requires the native NVML library which is
# unavailable on the dxcore/D3D12 driver path used by both WSL2 and Hyper-V
# GPU-PV. Deploying it would only produce a crash-looping pod. The manifest
# is kept in manifests/dcgm-exporter.yaml for potential future bare-metal
# passthrough support.
Write-Log '[GPU] Skipping DCGM-Exporter: NVML is not available via the dxcore/D3D12 GPU-PV path. GPU workloads are not affected.' -Console

if ($TimeSlices -gt 1) {
    Write-Log "[gpu-node] GPU time-slicing enabled: $TimeSlices virtual GPU slots available (pods share 1 physical GPU)" -Console
}
Write-Log 'KubeMaster configured successfully as GPU node' -Console

# Check for any external GPU-labeled worker nodes
Write-Log '[gpu-node] Checking for external GPU-capable worker nodes...' -Console
$allGpuNodes = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'gpu=true', '-o', 'jsonpath={.items[*].metadata.name}').Output
if (![string]::IsNullOrWhiteSpace($allGpuNodes)) {
    $gpuNodeList = $allGpuNodes -split '\s+'
    $externalGpuNodes = $gpuNodeList | Where-Object { $_ -ne $labelNodeName }
    if ($externalGpuNodes.Count -gt 0) {
        Write-Log "[gpu-node] Found $($externalGpuNodes.Count) external GPU-capable worker node(s):" -Console
        foreach ($node in $externalGpuNodes) {
            Write-Log "[gpu-node]   - $node" -Console
        }
        Write-Log '[gpu-node] These nodes will receive the NVIDIA device plugin DaemonSet pods.' -Console
    }
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'gpu-node' })

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
