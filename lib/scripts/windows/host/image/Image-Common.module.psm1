# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"

# -Global ensures functions from these modules are visible to scripts that import this module
Import-Module $infraModule, $clusterModule, $nodeModule -Global

<#
.SYNOPSIS
Tests whether a Kubernetes node is in Ready state.

.DESCRIPTION
Uses kubectl to check if the node is reporting Ready status.
Returns $true if the node is Ready, $false otherwise.
For control-plane and local Windows host, always returns $true (they must be Ready for the cluster to be up).

.PARAMETER NodeName
The name of the node to check.

.PARAMETER Kind
The kind of node (ControlPlane, LinuxWorker, LocalWindows, WindowsWorker).
#>
function Test-NodeReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NodeName,
        [Parameter(Mandatory = $false)]
        [string]$Kind = ''
    )

    # Control-plane and local Windows host are implicitly Ready if we got this far (cluster is running)
    if ($Kind -in @('ControlPlane', 'LocalWindows')) {
        return $true
    }

    try {
        $kubePath = Get-KubePath
        $kubectlExe = "$kubePath\bin\kube\kubectl.exe"
        $nodeStatus = & $kubectlExe get node $NodeName --no-headers 2>&1 | Out-String
        if (-not [string]::IsNullOrWhiteSpace($nodeStatus) -and $nodeStatus -match '\s+Ready(?:\s|,|$)') {
            return $true
        }
    }
    catch {
        Write-Log "[NodeReady] Error checking status for node '$NodeName': $_"
    }

    return $false
}

<#
.SYNOPSIS
Initializes image script runtime (logging + system availability check).

.DESCRIPTION
- Initializes logging with optional console output.
- Checks system availability.
- On structured mode, forwards system error to CLI and returns $false.
- On return-status mode, returns $false instead of exiting the caller.
- On non-structured mode, logs error and exits with code 1.
#>
function Initialize-ImageScriptContext {
    param(
        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs = $false,
        [Parameter(Mandatory = $false)]
        [switch]$EncodeStructuredOutput,
        [Parameter(Mandatory = $false)]
        [switch]$ReturnStatus,
        [Parameter(Mandatory = $false)]
        [string]$MessageType
    )

    Initialize-Logging -ShowLogs:$ShowLogs

    $systemError = Test-SystemAvailability -Structured
    if ($systemError) {
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
            return $false
        }

        Write-Log $systemError.Message -Error
        if ($ReturnStatus) {
            return $false
        }
        exit 1
    }

    return $true
}

<#
.SYNOPSIS
Resolves a node name to its metadata (OS, kind, and connection details).

.DESCRIPTION
Checks in order:
  1. Local Windows host  (matches $env:ComputerName)
  2. Linux control-plane (matches ControlPlaneNodeHostname from setup.json)
  3. Remote node from cluster descriptor (cluster.json)

Returns a hashtable with keys:
  Name      - node name (lowercase)
  OS        - 'linux' | 'windows'
  Kind      - 'ControlPlane' | 'LinuxWorker' | 'LocalWindows' | 'WindowsWorker'
  IpAddress - SSH target IP  (Linux workers only)
  Username  - SSH username   (Linux workers only)
  NodeType  - NodeType value from cluster.json (e.g. 'HOST', 'VM-EXISTING')

Returns $null if the node cannot be resolved.
#>
function Resolve-ImageNode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NodeName
    )

    $nodeLower = $NodeName.ToLower()
    $localWindowsName = $env:ComputerName.ToLower()

    # 1. Local Windows host
    if ($nodeLower -eq $localWindowsName) {
        Write-Log "[ImageNode] '$nodeLower' identified as local Windows host"
        return @{
            Name     = $nodeLower
            OS       = 'windows'
            Kind     = 'LocalWindows'
            NodeType = 'HOST'
        }
    }

    # 2. Linux control-plane
    $setupFilePath = Get-SetupConfigFilePath
    $controlPlaneHostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    if ([string]::IsNullOrWhiteSpace($controlPlaneHostname)) {
        $controlPlaneHostname = 'kubemaster'
    }

    if ($nodeLower -eq $controlPlaneHostname.ToLower()) {
        Write-Log "[ImageNode] '$nodeLower' identified as Linux control-plane"
        return @{
            Name = $nodeLower
            OS   = 'linux'
            Kind = 'ControlPlane'
        }
    }

    # 3. Remote node from cluster descriptor
    $clusterNode = Get-NodeConfig -NodeName $NodeName
    if ($null -eq $clusterNode) {
        Write-Log "[ImageNode] '$NodeName' not found in cluster descriptor"
        return $null
    }

    $nodeOs = "$($clusterNode.OS)".ToLower()

    if ($nodeOs -eq 'linux') {
        if ([string]::IsNullOrWhiteSpace($clusterNode.IpAddress) -or [string]::IsNullOrWhiteSpace($clusterNode.Username)) {
            Write-Log "[ImageNode] '$NodeName' is a Linux worker but IpAddress or Username is missing in cluster descriptor"
            return $null
        }
        Write-Log "[ImageNode] '$nodeLower' identified as Linux worker (IP=$($clusterNode.IpAddress))"
        return @{
            Name      = $nodeLower
            OS        = 'linux'
            Kind      = 'LinuxWorker'
            IpAddress = $clusterNode.IpAddress
            Username  = $clusterNode.Username
            NodeType  = $clusterNode.NodeType
        }
    }

    if ($nodeOs -eq 'windows') {
        Write-Log "[ImageNode] '$nodeLower' identified as Windows worker (NodeType=$($clusterNode.NodeType))"
        return @{
            Name     = $nodeLower
            OS       = 'windows'
            Kind     = 'WindowsWorker'
            NodeType = $clusterNode.NodeType
        }
    }

    Write-Log "[ImageNode] '$NodeName' has unsupported OS '$nodeOs' in cluster descriptor"
    return $null
}

<#
.SYNOPSIS
Returns NodeInfo entries for the default nodes queried when no --node filter is given.

