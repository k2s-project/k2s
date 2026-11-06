# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs KubeVirt in the cluster

.DESCRIPTION
Kubevirt is needed for running VMs in Kubernetes for apps which cannot containerized

# Current version is checked in, pick an upstream version of KubeVirt to install:
$ export RELEASE=v0.58.0
# Deploy the KubeVirt operator
$ kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-operator.yaml
# Create the KubeVirt CR (instance deployment request) which triggers the actual installation
$ kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-cr.yaml
# wait until all KubeVirt components are up
$ kubectl -n kubevirt wait kv kubevirt --for condition=Available

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\Kubevirt\Enable.ps1
# with software virtualization
powershell <installation folder>\addons\Kubevirt\Enable.ps1 -UseSoftwareVirtualization
# For OnPremise setup
powershell <installation folder>\addons\Kubevirt\Enable.ps1 -K8sSetup  OnPremise
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use software virtualization')]
    [switch] $UseSoftwareVirtualization = $false,
    [parameter(Mandatory = $false, HelpMessage = 'K8sSetup: SmallSetup/OnPremise')]
    [string] $K8sSetup = 'SmallSetup',
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$kubevirtModule = "$PSScriptRoot\kubevirt.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $nodeModule, $kubevirtModule

Initialize-Logging -ShowLogs:$ShowLogs

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$Proxy = "http://$($windowsHostIpAddress):8181"

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

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'kubevirt' })) -eq $true) {
    $errMsg = "Addon 'kubevirt' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$wsl = Get-ConfigWslFlag
if ($wsl) {
    $errMsg = "kubevirt addon is not available with WSL2 setup!`n" `
        + "Please install cluster without wsl option in order to use kubevirt addon!`n" `
        + 'kubevirt not available on current setup!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing kubevirt addon' -Console

# check memory
$controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
$MasterVMMemory = Get-VMMemory -VMName $controlPlaneNodeName
if ( $MasterVMMemory.Startup -lt 10GB ) {
    $errMsg = "KubeVirt needs minimal 8GB main memory, you have a K2s Setup with less memory!`n" `
        + "Please increase main memory for the VM $controlPlaneNodeName (shutdown, increase memory to 10GB, start)`n" `
        + "or install from scratch with k2s install --master-cpus 8 --master-memory 12GB --master-disk 120GB`n"`
        + 'Memory in master vm too low, stop your cluster and increase the memory of your master vm to at least 12GB!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# check disk
$MasterDiskSize = Get-VM -VMName $controlPlaneNodeName | Select-Object VMId | Get-VHD
if ( $MasterDiskSize.Size -lt 100GB ) {
    $errMsg = "KubeVirt needs minimal 100GB disk size, you have a K2s Setup with less disk size!`n" `
        + "Please increase disk size for the VM $controlPlaneNodeName (shutdown, increase disk size to 100GB by expanding vhdx, start)`n" `
        + "or install from scratch with k2s install --master-cpus 8 --master-memory 12GB --master-disk 120GB`n"`
        + 'Disk size for master vm too low'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# restart KubeMaster
Write-Log "Stopping VM $controlPlaneNodeName"
Stop-VM -Name $controlPlaneNodeName -Force -WarningAction SilentlyContinue
$state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
while (!$state) {
    Write-Log 'Still waiting for stop...'
    Start-Sleep -s 1
}
Set-VMProcessor -VMName $controlPlaneNodeName -ExposeVirtualizationExtensions $true
Write-Log "Start VM $controlPlaneNodeName"
Start-VM -Name $controlPlaneNodeName
# for the next steps we need ssh access, so let's wait for ssh
Wait-ForSSHConnectionToLinuxVMViaSshKey

# missing
Install-DebianPackages -addon 'kubevirt' -packages 'fuse3'

# enable virtualization in VM
Write-Log 'enable virtualization in the VM'
# https://wiki.debian.org/KVM
# for debian 11: sudo apt-get install --no-install-recommends qemu-system libvirt-clients libvirt-daemon-system
Install-DebianPackages -addon 'kubevirt' -packages 'qemu-system', 'libvirt-clients', 'libvirt-daemon-system'

# disable app armor
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl stop apparmor 2>&1').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl disable apparmor 2>&1').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt remove --assume-yes --purge apparmor 2>&1').Output | Write-Log

# check state of virtualization
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo virt-host-validate qemu').Output | Write-Log

# add kernel parameter to use cgroup v1 (will be only valid after restart of VM)
Write-Log 'change to cgroup v1'
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sed -i 's,systemd.unified_cgroup_hierarchy=0\ ,,g' /etc/default/grub").Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sed -i 's,console=tty0,systemd.unified_cgroup_hierarchy=0\ console=tty0,g' /etc/default/grub").Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo update-grub 2>&1').Output | Write-Log

# wait for API server
Wait-ForAPIServer

Write-Log "Use of software virtualization: $UseSoftwareVirtualization"

# use software virtualization
if ( $UseSoftwareVirtualization ) {
    Write-Log 'enable the software virtualization'
    (Invoke-Kubectl -Params 'create', 'namespace', 'kubevirt').Output | Write-Log
    # enable feature
    (Invoke-Kubectl -Params 'create', 'configmap', 'kubevirt-config', '-n', 'kubevirt', '--from-literal=feature-gates=HostDisk', '--from-literal=debug.useEmulation=true').Output | Write-Log
}

# deploy kubevirt
$VERSION_KV = 'v1.9.1'
Write-Log "deploy kubevirt version $VERSION_KV"
(Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\kubevirt-operator.yaml").Output | Write-Log

# deploy virtctrl
$VERSION_VCTRL = 'v1.9.1'
$IMPLICITPROXY = "http://$(Get-ConfiguredKubeSwitchIP):8181"
Write-Log "deploy virtctl version $VERSION_VCTRL"
if ( $K8sSetup -eq 'SmallSetup' ) {
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "export VERSION_VCTRL=$VERSION_VCTRL").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "export IMPLICITPROXY=$IMPLICITPROXY").Output | Write-Log
    $success = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute '[ -f /usr/local/bin/virtctl ]').Success
    if (!$success) {
            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo curl --retry 3 --retry-all-errors --proxy $IMPLICITPROXY -sL -o /usr/local/bin/virtctl https://github.com/kubevirt/kubevirt/releases/download/$VERSION_VCTRL/virtctl-$VERSION_VCTRL-linux-amd64 2>&1").Output | Write-Log
    }
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chmod +x /usr/local/bin/virtctl').Output | Write-Log
}

