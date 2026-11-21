# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Gathers network information of the host.

.DESCRIPTION
Gathers networking details such HNS network stack and vfprules.

.EXAMPLE
# Outputs addons status information to default output stream as is
PS> .\network_dump.ps1 -DumpDir 'c:\var\log' -SwitchName 'L2Bridge'
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Dumpfile directory. Default: <installation drive letter>:\var\log')]
    [string]$DumpDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Name of the switch to dump. Default: L2Bridge')]
    [string]$SwitchName = 'L2Bridge'
)


$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
Import-Module $infraModule, $nodeModule

$lineBreak = '**********************************************************************************************************************'

if ($DumpDir -eq '') {
    $DumpDir = Get-k2sLogDirectory
}

Write-Log "Gathering network configuration.." -Console
$networkOutfile = Join-Path $DumpDir 'network.txt'

# Network Interface Information
Get-NetIPInterface -IncludeAllCompartments | Sort-Object InterfaceMetric | Out-String `
| Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "Network Interface Information" -Separator $lineBreak

# IP Address and Compartments
ipconfig /all | Out-String | Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "IP addresses" -Separator $lineBreak

ipconfig /allcompartments | Out-String | Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "IP compartments" -Separator $lineBreak

# Windows routes
route print | Out-String | Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "route print" -Separator $lineBreak

Get-NetConnectionProfile | Out-String | Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "Get-NetConnectionProfile" -Separator $lineBreak

Get-NetRoute -IncludeAllCompartments | Sort-Object RouteMetric | Out-String `
| Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "Get-NetRoute" -Separator $lineBreak