.DESCRIPTION
The default set is: control-plane (Linux) + local Windows host.
Both are resolved via Resolve-ImageNode so the same routing logic applies.
#>
function Get-DefaultNodeInfoList {
    $setupFilePath = Get-SetupConfigFilePath
    $controlPlaneHostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    if ([string]::IsNullOrWhiteSpace($controlPlaneHostname)) {
        $controlPlaneHostname = 'kubemaster'
    }

    $defaultNodes = @(
        (Resolve-ImageNode -NodeName $controlPlaneHostname),
        (Resolve-ImageNode -NodeName $env:ComputerName)
    )

    return @($defaultNodes | Where-Object { $null -ne $_ })
}

<#
.SYNOPSIS
Lists container images on a resolved node by executing the correct command.

.DESCRIPTION
Routes to the matching execution path based on NodeInfo.Kind:

  ControlPlane  → SSH to control-plane  → sudo buildah images
  LinuxWorker   → SSH to worker node    → sudo buildah images
  LocalWindows  → local process         → crictl images
  WindowsWorker → remote session        → crictl images (remote)

Returns an array of ContainerImage objects.
#>
function Get-ImagesOnNode {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $false)]
        [bool]$IncludeK8sImages = $false,
        [Parameter(Mandatory = $false)]
        [bool]$ExcludeAddonImages = $false,
        [Parameter(Mandatory = $false)]
        [string]$CrictlExePath = '',
        [Parameter(Mandatory = $false)]
        [string]$CrictlConfigPath = ''
    )

    switch ($NodeInfo.Kind) {
        'ControlPlane' {
            Write-Log "[ImageNode] Executing 'sudo buildah images' on control-plane '$($NodeInfo.Name)'"
            return @(Get-ContainerImagesOnLinuxNode `
                    -IncludeK8sImages $IncludeK8sImages `
                    -ExcludeAddonImages $ExcludeAddonImages `
                    -NodeName $NodeInfo.Name)
        }
        'LinuxWorker' {
            Write-Log "[ImageNode] Executing 'sudo buildah images' on Linux worker '$($NodeInfo.Name)' ($($NodeInfo.IpAddress))"
            return @(Get-ContainerImagesOnLinuxNode `
                    -IncludeK8sImages $IncludeK8sImages `
                    -ExcludeAddonImages $ExcludeAddonImages `
                    -IpAddress $NodeInfo.IpAddress `
                    -UserName $NodeInfo.Username `
                    -NodeName $NodeInfo.Name)
        }
        'LocalWindows' {
            Write-Log "[ImageNode] Executing 'crictl images' on local Windows host '$($NodeInfo.Name)'"
            return @(Get-ContainerImagesOnWindowsNode `
                    -IncludeK8sImages $IncludeK8sImages `
                    -ExcludeAddonImages $ExcludeAddonImages `
                    -NodeName $NodeInfo.Name `
                    -NodeType 'HOST' `
                    -CrictlExePath $CrictlExePath `
                    -CrictlConfigPath $CrictlConfigPath)
        }
        'WindowsWorker' {
            Write-Log "[ImageNode] Executing 'crictl images' on Windows worker '$($NodeInfo.Name)' via remote session"
            return @(Get-ContainerImagesOnWindowsNode `
                    -IncludeK8sImages $IncludeK8sImages `
                    -ExcludeAddonImages $ExcludeAddonImages `
                    -NodeName $NodeInfo.Name `
                    -NodeType $NodeInfo.NodeType `
                    -CrictlExePath $CrictlExePath `
                    -CrictlConfigPath $CrictlConfigPath)
        }
        default {
            Write-Log "[ImageNode] Unknown node kind '$($NodeInfo.Kind)' for '$($NodeInfo.Name)'; returning empty list"
            return @()
        }
    }
}

<#
.SYNOPSIS
Parses the -Nodes / -Node script parameters into a normalized array of node names.

.DESCRIPTION
- Merges -Nodes (comma-separated) and -Node (single) into one list.
- Returns an empty array when neither parameter is given, which signals "use all default nodes".
#>
function Resolve-NodeList {
    param(
        [string]$Nodes = '',
        [string]$Node = ''
    )

    $combined = $Nodes
    if ([string]::IsNullOrWhiteSpace($combined)) {
        $combined = $Node
    }

    if ([string]::IsNullOrWhiteSpace($combined)) {
        return @()
    }

    return @($combined -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
}

<#
.SYNOPSIS
Collects images from selected nodes using shared node-orchestration flow.

.DESCRIPTION
- Uses default nodes (Linux control-plane and local Windows host) when no node selector is provided.
- Uses explicit node resolution when -Node/-Nodes are provided.
- Returns Linux, Windows and combined image arrays.
#>
function Get-ImagesByNodeSelection {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Nodes = '',
        [Parameter(Mandatory = $false)]
        [string]$Node = '',
        [Parameter(Mandatory = $false)]
        [bool]$IncludeK8sImages = $false,
        [Parameter(Mandatory = $false)]
        [bool]$ExcludeAddonImages = $false,
        [Parameter(Mandatory = $false)]
        [string]$LogPrefix = 'ImageNode',
        [Parameter(Mandatory = $false)]
        [string]$CrictlExePath = '',
        [Parameter(Mandatory = $false)]
        [string]$CrictlConfigPath = ''
    )

    $nodeList = Resolve-NodeList -Nodes $Nodes -Node $Node
    Write-Log "[$LogPrefix] Node filter: $(if ($nodeList.Count -eq 0) { '<all default>' } else { $nodeList -join ', ' })"

    $targetNodeInfos = @()
    $skippedNodes = @()
    if ($nodeList.Count -eq 0) {
        $targetNodeInfos = @(Get-DefaultNodeInfoList)
    }
    else {
        foreach ($nodeName in $nodeList) {
            $nodeInfo = Resolve-ImageNode -NodeName $nodeName
            if ($null -eq $nodeInfo) {
                Write-Log "[$LogPrefix] Node '$nodeName' could not be resolved - verify the node name exists in the cluster" -Console
                $skippedNodes += @{ Name = $nodeName; Reason = 'not-found' }
                continue
            }
            # Check if node is Ready before adding to target list
            if (-not (Test-NodeReady -NodeName $nodeName -Kind $nodeInfo.Kind)) {
                Write-Log "[$LogPrefix] Node '$nodeName' is not in Ready state - start the node with 'k2s start --node $nodeName' first" -Console
                $skippedNodes += @{ Name = $nodeName; Reason = 'not-ready' }
                continue
            }
            $targetNodeInfos += $nodeInfo
        }
    }

    $linuxContainerImages = @()
    $windowsContainerImages = @()

    foreach ($nodeInfo in $targetNodeInfos) {
        Write-Log "[$LogPrefix] Querying images on '$($nodeInfo.Name)' (kind=$($nodeInfo.Kind), os=$($nodeInfo.OS))"
        $nodeImages = @(Get-ImagesOnNode -NodeInfo $nodeInfo -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages -CrictlExePath $CrictlExePath -CrictlConfigPath $CrictlConfigPath)
        if ($nodeInfo.OS -eq 'linux') {
            $linuxContainerImages += $nodeImages
        }
        elseif ($nodeInfo.OS -eq 'windows') {
            $windowsContainerImages += $nodeImages
        }
    }

    return @{
        NodeInfos      = @($targetNodeInfos)
        SkippedNodes   = @($skippedNodes)
        LinuxImages    = @($linuxContainerImages)
        WindowsImages  = @($windowsContainerImages)
        AllImages      = @($linuxContainerImages) + @($windowsContainerImages)
    }
}

