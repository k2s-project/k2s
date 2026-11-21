# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls KubeVirt in the cluster

.DESCRIPTION
Kubevirt is needed for running VMs in Kubernetes for apps which cannot containerized

#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'K8sSetup: SmallSetup')]
    [string] $K8sSetup = 'SmallSetup',
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

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

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

Write-Log 'Check whether kubevirt addon is already disabled'

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'kubevirt', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'kubevirt' })) -ne $true) {
    $errMsg = "Addon 'kubevirt' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling kubevirt addon' -Console

# show all pods
Write-Log "`nKubernetes pods before:`n"
(Invoke-Kubectl -Params 'get', 'pods', '-A', '-o', 'wide').Output | Write-Log

$ScriptBlockNamespaces = {
    param (
        [parameter(Mandatory = $true)]
        [string] $Namespace
    )
    Write-Log "Start to cleanup namespace $Namespace"
    Remove-Item -Path $Namespace-namespace.json -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $Namespace-namespace-cleaned.json -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 60
    $n = (Invoke-Kubectl -Params 'get', 'namespace', $Namespace).Output
    if ($n) {
        (Invoke-Kubectl -Params 'get', 'namespace', $Namespace, '-o', 'json').Output > $Namespace-namespace.json
        $json = Get-Content $Namespace-namespace.json -Encoding Ascii | ConvertFrom-Json
        if ( $json ) {
            Write-Log ($json.spec.finalizers | Format-List | Out-String)
            $json.spec.finalizers = @()
            $json | ConvertTo-Json -depth 100 | Out-File $Namespace-namespace-cleaned.json -Encoding Ascii
            (Invoke-Kubectl -Params 'replace', '--raw', "/api/v1/namespaces/$Namespace/finalize", '-f', "$Namespace-namespace-cleaned.json").Output | Write-Log
        }
    }
    Write-Log "Namespace $Namespace cleaned"
}

Write-Log 'Deleting kubevirt'
(Invoke-Kubectl -Params 'delete', '-n', 'kubevirt', 'kubevirt', 'kubevirt', '--wait=true').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'apiservices', 'v1alpha3.subresources.kubevirt.io', '--ignore-not-found').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'mutatingwebhookconfigurations', 'virt-api-mutator', '--ignore-not-found').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'validatingwebhookconfigurations', 'virt-api-validator', '--ignore-not-found').Output | Write-Log
(Invoke-Kubectl -Params 'delete', 'validatingwebhookconfigurations', 'virt-operator-validator', '--ignore-not-found').Output | Write-Log
(Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\kubevirt-operator.yaml", '--wait=false').Output | Write-Log

$patch = '{\"metadata\":{\"finalizers\":null}}'
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patch = '{"metadata":{"finalizers":null}}'
}

(Invoke-Kubectl -Params 'patch', 'namespace', 'kubevirt', '-p', $patch).Output | Write-Log

Start-Job $ScriptBlockNamespaces -ArgumentList 'kubevirt'

(Invoke-Kubectl -Params 'delete', 'namespace', 'kubevirt', '--force', '--grace-period=0').Output | Write-Log
Write-Log "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"

# show all pods
Write-Log "`nKubernetes pods after:`n"
(Invoke-Kubectl -Params 'get', 'pods', '-A', '-o', 'wide').Output | Write-Log

# remove runtime settings
# only for small setup we use software virtualization
if ( $K8sSetup -eq 'SmallSetup' ) {
    # remove cgroup setting
    Write-Log 'change back to cgroup v2'
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sed -i 's,systemd.unified_cgroup_hierarchy=0\ ,,g' /etc/default/grub").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo update-grub 2>&1').Output | Write-Log

    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname

    # restart KubeMaster
    Write-Log "Stopping VM $controlPlaneNodeName"
    Stop-VM -Name $controlPlaneNodeName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop..'
        Start-Sleep -s 1
    }
    Write-Log "Starting VM $controlPlaneNodeName"
    Start-VM -Name $controlPlaneNodeName
    Wait-ForSSHConnectionToLinuxVMViaSshKey
}

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'kubevirt' })

$binPath = Get-KubeBinPath

Remove-Item "$binPath\virtctl.exe" -Force -ErrorAction SilentlyContinue

Write-Log 'Removing virtviewer' -Console
$virtviewer = Get-VirtViewerMsiFileName
msiexec /x "$binPath\$virtviewer" /qn /L*VX "$binPath\msiuninstall.log"
Remove-Item "$binPath\$virtviewer" -Force -ErrorAction SilentlyContinue

Write-Log 'Uninstallation of kubevirt addon done'

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