Get-NetNeighbor -IncludeAllCompartments | Sort-Object IPAddress | Out-String `
| Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "Get-NetNeighbour" -Separator $lineBreak

arp -a | Out-String | Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "arp -a" -Separator $lineBreak

# VM Switch Dump
$nmsScrubFile = Join-Path $DumpDir "nmscrub.txt"
$nvspInfoFile = Join-Path $DumpDir "nvspinfo.txt"
nmscrub -a -n -t -w | Out-String | Write-OutputIntoDumpFile -DumpFilePath $nmsScrubFile -Description "nmscrub -a -n -t -w "
nvspinfo -a -i -h -D -p -d -m -q | Out-String | Write-OutputIntoDumpFile -DumpFilePath $nvspInfoFile -Description "nmscrub -a -n -t -w "

# Service status
$serviceStatusFile = Join-Path $DumpDir "servicestatus.txt"
sc.exe queryex | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe queryex'
sc.exe qc hns | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc hns'
sc.exe qc vfpext | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc vfpext'
sc.exe qc dnscache | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc dnscache'
sc.exe qc iphlpsvc | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc iphlpsvc'
sc.exe qc BFE | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc BFE'
sc.exe qc Dhcp | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc Dhcp'
sc.exe qc hvsics | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc hvsics'
sc.exe qc NetSetupSvc | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc NetSetupSvc'
sc.exe qc mpssvc | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc mpssvc'
sc.exe qc nvagent | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc nvagent'
sc.exe qc nsi | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc nsi'
sc.exe qc vmcompute | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc vmcompute'
sc.exe qc SharedAccess | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc ShareAccess'
sc.exe qc CmService | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc CmService'
sc.exe qc vmms | Out-String | Write-OutputIntoDumpFile -DumpFilePath $serviceStatusFile -Description 'sc.exe qc vmms'

# Firewal Rules
$firewallRulesFile = Join-Path $DumpDir "firewallrules.txt"
Get-NetFirewallRule -PolicyStore ActiveStore | Out-String | Write-OutputIntoDumpFile -DumpFilePath $firewallRulesFile -Description "Firewall Rules"

# excluded port ranges
$excludedPortRangeFile = Join-Path $DumpDir "excludedportrange.txt"
netsh int ipv4 sh excludedportrange TCP | Out-String | Write-OutputIntoDumpFile -DumpFilePath $excludedPortRangeFile -Description "Excluded Port Range TCP"
netsh int ipv4 sh excludedportrange UDP | Out-String | Write-OutputIntoDumpFile -DumpFilePath $excludedPortRangeFile -Description "Excluded Port Range UDP"

# TCP connections
$tcpconnectionsFile = Join-Path $DumpDir "tcpconnections.txt"
netsh int ipv4 sh tcpconnections | Out-String | Write-OutputIntoDumpFile -DumpFilePath $tcpconnectionsFile -Description "TCP Connections"

# Dynamic Port ranges
$dynamicPortRangesFile = Join-Path $DumpDir "dynamicportrange.txt"
netsh int ipv4 sh dynamicportrange TCP | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dynamicPortRangesFile -Description "Dynamic Port Range TCP"
netsh int ipv4 sh dynamicportrange UDP | Out-String | Write-OutputIntoDumpFile -DumpFilePath $dynamicPortRangesFile -Description "Dynamic Port Range UDP"

# VFP Dump
$vfpCtrlExe = 'vfpctrl.exe'
$vfpDumpFile = Join-Path $DumpDir 'vfprules.txt'
$portsFile = Join-Path $DumpDir 'ports.txt'
$ports = Get-VfpPorts -SwitchName $switchName
$ports | Select-Object 'Port name', 'Mac Address', 'PortId', 'Switch Name' | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "VFP Ports"

foreach ($port in $ports) {
	$portGuid = $port.'Port name'
	"Policy for port Name: $portGuid" | Out-File -Append -FilePath $vfpDumpFile -Encoding UTF8
	& $vfpCtrlExe /list-space /port $portGuid | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "$vfpCtrlExe /list-space /port $portGuid"
	& $vfpCtrlExe /list-mapping /port $portGuid | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "$vfpCtrlExe /list-mapping /port $portGuid"
	& $vfpCtrlExe /list-rule /port $portGuid | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "$vfpCtrlExe /list-rule /port $portGuid"
    & $vfpCtrlExe /port $portGuid /get-rule-counter | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "$vfpCtrlExe /port $portGuid /get-rule-counter"
	& $vfpCtrlExe /port $portGuid /get-port-state | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "$vfpCtrlExe /port $portGuid /get-port-state"
	& $vfpCtrlExe /port $portGuid /list-nat-range | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "$vfpCtrlExe /port $portGuid /list-nat-range"
    & $vfpCtrlExe /port $portGuid /get-flow-stats | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "$vfpCtrlExe /port $portGuid /get-flow-stats"
    & $vfpCtrlExe /port $portGuid /get-port-counter | Out-String | Write-OutputIntoDumpFile -DumpFilePath $portsFile -Description "$vfpCtrlExe /port $portGuid /get-port-counter"
    if (!$switchDumpSuccess) {
        & $vfpCtrlExe /switch $port.'Switch Name' /get-switch-forwarding-settings | Out-Null
        if ($?) {
            $switchDumpSuccess = $true
            & $vfpCtrlExe /switch $port.'Switch Name' /get-switch-forwarding-settings | Out-String | Write-OutputIntoDumpFile -DumpFilePath $vfpDumpFile -Description "$vfpCtrlExe /switch $port.'Switch Name' /get-switch-forwarding-settings"
        }
    }
    "`n###########################################################################`n" | Out-File -Append -FilePath $vfpDumpFile -Encoding UTF8
}


# HNS Dump
$hnsdiagExists = Get-Command hnsdiag.exe -ErrorAction SilentlyContinue
if ($hnsdiagExists) {
    $hnsDiagFile = Join-Path $DumpDir "hnsdiag.txt"
    hnsdiag list all -d | Out-String | Write-OutputIntoDumpFile -DumpFilePath $hnsDiagFile -Description "hnsdiag list all -d"
    hcsdiag list | Out-String | Write-OutputIntoDumpFile -DumpFilePath $hnsDiagFile -Description "hcsdiag list"
}

# Linux VM Networking
$isLinuxVMRunning = Get-IsControlPlaneRunning
if ($isLinuxVMRunning) {
    (Invoke-CmdOnControlPlaneViaSSHKey "sudo ifconfig").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "KubeMaster~$ sudo ifconfig" -Separator $lineBreak
    (Invoke-CmdOnControlPlaneViaSSHKey "ip route").Output | Out-String | Write-OutputIntoDumpFile -DumpFilePath $networkOutfile -Description "KubeMaster~$ ip route" -Separator $lineBreak
}