<#
.SYNOPSIS
Get the IP address of the registry host node.

.DESCRIPTION
Determines which node is running the registry pod and returns its IP address.
Falls back to control-plane IP if registry pod is not found or is running on control-plane.
#>
function Get-RegistryHostIp {
    $controlPlaneIp = Get-ConfiguredIPControlPlane

    $registryNodeName = ''
    try {
        $kubeToolsPath = Get-KubeToolsPath
        $kubectlExe = "$kubeToolsPath\kubectl.exe"
        if (Test-Path $kubectlExe) {
            $registryNodeName = (& $kubectlExe -n registry get pod -l app=registry -o jsonpath='{.items[0].spec.nodeName}' 2>$null) | Out-String
            $registryNodeName = $registryNodeName.Trim()
        }
    }
    catch {
        Write-Log "[Image] Unable to detect registry pod node, using control-plane IP fallback"
    }

    if ([string]::IsNullOrWhiteSpace($registryNodeName)) {
        return $controlPlaneIp
    }

    $setupFilePath = Get-SetupConfigFilePath
    $controlPlaneHostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    if ([string]::IsNullOrWhiteSpace($controlPlaneHostname)) {
        $controlPlaneHostname = 'kubemaster'
    }

    if ($registryNodeName.ToLower() -eq $controlPlaneHostname.ToLower()) {
        return $controlPlaneIp
    }

    $registryNodeConfig = Get-NodeConfig -NodeName $registryNodeName
    if ($null -ne $registryNodeConfig -and -not [string]::IsNullOrWhiteSpace($registryNodeConfig.IpAddress)) {
        return $registryNodeConfig.IpAddress
    }

    return $controlPlaneIp
}

<#
.SYNOPSIS
Builds the shell environment prefix that routes buildah/network traffic through the K2s transparent proxy.

.DESCRIPTION
Returns a command prefix like "HTTP_PROXY=... HTTPS_PROXY=... NO_PROXY=... " that can be prepended to a
'sudo <command>' invocation on a Linux node so external registry access works in isolated/corporate-proxy networks.

- Returns an empty string (no proxy) when the reference targets the in-cluster registry (k2s.registry.local),
  which must never be routed through the corporate/transparent proxy.
- Returns an empty string and logs a warning when no cluster proxy is configured.

.PARAMETER LogPrefix
Log category tag, e.g. 'Pull', 'Push', 'Registry'.

.PARAMETER NodeName
Name of the node the command runs on (used for logging).

.PARAMETER Reference
Optional image or registry reference. When it targets k2s.registry.local, no proxy prefix is returned.
#>
function Get-LinuxTransparentProxyPrefix {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [Parameter(Mandatory = $true)]
        [string]$NodeName,
        [Parameter(Mandatory = $false)]
        [string]$Reference = ''
    )

    # The in-cluster registry (k2s.registry.local) is internal and must not be routed through the proxy.
    if ($Reference -match '^k2s\.registry\.local(:\d+)?(/|$)') {
        return ''
    }

    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP
    if ([string]::IsNullOrWhiteSpace($kubeSwitchIp)) {
        Write-Log "[$LogPrefix] WARNING: No cluster proxy configured for '$NodeName' - operation may fail in isolated networks. Configure proxy with: k2s system proxy set --proxy <corporate-proxy>" -Console
        return ''
    }

    $proxyAddr = "http://${kubeSwitchIp}:8181"
    Write-Log "[$LogPrefix] Using K2s transparent proxy $proxyAddr for '$NodeName'" -Console
    return "HTTP_PROXY=$proxyAddr HTTPS_PROXY=$proxyAddr NO_PROXY=k2s.registry.local,localhost,127.0.0.1 "
}

function Test-ImageImportSuccess {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Result
    )

    if ($null -eq $Result -or $Result -is [array]) {
        return $false
    }

    return ($Result.Success -is [bool] -and $Result.Success)
}

<#
.SYNOPSIS
Normalizes an archive member path the way Buildah (containers/image) compares tar member names.

.DESCRIPTION
Applies Go's path.Clean, which Buildah uses for both the manifest.json references and the tar member names:
'.' and empty segments are removed and '..' removes the previous segment. A leading '..' of a relative path and a
leading '/' are kept, so a path outside the archive root never becomes a valid-looking member name. '/' is the only
separator; a backslash is an ordinary character as in tar member names. './' and '' become ''.
For example './blobs/sha256/abc' and 'blobs//sha256/abc' both become 'blobs/sha256/abc', '../layer.tar' stays '../layer.tar'.
#>
function ConvertTo-ImageArchiveMemberPath {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return ''
    }

    $rooted = $Path.StartsWith('/')
    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in $Path.Split('/')) {
        if ($segment -eq '' -or $segment -eq '.') {
            continue
        }
        if ($segment -eq '..') {
            if ($segments.Count -gt 0 -and $segments[$segments.Count - 1] -ne '..') {
                $segments.RemoveAt($segments.Count - 1)
            }
            elseif (-not $rooted) {
                $segments.Add($segment)
            }
            continue
        }
        $segments.Add($segment)
    }

    $cleaned = $segments -join '/'
    if ($rooted) {
        return "/$cleaned"
    }
    return $cleaned
}