$binPath = Get-KubeBinPath
if (!(Test-Path "$binPath\virtctl.exe")) {
    Invoke-DownloadFile "$binPath\virtctl.exe" "https://github.com/kubevirt/kubevirt/releases/download/$VERSION_VCTRL/virtctl-$VERSION_VCTRL-windows-amd64.exe" $true -ProxyToUse $Proxy
}

# enable config
(Invoke-Kubectl -Params 'wait', '--timeout=180s', '--for=condition=Ready', '-n', 'kube-system', "pod/kube-apiserver-$controlPlaneNodeName").Output | Write-Log
(Invoke-Kubectl -Params 'wait', '--timeout=30s', '--for=condition=Available', '-n', 'kubevirt', 'deployment/virt-operator').Output | Write-Log
# Clear kubectl discovery cache so KubeVirt CR kind is resolvable after operator CRD installation
Clear-KubectlDiscoveryCache
(Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-f', "$PSScriptRoot\manifests\kubevirt-cr.yaml").Output | Write-Log

# for small setup restart VM
if ( $K8sSetup -eq 'SmallSetup' ) {
    Write-Log "Stopping VM $controlPlaneNodeName"
    Stop-VM -Name $controlPlaneNodeName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
        $state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    }
    Write-Log "Start VM $controlPlaneNodeName"
    Start-VM -Name $controlPlaneNodeName
    Wait-ForAPIServer
}

# install virt viewer
$virtviewer = Get-VirtViewerMsiFileName
if (!(Test-Path "$binPath\$virtviewer")) {
    Write-Log 'Installing VirtViewer ...'
    if (!(Test-Path "$binPath\$virtviewer")) {
        Invoke-DownloadFile "$binPath\$virtviewer" "https://gitlab.com/virt-viewer/virt-viewer/-/releases/v11.0/downloads/$virtviewer" $true -ProxyToUse $Proxy
    }
    msiexec.exe /i "$binPath\$virtviewer" /L*VX "$binPath\msiinstall.log" /quiet /passive /norestart

    # add to environment variable
    # version 11.0-1.0 results in folder naming v11.0-256
    $pathAdditions = 'C:\Program Files\VirtViewer v11.0-256\bin'
    Update-SystemPath -Action 'add' "$pathAdditions"

    Write-Log 'VirtViewer installed'
}

Write-Log 'Waiting for kubevirt components to be running..'
(Invoke-Kubectl -Params 'wait', '--timeout=180s', '--for=condition=Ready', '-n', 'kube-system', "pod/kube-apiserver-$controlPlaneNodeName").Output | Write-Log
(Invoke-Kubectl -Params 'wait', '--timeout=180s', '--for=condition=Available', '-n', 'kubevirt', 'kv/kubevirt').Output | Write-Log

# label master node with kubevirt label
if ( $K8sSetup -eq 'SmallSetup' ) {
    (Invoke-Kubectl -Params 'label', 'node', $controlPlaneNodeName, 'kubevirt=true', '--overwrite').Output | Write-Log
}

Write-Log 'kubevirt components are running'

Write-RefreshEnvVariables

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'kubevirt' })

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
