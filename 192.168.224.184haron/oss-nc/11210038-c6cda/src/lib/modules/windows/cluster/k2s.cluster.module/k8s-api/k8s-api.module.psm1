# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$formattingModule = "$PSScriptRoot/formatting/formatting.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\path\path.module.psm1"

Import-Module $formattingModule, $logModule, $pathModule

class Pod {
    [string]$Status
    [string]$Namespace
    [string]$Name
    [string]$Ready
    [string]$Restarts
    [string]$Age
    [string]$Ip
    [string]$Node
    [bool]$IsRunning
}

$supportedApiVersion = 'v1'

function Get-Now {
    return [datetime]::UtcNow
}

function Confirm-ApiVersionIsValid {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Version = $(throw 'API version not specified')
    )    

    Write-Log "Validating Version='$Version'.."

    if ($Version -ne $supportedApiVersion) {
        throw "expected K8s API version '$supportedApiVersion', but got '$($Version)'"
    }

    Write-Log 'Version valid'
}

function Get-Age {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Timestamp
    )    

    Write-Log "Converting '$Timestamp' to age.."

    [datetime]$now = Get-Now
    [datetime]$then = ([System.DateTimeOffset]::Parse($Timestamp)).UtcDateTime

    if ($then -gt $now) {
        throw "timestamp cannot be in the future: '$Timestamp'"
    }

    $duration = $now - $then

    $result = (Convert-ToAgeString -Duration $duration)

    Write-Log "returning '$result'"

    return $result
}

function Get-NodeStatus {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject[]]
        $Conditions
    )    

    Write-Log 'Extracting Node status from JSON..'

    $status = 'Unknown'
    $isReady = $false

    foreach ($condition in $Conditions) {
        if ($condition.status -eq 'True') {
            Write-Log 'Current Node condition found'

            $status = $condition.type

            Write-Log "Node status='$status'"

            if ($status -eq 'Ready') {
                Write-Log 'Node is ready'
                $isReady = $true
            }
            else {
                Write-Log 'Node not ready'
            }
            break
        }
    }

    $result = @{StatusText = $status; IsReady = $isReady }

    Write-Log "returning StatusText='$($result.StatusText)' and IsReady='$($result.IsReady)'"

    return $result
}

function Get-NodeRole {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]
        $Labels
    )    

    Write-Log 'Extracting Node role from JSON..'

    foreach ($label in $Labels.PSObject.Properties) {
        if ($label.Name -eq 'node-role.kubernetes.io/control-plane') {
            Write-Log "Role 'control-plane' found"

            return 'control-plane'
        }

        if ($label.Name -eq 'kubernetes.io/role' -and $label.Value -eq 'worker') {
            Write-Log "Role 'worker' found"

            return 'worker'
        }
    }

    Write-Log ' No role found'

    return 'Unknown'
}

function Get-NodeInternalIp {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject[]]
        $Addresses
    )   

    Write-Log 'Extracting Node internal IP from JSON..'

    foreach ($address in $Addresses) {
        Write-Log "Checking address '$address'.."

        if ($address.type -eq 'InternalIP') {
            Write-Log "Internal IP '$($address.address)' found"

            return $address.address
        }
    }

    Write-Log 'No internal IP found'

    return '<none>'
}

function Get-NodeCapacity {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]
        $Capacity
    )   

    Write-Log 'Extracting Node capacity from JSON..'

    [pscustomobject]@{
        CPU     = $Capacity.cpu;
        Storage = $Capacity.'ephemeral-storage';
        Memory  = $Capacity.memory
    }
}

function Get-Node {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]
        $JsonNode = $(throw 'JSON node not specified')
    )   

    Write-Log 'Extracting Node info from JSON..'

    $status = Get-NodeStatus -Conditions $JsonNode.status.conditions
    $role = Get-NodeRole -Labels $JsonNode.metadata.labels
    $age = Get-Age -Timestamp $($JsonNode.metadata.creationTimestamp).ToString()
    $internalIp = Get-NodeInternalIp -Addresses $JsonNode.status.addresses
    $capacity = Get-NodeCapacity -Capacity $JsonNode.status.capacity

    [pscustomobject]@{
        Status           = $status.StatusText
        Name             = $JsonNode.metadata.name
        Role             = $role
        Age              = $age
        KubeletVersion   = $JsonNode.status.nodeInfo.kubeletVersion
        InternalIp       = $internalIp
        OsImage          = $JsonNode.status.nodeInfo.osImage
        KernelVersion    = $JsonNode.status.nodeInfo.kernelVersion
        ContainerRuntime = $JsonNode.status.nodeInfo.containerRuntimeVersion
        IsReady          = $status.IsReady
        Capacity         = $capacity
    }
}

