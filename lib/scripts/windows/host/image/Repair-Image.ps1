# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Repairs missing K2s system images on the control plane node from local archives

.DESCRIPTION
Compares the system image archives in bin\linuxnode\images (control plane, flannel, clusterip-webhook)
with the images present on the control plane node and re-imports only the missing ones.
Afterwards kubelet is restarted and the control plane pods are awaited. No network access is required.

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
PS> .\Repair-Image.ps1 -ShowLogs
#>

Param (
    [parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$imageCommonModule = "$PSScriptRoot/Image-Common.module.psm1"
Import-Module $imageCommonModule

Initialize-Logging -ShowLogs:$ShowLogs

function Send-RepairResult {
    param([object] $Err)
    if ($null -ne $Err) {
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $Err }
            return
        }
        Write-Log $Err.Message -Error
        exit 1
    }
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
}

# The control plane may be unhealthy here (that is the reason for the repair), so only the setup is checked, not the running state
$setupInfo = Get-SetupInfo
if ($setupInfo.Error) {
    Send-RepairResult -Err (New-Error -Severity Warning -Code $setupInfo.Error -Message 'You have not installed K2s setup yet, please install K2s first.')
    return
}

$archiveDir = Get-DirectoryOfKubenodeImagesOnWindowsHost
$systemArchivePattern = '^(registry\.k8s\.io_|docker\.io_flannel|.*clusterip-webhook)'
$archives = @()
if (Test-Path -Path $archiveDir) {
    $archives = @(Get-ChildItem -Path $archiveDir -Filter '*.tar' -File | Where-Object { $_.Name -match $systemArchivePattern })
}
if ($archives.Count -eq 0) {
    Send-RepairResult -Err (New-Error -Code 'image-repair-no-archives' -Message "No system image archives found in '$archiveDir' - repair is not possible offline")
    return
}

# no double quotes: Windows PowerShell drops them when passing the command to ssh.exe
$listResult = Invoke-CmdOnControlPlaneViaSSHKey 'sudo crictl images | grep -v ''<none>'' | awk -v OFS=: ''NR>1 { print $1, $2 }''' -Retries 3 -Timeout 10 -NoLog
if (-not $listResult.Success) {
    Send-RepairResult -Err (New-Error -Code 'image-repair-node-unreachable' -Message 'Could not list images on the control plane node - is the node VM running?')
    return
}
$presentFiles = @{}
foreach ($ref in @($listResult.Output)) {
    $ref = "$ref".Trim()
    if ($ref -ne '') {
        $presentFiles["$($ref.Replace('/','_').Replace(':', '__')).tar"] = $true
    }
}

$missing = @($archives | Where-Object { -not $presentFiles.ContainsKey($_.Name) })
if ($missing.Count -eq 0) {
    Write-Log '[Repair] All system images are present on the control plane node' -Console
}
else {
    Write-Log "[Repair] Re-importing $($missing.Count) missing system image(s). This can take some time..." -Console
    $nodeInfo = @{ Kind = 'ControlPlane'; Name = 'control-plane' }
    $failed = @()
    foreach ($archive in $missing) {
        Write-Log "[Repair] Importing '$($archive.Name)'" -Console
        if (-not (Invoke-LinuxNodeImageImport -ImagePath $archive.FullName -NodeInfo $nodeInfo)) {
            $failed += $archive.Name
        }
    }
    if ($failed.Count -gt 0) {
        Send-RepairResult -Err (New-Error -Code 'image-repair-import-failed' -Message "Import failed for: $($failed -join ', ') - check the log for details")
        return
    }
}

Write-Log '[Repair] Restarting kubelet on the control plane node' -Console
$restart = Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart kubelet' -Retries 3 -Timeout 10 -NoLog
if (-not $restart.Success) {
    Send-RepairResult -Err (New-Error -Code 'image-repair-kubelet-restart-failed' -Message 'Could not restart kubelet on the control plane node')
    return
}

# a freshly started API server answers Forbidden until RBAC is bootstrapped; /readyz covers that
Write-Log '[Repair] Waiting for the API server to become ready' -Console
$kubectlExe = "$(Get-KubeToolsPath)\kubectl.exe"
$apiReady = $false
$savedErrorActionPreference = $ErrorActionPreference
for ($i = 0; $i -lt 60 -and -not $apiReady; $i++) {
    $ErrorActionPreference = 'Continue'
    $apiReady = (& $kubectlExe get --raw /readyz 2>$null) -eq 'ok'
    $ErrorActionPreference = $savedErrorActionPreference
    if (-not $apiReady) { Start-Sleep -Seconds 5 }
}

try {
    Wait-ForControlPlanePodsReady -SuppressRepairHint
}
catch {
    Send-RepairResult -Err (New-Error -Code 'image-repair-control-plane-not-ready' -Message "Images repaired, but the control plane did not become Ready: $_")
    return
}

Write-Log '[Repair] Control plane is Ready' -Console
Send-RepairResult -Err $null