<#
.SYNOPSIS
Returns $true when a manifest.json path refers to a location inside the archive root.

.DESCRIPTION
Docker archives reference their members with relative '/'-separated paths. Absolute paths ('/x'), drive-qualified
paths ('C:\x', 'C:x'), UNC paths ('\\server\share\x'), paths that leave the archive root after cleaning ('../x',
'a/../../x') and paths without a file name ('', './') are rejected. Because containerd on Windows may treat '\' as a
separator, these checks are also applied to the path with '\' read as '/'; 'folder\layer.tar' is still accepted.
#>
function Test-ImageArchiveMemberReference {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return $false
    }
    foreach ($candidate in @($Path, ($Path -replace '\\', '/'))) {
        if ($candidate.StartsWith('/') -or $candidate -match '^[A-Za-z]:') {
            return $false
        }
        $cleaned = ConvertTo-ImageArchiveMemberPath -Path $candidate
        if ($cleaned -eq '' -or $cleaned -eq '..' -or $cleaned.StartsWith('../')) {
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
Converts a member name printed by 'tar.exe -t' (bsdtar) back to the stored name.

.DESCRIPTION
bsdtar escapes '\' as '\\' and control characters as '\a', '\b', '\f', '\n', '\r', '\t', '\v' or '\ooo' when listing.
#>
function ConvertFrom-TarListingName {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrEmpty($Name) -or $Name.IndexOf('\') -lt 0) {
        return $Name
    }
    return [regex]::Replace($Name, '\\([0-7]{3}|[abfnrtv\\])', {
            param($match)
            $value = $match.Groups[1].Value
            switch -CaseSensitive ($value) {
                'a' { return [string][char]7 }
                'b' { return [string][char]8 }
                'f' { return [string][char]12 }
                'n' { return "`n" }
                'r' { return "`r" }
                't' { return "`t" }
                'v' { return [string][char]11 }
                '\' { return '\' }
            }
            return [string][char][Convert]::ToInt32($value, 8)
        })
}

<#
.SYNOPSIS
Reads the Docker 'manifest.json' of an image archive without extracting the archive.

.DESCRIPTION
Uses the Windows system tar.exe to list the archive members and to stream the top-level 'manifest.json' (any
member name that cleans to 'manifest.json', such as './manifest.json'), then parses it with ConvertFrom-Json.
Never throws. Returns an object with:
  State   - 'Valid'       non-empty JSON array of JSON objects (the entries are not validated further, see Get-DockerArchiveEntryProblem)
            'Invalid'     manifest.json exists but is empty, malformed, not an array of objects, or present more than once
            'Unreadable'  manifest.json exists but tar.exe could not read it
            'NotFound'    archive has no manifest.json (e.g. OCI-only archives)
            'Unavailable' the archive could not be inspected: path missing, tar.exe missing, or listing failed
  Reason  - why the State is not 'Valid' or 'NotFound' (for log messages)
  Entries - the parsed manifest entries in manifest.json order (only populated when State is 'Valid')
  Members - the normalized archive member paths (populated when the archive could be listed and every name is ASCII)
#>
function Get-DockerArchiveManifestInfo {
    param(
        [Parameter(Mandatory = $false)]
        [string]$ImagePath
    )

    $info = [pscustomobject]@{ State = 'Unavailable'; Reason = 'the archive file does not exist'; Entries = @(); Members = @() }

    try {
        if ([string]::IsNullOrWhiteSpace($ImagePath) -or -not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            return $info
        }

        $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (-not (Test-Path -LiteralPath $tarExe -PathType Leaf)) {
            $info.Reason = "'$tarExe' was not found"
            Write-Log "[Import] Warning: '$tarExe' not found; cannot inspect '$ImagePath' for multiple images"
            return $info
        }

        # tar.exe resolves relative paths against the process directory, not the PowerShell location
        $archivePath = (Resolve-Path -LiteralPath $ImagePath).ProviderPath

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $memberNames = @(& $tarExe -tf $archivePath 2>$null)
            $listExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEAP
        }

        if ($listExitCode -ne 0) {
            $info.Reason = "tar.exe could not list the archive (exit code $listExitCode)"
            Write-Log "[Import] Warning: tar.exe could not list '$ImagePath' (exit code $listExitCode); it is not inspected for multiple images"
            return $info
        }

        $normalizedMembers = [System.Collections.Generic.List[string]]::new()
        $manifestMembers = [System.Collections.Generic.List[string]]::new()
        foreach ($memberName in $memberNames) {
            $normalizedName = ConvertTo-ImageArchiveMemberPath -Path (ConvertFrom-TarListingName -Name $memberName)
            if ($normalizedName -eq '') {
                continue
            }
            $normalizedMembers.Add($normalizedName)
            if ($normalizedName -eq 'manifest.json') {
                # The listed name is passed back to tar.exe unchanged; a manifest.json member name contains no escapes
                $manifestMembers.Add($memberName)
            }
        }
        $info.Members = $normalizedMembers.ToArray()
        if (@($info.Members | Where-Object { $_ -match '[^\x00-\x7F]' }).Count -gt 0) {
            # tar.exe prints non-ASCII names in the ANSI code page and PowerShell decodes them with the console encoding,
            # so they cannot be compared with manifest.json paths; the member check is skipped and left to Buildah
            Write-Log "[Import] '$ImagePath' has member names with non-ASCII characters; archive members are not checked before the import"
            $info.Members = @()
        }

        if ($manifestMembers.Count -eq 0) {
            $info.State = 'NotFound'
            $info.Reason = ''
            return $info
        }
        if ($manifestMembers.Count -gt 1) {
            # Buildah would use the first and other tools may use the last copy; neither is known to be the intended one
            $info.State = 'Invalid'
            $info.Reason = "the archive contains $($manifestMembers.Count) manifest.json members"
            return $info
        }
        $manifestMember = $manifestMembers[0]

        $ErrorActionPreference = 'Continue'
        try {
            $tarOutput = & $tarExe -xOqf $archivePath $manifestMember 2>$null
            $tarExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEAP
        }

        if ($tarExitCode -ne 0) {
            $info.State = 'Unreadable'
            $info.Reason = "tar.exe could not read '$manifestMember' (exit code $tarExitCode)"
            Write-Log "[Import] Warning: tar.exe could not read '$manifestMember' from '$ImagePath' (exit code $tarExitCode)"
            return $info
        }

        $info.State = 'Invalid'
        $info.Reason = 'manifest.json is not valid JSON'
        $convertParams = @{ ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('NoEnumerate')) {
            # PowerShell 7 would otherwise unroll a one-element array into a single object
            $convertParams.NoEnumerate = $true
        }
        try {
            # Assign before testing: PS 5.1 emits a JSON array as a single object[] instead of enumerating it
            $manifest = (@($tarOutput) -join "`n") | ConvertFrom-Json @convertParams
        }
        catch {
            return $info
        }

        $info.Reason = 'manifest.json is empty or not a list of image entries'
        if ($null -eq $manifest -or $manifest -isnot [array] -or $manifest.Count -eq 0) {
            return $info
        }
        foreach ($entry in $manifest) {
            if ($entry -isnot [System.Management.Automation.PSCustomObject]) {
                return $info
            }
        }

        $info.State = 'Valid'
        $info.Reason = ''
        $info.Entries = $manifest
    }
    catch {
        Write-Log "[Import] Warning: could not inspect '$ImagePath' for multiple images: $_"
        $info.State = 'Unavailable'
        $info.Reason = "the archive could not be inspected: $_"
        $info.Entries = @()
    }

    return $info
}

<#
.SYNOPSIS
Checks one Docker archive manifest entry before it is imported with an '@<index>' selector.

.DESCRIPTION
Returns $null when the entry is usable, otherwise a short description of the problem:
- 'Config' must be a non-empty string and 'Layers' an array of non-empty strings.
- 'RepoTags', when present, must be an array of strings (it may be missing or null for untagged images).
- The config and layer paths must stay inside the archive (see Test-ImageArchiveMemberReference).
- When Members is given, the config and every layer must be members of the archive.
The image content itself (digests, layer count versus config) is verified by Buildah during the pull.
#>
function Get-DockerArchiveEntryProblem {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Entry,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string[]]$Members = @()
    )

    if ($Entry -isnot [System.Management.Automation.PSCustomObject]) {
        return 'the entry is not a JSON object'
    }

    $configProperty = $Entry.PSObject.Properties['Config']
    if ($null -eq $configProperty -or $configProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($configProperty.Value)) {
        return "'Config' is missing or not a non-empty string"
    }

    $layersProperty = $Entry.PSObject.Properties['Layers']
    if ($null -eq $layersProperty -or $layersProperty.Value -isnot [array]) {
        return "'Layers' is missing or not an array"
    }
    foreach ($layer in $layersProperty.Value) {
        if ($layer -isnot [string] -or [string]::IsNullOrWhiteSpace($layer)) {
            return "'Layers' contains an item that is not a non-empty string"
        }
    }

    $repoTagsProperty = $Entry.PSObject.Properties['RepoTags']
    if ($null -ne $repoTagsProperty -and $null -ne $repoTagsProperty.Value) {
        if ($repoTagsProperty.Value -isnot [array]) {
            return "'RepoTags' is not an array"
        }
        foreach ($tag in $repoTagsProperty.Value) {
            if ($tag -isnot [string]) {
                return "'RepoTags' contains an item that is not a string"
            }
        }
    }

    $referenced = @($configProperty.Value) + @($layersProperty.Value)
    $outside = @($referenced | Where-Object { -not (Test-ImageArchiveMemberReference -Path $_) } | Select-Object -Unique)
    if ($outside.Count -gt 0) {
        return "path(s) outside the archive: $($outside -join ', ')"
    }

    $memberList = @($Members | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($memberList.Count -gt 0) {
        $memberSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$memberList, [System.StringComparer]::Ordinal)
        $missing = @($referenced | Where-Object { -not $memberSet.Contains((ConvertTo-ImageArchiveMemberPath -Path $_)) } | Select-Object -Unique)
        if ($missing.Count -gt 0) {
            return "archive member(s) not found: $($missing -join ', ')"
        }
    }

    return $null
}