function Get-PodStatus {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]
        $JsonNode = $(throw 'JSON node not specified')
    )    

    Write-Log 'Extracting Pod status from JSON..'

    $status = 'Running'
    $restarts = 0
    $readyCount = 0
    $isRunning = $true

    if ($JsonNode.status.containerStatuses.Count -gt 0) {
        Write-Log "'$($JsonNode.status.containerStatuses.Count)' Container statuses found"

        foreach ($containerStatus in $JsonNode.status.containerStatuses) {
            Write-Log "Checking status for Container '$($containerStatus.name)'.."

            $restarts = ($restarts + $containerStatus.restartCount)

            Write-Log "Detected '$restarts' restarts"

            if ($containerStatus.ready -eq $true) {
                Write-Log 'Container is ready'

                $readyCount = ($readyCount + 1)
            }

            if ($containerStatus.state.PSobject.Properties.Name.Contains('running') -ne $true) {
                Write-Log 'Container not running'

                $isRunning = $false
                $status = $containerStatus.state.PSobject.Properties.Value.reason
            }
        }
    }
    else {
        $isRunning = $false
        $status = $JsonNode.status.phase

        Write-Log "Pod not running, phase='$status'"
    }

    $ready = "$($readyCount)/$($JsonNode.spec.containers.Count)"

    $result = @{StatusText = $status; IsRunning = $isRunning; Restarts = $restarts; Ready = $ready }

    Write-Log "returning StatusText='$($result.StatusText)', IsRunning='$($result.IsRunning)', Restarts='$($result.Restarts)' and Ready='$($result.Ready)'"

    return $result
}

function Get-Pod {
    param (
        [Parameter(Mandatory = $false)]
        [pscustomobject]
        $JsonNode = $(throw 'JSON node not specified')
    )    

    Write-Log 'Extracting Pod info from JSON..'

    $status = Get-PodStatus -JsonNode $JsonNode
    $age = Get-Age -Timestamp $($JsonNode.metadata.creationTimestamp).ToString()

    return New-Object Pod -Property @{
        Status    = $status.StatusText;
        Namespace = $JsonNode.metadata.namespace;
        Name      = $JsonNode.metadata.name;
        Ready     = $status.Ready;
        Restarts  = $status.Restarts;
        Age       = $age;
        Ip        = $JsonNode.status.podIP;
        Node      = $JsonNode.spec.nodeName;
        IsRunning = $status.IsRunning
    }
}

function Get-PodsForNamespace {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Namespace = $(throw 'Namespace not specified')
    )

    $params = 'get', 'pod', '-n', $Namespace, '-o', 'json'

    Write-Log "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }

    $obj = $result.Output | Out-String | ConvertFrom-Json

    Confirm-ApiVersionIsValid -Version $obj.apiVersion

    Write-Log "Found '$($obj.items.Count)' Pod nodes"

    $pods = [System.Collections.ArrayList]@()

    foreach ($item in $obj.items) {
        $pod = Get-Pod -JsonNode $item

        Write-Log "Pod '$($pod.Name)' found"

        $pods.Add($pod) | Out-Null
    }

    return $pods
}

