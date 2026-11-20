# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# ImportImage.ps1

<#
.Description
Import image from oci tar archive
#>

Param (
    [parameter(Mandatory = $false)]
    [string] $ImagePath,
    [parameter(Mandatory = $false)]
    [string] $ImageDir,
    [parameter(Mandatory = $false)]
    [switch] $Windows = $false,
    [parameter(Mandatory = $false)]
    [switch] $DockerArchive = $false,
    [parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$clusterModule = "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$infraModule = "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"

Import-Module $clusterModule, $imageFunctionsModule, $infraModule -DisableNameChecking

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$images = @()
if ($ImagePath -ne '') {
    $images += $ImagePath
    Write-Log "Importing image $ImagePath. This can take some time..." -Console
}
elseif ($ImageDir -ne '') {
    $files = Get-Childitem -recurse $ImageDir | Where-Object { $_.Name -match '.*.tar' } | ForEach-Object { $_.Fullname }
    $images += $files
    Write-Log "Importing images from $ImageDir. This can take some time..." -Console
}

if ($Windows) {
    $setupInfo = Get-SetupInfo
    if ($setupInfo.LinuxOnly) {
        $errMsg = 'Cannot import windows image, Linux-only setup is installed'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }

    foreach ($image in $images) {
        $importSuccess = Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'import', $image
        if ($importSuccess) {
            Write-Log "$image imported successfully" -Console
        }
    }
}
else {
    foreach ($image in $images) {
        Copy-FromToMaster $image $($global:Remote_Master + ':' + '/tmp/import.tar')

        if (!$?) {
            Write-Error "Image $image could not be copied to KubeMaster"
        }

        if (!$DockerArchive) {
            ExecCmdMaster 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1' -NoLog
        }
        else {
            ExecCmdMaster 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' -NoLog
        }

        if ($?) {
            Write-Log "Image archive $image imported successfully." -Console
        }

        ExecCmdMaster 'cd /tmp && sudo rm -rf import.tar' -NoLog
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
