# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
List registries on specific nodes

.DESCRIPTION
List container registries configured on specific nodes by querying their local registry config.

.PARAMETER Nodes
Comma-separated node names to target. If omitted, lists global registries.

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# List registries on a specific node
PS> .\List-Registries.ps1 -Nodes "worker-1"

.EXAMPLE
# List registries on multiple nodes
PS> .\List-Registries.ps1 -Nodes "worker-1,worker-2"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Comma-separated node names to target')]
    [string] $Nodes = '',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$imageCommonModule = "$PSScriptRoot/../Image-Common.module.psm1"
Import-Module $infraModule, $imageCommonModule

Initialize-Logging -ShowLogs:$ShowLogs

function Write-TraceLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($ShowLogs) {
        Write-Log $Message -Console
    }
    else {
        Write-Log $Message
    }
}

Write-TraceLog "Listing registries on nodes: $Nodes"

$nodeList = Resolve-NodeList -Nodes $Nodes

if ($nodeList.Count -eq 0) {
    Write-TraceLog "[Registry] No nodes specified or resolved"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'nodes-not-found' -Message 'No nodes specified or resolved'
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    exit 1
}

Write-TraceLog "[Registry] Querying registries on $($nodeList.Count) node(s): $($nodeList -join ', ')"

foreach ($nodeName in $nodeList) {
    $nodeInfo = Resolve-ImageNode -NodeName $nodeName
    if ($null -eq $nodeInfo) {
        Write-TraceLog "[Registry] Node '$nodeName' could not be resolved, skipping"
        continue
    }

    # Check if node is Ready before querying
    if (-not (Test-NodeReady -NodeName $nodeName -Kind $nodeInfo.Kind)) {
        Write-TraceLog "[Registry] Node '$nodeName' is not in Ready state - start the node with 'k2s start --node $nodeName' first"
        continue
    }

    Write-Output "[Registry] === Registries on '$nodeName' (kind=$($nodeInfo.Kind), os=$($nodeInfo.OS)) ==="

    if ($nodeInfo.OS -eq 'linux') {
        $listLinuxRegistriesCmd = 'sudo sh -c ''for f in /etc/containers/registries.conf.d/*.conf; do [ -f "$f" ] && basename "$f"; done'''

        if ($nodeInfo.Kind -eq 'ControlPlane') {
            $registryListRaw = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $listLinuxRegistriesCmd -IgnoreErrors).Output
        }
        else {
            $registryListRaw = (Invoke-CmdOnVmViaSSHKey -CmdToExecute $listLinuxRegistriesCmd -IpAddress $nodeInfo.IpAddress -UserName $nodeInfo.Username -NoLog -IgnoreErrors).Output
        }

        $registryDirs = @()
        if ($null -ne $registryListRaw) {
            $rawText = ($registryListRaw | Out-String)
            $registryDirs = @($rawText -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -match '\.conf$' })
        }

        $registryDirs = @($registryDirs | Where-Object { $_ -notin @('crio.conf', 'shortnames.conf') })

        if ($registryDirs -and $registryDirs.Count -gt 0) {
            foreach ($registryFile in $registryDirs) {
                $registryName = $registryFile -replace '\.conf$', ''
                Write-Log " - $registryName" -Console
            }
        }
        else {
            Write-Log " (no custom registries configured)" -Console
        }
    }
    elseif ($nodeInfo.OS -eq 'windows') {
        # For Windows, query the certs.d directory
        if ($nodeInfo.Kind -eq 'LocalWindows') {
            $systemDrive = [char](Get-SystemDriveLetter).Chars(0)
            $registryDirs = Get-ChildItem -Path "$($systemDrive):\etc\containerd\certs.d\" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
        }
        else {
            $session = $null
            try {
                $session = Open-RemoteSession -VmName $nodeInfo.Name -VmPwd (Get-DefaultTempPwd) -NoLog

                $registryDirs = Invoke-Command -Session $session -ScriptBlock {
                    $targetPath = "$($env:SystemDrive)\etc\containerd\certs.d\"
                    if (-not (Test-Path -Path $targetPath)) {
                        return @()
                    }

                    $dirs = Get-ChildItem -Path $targetPath -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                    if ($null -eq $dirs) {
                        return @()
                    }

                    return @($dirs)
                }
            }
            catch {
                Write-Log "[Registry] Failed to query remote Windows node '$($nodeInfo.Name)': $($_.Exception.Message)" -Console
                continue
            }
            finally {
                if ($null -ne $session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                }
            }
        }

        if ($registryDirs -and $registryDirs.Count -gt 0) {
            foreach ($registryDir in $registryDirs) {
                Write-Log " - $registryDir" -Console
            }
        }
        else {
            Write-Log " (no custom registries configured)" -Console
        }
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