function Get-PodsWithPersistentVolumeClaims {
    $result = [System.Collections.ArrayList]@()

    $params = @()
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        $params = 'get', 'pods', '-A', "-o=jsonpath=[{range .items[*]}{`"{name:%`"}{.metadata.name}%, volumes:[{range .spec.volumes[?(@.persistentVolumeClaim)]}%{.persistentVolumeClaim.claimName}%,{end}]{`"}`"},{end}]"
    }
    else {
        $params = 'get', 'pods', '-A', "-o=jsonpath=[{range .items[*]}{\`"{name:%\`"}{.metadata.name}%, volumes:[{range .spec.volumes[?(@.persistentVolumeClaim)]}%{.persistentVolumeClaim.claimName}%,{end}]{\`"}\`"},{end}]"
    }

    Write-Information "Invoking kubectl with '$params'.."

    $invokeResult = Invoke-Kubectl -Params $params
    if ($invokeResult.Success -ne $true) {
        Write-Information "Error occurred while invoking kubectl: $($invokeResult.Output)"
        return
    }

    $pods = $invokeResult.Output -replace ',%%,', '' -replace ',]', ']' -replace '%', '"' | ConvertFrom-Json

    foreach ($pod in $pods) {
        if ($pod.volumes.Count -gt 0) {
            $result.Add($pod) > $null
        }
    }

    return $result
}

function Get-AllPersistentVolumeClaims {
    $params = 'get', 'pvc', '-A', '-o', 'json'

    Write-Information "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        Write-Information "Error occurred while invoking kubectl: $($result.Output)"
        return
    }

    return ($result.Output | Out-String | ConvertFrom-Json).items
}

<#
.Synopsis
Prints the given nodes

.Description
Prints the given nodes as table

.PARAMETER Nodes
The nodes to print

.Example
Write-Nodes -Nodes <nodes>
#>
function Write-Nodes {
    param (
        [Parameter(Mandatory = $false)]
        [System.Collections.ArrayList]$Nodes = $(throw 'Please specify the nodes list.')
    )
    $defaultColor = [console]::ForegroundColor
    $Nodes | Format-Table -AutoSize @{L = '  '; E = {
            if ($_.IsReady -eq $true) {
                [System.Char]::ConvertFromUtf32(0x00002705)
            }
            else {
                [System.Char]::ConvertFromUtf32(0x0000274C)
            }
        }
    },
    @{L = 'STATUS'; E = { $_.Status } },
    @{L = 'NAME'; E = { $_.Name } },
    @{L = 'ROLE'; E = { $_.Role } },
    @{L = 'AGE'; E = { $_.Age } },
    @{L = 'VERSION'; E = { $_.KubeletVersion } },
    @{L = 'INTERNAL-IP'; E = { $_.InternalIp } },
    @{L = 'OS-IMAGE'; E = { $_.OsImage } },
    @{L = 'KERNEL-VERSION'; E = { $_.KernelVersion } },
    @{L = 'CONTAINER-RUNTIME'; E = { $_.ContainerRuntime } }

    $isANodeNotReady = $Nodes.Where({ $_.IsReady -ne $true }, 'First').Count -gt 0

    if ($isANodeNotReady -eq $true) {
        Write-Warning 'Some nodes are not ready'
    }
    else {
        [console]::ForegroundColor = 'green';
        Write-Output 'All nodes are ready'
        [console]::ForegroundColor = $defaultColor;
    }
}

<#
 .Synopsis
  Prints the given pods

 .Description
  Prints the given pods as table

 .PARAMETER Nodes
  The pods to print

 .Example
  Write-Pods -Pods <pods>
#>
function Write-Pods {
    param (
        [Parameter(Mandatory = $false)]
        [System.Collections.ArrayList]$Pods = $(throw 'Please specify the pods list.')
    )
    $defaultColor = [console]::ForegroundColor
    $Pods | Format-Table -AutoSize @{L = '  '; E = {
            if ($_.IsRunning -eq $true) {
                [System.Char]::ConvertFromUtf32(0x00002705)
            }
            else {
                [System.Char]::ConvertFromUtf32(0x0000274C)
            }
        }
    },
    @{L = 'STATUS'; E = { $_.Status } },
    @{L = 'NAMESPACE'; E = { $_.Namespace } },
    @{L = 'NAME'; E = { $_.Name } },
    @{L = 'READY'; E = { $_.Ready } },
    @{L = 'RESTARTS'; E = { $_.Restarts } },
    @{L = 'AGE'; E = { $_.Age } } ,
    @{L = 'IP'; E = { $_.Ip } } ,
    @{L = 'NODE'; E = { $_.Node } }

    $isAPodNotRunning = $Pods.Where({ $_.IsRunning -ne $true }, 'First').Count -gt 0

    if ($isAPodNotRunning -eq $true) {
        Write-Warning 'Some essential pods are not running'
    }
    else {
        [console]::ForegroundColor = 'green';
        Write-Output 'All essential pods are running'
        [console]::ForegroundColor = $defaultColor;
    }
}

<#
.SYNOPSIS
Gets the K8s nodes

.DESCRIPTION
Gets the K8s nodes info for the current K8s context

.OUTPUTS
An array of Node objects

.EXAMPLE
Get-Nodes
#>
function Get-Nodes {    

    $params = 'get', 'nodes', '-o', 'json'

    Write-Log "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }

    $obj = $result.Output | Out-String | ConvertFrom-Json

    Confirm-ApiVersionIsValid -Version $obj.apiVersion

    Write-Log "Found '$($obj.items.Count)' Node nodes"

    $nodes = [System.Collections.ArrayList]@()

    foreach ($item in $obj.items) {
        $node = Get-Node -JsonNode $item

        Write-Log "Node '$($node.Name)' found"

        $nodes.Add($node) | Out-Null
    }

    return $nodes
}

<#
.SYNOPSIS
Gets the K8s system pods

.DESCRIPTION
Gets the K8s system pods info for the current K8s context, i.e. pods for flannel and kube-system

.OUTPUTS
An array of Pod objects

.EXAMPLE
Get-SystemPods
#>
function Get-SystemPods {    

    Write-Log 'Getting system Pods..'

    $pods = [System.Collections.ArrayList]@()

    Get-PodsForNamespace -Namespace 'kube-flannel' | ForEach-Object { $pods.Add($_) | Out-Null }
    Get-PodsForNamespace -Namespace 'kube-system' | ForEach-Object { $pods.Add($_) | Out-Null }

    Write-Log "Found '$($pods.Count)' system Pods"

    return $pods
}

function Get-K8sVersionInfo {    

    $params = 'version', '-o', 'json'

    Write-Log "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }

    $obj = $result.Output | Out-String | ConvertFrom-Json

    $result = @{K8sServerVersion = $obj.serverVersion.gitVersion; K8sClientVersion = $obj.clientVersion.gitVersion }

    Write-Log "returning K8sServerVersion='$($result.K8sServerVersion)' and K8sClientVersion='$($result.K8sClientVersion)'"

    return $result
}

function Add-Secret {
    param (
        [parameter(Mandatory = $false)]
        [string]$Name = $(throw 'Name not specified'),
        [parameter(Mandatory = $false)]
        [string]$Namespace = $(throw 'Namespace not specified'),
        [parameter(Mandatory = $false)]
        [array]$Literals = $(throw 'Literals not specified')
    )
    Write-Output "Adding secret '$Name' to namespace '$Namespace'.."

    $params = 'get', 'secret', $Name, '-n', $Namespace, '--ignore-not-found'

    Write-Output "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }

    if ($null -ne $result.Output) {
        Write-Output "Secret '$Name' already existing in namespace '$Namespace', skipping."
        return
    }

    Write-Output "Secret '$Name' not found in namespace '$Namespace', creating it.."

    $params = 'create', 'secret', 'generic', "$Name", '-n', $Namespace

    Write-Output "Invoking kubectl with '$params <--from-literal credentials truncated>'.."

    foreach ($literal in $Literals) {
        $params += '--from-literal'
        $params += $literal
    }

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        throw $result.Output
    }

    Write-Output "Secret '$Name' created in namespace '$Namespace'."
}

function Remove-Secret {
    param (
        [parameter(Mandatory = $false)]
        [string]$Name = $(throw 'Name not specified'),
        [parameter(Mandatory = $false)]
        [string]$Namespace = $(throw 'Namespace not specified')
    )
    Write-Output "Removing secret '$Name' from namespace '$Namespace'.."

    $params = 'delete', 'secret', $Name, '-n', $Namespace, '--ignore-not-found'

    Write-Output "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        Write-Warning " Error occurred while invoking kubectl: $($result.Output)"
        return
    }

    Write-Output "Secret '$Name' deleted in namespace '$Namespace'."
}

function Remove-PersistentVolumeClaim {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $StorageClass = $(throw 'StorageClass not specified'),
        [Parameter(Mandatory = $false)]
        [pscustomobject]
        $Pvc = $(throw 'PVC not specified'),
        [Parameter(Mandatory = $false)]
        [object]
        $PodsWithPersistentVolumeClaims = $(throw 'Pods not specified')
    )
    Write-Output "      Removing PVC '$($Pvc.metadata.name)' in namespace '$($Pvc.metadata.namespace)'.."

    foreach ($pod in $PodsWithPersistentVolumeClaims) {
        foreach ($volume in $pod.volumes) {
            if ($volume -eq $Pvc.metadata.name) {
                throw "Pod '$($pod.name)' is still using PVC '$($Pvc.metadata.name)' in namespace '$($Pvc.metadata.namespace)'. Delete all workloads using the SC '$StorageClass' and try again."
            }
        }
    }

    $params = 'delete', 'pvc', $Pvc.metadata.name, '-n', $Pvc.metadata.namespace

    Write-Output "Invoking kubectl with '$params'.."

    $result = Invoke-Kubectl -Params $params
    if ($result.Success -ne $true) {
        Write-Warning " Error occurred while invoking kubectl: $($result.Output)"
        return
    }

    Write-Output "      PVC '$($Pvc.metadata.name)' deleted from namespace '$($Pvc.metadata.namespace)'."
}

function Remove-PersistentVolumeClaimsForStorageClass {
    param (
        [parameter(Mandatory = $false)]
        [string]$StorageClass = $(throw 'StorageClass not specified')
    )
    Write-Output "Deleting all PVCs related to the StorageClass '$StorageClass'.."

    $podsWithPersistentVolumeClaims = Get-PodsWithPersistentVolumeClaims

    if ($podsWithPersistentVolumeClaims -is [array]) {
        Write-Output "  Found $($podsWithPersistentVolumeClaims.Count) Pods across all namespaces with PersistentVolumeClaims"
    }
    elseif ($null -eq $podsWithPersistentVolumeClaims) {
        Write-Output '  No Pods with PersistentVolumeClaims found across all namespaces'
    }
    elseif ($podsWithPersistentVolumeClaims -is [pscustomobject]) {
        Write-Output '  Found one Pod across all namespaces with PersistentVolumeClaims'
    }
    else {
        throw 'invalid return type'
    }

    $allPersistentVolumeClaims = Get-AllPersistentVolumeClaims

    $count = 0

    foreach ($pvc in $allPersistentVolumeClaims) {
        if ($pvc.spec.storageClassName -eq $StorageClass) {
            Remove-PersistentVolumeClaim -StorageClass $StorageClass -Pvc $pvc -PodsWithPersistentVolumeClaims $podsWithPersistentVolumeClaims
            $count += 1
        }
    }

    if ($count -eq 0) {
        Write-Output "  No PVCs related to StorageClass '$StorageClass' found."
    }
}

<#
.SYNOPSIS
Invokes kubectl

.DESCRIPTION
Invokes kubectl with optional parameters and returns a result object with properties "Success"and "Output" also containing the error stream

.PARAMETER Params
Arbitrary parameter array (1...*)

.EXAMPLE
# To display the kubectl version info:
PS> Invoke-Kubectl -Params "version","--short"
#>
function Invoke-Kubectl {
    param (
        [Parameter(Mandatory = $false)]
        [array]
        $Params
    )
    $kubeToolsPath = Get-KubeToolsPath
    $output = &"$kubeToolsPath\kubectl.exe" $params 2>&1

    return [pscustomobject]@{ Success = ($LASTEXITCODE -eq 0); Output = $output }
}

function Wait-ForPodCondition {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Label = $(throw 'Label not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Namespace = 'default',
        [Parameter(Mandatory = $false)]
        [ValidateSet('Ready', 'Deleted')]
        [string]
        $Condition = 'Ready',
        [Parameter(Mandatory = $false)]
        [int]
        $TimeoutSeconds = 60
    )

    if ($Condition -eq 'Ready') {
        $conditionParam = '--for=condition=ready'
    }

    if ($Condition -eq 'Deleted') {
        $conditionParam = '--for=delete'
    }

    do {
        $params = 'wait', 'pod', '-l', $Label, '-n', $Namespace, $conditionParam, "--timeout=$($TimeoutSeconds)s"
        Write-Information "Invoking kubectl with '$params'.."
        $result = Invoke-Kubectl -Params $params
        
        # Check if we actually got pods ready, not just "no resources found"
        if ($result.Success -and $result.Output -match '(condition met|condition satisfied)') {
            # Pods found and condition met
            return $true
        }
        
        # If Success=true but no proper message, assume it worked (for backward compatibility with tests/mocks)
        if ($result.Success -and -not $result.Output) {
            return $true
        }
        
        if ($result.Output -match 'timed out waiting for the condition') {
            # Real timeout - pods exist but didn't become ready
            throw "Timeout waiting for pods with label '$Label' in namespace '$Namespace' to become $Condition`: $($result.Output)"
        }
        
        if ($result.Output -match 'no matching resources found') {
            # No pods found yet, keep waiting
            Write-Information "No pods found yet with label '$Label' in namespace '$Namespace', waiting 2s..."
            Start-Sleep 2
            $TimeoutSeconds = $TimeoutSeconds - 2
            continue
        }
        
        if (-not $result.Success) {
            # Some other error - check if we should retry or fail immediately
            if ($TimeoutSeconds -le 2) {
                # No more time for retry, throw the error
                throw $result.Output
            }
            # Retry with backoff
            Write-Information "kubectl wait failed: $($result.Output). Waiting 2s..."
            Start-Sleep 2
            $TimeoutSeconds = $TimeoutSeconds - 2
            continue
        }
        
        # Success with output but no expected message - assume it worked (backward compatibility)
        if ($result.Success) {
            Write-Information "kubectl wait succeeded with output: $($result.Output)"
            return $true
        }
        
        # Should not reach here, but break to avoid infinite loop
        Write-Information "Unexpected kubectl output: $($result.Output)"
        break
        
    } while ($TimeoutSeconds -gt 0)

    # Final validation
    if ($result.Success) {
        return $true
    }
    
    if ($TimeoutSeconds -le 0) {
        throw "Timeout expired waiting for pods with label '$Label' in namespace '$Namespace' to become $Condition"
    }

    throw "Failed to wait for pods with label '$Label' in namespace '$Namespace': $($result.Output)"
}

