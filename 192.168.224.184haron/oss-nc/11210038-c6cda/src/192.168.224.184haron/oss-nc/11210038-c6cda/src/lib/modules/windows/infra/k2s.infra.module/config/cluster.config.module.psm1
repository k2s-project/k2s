# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0


$pathModule = "$PSScriptRoot\..\path\path.module.psm1"
$configModule = "$PSScriptRoot\config.module.psm1"
$fileModule = "$PSScriptRoot\file.module.psm1"
Import-Module $pathModule, $configModule, $fileModule

$k2sConfigDir = Get-K2sConfigDir
$clusterDescriptorFile = "$k2sConfigDir\cluster.json"

function Get-ClusterDescriptorFilePath {
    return $clusterDescriptorFile
}


<#
$nodeParams = @{
    Name = 'minatoav"
    IpAddress = '172.19.1.104'
    UserName = 'remote'
    NodeType = 'HOST'
    Role = 'worker'
    OS = 'linux'
}
Add-NodeConfig @nodeParams

Supported NodeTypes:
- HOST          -> Baremetal machine
- VM-EXISTING   -> Existing VM from the consumer of k2s
#>
function Add-NodeConfig {
    Param (
        [string] $Name,
        [string] $IpAddress,
        [string] $Username,
        [string] $NodeType,
        [string] $Role,
        [string] $OS,
        [string] $Proxy,
        [string] $PodCIDR,
        [string] $VmName  # Hyper-V VM name (for VM-EXISTING nodes)
    )
    $clusterFilePath = Get-ClusterDescriptorFilePath
    $json = Get-JsonContent -FilePath $clusterFilePath

    if (-Not $json) {
        $json = @{ nodes = @() }
    } elseif (-Not $json.nodes) {
        $json.nodes = @()
    } else {
        # Ensure nodes is always an array (single object becomes array of one)
        $json.nodes = @($json.nodes)
    }

    $existingNode = $json.nodes | Where-Object { $_.Name -eq $Name }
    if ($existingNode) {
        throw "A node configuration with the name '$Name' already exists."
    }

    $newNode = @{
        Name      = $Name
        IpAddress = $IpAddress
        Username  = $Username
        NodeType  = $NodeType
        Role      = $Role
        OS        = $OS
        Proxy     = $Proxy
        PodCIDR   = $PodCIDR
    }
    
    # Add VmName for VM-EXISTING nodes (needed to find VM during cluster start)
    if ($VmName) {
        $newNode.VmName = $VmName
    }
    
    $json.nodes += $newNode
    Save-JsonContent -JsonObject $json -FilePath $clusterFilePath
    Write-Log "Node '$Name' configuration added successfully."
}

function Remove-NodeConfig {
    param (
        [string]$Name
    )
    $clusterFilePath = Get-ClusterDescriptorFilePath
    $json = Get-JsonContent -FilePath $clusterFilePath
    if (-Not $json) { return }
    if (-Not $json.nodes) { return }
    
    # Ensure nodes is always an array
    $json.nodes = @($json.nodes)

    $nodeToRemove = $json.nodes | Where-Object { $_.Name -eq $Name }
    if (-Not $nodeToRemove) {
        Write-Log "No node configuration found with the name '$Name'."
        return
    }

    $json.nodes = @($json.nodes | Where-Object { $_.Name -ne $Name })

    Save-JsonContent -JsonObject $json -FilePath $clusterFilePath
    Write-Log "Node '$Name' configuration removed successfully."
}

function Get-NodeConfig {
    param (
        [string]$NodeName
    )
    $clusterFilePath = Get-ClusterDescriptorFilePath
    $json = Get-JsonContent -FilePath $clusterFilePath
    if (-Not $json) { return $null }
    if (-Not $json.nodes) { return $null }
    
    # Ensure nodes is always an array
    $nodes = @($json.nodes)

    $node = $nodes | Where-Object { $_.Name -eq $NodeName }
    if (-Not $node) {
        Write-Log "No node configuration found with the name '$NodeName'."
        return $null
    }

    return $node
}

<#
Update-NodeConfig -Name "gtry22c" -Updates @{
    Role = "master"
    IpAddress = "172.19.1.104"
    OS = "windows"
}
#>
function Update-NodeConfig {
    param (
        [string]$Name,
        [hashtable]$Updates
    )
    $clusterFilePath = Get-ClusterDescriptorFilePath
    $json = Get-JsonContent -FilePath $clusterFilePath
    if (-Not $json) { return }
    if (-Not $json.nodes) { return }
    
    # Ensure nodes is always an array
    $json.nodes = @($json.nodes)

    $nodeToUpdate = $json.nodes | Where-Object { $_.Name -eq $Name }
    if (-Not $nodeToUpdate) {
        Write-Log "No node configuration found with the name '$Name'."
        return
    }

    foreach ($key in $Updates.Keys) {
        if ($nodeToUpdate.PSObject.Properties[$key]) {
            $nodeToUpdate.$key = $Updates[$key]
        }
        else {
            Write-Log "Property '$key' does not exist on the node. Skipping."
        }
    }

    Save-JsonContent -JsonObject $json -FilePath $clusterFilePath
    Write-Log "Node '$Name' configuration updated successfully."
}

Export-ModuleMember -Function Add-NodeConfig, Remove-NodeConfig,
Get-NodeConfig, Update-NodeConfig, Get-ClusterDescriptorFilePath