<#
.SYNOPSIS
Converts a Docker archive 'RepoTags' reference to the fully qualified name stored by containerd and Buildah.

.DESCRIPTION
Applies the Docker reference normalization: a reference without a registry domain gets 'docker.io',
single-component Docker Hub names get 'library/', 'index.docker.io' becomes 'docker.io', and ':latest' is added
when neither a tag nor a digest is given. For example 'python:3' becomes 'docker.io/library/python:3'.
#>
function ConvertTo-ContainerdImageName {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Reference
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        return ''
    }

    $name = $Reference.Trim()
    $domain = 'docker.io'
    $remainder = $name
    $slashIndex = $name.IndexOf('/')
    if ($slashIndex -gt 0) {
        $firstComponent = $name.Substring(0, $slashIndex)
        if ($firstComponent -match '[.:]' -or $firstComponent -ceq 'localhost' -or $firstComponent -cne $firstComponent.ToLowerInvariant()) {
            $domain = $firstComponent
            $remainder = $name.Substring($slashIndex + 1)
        }
    }
    if ($domain -eq 'index.docker.io') {
        $domain = 'docker.io'
    }
    if ($domain -eq 'docker.io' -and $remainder.IndexOf('/') -lt 0) {
        $remainder = "library/$remainder"
    }

    $lastSlash = $remainder.LastIndexOf('/')
    $lastPart = $remainder.Substring($lastSlash + 1)
    if ($lastPart.IndexOf(':') -lt 0 -and $lastPart.IndexOf('@') -lt 0) {
        $remainder = "${remainder}:latest"
    }

    return "$domain/$remainder"
}

<#
.SYNOPSIS
Summarizes the image names of the entries of a Docker archive manifest.

.DESCRIPTION
Returns an object with:
  ExpectedNames   - the normalized names of all RepoTags (unique, in manifest order)
  UntaggedEntries - the indexes of entries without usable RepoTags
  DuplicateTags   - one object per normalized name used by more than one entry (Name, Entries); the runtime keeps
                    the image of the last entry for such a name
