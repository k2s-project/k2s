# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores ingress nginx-gw configuration/resources.

.DESCRIPTION
Applies previously exported Kubernetes resources from a staging folder.
The addon should already be enabled before running this restore.
Restores TLS continuity by restoring the CA root secret + the TLS secret,
and (re-)importing the CA cert into the Windows trusted root store.

.PARAMETER BackupDir
Directory containing backup.json and the referenced files.

.EXAMPLE
powershell <installation folder>\addons\ingress\nginx-gw\Restore.ps1 -BackupDir C:\Temp\ingress-nginx-gw-backup
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory containing backup.json and referenced files')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$manifestPath = Join-Path $BackupDir 'backup.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    $errMsg = "backup.json not found in '$BackupDir'"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json

Write-Log "[AddonRestore] Restoring addon 'ingress nginx-gw'" -Console

function Invoke-ApplyWithConflictFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string] $FilePath
    )

    $applyResult = Invoke-Kubectl -Params 'apply', '-f', $FilePath
    if ($applyResult.Success) {
        if (-not [string]::IsNullOrWhiteSpace($applyResult.Output)) {
            $applyResult.Output | Write-Log
        }
        return
    }

    $outputText = "$($applyResult.Output)"
    if ($outputText -match '(the object has been modified|Error from server \(Conflict\)|conflict)') {
        Write-Log "[AddonRestore] Detected conflict during apply; retrying with 'kubectl replace --force' for '$FilePath'" -Console

        $replaceResult = Invoke-Kubectl -Params 'replace', '--force', '-f', $FilePath
        if (-not $replaceResult.Success) {
            throw "Failed to apply '$FilePath' (conflict) and replace also failed: $($replaceResult.Output)"
        }

        if (-not [string]::IsNullOrWhiteSpace($replaceResult.Output)) {
            $replaceResult.Output | Write-Log
        }
        return
    }

    throw "Failed to apply '$FilePath': $outputText"
}

try {
    foreach ($file in $manifest.files) {
        $filePath = Join-Path $BackupDir $file
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw "Backup file not found: $file"
        }

        Invoke-ApplyWithConflictFallback -FilePath $filePath
    }

    # Ensure NginxProxy external IP is consistent with the current machine setup.
    # Restore intentionally does not apply NginxProxy from backup; it is derived from the
    # current control-plane IP.
    try {
        $controlPlaneIp = Get-ConfiguredIPControlPlane
        if (-not [string]::IsNullOrWhiteSpace($controlPlaneIp)) {
            Write-Log "[AddonRestore] Applying NginxProxy with external IP $controlPlaneIp" -Console
            $nginxProxyTemplatePath = Join-Path $PSScriptRoot 'manifests\nginxproxy.yaml'
            if (Test-Path -LiteralPath $nginxProxyTemplatePath) {
                $nginxProxyTemplate = Get-Content -LiteralPath $nginxProxyTemplatePath -Raw
                $nginxProxyYaml = $nginxProxyTemplate.Replace('__CONTROL_PLANE_IP__', $controlPlaneIp)
                $nginxProxyYaml | & kubectl apply -f -
            }
            else {
                Write-Log "[AddonRestore] NginxProxy template not found at '$nginxProxyTemplatePath'; skipping." -Console
            }
        }
    }
    catch {
        Write-Log "[AddonRestore] Failed to apply NginxProxy using current control-plane IP: $($_.Exception.Message)" -Error
        throw
    }

    Write-Log "[AddonRestore] Waiting for nginx-gw controller pod to be Ready" -Console
    Wait-ForPodCondition -Label 'app.kubernetes.io/name=nginx-gw' -Namespace 'nginx-gw' -Condition Ready -TimeoutSeconds 180 | Out-Null

    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Update.ps1')) {
        Write-Log '[AddonRestore] Running nginx-gw Update.ps1' -Console
        &"$PSScriptRoot\Update.ps1"
    }
}
catch {
    $errMsg = "Restore of addon 'ingress nginx-gw' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log '[AddonRestore] Restore completed' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