function Wait-ForJobCondition {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Label = $(throw 'Label not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Namespace = 'default',
        [Parameter(Mandatory = $false)]
        [ValidateSet('Complete')]
        [string]
        $Condition = 'Complete',
        [Parameter(Mandatory = $false)]
        [int]
        $TimeoutSeconds = 30
    )

    if ($Condition -eq 'Complete') {
        $conditionParam = '--for=condition=complete'
    }

    do {
        $params = 'wait', 'job', '-l', $Label, '-n', $Namespace, $conditionParam, "--timeout=$($TimeoutSeconds)s"
        Write-Information "Invoking kubectl with '$params'.."
        $result = Invoke-Kubectl -Params $params

        if ($result.Success -or $result.Output -match 'timed out') {
            break
        }

        Write-Information 'Resource not existing yet, waiting 2s...'
        Start-Sleep 2
        $TimeoutSeconds = $TimeoutSeconds - 2
    } while ($TimeoutSeconds -gt 0)

    if ($result.Success -ne $true) {
        throw $result.Output
    }

    return $true
}

<#
.SYNOPSIS
Invokes helm

.DESCRIPTION
Invokes helm with optional parameters and returns a result object with properties "Success"and "Output" also containing the error stream

.PARAMETER Params
Arbitrary parameter array (1...*)

.EXAMPLE
# To display the helm version info:
PS> Invoke-Helm -Params "version","--short"
#>
function Invoke-Helm {
    param (
        [Parameter(Mandatory = $false)]
        [array]
        $Params
    )
    $kubeBinPath = Get-KubeBinPath

    $originalOutputEncoding = [Console]::OutputEncoding
    try {
        # Helm emits UTF-8 notes; switch decoding temporarily so PowerShell 5.1 does not mojibake redirected output.
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $output = &"$kubeBinPath\helm.exe" $params 2>&1
    }
    finally {
        [Console]::OutputEncoding = $originalOutputEncoding
    }

    return [pscustomobject]@{ Success = ($LASTEXITCODE -eq 0); Output = $output }
}

Export-ModuleMember -Function Get-Nodes, Get-SystemPods, Write-Nodes, Write-Pods, Get-K8sVersionInfo, Add-Secret,
Remove-Secret, Remove-PersistentVolumeClaimsForStorageClass, Invoke-Kubectl, Wait-ForPodCondition, Wait-ForJobCondition, Invoke-Helm