#>
function Get-DockerArchiveTagReport {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Entries = @()
    )

    $expectedNames = [System.Collections.Generic.List[string]]::new()
    $untaggedEntries = [System.Collections.Generic.List[int]]::new()
    $entriesByName = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[int]]]::new([System.StringComparer]::Ordinal)

    $entryList = @($Entries)
    for ($i = 0; $i -lt $entryList.Count; $i++) {
        $entry = $entryList[$i]
        $names = @()
        if ($entry -is [System.Management.Automation.PSCustomObject] -and $null -ne $entry.PSObject.Properties['RepoTags']) {
            $names = @($entry.RepoTags | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { ConvertTo-ContainerdImageName -Reference $_ } | Select-Object -Unique)
        }
        if ($names.Count -eq 0) {
            $untaggedEntries.Add($i)
            continue
        }
        foreach ($name in $names) {
            if (-not $entriesByName.ContainsKey($name)) {
                $entriesByName[$name] = [System.Collections.Generic.List[int]]::new()
                $expectedNames.Add($name)
            }
            $entriesByName[$name].Add($i)
        }
    }

    $duplicateTags = @(foreach ($name in $expectedNames) {
            if ($entriesByName[$name].Count -gt 1) {
                [pscustomobject]@{ Name = $name; Entries = $entriesByName[$name].ToArray() }
            }
        })

    return [pscustomobject]@{
        ExpectedNames   = $expectedNames.ToArray()
        UntaggedEntries = $untaggedEntries.ToArray()
        DuplicateTags   = $duplicateTags
    }
}

function Write-DockerArchiveDuplicateTagWarning {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TagReport,
        [Parameter(Mandatory = $true)]
        [string]$ImagePath
    )

    foreach ($duplicate in @($TagReport.DuplicateTags)) {
        $lastEntry = @($duplicate.Entries)[-1]
        Write-Log "[Import] Warning: tag '$($duplicate.Name)' is used by archive entries @$(@($duplicate.Entries) -join ', @') of '$ImagePath'; it will refer to entry @$lastEntry" -Console
    }
}

function Invoke-LinuxNodeImageImport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [object]$NodeInfo,
        [Parameter(Mandatory = $false)]
        [switch]$DockerArchive
    )

    # A unique remote file per import keeps concurrent imports to the same node from overwriting or deleting each other's archive
    $remoteImagePath = "/tmp/k2s-image-import-$([guid]::NewGuid().ToString('N')).tar"
    $importSuccess = $false
    $archiveTransport = if ($DockerArchive) { 'docker-archive' } else { 'oci-archive' }
    $pullCommand = "sudo buildah pull ${archiveTransport}:$remoteImagePath 2>&1"

    # Multi-image Docker archives are imported entry by entry; everything else keeps the single pull above
    $manifestInfo = Get-DockerArchiveManifestInfo -ImagePath $ImagePath
    $manifestEntries = @($manifestInfo.Entries)
    $isMultiImageArchive = ($manifestInfo.State -eq 'Valid' -and $manifestEntries.Count -ge 2)
    if ($manifestInfo.State -eq 'Invalid' -or $manifestInfo.State -eq 'Unreadable') {
        # A fallback pull could import only part of the archive (e.g. through index.json) and still report success
        Write-Log "[Import] Image archive '$ImagePath' is not imported on '$($NodeInfo.Name)': $($manifestInfo.Reason)" -Error
        return $false
    }

    $invokeRemote = {
        param([string]$Command)
        if ($NodeInfo.Kind -eq 'ControlPlane') {
            return Invoke-CmdOnControlPlaneViaSSHKey $Command -Retries 3 -Timeout 10 -NoLog
        }
        return Invoke-CmdOnVmViaSSHKey $Command -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -Retries 3 -Timeout 10 -NoLog
    }

    try {
        if ($NodeInfo.Kind -eq 'ControlPlane') {
            Copy-ToControlPlaneViaSSHKey $ImagePath $remoteImagePath
        }
        else {
            Copy-ToRemoteComputerViaSshKey -Source $ImagePath -Target $remoteImagePath -UserName $NodeInfo.Username -IpAddress $NodeInfo.IpAddress
        }

        if (-not $isMultiImageArchive) {
            $importResult = & $invokeRemote $pullCommand

            if ($importResult.Output) {
                $importResult.Output | Write-Log
            }
            $importSuccess = Test-ImageImportSuccess -Result $importResult
            if (-not $importSuccess) {
                Write-Log "[Import] Image import failed on '$($NodeInfo.Name)'" -Error
            }
        }
        else {
            $entryCount = $manifestEntries.Count
            Write-Log "[Import] Docker archive '$ImagePath' contains $entryCount images; importing each entry on '$($NodeInfo.Name)'" -Console
            Write-DockerArchiveDuplicateTagWarning -TagReport (Get-DockerArchiveTagReport -Entries $manifestEntries) -ImagePath $ImagePath
            $failedEntries = @()

            # '@<index>' addresses the entry at that position of manifest.json (not index.json); Buildah applies that entry's RepoTags
            for ($i = 0; $i -lt $entryCount; $i++) {
                $entry = $manifestEntries[$i]
                $repoTags = @()
                if ($entry -is [System.Management.Automation.PSCustomObject] -and $null -ne $entry.PSObject.Properties['RepoTags']) {
                    $repoTags = @($entry.RepoTags | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
                }
                $tagText = if ($repoTags.Count -gt 0) { $repoTags -join ', ' } else { '<untagged>' }

                # Not -Error: Write-Error would stop the loop under ErrorActionPreference 'Stop'; the summary below reports the error
                $entryProblem = Get-DockerArchiveEntryProblem -Entry $entry -Members $manifestInfo.Members
                if ($null -ne $entryProblem) {
                    Write-Log "[Import] Skipping archive entry @$i ($tagText) of '$ImagePath': invalid manifest.json entry: $entryProblem" -Console
                    $failedEntries += $i
                    continue
                }
                if ($repoTags.Count -eq 0) {
                    Write-Log "[Import] Warning: archive entry @$i has no RepoTags; the image will only be referenceable by ID" -Console
                }

                Write-Log "[Import] Importing archive entry @$i ($tagText, config '$($entry.Config)') on '$($NodeInfo.Name)'"
                $entryResult = & $invokeRemote "sudo buildah pull docker-archive:${remoteImagePath}:@$i 2>&1"

                if ($entryResult.Output) {
                    $entryResult.Output | Write-Log
                }
                if (-not (Test-ImageImportSuccess -Result $entryResult)) {
                    Write-Log "[Import] Image import failed for archive entry @$i ($tagText) of '$ImagePath' on '$($NodeInfo.Name)'" -Console
                    $failedEntries += $i
                }
            }

            $importSuccess = ($failedEntries.Count -eq 0)
            if (-not $importSuccess) {
                Write-Log "[Import] Imported $($entryCount - $failedEntries.Count) of $entryCount images from '$ImagePath' on '$($NodeInfo.Name)'; failed entries: @$($failedEntries -join ', @'). Successfully imported images are kept." -Error
            }
        }
    }
    catch {
        Write-Log "[Import] Image import failed on '$($NodeInfo.Name)': $_" -Error
    }
    finally {
        # Errors are collected first so that logging them cannot skip the cleanup result or replace an import error
        $cleanupError = $null
        try {
            $cleanupResult = & $invokeRemote "sudo rm -f $remoteImagePath"

            if ($cleanupResult.Output) {
                $cleanupResult.Output | Write-Log
            }
            if (-not (Test-ImageImportSuccess -Result $cleanupResult)) {
                $cleanupError = "[Import] Could not remove temporary image archive '$remoteImagePath' from '$($NodeInfo.Name)'"
            }
        }
        catch {
            $cleanupError = "[Import] Could not remove temporary image archive '$remoteImagePath' from '$($NodeInfo.Name)': $_"
        }

        if ($null -ne $cleanupError) {
            $importSuccess = $false
            Write-Log $cleanupError -Error
        }
    }

    return $importSuccess
}

