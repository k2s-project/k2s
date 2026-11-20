# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Delete K8s namespace with blocking finalizers

.DESCRIPTION
This script assists in the following actions:
Delete K8s namespace with blocking finalizers

.PARAMETER Mode
Namespace to be deleted

.EXAMPLE
Without proxy
powershell <installation folder>\smallsetup\helpers\DeleteNamespace.ps1 -Namespace argo-events

#>

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Namespace: XXXX')]
    [string] $Namespace
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

$ErrorActionPreference = 'Stop'

$ScriptBlockNamespaces = {
    param (
        [parameter(Mandatory = $true)]
        [string] $Namespace
    )
    Write-Host "Start to cleanup namespace $Namespace"
    Remove-Item -Path $Namespace-namespace.json -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $Namespace-namespace-cleaned.json -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 20
    $n = &$global:KubectlExe get namespace $Namespace
    if ($n) {
        &$global:KubectlExe get namespace $Namespace -o json > $Namespace-namespace.json 
        $json = Get-Content $Namespace-namespace.json -Encoding Ascii | ConvertFrom-Json
        if ( $json ) {
            Write-Host ($json.spec.finalizers | Format-List | Out-String)
            $json.spec.finalizers = @()
            Write-Host ($json.spec.finalizers | Format-List | Out-String) 
            $json | ConvertTo-Json -depth 100 | Out-File $Namespace-namespace-cleaned.json -Encoding Ascii
            &$global:KubectlExe replace --raw "/api/v1/namespaces/$Namespace/finalize" -f $Namespace-namespace-cleaned.json
        }
    }
    Write-Host "Namespace $Namespace clean now !"
}

Write-Host "Delete K8s namespace: $Namespace"

Write-Host "`nKubernetes config:`n"
&$global:KubectlExe config get-contexts 

# delete namespace
&$global:KubectlExe patch namespace $Namespace -p "{\`"metadata\`":{\`"finalizers\`":null}}"
Start-Job $ScriptBlockNamespaces -ArgumentList $Namespace
&$global:KubectlExe delete namespace $Namespace --force --grace-period=0

Write-Host "K8s namespace: $Namespace deleted"