<#
.SYNOPSIS
Inspects an image archive before a Windows (containerd) import.

.DESCRIPTION
containerd ('ctr images import') imports every image of a Docker or OCI archive in one operation, so no per-entry
import is needed on Windows. This function only reads the Docker 'manifest.json' to report the number of images and
duplicate tags, and returns the information needed to verify the import afterwards.
Returns $null when the archive has no Docker manifest that can be checked; the import result of such an archive is the
ctr result only, and the log states that the image names are not verified:
- 'NotFound'    no manifest.json (for example OCI-only archives); supported, names come from index.json
- 'Unavailable' the archive could not be listed (or tar.exe is missing); warned on the console
Returns an object with Rejected = $true and a Reason when manifest.json exists but is 'Invalid' or 'Unreadable';
such an archive must not be imported, because ctr could import only part of it and still succeed.
#>
function Get-WindowsImageArchiveReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath
    )

    $manifestInfo = Get-DockerArchiveManifestInfo -ImagePath $ImagePath
    switch ($manifestInfo.State) {
        'NotFound' {
            Write-Log "[Import] '$ImagePath' has no Docker manifest.json (for example an OCI archive); the imported image names are not verified"
        }
        'Unavailable' {
            Write-Log "[Import] Warning: '$ImagePath' could not be inspected ($($manifestInfo.Reason)); the imported image names are not verified" -Console
        }
    }
    if ($manifestInfo.State -eq 'Invalid' -or $manifestInfo.State -eq 'Unreadable') {
        return [pscustomobject]@{ Rejected = $true; Reason = $manifestInfo.Reason }
    }
    if ($manifestInfo.State -ne 'Valid') {
        return $null
    }

    $entries = @($manifestInfo.Entries)
    $tagReport = Get-DockerArchiveTagReport -Entries $entries
    if ($entries.Count -ge 2) {
        Write-Log "[Import] Docker archive '$ImagePath' contains $($entries.Count) images; containerd imports all of them in one operation" -Console
    }
    Write-DockerArchiveDuplicateTagWarning -TagReport $tagReport -ImagePath $ImagePath

    return [pscustomobject]@{
        Rejected        = $false
        Reason          = ''
        EntryCount      = $entries.Count
        ExpectedNames   = @($tagReport.ExpectedNames)
        UntaggedEntries = @($tagReport.UntaggedEntries)
        DuplicateTags   = @($tagReport.DuplicateTags)
    }
}

<#
.SYNOPSIS
Verifies that every tagged image of a Docker archive exists in containerd after 'ctr images import' succeeded.

.DESCRIPTION
Returns $true only when every expected image name was found. Called only after ctr succeeded.
- Untagged entries: containerd creates no named image for them (and still exits with code 0), and a name-based check
  cannot show that they were imported, so they are reported and the result is $false.
- ImageNames $null: the image list of the 'k8s.io' namespace could not be read; ctr succeeded but the names cannot be
  verified, so the result is $false.
- Duplicate tags: such a name is one image (the last entry using it); the success message says so.
$ArchiveReport $null (no usable Docker manifest) returns $true: the ctr result is the only available result.
#>
function Test-WindowsImageArchiveImport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$ArchiveReport,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string[]]$ImageNames,
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if ($null -eq $ArchiveReport) {
        return $true
    }

    $complete = $true
    foreach ($index in @($ArchiveReport.UntaggedEntries)) {
        Write-Log "[Import] Archive entry @$index of '$ImagePath' has no RepoTags; containerd does not import untagged Docker archive entries on $Target, and its import cannot be verified by name" -Console
        $complete = $false
    }

    if ($null -eq $ImageNames) {
        Write-Log "[Import] ctr imported '$ImagePath' on $Target, but the image list could not be read; the $(@($ArchiveReport.ExpectedNames).Count) expected image name(s) are not verified" -Console
        return $false
    }

    $nameSet = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ImageNames | Where-Object { $null -ne $_ } | ForEach-Object { $_.Trim() }), [System.StringComparer]::Ordinal)
    $missingNames = @($ArchiveReport.ExpectedNames | Where-Object { -not $nameSet.Contains($_) })
    foreach ($missingName in $missingNames) {
        Write-Log "[Import] Image '$missingName' from '$ImagePath' was not found on $Target after the import" -Console
    }
    if ($missingNames.Count -gt 0) {
        $complete = $false
    }

    if ($complete) {
        $sharedText = ''
        $sharedCount = @($ArchiveReport.DuplicateTags | Where-Object { $null -ne $_ }).Count
        if ($sharedCount -gt 0) {
            $sharedText = "; $sharedCount of these name(s) are used by several entries and refer only to the last of them"
        }
        Write-Log "[Import] Verified $(@($ArchiveReport.ExpectedNames).Count) image name(s) of $($ArchiveReport.EntryCount) archive entries from '$ImagePath' on $Target$sharedText"
    }
    return $complete
}

function Get-LocalWindowsImageNames {
    $ctrExe = "$(Get-KubeBinPath)\containerd\ctr.exe"

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $ctrExe -n k8s.io images ls -q 2>$null)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEAP
    }

    return [pscustomobject]@{
        Success = ($exitCode -eq 0)
        Names   = @($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' })
    }
}

function Invoke-LocalWindowsImageImport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath
    )

    $target = 'the local Windows host'
    $archiveReport = Get-WindowsImageArchiveReport -ImagePath $ImagePath
    if ($null -ne $archiveReport -and $archiveReport.Rejected) {
        Write-Log "[Import] Image archive '$ImagePath' is not imported on ${target}: $($archiveReport.Reason)" -Error
        return $false
    }

    if (-not (Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'import', $ImagePath)) {
        Write-Log "[Import] Image import of '$ImagePath' failed on $target" -Error
        return $false
    }

    $imageNames = $null
    if ($null -ne $archiveReport) {
        $listing = Get-LocalWindowsImageNames
        if ($listing.Success) {
            $imageNames = [string[]]@($listing.Names)
        }
    }
    if (-not (Test-WindowsImageArchiveImport -ImagePath $ImagePath -ArchiveReport $archiveReport -ImageNames $imageNames -Target $target)) {
        Write-Log "[Import] Image archive '$ImagePath' was not completely imported or could not be verified on $target" -Error
        return $false
    }

    if ($null -eq $archiveReport) {
        Write-Log "$ImagePath imported successfully on $target (image names not verified)"
    }
    else {
        Write-Log "$ImagePath imported successfully on $target"
    }
    return $true
}

function Invoke-WindowsWorkerImageImport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImagePath,
        [Parameter(Mandatory = $true)]
        [string]$NodeName
    )

    $session = $null
    # A unique remote file per import keeps concurrent imports to the same node from overwriting or deleting each other's archive
    $remoteImagePath = "C:\Windows\Temp\k2s-image-import-$([guid]::NewGuid().ToString('N')).tar"
    $importSuccess = $false
    $target = "Windows worker '$NodeName'"
    $archiveReport = Get-WindowsImageArchiveReport -ImagePath $ImagePath
    if ($null -ne $archiveReport -and $archiveReport.Rejected) {
        Write-Log "[Import] Image archive '$ImagePath' is not imported on ${target}: $($archiveReport.Reason)" -Error
        return $false
    }

    try {
        $session = Open-RemoteSession -VmName $NodeName -VmPwd (Get-DefaultTempPwd) -NoLog
        Copy-Item -Path $ImagePath -Destination $remoteImagePath -ToSession $session -Force -ErrorAction Stop
        $importResult = Invoke-Command -Session $session -ArgumentList $remoteImagePath -ScriptBlock {
            param($path)
            $remoteCtrCmd = Get-Command ctr.exe -ErrorAction SilentlyContinue
            $remoteCtrPath = if ($remoteCtrCmd) { $remoteCtrCmd.Source } else { 'ctr.exe' }
            $global:LASTEXITCODE = 1
            $output = @(& $remoteCtrPath -n k8s.io images import $path 2>&1)
            $exitCode = $LASTEXITCODE
            $imageNames = $null
            if ($exitCode -eq 0) {
                $global:LASTEXITCODE = 1
                $listOutput = @(& $remoteCtrPath -n k8s.io images ls -q 2>$null)
                if ($LASTEXITCODE -eq 0) {
                    $imageNames = @($listOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne '' })
                }
            }
            [PSCustomObject]@{
                Success    = ($exitCode -eq 0)
                Output     = ($output -join [Environment]::NewLine)
                ImageNames = $imageNames
            }
        }

        if ($importResult.Output) {
            $importResult.Output | Write-Log
        }
        $importSuccess = Test-ImageImportSuccess -Result $importResult
        if (-not $importSuccess) {
            Write-Log "[Import] Image import failed on $target" -Error
        }
        else {
            $imageNames = $null
            if ($null -ne $importResult.PSObject.Properties['ImageNames'] -and $null -ne $importResult.ImageNames) {
                $imageNames = [string[]]@($importResult.ImageNames)
            }
            if (-not (Test-WindowsImageArchiveImport -ImagePath $ImagePath -ArchiveReport $archiveReport -ImageNames $imageNames -Target $target)) {
                $importSuccess = $false
                Write-Log "[Import] Image archive '$ImagePath' was not completely imported or could not be verified on $target" -Error
            }
        }
    }
    catch {
        $importSuccess = $false
        Write-Log "[Import] Image import failed on ${target}: $_" -Error
    }
    finally {
        if ($null -ne $session) {
            try {
                $removed = Invoke-Command -Session $session -ArgumentList $remoteImagePath -ScriptBlock {
                    param($path)
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                    -not (Test-Path -LiteralPath $path)
                } -ErrorAction Stop
                if ($removed -ne $true) {
                    Write-Log "[Import] Could not remove temporary image archive '$remoteImagePath' from $target" -Error
                    $importSuccess = $false
                }
            }
            catch {
                Write-Log "[Import] Could not remove temporary image archive '$remoteImagePath' from ${target}: $_" -Error
                $importSuccess = $false
            }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }

    return $importSuccess
}

Export-ModuleMember -Function Initialize-ImageScriptContext, Resolve-ImageNode, Get-DefaultNodeInfoList, Get-ImagesOnNode, Resolve-NodeList, Get-ImagesByNodeSelection, Test-NodeReady, Get-RegistryHostIp, Get-LinuxTransparentProxyPrefix, Test-ImageImportSuccess, Invoke-LinuxNodeImageImport, Invoke-LocalWindowsImageImport, Invoke-WindowsWorkerImageImport
