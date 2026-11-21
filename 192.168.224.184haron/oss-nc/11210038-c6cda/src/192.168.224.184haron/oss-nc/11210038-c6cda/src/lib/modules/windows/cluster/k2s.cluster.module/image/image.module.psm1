# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$registryFunctionsModule = "$PSScriptRoot\registry\registry.module.psm1"
$k8sApiModule = "$PSScriptRoot\..\k8s-api\k8s-api.module.psm1"
$statusModule = "$PSScriptRoot\..\status\status.module.psm1"
$configModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$vmModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\linuxnode\vm\vm.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$vmNodeModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\vmnode\vmnode.module.psm1"
$clusterConfigModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\config\cluster.config.module.psm1"

Import-Module $configModule, $k8sApiModule, $registryFunctionsModule, $vmModule, $statusModule, $pathModule, $vmNodeModule, $clusterConfigModule

$kubernetesImagesJson = Get-KubernetesImagesFilePath
$windowsPauseImageRepository = 'shsk2s.azurecr.io/pause-win'
$kubeBinPath = Get-KubeBinPath
$dockerExe = "$kubeBinPath\docker\docker.exe"
$nerdctlExe = "$kubeBinPath\nerdctl.exe"
$ctrExe = "$kubeBinPath\containerd\ctr.exe"
$crictlExe = Get-CrictlExePath
$rootConfig = Get-RootConfigk2s
class ContainerImage {
    [string]$ImageId
    [string]$Repository
    [string]$Tag
    [string]$Node
    [string]$Size
}

class PushedImage {
    [string]$Name
    [string]$Tag
    [string]$Node
}

$headers = @(
    'application/vnd.oci.image.manifest.v1+json',
    'application/vnd.oci.image.index.v1+json',
    'application/vnd.oci.artifact.manifest.v1+json',
    'application/vnd.docker.distribution.manifest.v2+json',
    'application/vnd.docker.distribution.manifest.list.v2+json',
    'application/vnd.docker.distribution.manifest.v1+prettyjws',
    'application/vnd.docker.distribution.manifest.v1+json'
)
$concatenatedHeadersString = ''
$headers | ForEach-Object { $concatenatedHeadersString += " -H `"Accept: $_`"" }

function New-KubernetesImageJsonFileIfNotExists() {
    $fileExists = Test-Path -Path $kubernetesImagesJson
    if (!$fileExists) {
        New-Item -Path $kubernetesImagesJson | Out-Null

        '[]' | Set-Content -Path "$kubernetesImagesJson"
    }
}

function Get-KubernetesImagesFromJson() {
    New-KubernetesImageJsonFileIfNotExists
    $kubernetesImages = @(Get-Content -Path $kubernetesImagesJson -Raw | ConvertFrom-Json)
    return $kubernetesImages
}

<#
.DESCRIPTION
This function is used to collect the kubernetes images present on the nodes.
!!! CAUTION !!! This function must be called only during installation. Otherwise, user's images will also be written into the json file.
User will see an incorrect output on listing images.
#>
function Write-KubernetesImagesIntoJson {
    New-KubernetesImageJsonFileIfNotExists
    $kubernetesImages = @()
    $linuxKubernetesImages = Get-ContainerImagesOnLinuxNode
    $windowsKubernetesImages = $(Get-ContainerImagesOnWindowsNode -IncludeK8sImages $false) | Where-Object { $_.Repository -match $windowsPauseImageRepository }
    $kubernetesImages = @($linuxKubernetesImages) + @($windowsKubernetesImages)
    $kubernetesImagesJsonString = $kubernetesImages | ConvertTo-Json -Depth 100
    $kubernetesImagesJsonString | Set-Content -Path $kubernetesImagesJson
}

function Get-FilteredImages([ContainerImage[]]$ContainerImages, [ContainerImage[]]$ContainerImagesToBeCleaned) {
    $filteredImages = @()
    foreach ($containerImage in $ContainerImages) {
        $count = ($ContainerImagesToBeCleaned | Where-Object { $_.ImageId -eq $containerImage.ImageId } ).Count
        if ($count -eq 0 ) {
            $filteredImages += $containerImage
        }
    }
    return $filteredImages
}

function Convert-ImageCommandOutputToLines {
    param(
        [Parameter(Mandatory = $false)]
        $Output
    )

    if ($null -eq $Output) {
        return @()
    }

    $lines = @()
    foreach ($item in @($Output)) {
        if ($null -eq $item) {
            continue
        }

        $itemLines = @(("$item" -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($itemLines.Count -gt 0) {
            $lines += $itemLines
        }
    }

    return @($lines)
}

function Get-ContainerImagesOnLinuxNode([bool]$IncludeK8sImages = $false, [bool]$ExcludeAddonImages = $false, [string]$IpAddress = '', [string]$UserName = '', [string]$NodeName = '') {
    $setupFilePath = Get-SetupConfigFilePath
    $hostname = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    if (-not [string]::IsNullOrWhiteSpace($NodeName)) {
        $hostname = $NodeName
    }
    $KubernetesImages = Get-KubernetesImagesFromJson
    $linuxContainerImages = @()
    if ([string]::IsNullOrWhiteSpace($IpAddress)) {
        $output = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo buildah images').Output
    }
    else {
        $resolvedUser = $UserName
        if ([string]::IsNullOrWhiteSpace($resolvedUser)) {
            $resolvedUser = Get-DefaultUserNameControlPlane
        }
        $output = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo buildah images' -IpAddress $IpAddress -UserName $resolvedUser).Output
    }

    $outputLines = @(Convert-ImageCommandOutputToLines -Output $output)

    Write-Log "[ImageList] Raw output type = $($output.GetType().Name)"
    Write-Log "[ImageList] Normalized output line count = $($outputLines.Count)"
    if ($outputLines.Count -gt 0) {
        Write-Log "[ImageList] Output is normalized to $($outputLines.Length) line(s)"
        for ($i = 0; $i -lt [Math]::Min($outputLines.Length, 10); $i++) {
            Write-Log "[ImageList]   Line[$i]: '$($outputLines[$i])'"
        }
    } else {
        Write-Log "[ImageList] Output is single value: '$output'"
    }

    if ($outputLines.Count -le 1) {
        Write-Log '[ImageList] No image rows found in Linux image command output'
        return @()
    }

    foreach ($line in $outputLines[1..($outputLines.Count - 1)]) {
        $words = $($line -replace '\s+', ' ').split()
        Write-Log "[ImageList] Parsing line: '$line' -> words count=$($words.Count)"
        if ($words.Count -lt 3) {
            Write-Log "[ImageList] Skipping line with insufficient words"
            continue
        }
        $containerImage = [ContainerImage]@{
            ImageId    = $words[2]
            Repository = $words[0]
            Tag        = $words[1]
            Node       = "$hostname"
            Size       = $words[$words.Count - 2] + $words[$words.Count - 1]
        }
        Write-Log "[ImageList] Parsed image: Repository='$($words[0])' Tag='$($words[1])' ImageId='$($words[2])'"
        $linuxContainerImages += $containerImage
    }
    Write-Log "[ImageList] Total parsed images before K8s filter = $($linuxContainerImages.Count)"
    if ($IncludeK8sImages -eq $false) {
        $linuxContainerImages =
        Get-FilteredImages -ContainerImages $linuxContainerImages -ContainerImagesToBeCleaned $KubernetesImages
        Write-Log "[ImageList] Total images after K8s filter = $($linuxContainerImages.Count)"
    }
    # Filter addon images and deduplicate
    $linuxContainerImages = Invoke-ImageFilteringAndDeduplication -ContainerImages $linuxContainerImages -ExcludeAddonImages $ExcludeAddonImages -NodeType 'Linux'

    return $linuxContainerImages
}

function Get-RemoteWindowsNodeImageOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $session = $null
    try {
        $session = Open-RemoteSession -VmName $VmName -VmPwd (Get-DefaultTempPwd) -NoLog
        $output = Invoke-Command -Session $session -ScriptBlock {
            $remoteCrictlPath = "$using:kubeBinPath\crictl.exe"
            if (-not (Test-Path $remoteCrictlPath)) {
                $remoteCrictlPath = (Get-Command crictl.exe -ErrorAction Stop).Path
            }

            $remoteConfigPath = "$using:kubeBinPath\crictl.yaml"
            if (-not (Test-Path $remoteConfigPath)) {
                $remoteConfigPath = Join-Path (Split-Path $remoteCrictlPath -Parent) 'crictl.yaml'
            }

            & $remoteCrictlPath --config $remoteConfigPath images 2>$null
        }

        return @($output)
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Get-ContainerImagesOnWindowsNode([bool]$IncludeK8sImages = $false, [bool]$ExcludeAddonImages = $false, [string]$NodeName = '', [string]$NodeType = '', [string]$CrictlExePath = '', [string]$CrictlConfigPath = '') {
    $localNodeName = $env:ComputerName.ToLower()
    $node = $localNodeName
    $output = @()

    $resolvedCrictlExe    = if ($CrictlExePath -ne '')    { $CrictlExePath }    else { $crictlExe }
    $resolvedCrictlConfig = if ($CrictlConfigPath -ne '') { $CrictlConfigPath } else { "$kubeBinPath\crictl.yaml" }

    if (-not [string]::IsNullOrWhiteSpace($NodeName)) {
        $requestedNode = $NodeName.ToLower()
        if ($requestedNode -ne $localNodeName) {
            if ($NodeType -eq 'VM-EXISTING') {
                Write-Log "[ImageFilter] Collecting Windows images from remote VM node '$NodeName'"
                $output = @(Get-RemoteWindowsNodeImageOutput -VmName $NodeName)
                $node = $requestedNode
            }
            else {
                Write-Log "[ImageFilter] Node '$NodeName' is a non-local Windows HOST node; remote Windows image listing is not implemented"
                return @()
            }
        }
        else {
            $output = @(&$resolvedCrictlExe --config $resolvedCrictlConfig images 2> $null)
            $node = $requestedNode
        }
    }
    else {
        $output = @(&$resolvedCrictlExe --config $resolvedCrictlConfig images 2> $null)
    }

    $KubernetesImages = Get-KubernetesImagesFromJson
    $outputLines = @(Convert-ImageCommandOutputToLines -Output $output)

    $windowsContainerImages = @()
    if ($outputLines.Count -gt 1) {
        foreach ( $line in $outputLines[1..($outputLines.Count - 1)]) {
            $words = $($line -replace '\s+', ' ').split()
            $containerImage = [ContainerImage]@{
                ImageId    = $words[2]
                Repository = $words[0]
                Tag        = $words[1]
                Size       = $words[3]
                Node       = $node
            }
            $windowsContainerImages += $containerImage
        }
        if ($IncludeK8sImages -eq $false) {
            $windowsContainerImages =
            Get-FilteredImages -ContainerImages $windowsContainerImages -ContainerImagesToBeCleaned $KubernetesImages
        }

        # Filter addon images and deduplicate
        $windowsContainerImages = Invoke-ImageFilteringAndDeduplication -ContainerImages $windowsContainerImages -ExcludeAddonImages $ExcludeAddonImages -NodeType 'Windows'
    }
    return $windowsContainerImages
}

function Invoke-ImageFilteringAndDeduplication {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Array of container images to process.')]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$ContainerImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Set to $true to exclude addon images.')]
        [bool]$ExcludeAddonImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Type of node: Linux or Windows.')]
        [ValidateSet('Linux', 'Windows')]
        [string]$NodeType
    )

    # Handle null input
    if ($null -eq $ContainerImages) {
        Write-Log "[$NodeType`Node] No images available to filter"
        $ContainerImages = @()
        return $ContainerImages
    }

    # Filter addon images from excluded namespaces
    $ContainerImages = Filter-AddonImagesFromList -ContainerImages $ContainerImages -ExcludeAddonImages $ExcludeAddonImages -NodeType $NodeType

    # Ensure we have an array (even if empty) before deduplication
    if ($null -eq $ContainerImages) {
        Write-Log "[$NodeType`Node] Filter returned null, initializing empty array"
        $ContainerImages = @()
        return $ContainerImages
    }

    # Deduplicate images with same ImageID (prefer tagged over <none>) - only if there are images
    if ($ContainerImages.Count -gt 0) {
        $ContainerImages = Remove-DuplicateImages -ContainerImages $ContainerImages -NodeType $NodeType
    } else {
        Write-Log "[$NodeType`Node] No images to deduplicate"
    }

    return $ContainerImages
}

function Invoke-RegistryQueryOnLinuxNode {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$NodeInfo,
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    if ($NodeInfo.Kind -eq 'ControlPlane') {
        return (Invoke-CmdOnControlPlaneViaSSHKey $Command -IgnoreErrors -Timeout 30).Output | Out-String
    }

    if ($NodeInfo.Kind -eq 'LinuxWorker') {
        return (Invoke-CmdOnVmViaSSHKey -CmdToExecute $Command -IpAddress $NodeInfo.IpAddress -UserName $NodeInfo.Username -NoLog -IgnoreErrors -Timeout 30).Output | Out-String
    }

    return ''
}

function Get-PushedContainerImages  {
      param(
        [Parameter(Mandatory = $false)]
        [hashtable[]]$NodeInfos = @()
    ) 
    $setupFilePath = Get-SetupConfigFilePath
    $enableAddons = Get-ConfigValue -Path $setupFilePath -Key 'EnabledAddons'
    $isRegistryAddonEnabled = $enableAddons | Select-Object -ExpandProperty Name | Where-Object { $_ -eq 'registry' }
    if (!$isRegistryAddonEnabled) {
        return @()
    }

    $registryName = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s.registry.local' }
    if ([string]::IsNullOrWhiteSpace($registryName)) {
        Write-Log '[ImageList] Registry addon enabled, but no k2s.registry.local entry found in setup config'
        return @()
    }

    $registryNodeName = ''
    try {
        $kubectlExe = "$kubeBinPath\kubectl.exe"
        if (Test-Path $kubectlExe) {
            $registryPodsJson = (& $kubectlExe -n registry get pod -l app=registry -o json 2>$null) | Out-String
            if (-not [string]::IsNullOrWhiteSpace($registryPodsJson)) {
                $registryPods = $registryPodsJson | ConvertFrom-Json
                if ($null -ne $registryPods -and $null -ne $registryPods.items -and $registryPods.items.Count -gt 0) {
                    $registryNodeName = [string]$registryPods.items[0].spec.nodeName
                    $registryNodeName = $registryNodeName.Trim()
                }
            }
        }
    }
    catch {
        Write-Log "[ImageList] Unable to detect registry pod node, using control-plane node name fallback"
    }

    if ([string]::IsNullOrWhiteSpace($registryNodeName)) {
        $registryNodeName = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
        if ([string]::IsNullOrWhiteSpace($registryNodeName)) {
            $registryNodeName = 'kubemaster'
        }
    }

    $isNodePort = $registryName -match ':'

    $catalog = $null
    try {
        if (!$isNodePort) {
            $catalogRaw = $(curl.exe --noproxy $registryName --retry 3 --retry-all-errors -k -X GET https://$registryName/v2/_catalog) 2> $null | Out-String
        }
        else {
            $catalogRaw = $(curl.exe --noproxy $registryName --retry 3 --retry-all-errors -X GET http://$registryName/v2/_catalog) 2> $null | Out-String
        }

        if (-not [string]::IsNullOrWhiteSpace($catalogRaw)) {
            $catalog = $catalogRaw | ConvertFrom-Json
        }
    }
    catch {
        Write-Log "[ImageList] Failed to query registry catalog from '$registryName': $($_.Exception.Message)"
        return @()
    }

    if ($null -eq $catalog -or $null -eq $catalog.repositories) {
        Write-Log "[ImageList] Registry catalog is empty or invalid for '$registryName'"
        return @()
    }

    $images = @($catalog.repositories)
    if ($images.Count -eq 0) {
        return @()
    }

    $pushedContainerImages = @()
    foreach ($image in $images) {
        $imageWithTags = $null
        try {
            if (!$isNodePort) {
                $imageWithTagsRaw = curl.exe --noproxy $registryName --retry 3 --retry-all-errors -k -X GET https://$registryName/v2/$image/tags/list 2> $null | Out-String
            }
            else {
                $imageWithTagsRaw = curl.exe --noproxy $registryName --retry 3 --retry-all-errors -X GET http://$registryName/v2/$image/tags/list 2> $null | Out-String
            }

            if (-not [string]::IsNullOrWhiteSpace($imageWithTagsRaw)) {
                $imageWithTags = $imageWithTagsRaw | ConvertFrom-Json
            }
        }
        catch {
            Write-Log "[ImageList] Failed to query tags for image '$image' from '$registryName': $($_.Exception.Message)"
            continue
        }

        $tags = @()
        if ($null -ne $imageWithTags -and $null -ne $imageWithTags.tags) {
            $tags = @($imageWithTags.tags)
        }
        if ($tags.Count -eq 0) {
            continue
        }

        foreach ($tag in $tags) {
            $pushedimage = [PushedImage]@{
                Name = "$registryName/" + $image
                Tag  = $tag
                Node = $registryNodeName
            }
            $pushedContainerImages += $pushedimage
        }
    }

    return $pushedContainerImages
}

function Remove-ImageOnLinuxViaSSH {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageId,
        [Parameter(Mandatory = $true)]
        [string]$ImageReference,
        [Parameter(Mandatory = $true)]
        [string]$NodeName,
        [Parameter(Mandatory = $false)]
        [string]$IpAddress = '',
        [Parameter(Mandatory = $false)]
        [string]$UserName = '',
        [Parameter(Mandatory = $false)]
        [switch]$Force,
        [Parameter(Mandatory = $false)]
        [switch]$IsControlPlane
    )

    $invokeCmd = if ($IsControlPlane) {
        { param($cmd) (Invoke-CmdOnControlPlaneViaSSHKey $cmd -NoLog -IgnoreErrors) }
    }
    else {
        $resolvedUser = if ([string]::IsNullOrWhiteSpace($UserName)) { Get-DefaultUserNameControlPlane } else { $UserName }
        { param($cmd) (Invoke-CmdOnVmViaSSHKey -CmdToExecute $cmd -IpAddress $IpAddress -UserName $resolvedUser -NoLog -IgnoreErrors) }
    }

    if ($Force) {
        $imageSelectors = @($ImageId)
        if (-not [string]::IsNullOrWhiteSpace($ImageReference) -and $ImageReference -ne $ImageId) {
            $imageSelectors += $ImageReference
        }

        foreach ($imageSelector in $imageSelectors) {
            $containersResult = & $invokeCmd "sudo crictl ps -a -q --image '$imageSelector' 2>/dev/null"
            $containersOutput = @($containersResult.Output)
            foreach ($containerId in @($containersOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
                Write-Log "[ImageRm] Stopping container $containerId on '$NodeName' (selector='$imageSelector')"
                & $invokeCmd "sudo crictl stop $containerId 2>/dev/null" | Out-Null
                & $invokeCmd "sudo crictl rm $containerId 2>/dev/null" | Out-Null
            }

            $podsResult = & $invokeCmd 'sudo crictl pods -q 2>/dev/null'
            $podsOutput = @($podsResult.Output)
            foreach ($podId in @($podsOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $podContainersResult = & $invokeCmd "sudo crictl ps -a -q -p $podId --image '$imageSelector' 2>/dev/null"
                $podContainers = @($podContainersResult.Output)
                if ($podContainers.Count -gt 0) {
                    Write-Log "[ImageRm] Stopping pod $podId on '$NodeName' (selector='$imageSelector')"
                    & $invokeCmd "sudo crictl stopp $podId 2>/dev/null" | Out-Null
                    & $invokeCmd "sudo crictl rmp $podId 2>/dev/null" | Out-Null
                }
            }
        }

        # Give kubelet/runtime a short grace period after container/pod removals.
        Start-Sleep -Seconds 2
    }

    # OS-specific backend fallback for Linux nodes:
    # 1) buildah by reference (aligns with Linux listing)
    # 2) crictl by reference
    # 3) crictl by image id
    $attemptLogs = @()

    $buildahExists = & $invokeCmd 'command -v buildah >/dev/null 2>&1'
    if ($buildahExists.Success) {
        $buildahRemoveCmd = if ($Force) {
            "sudo buildah rmi -f '$ImageReference' 2>&1"
        }
        else {
            "sudo buildah rmi '$ImageReference' 2>&1"
        }

        $buildahRemoveResult = & $invokeCmd $buildahRemoveCmd
        if ($buildahRemoveResult.Success) {
            return ($buildahRemoveResult.Output | Out-String)
        }

        $attemptLogs += "buildah(reference=$ImageReference): $($buildahRemoveResult.Output | Out-String)"
        Write-Log "[ImageRm] buildah remove failed on '$NodeName', trying crictl fallback"
    }
    else {
        $attemptLogs += 'buildah: not available'
    }

    $crictlRefResult = & $invokeCmd "sudo crictl rmi '$ImageReference' 2>&1"
    if ($crictlRefResult.Success) {
        return ($crictlRefResult.Output | Out-String)
    }
    $attemptLogs += "crictl(reference=$ImageReference): $($crictlRefResult.Output | Out-String)"

    if ($ImageReference -ne $ImageId) {
        $crictlIdResult = & $invokeCmd "sudo crictl rmi '$ImageId' 2>&1"
        if ($crictlIdResult.Success) {
            return ($crictlIdResult.Output | Out-String)
        }
        $attemptLogs += "crictl(id=$ImageId): $($crictlIdResult.Output | Out-String)"
    }

    return "__K2S_IMAGE_DELETE_FAILED__`n$($attemptLogs -join "`n")"
}

function Remove-ImageOnWindowsVm {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageId,
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    $session = $null
    try {
        $session = Open-RemoteSession -VmName $VmName -VmPwd (Get-DefaultTempPwd) -NoLog

        $output = Invoke-Command -Session $session -ArgumentList $ImageId, [bool]$Force, $kubeBinPath -ScriptBlock {
            param($remoteImageId, $remoteForce, $remoteKubeBinPath)

            $remoteCrictlPath = "$remoteKubeBinPath\crictl.exe"
            if (-not (Test-Path $remoteCrictlPath)) {
                $remoteCrictlPath = (Get-Command crictl.exe -ErrorAction Stop).Path
            }

            $remoteConfigPath = "$remoteKubeBinPath\crictl.yaml"
            if (-not (Test-Path $remoteConfigPath)) {
                $remoteConfigPath = Join-Path (Split-Path $remoteCrictlPath -Parent) 'crictl.yaml'
            }

            if ($remoteForce) {
                $containersOutput = & $remoteCrictlPath --config $remoteConfigPath ps -a -q --image $remoteImageId 2>$null
                foreach ($containerId in @($containersOutput)) {
                    if (![string]::IsNullOrWhiteSpace($containerId)) {
                        & $remoteCrictlPath --config $remoteConfigPath stop $containerId 2>$null | Out-Null
                        & $remoteCrictlPath --config $remoteConfigPath rm $containerId 2>$null | Out-Null
                    }
                }

                $podsOutput = & $remoteCrictlPath --config $remoteConfigPath pods -q 2>$null
                foreach ($podId in @($podsOutput)) {
                    if (![string]::IsNullOrWhiteSpace($podId)) {
                        $podContainers = & $remoteCrictlPath --config $remoteConfigPath ps -a -q -p $podId --image $remoteImageId 2>$null
                        if ($podContainers) {
                            & $remoteCrictlPath --config $remoteConfigPath stopp $podId 2>$null | Out-Null
                            & $remoteCrictlPath --config $remoteConfigPath rmp $podId 2>$null | Out-Null
                        }
                    }
                }
            }

            & $remoteCrictlPath --config $remoteConfigPath rmi $remoteImageId 2>&1
        }

        return @($output)
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Remove-Image([ContainerImage]$ContainerImage, [switch]$Force) {
    $output = ''
    $imageId = $ContainerImage.ImageId
    $imageReference = "$($ContainerImage.Repository):$($ContainerImage.Tag)"
    $nodeName = $ContainerImage.Node.ToLower()

    # Resolve control-plane node name from setup.json
    $setupFilePath = Get-SetupConfigFilePath
    $controlPlaneNodeName = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    if ([string]::IsNullOrWhiteSpace($controlPlaneNodeName)) {
        $controlPlaneNodeName = 'kubemaster'
    }
    $controlPlaneNodeNameLower = $controlPlaneNodeName.ToLower()
    $localWindowsNodeName = $env:ComputerName.ToLower()

    Write-Log "[ImageRm] Removing image '$imageId' from node '$nodeName'"

    if ($nodeName -eq $localWindowsNodeName) {
        # ── Windows host node ────────────────────────────────────────────
        if ($Force) {
            $containersOutput = $(&$crictlExe --config $kubeBinPath\crictl.yaml ps -a -q --image $imageId 2>&1)
            if ($containersOutput) {
                foreach ($containerId in $containersOutput) {
                    if (![string]::IsNullOrWhiteSpace($containerId)) {
                        Write-Log "[ImageRm] Stopping and removing container $containerId that uses image $imageId"
                        $(&$crictlExe --config $kubeBinPath\crictl.yaml stop $containerId 2>&1) | Out-Null
                        $(&$crictlExe --config $kubeBinPath\crictl.yaml rm $containerId 2>&1) | Out-Null
                    }
                }
            }
            $podsOutput = $(&$crictlExe --config $kubeBinPath\crictl.yaml pods -q 2>&1)
            if ($podsOutput) {
                foreach ($podId in $podsOutput) {
                    if (![string]::IsNullOrWhiteSpace($podId)) {
                        $podContainers = $(&$crictlExe --config $kubeBinPath\crictl.yaml ps -a -q -p $podId --image $imageId 2>&1)
                        if ($podContainers) {
                            Write-Log "[ImageRm] Stopping and removing pod $podId that uses image $imageId"
                            $(&$crictlExe --config $kubeBinPath\crictl.yaml stopp $podId 2>&1) | Out-Null
                            $(&$crictlExe --config $kubeBinPath\crictl.yaml rmp $podId 2>&1) | Out-Null
                        }
                    }
                }
            }
        }
        $output = $(&$crictlExe --config $kubeBinPath\crictl.yaml rmi $imageReference 2>&1)
        if (!$?) {
            $output = "__K2S_IMAGE_DELETE_FAILED__`n$($output | Out-String)"
        }

    }
    elseif ($nodeName -eq $controlPlaneNodeNameLower) {
        # ── Linux control-plane node ─────────────────────────────────────
        $output = Remove-ImageOnLinuxViaSSH -ImageId $imageId -ImageReference $imageReference -NodeName $nodeName -Force:$Force -IsControlPlane

    }
    else {
        # ── Remote node (Linux/Windows) from cluster descriptor ──────────
        $clusterNode = Get-NodeConfig -NodeName $nodeName
        if ($null -eq $clusterNode) {
            $errMsg = "Cannot remove image '$imageId': node '$nodeName' not found in cluster descriptor"
            Write-Log "[ImageRm] $errMsg"
            return $errMsg
        }

        $nodeOs = "$($clusterNode.OS)".ToLower()
        if ($nodeOs -eq 'linux') {
            if ([string]::IsNullOrWhiteSpace($clusterNode.IpAddress)) {
                $errMsg = "Cannot remove image '$imageId': node '$nodeName' has no IpAddress in cluster descriptor"
                Write-Log "[ImageRm] $errMsg"
                return $errMsg
            }

            $output = Remove-ImageOnLinuxViaSSH -ImageId $imageId -ImageReference $imageReference -NodeName $nodeName `
                -IpAddress $clusterNode.IpAddress -UserName $clusterNode.Username `
                -Force:$Force
        }
        elseif ($nodeOs -eq 'windows') {
            $nodeType = "$($clusterNode.NodeType)"
            if ($nodeType -eq 'VM-EXISTING') {
                Write-Log "[ImageRm] Removing image '$imageId' on remote Windows VM node '$nodeName'"
                $output = Remove-ImageOnWindowsVm -ImageId $imageId -VmName $nodeName -Force:$Force
            }
            else {
                $errMsg = "Cannot remove image '$imageId': node '$nodeName' is a non-local Windows HOST node; remote deletion is not implemented"
                Write-Log "[ImageRm] $errMsg"
                return $errMsg
            }
        }
        else {
            $errMsg = "Cannot remove image '$imageId': node '$nodeName' has unsupported OS '$nodeOs'"
            Write-Log "[ImageRm] $errMsg"
            return $errMsg
        }
    }

    $errorString = Get-ErrorMessageIfImageDeletionFailed -Output $output

    return $errorString
}

function Remove-PushedImage($name, $tag) {
    $registryName = $(Get-RegistriesFromSetupJson) | Where-Object { $_ -match 'k2s.registry.*' }
    # $auth = Get-RegistryAuthToken $registryName
    # if (!$auth) {
    #     Write-Error "Can't find authentication token for $registryName."
    #     return
    # }

    if ($name.Contains("$registryName/")) {
        $name = $name.Replace("$registryName/", '')
    }

    $status = $null
    $statusDescription = $null

    $isNodePort = $registryName -match ':'
    if (!$isNodePort) {
        $headRequest = "curl.exe -m 10 --noproxy $registryName --retry 3 --retry-connrefused -k -I https://$registryName/v2/$name/manifests/$tag $concatenatedHeadersString -v 2>&1"
    }
    else {
        $headRequest = "curl.exe -m 10 --noproxy $registryName --retry 3 --retry-connrefused -I http://$registryName/v2/$name/manifests/$tag $concatenatedHeadersString -v 2>&1"
    }

    $headResponse = Invoke-Expression $headRequest
    foreach ($line in $headResponse) {
        if ($line -match 'HTTP/1.1 (\d{3}) (.+)') {
            # Extract the HTTP status code and description
            $status = $matches[1]
            $statusDescription = $matches[2]
            break
        }
    }
    $imageName = $name + ':' + $tag
    if ($status -eq '200') {
        Write-Output "Successfully retrieved digest for $imageName from $registryName"
    }
    else {
        Write-Error "An error occurred while getting digest. HTTP Status Code: $status $statusDescription"
    }


    $lineWithDigest = $headResponse | Select-String 'Docker-Content-Digest:' | Select-Object -ExpandProperty Line -First 1
    $match = Select-String 'Docker-Content-Digest: (.*)' -InputObject $lineWithDigest
    $digest = $match.Matches.Groups[1].Value

    if (!$isNodePort) {
        $deleteRequest = "curl.exe -m 10 -k -I --noproxy $registryName --retry 3 --retry-connrefused -X DELETE https://$registryName/v2/$name/manifests/$digest $concatenatedHeadersString -v 2>&1"
    }
    else {
        $deleteRequest = "curl.exe -m 10 -I --noproxy $registryName --retry 3 --retry-connrefused -X DELETE http://$registryName/v2/$name/manifests/$digest $concatenatedHeadersString -v 2>&1"
    }
    $deleteResponse = Invoke-Expression $deleteRequest

    foreach ($line in $deleteResponse) {
        if ($line -match 'HTTP/1.1 (\d{3}) (.+)') {
            # Extract the HTTP status code and description
            $status = $matches[1]
            $statusDescription = $matches[2]
            break
        }
    }

    $imageName = $name + ':' + $tag
    if ($status -eq '202') {
        Write-Output "Successfully deleted image $imageName from $registryName"
    }
    else {
        Write-Error "An error occurred while deleting image. HTTP Status Code: $status $statusDescription"
    }
}

function Get-RegistryAuthToken($registryName) {
    # read auth
    $authJson = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json').Output | Out-String
    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    $auth = $authk2s.psobject.properties['auth'].value
    return $auth
}

function Get-ContainerImagesInk2s([bool]$IncludeK8sImages = $false, [bool]$ExcludeAddonImages = $false, [string]$Nodes = '') {
    $setupFilePath = Get-SetupConfigFilePath
    $linuxNodeName = Get-ConfigValue -Path $setupFilePath -Key 'ControlPlaneNodeHostname'
    if ([string]::IsNullOrWhiteSpace($linuxNodeName)) {
        $linuxNodeName = 'kubemaster'
    }

    $linuxNodeNameLower = $linuxNodeName.ToLower()
    $windowsNodeName = $env:ComputerName.ToLower()
    $requestedNodes = @()

    if (-not [string]::IsNullOrWhiteSpace($Nodes)) {
        $requestedNodes = @($Nodes -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' } | Select-Object -Unique)
        Write-Log "[ImageFilter] Node filter requested: $($requestedNodes -join ', ')"
    }

    if ($requestedNodes.Count -eq 0) {
        $linuxContainerImages = @(Get-ContainerImagesOnLinuxNode -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages)
        Write-Log "[ImageFilter] Found $($linuxContainerImages.Count) Linux image(s)"
        $linuxContainerImages | ForEach-Object { Write-Log "[ImageFilter]   Linux: $($_.Repository):$($_.Tag) (ID: $($_.ImageId), Node: $($_.Node), Size: $($_.Size))" }

        $windowsContainerImages = @(Get-ContainerImagesOnWindowsNode -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages)
        Write-Log "[ImageFilter] Found $($windowsContainerImages.Count) Windows image(s)"
        $windowsContainerImages | ForEach-Object { Write-Log "[ImageFilter]   Windows: $($_.Repository):$($_.Tag) (ID: $($_.ImageId), Node: $($_.Node), Size: $($_.Size))" }

        return @($linuxContainerImages) + @($windowsContainerImages)
    }

    $allContainerImages = @()

    foreach ($requestedNode in $requestedNodes) {
        if ($requestedNode -eq $linuxNodeNameLower) {
            $linuxImages = @(Get-ContainerImagesOnLinuxNode -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages -NodeName $requestedNode)
            Write-Log "[ImageFilter] Found $($linuxImages.Count) Linux image(s) for node '$requestedNode'"
            $allContainerImages += $linuxImages
            continue
        }

        if ($requestedNode -eq $windowsNodeName) {
            $windowsImages = @(Get-ContainerImagesOnWindowsNode -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages -NodeName $requestedNode -NodeType 'HOST')
            Write-Log "[ImageFilter] Found $($windowsImages.Count) Windows image(s) for node '$requestedNode'"
            $allContainerImages += $windowsImages
            continue
        }

        $clusterNode = Get-NodeConfig -NodeName $requestedNode
        if ($null -eq $clusterNode) {
            Write-Log "[ImageFilter] Requested node '$requestedNode' not found in cluster descriptor"
            continue
        }

        $nodeOs = "$($clusterNode.OS)".ToLower()
        if ($nodeOs -eq 'linux') {
            if ([string]::IsNullOrWhiteSpace($clusterNode.IpAddress) -or [string]::IsNullOrWhiteSpace($clusterNode.Username)) {
                Write-Log "[ImageFilter] Node '$requestedNode' is linux but missing IpAddress/Username in cluster.json"
                continue
            }

            $linuxImages = @(Get-ContainerImagesOnLinuxNode -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages -IpAddress $clusterNode.IpAddress -UserName $clusterNode.Username -NodeName $requestedNode)
            Write-Log "[ImageFilter] Found $($linuxImages.Count) Linux image(s) for node '$requestedNode'"
            $allContainerImages += $linuxImages
            continue
        }

        if ($nodeOs -eq 'windows') {
            $windowsImages = @(Get-ContainerImagesOnWindowsNode -IncludeK8sImages $IncludeK8sImages -ExcludeAddonImages $ExcludeAddonImages -NodeName $requestedNode -NodeType "$($clusterNode.NodeType)")
            Write-Log "[ImageFilter] Found $($windowsImages.Count) Windows image(s) for node '$requestedNode'"
            $allContainerImages += $windowsImages
            continue
        }

        Write-Log "[ImageFilter] Node '$requestedNode' has unsupported OS '$nodeOs' in cluster.json"
    }

    Write-Log "[ImageFilter] Total images after node filter: $($allContainerImages.Count)"
    return @($allContainerImages)
}

function Get-ErrorMessageIfImageDeletionFailed([string]$Output) {
    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $null
    }

    if ($output.Contains('__K2S_IMAGE_DELETE_FAILED__')) {
        $details = $output.Replace('__K2S_IMAGE_DELETE_FAILED__', '').Trim()

        if ($details.Contains('image is in use by a container')) {
            return 'Unable to delete the image as it is in use by a container.'
        }
        if ($details.Contains('context deadline exceeded')) {
            return 'Unable to delete the image as the operation timed-out.'
        }
        if ($details.Contains('no such image') -or $details.Contains('image not known') -or $details.Contains('ImageUnknown')) {
            return 'Unable to delete the image as it was not found.'
        }

        $firstLine = (($details -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($firstLine)) {
            return "Unable to delete the image on target node. Details: $firstLine"
        }

        return 'Unable to delete the image on target node.'
    }

    if ($output.Contains('image is in use by a container')) {
        return 'Unable to delete the image as it is in use by a container.'
    }
    elseif ($output.Contains('context deadline exceeded')) {
        return 'Unable to delete the image as the operation timed-out.'
    }
    elseif ($output.Contains('no such image') -or $output.Contains('image not known') -or $output.Contains('ImageUnknown')) {
        return 'Unable to delete the image as it was not found.'
    }
    else {
        return $null
    }
}

function Show-ImageDeletionStatus([ContainerImage]$ContainerImage, [string]$ErrorMessage) {
    $imageName = $ContainerImage.Repository + ':' + $ContainerImage.Tag
    $node = $ContainerImage.Node
    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) {
        Write-Log "Successfully deleted image $imageName from $node"
        return 0
    }
    else {
        Write-Log "Failed to delete image $imageName from $node. Reason: $ErrorMessage"
        return 1
    }
}

function Get-BuildArgs([string[]]$buildArgs) {
    $buildArgString = ''
    foreach ($buildArgValuePair in $buildArgs) {
        $array = $buildArgValuePair.Split('=')
        $name = $array[0]
        $value = $array[1]
        $buildArgString += "--build-arg $name=$value "
    }
    if ($buildArgString.Length -gt 0) {
        $buildArgString = $buildArgString.Substring(0, $buildArgString.Length - 1)
    }
    return $buildArgString
}

function Get-DockerfileAbsolutePathAndPreCompileFlag {
    param(
        [Parameter()]
        [String] $InputFolder,
        [Parameter()]
        [String] $Dockerfile,
        [Parameter()]
        [switch] $PreCompile
    )

    if ($Dockerfile -ne '') {
        $filePath = ''
        try {
            # try to resolve the path relative to current working directory first.
            $filePath = (Resolve-Path -Path $Dockerfile -ErrorAction Stop).Path
        }
        catch {
            # if this fails, try to resolve it relative to Input folder.
            # if this also fails, stop execution
            Write-Log "Could not resolve Dockerfile from current working directory. We will now try to resolve it from $InputFolder"
            if (! (Test-Path "$InputFolder\$Dockerfile")) { throw 'Unable to find Dockerfile' }
            $filePath = "$InputFolder\$Dockerfile"
        }
        # If the Dockerfile ends with PreCompile, we set the PreCompile flag to true
        if ($Dockerfile -like '*PreCompile') {
            $PreCompile = $True
        }

        # We return PreCompile flag
        return $filePath, $PreCompile
    }

    if ($Dockerfile -eq '' -and $PreCompile) {
        $Dockerfile = 'Dockerfile.PreCompile'
        Write-Log "Pre-Compilation: using $Dockerfile"
    }

    # set defaults if no dockerfile given: If Dockerfile.PreCompile is available, use that,
    # otherwise use Dockerfile
    if ($Dockerfile -eq '') {
        $Dockerfile = 'Dockerfile.PreCompile'
        if (Test-Path "$InputFolder\$Dockerfile") {
            $PreCompile = $True
            Write-Log "Pre-Compilation: using $Dockerfile"
        }
        else {
            $Dockerfile = 'Dockerfile'
            Write-Log "Full: using $Dockerfile"
        }
    }
    if (! (Test-Path "$InputFolder\$Dockerfile")) { throw "Missing Dockerfile: $InputFolder\$Dockerfile" }

    $filePath = "$InputFolder\$Dockerfile"
    return $filePath, $PreCompile
}

function Wait-UntilServiceIsRunning {
    param (
        $Name = $(throw 'Argument missing: ServiceName')
    )

    # ensure service is running
    $expectedServiceStatus = 'SERVICE_RUNNING'
    Write-Log "Waiting until service '$Name' has status '$expectedServiceStatus'"
    $retryNumber = 0
    $maxAmountOfRetries = 3
    $waitTimeInSeconds = 2
    $serviceIsRunning = $false
    while ($retryNumber -lt $maxAmountOfRetries) {
        $serviceStatus = (&$kubeBinPath\nssm status $Name)
        if ($serviceStatus -eq "$expectedServiceStatus") {
            $serviceIsRunning = $true
            break;
        }
        $retryNumber++
        Start-Sleep -Seconds $waitTimeInSeconds
        $totalWaitingTime = $waitTimeInSeconds * $retryNumber
        Write-Log "Waiting since $totalWaitingTime seconds for service '$Name' to be in status '$expectedServiceStatus' (current status: $serviceStatus)"
    }
    if (!$serviceIsRunning) {
        throw "Service '$Name' is not running."
    }
    Write-Log "Service '$Name' has status '$expectedServiceStatus'"
}

function New-WindowsImage {
    param(
        [Parameter()]
        [String] $InputFolder,
        [Parameter()]
        [String] $Dockerfile,
        [Parameter()]
        [String] $ImageName,
        [Parameter()]
        [String] $ImageTag,
        [Parameter()]
        [String] $NoCacheFlag,
        [Parameter()]
        [String] $BuildArgsString
    )
    $shouldStopDocker = $false
    $svc = (Get-Service 'docker' -ErrorAction Stop)
    if ($svc.Status -ne 'Running') {
        Write-Log 'Starting docker backend...'
        Start-Service docker
        Wait-UntilServiceIsRunning -Name 'docker'
        $shouldStopDocker = $true
    }

    $imageFullName = "${ImageName}:$ImageTag"

    Write-Log "Building Windows image $imageFullName" -Console
    if ($BuildArgsString -ne '') {
        $cmd = "$dockerExe build ""$InputFolder"" -f ""$Dockerfile"" --force-rm $NoCacheFlag -t $imageFullName $BuildArgsString"
    }
    else {
        $cmd = "$dockerExe build ""$InputFolder"" -f ""$Dockerfile"" --force-rm $NoCacheFlag -t $imageFullName"
    }
    Write-Log "Build cmd: $cmd"
    & cmd.exe /c $cmd *>&1 | Where-Object { (-not(($_ -is [System.Management.Automation.ErrorRecord])) -or (($_ -is [System.Management.Automation.ErrorRecord]) -and -not($_ -match 'System.Management.Automation.RemoteException'))) } | ForEach-Object { Write-Log $_ }
    
    if ($LASTEXITCODE -ne 0) { throw "error while creating image with 'docker build' on Windows. Error code returned was $LastExitCode" }

    Write-Log "Output of checking if the image $imageFullName is now available in docker:"
    $dockerListOutput = &$dockerExe image ls $ImageName -a --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}" 2>&1
    $dockerListOutput | ForEach-Object { Write-Log $_ }

    $exportedImageFullFileName = $env:TEMP + '\BuiltImage.tar'
    if (Test-Path($exportedImageFullFileName)) {
        Remove-Item $exportedImageFullFileName -Force
    }

    Write-Log "Saving image $imageFullName temporarily as $exportedImageFullFileName to import it afterwards into containerd..."
    &$dockerExe save -o "$exportedImageFullFileName" $imageFullName
    if (!$?) { throw "error while saving built image '$imageFullName' with 'docker save' on Windows. Error code returned was $LastExitCode" }
    Write-Log '...saved.'

    Write-Log "Importing image $imageFullName from $exportedImageFullFileName into containerd..."
    $importSuccess = Invoke-Ctr -Arguments '-n', 'k8s.io', 'images', 'import', $exportedImageFullFileName
    if (-not $importSuccess) { throw "error while importing built image '$imageFullName' with 'ctr images import' on Windows." }
    Write-Log '...imported'

    Write-Log "Removing temporarily created file $exportedImageFullFileName..."
    Remove-Item $exportedImageFullFileName -Force
    Write-Log '...removed'

    $imageList = &$ctrExe -n="k8s.io" images list 2>&1 | Out-string

    if (!$imageList.Contains($imageFullName)) {
        throw "The built image '$imageFullName' was not imported in the containerd's local repository."
    }
    Write-Log "The built image '$imageFullName' is available in the containerd's local repository."

    if ($shouldStopDocker) {
        Write-Log 'Stopping docker backend...'
        Stop-Service docker
    }
}

function Set-DockerToExperimental {
    $env:DOCKER_CLI_EXPERIMENTAL = 'enabled'

    nssm restart docker

    if ($LASTEXITCODE -ne 0) {
        throw 'error while restarting Docker'
    }
}

function New-DockerManifest {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $AmendTag = $(throw 'AmendTag not specified'),
        [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
        [switch] $AllowInsecureRegistries
    )
    if ($AllowInsecureRegistries -eq $true) {
        &$dockerExe manifest create --insecure $Tag --amend $AmendTag
    }
    else {
        &$dockerExe manifest create $Tag --amend $AmendTag
    }

    if ($LASTEXITCODE -ne 0) {
        throw 'error while creating manifest'
    }
}

function New-DockerManifestAnnotation {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $AmendTag = $(throw 'AmendTag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $OS = $(throw 'OS not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Arch = $(throw 'Arch not specified'),
        [string]
        $OSVersion = $(throw 'OSVersion not specified')
    )
    &$dockerExe manifest annotate --os $OS --arch $Arch --os-version $OSVersion $Tag $AmendTag

    if ($LASTEXITCODE -ne 0) {
        throw 'error while annotating manifest'
    }
}

function Push-DockerManifest {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
        [switch] $AllowInsecureRegistries
    )
    if ($AllowInsecureRegistries -eq $true) {
        &$dockerExe manifest push --insecure $Tag
    }
    else {
        &$dockerExe manifest push $Tag
    }

    if ($LASTEXITCODE -ne 0) {
        throw 'error pushing manifest'
    }
}


function Get-ImagesFromNamespaces {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Array of namespaces to query for images.')]
        [string[]]$Namespaces,

        [Parameter(Mandatory = $true, HelpMessage = 'Log prefix for filtering context (e.g., "addon", "user").')]
        [string]$LogPrefix
    )

    if ($Namespaces.Count -eq 0) {
        Write-Log "[ImageFilter] No $LogPrefix namespaces to query"
        return @()
    }

    $kubectlExe = "$kubeBinPath\kube\kubectl.exe"
    $collectedImages = @()

    foreach ($namespace in $Namespaces) {
        try {
            # Query images from namespace using jsonpath for efficiency
            $output = & $kubectlExe get pods -n $namespace -o jsonpath="{.items[*].spec.containers[*].image}" 2>$null

            if ($output) {
                # Split by whitespace and filter empty strings
                $images = $output -split '\s+' | Where-Object { $_ -ne '' }

                if ($images.Count -gt 0) {
                    Write-Log "[ImageFilter]   Namespace '$namespace': found $($images.Count) image(s)"
                    $collectedImages += $images
                }
            }
        }
        catch {
            Write-Log "[ImageFilter]   Warning: Failed to query namespace '$namespace': $_"
        }
    }

    # Return unique images
    $uniqueImages = $collectedImages | Select-Object -Unique
    Write-Log "[ImageFilter] Total unique $LogPrefix images: $($uniqueImages.Count)"

    return $uniqueImages
}

function Get-ImagesFromExcludedNamespaces {
    # Get excluded namespaces from config
    $excludedNamespacesString = $rootConfig.backup.excludednamespaces

    if ([string]::IsNullOrWhiteSpace($excludedNamespacesString)) {
        Write-Log '[ImageFilter] No excluded namespaces configured'
        return @()
    }

    # Parse comma-separated namespace list
    $excludedNamespaces = $excludedNamespacesString -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    Write-Log "[ImageFilter] Excluding images from $($excludedNamespaces.Count) addon/infrastructure namespaces"

    # Use common helper to get images
    return Get-ImagesFromNamespaces -Namespaces $excludedNamespaces -LogPrefix 'addon'
}

function Get-ImagesFromUserNamespaces {
    $kubectlExe = "$kubeBinPath\kube\kubectl.exe"

    # Get excluded namespaces from config
    $excludedNamespacesString = $rootConfig.backup.excludednamespaces
    # Parse excluded namespaces
    $excludedNamespaces = @()
    if (-not [string]::IsNullOrWhiteSpace($excludedNamespacesString)) {
        $excludedNamespaces = $excludedNamespacesString -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }

    # Get all namespaces
    try {
        $allNamespacesOutput = & $kubectlExe get namespaces -o jsonpath="{.items[*].metadata.name}" 2>$null

        if (-not $allNamespacesOutput) {
            Write-Log "[ImageFilter] No namespaces found in cluster"
            return @()
        }

        # Parse all namespaces
        $allNamespaces = $allNamespacesOutput -split '\s+' | Where-Object { $_ -ne '' }

        # Filter out excluded namespaces to get user namespaces
        $userNamespaces = $allNamespaces | Where-Object { $excludedNamespaces -notcontains $_ }

        Write-Log "[ImageFilter] Found $($userNamespaces.Count) user namespace(s) (excluding $($excludedNamespaces.Count) addon/system namespaces)"

        if ($userNamespaces.Count -eq 0) {
            Write-Log "[ImageFilter] No user namespaces found"
            return @()
        }

        # Use common helper to get images from user namespaces
        return Get-ImagesFromNamespaces -Namespaces $userNamespaces -LogPrefix 'user workload'
    }
    catch {
        Write-Log "[ImageFilter] Error getting user namespace images: $_" -Console
        return @()
    }
}

function Get-SharedImages {
    param(
        [string[]]$AddonImages,
        [string[]]$UserImages
    )

    $shared = @()
    if ($UserImages.Count -eq 0) {
        return $shared
    }
    foreach ($addonImg in $AddonImages) {
        if ($UserImages -contains $addonImg) {
            $shared += $addonImg
        }
    }
    if ($shared.Count -gt 0) {
        Write-Log "[ImageFilter] Found $($shared.Count) image(s) shared between addon and user namespaces - keeping them in backup:"
        $shared | ForEach-Object { Write-Log "[ImageFilter]   Shared: $_" }
    }
    return $shared
}

function Get-AddonOnlyRepositories {
    param([string[]]$AddonOnlyImages)

    return $AddonOnlyImages | ForEach-Object {
        if ($_ -match '^(.+):') { $Matches[1] } else { $_ }
    } | Select-Object -Unique
}

function Check-IsUserOrSharedImage {
    param(
        [object]$Image,
        [string[]]$AddonOnlyImages,
        [string[]]$AddonOnlyRepositories
    )

    # For <none> tags, match by repository only
    if ($Image.Tag -eq '<none>') {
        return $AddonOnlyRepositories -notcontains $Image.Repository
    }

    # For proper tags, match full image name
    $imageFullName = "$($Image.Repository):$($Image.Tag)"

    # Check if this image is in the addon-only list (not shared with users)
    return -not ($AddonOnlyImages -contains $imageFullName)
}

function Filter-AddonImagesFromList {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Array of container images to filter.')]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$ContainerImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Set to $true to exclude addon images from the list.')]
        [bool]$ExcludeAddonImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Node type: Linux or Windows.')]
        [ValidateSet('Linux', 'Windows')]
        [string]$NodeType
    )

    # Handle null or empty input
    if ($null -eq $ContainerImages -or $ContainerImages.Count -eq 0) {
        Write-Log "[$NodeType`Node] No images to filter (null or empty)"
        return @()
    }

    if ($ExcludeAddonImages -eq $false) {
        Write-Log "[$NodeType`Node] ExcludeAddonImages is FALSE, skipping addon filter"
        return $ContainerImages
    }

    Write-Log "[ImageFilter] Filtering addon images from $NodeType node..."

    # Get addon and user images
    $addonImageStrings = Get-ImagesFromExcludedNamespaces
    if ($addonImageStrings.Count -eq 0) {
        Write-Log "[ImageFilter] No addon images to exclude, returning all images"
        return $ContainerImages
    }

    $userImageStrings = Get-ImagesFromUserNamespaces
    Write-Log "[ImageFilter] Found $($addonImageStrings.Count) addon image(s) and $($userImageStrings.Count) user workload image(s)"

    # Identify shared images (used by both addons and users)
    $sharedImages = Get-SharedImages -AddonImages $addonImageStrings -UserImages $userImageStrings

    # Only exclude addon images that are NOT used by user workloads
    $addonOnlyImages = $addonImageStrings | Where-Object { $sharedImages -notcontains $_ }
    Write-Log "[ImageFilter] Excluding $($addonOnlyImages.Count) addon-only image(s) (not used by user workloads)"

    # Build lookup structures for efficient filtering
    $addonOnlyRepositories = Get-AddonOnlyRepositories -AddonOnlyImages $addonOnlyImages

    # Filter images
    $filteredImages = $ContainerImages | Where-Object {
        Check-IsUserOrSharedImage -Image $_ -AddonOnlyImages $addonOnlyImages -AddonOnlyRepositories $addonOnlyRepositories
    }

    Write-Log "[ImageFilter] After addon filtering: $($filteredImages.Count) image(s) remaining (user workload + shared images)"
    return $filteredImages
}

function Remove-DuplicateImages {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Array of container images to deduplicate.')]
        [AllowEmptyCollection()]
        [object[]]$ContainerImages,

        [Parameter(Mandatory = $true, HelpMessage = 'Type of node: Linux or Windows.')]
        [string]$NodeType
    )

    # Group images by ImageID to handle multiple tags per image
    $imageGroups = @{}
    foreach ($image in $ContainerImages) {
        $imageId = $image.ImageId

        if (-not $imageGroups.ContainsKey($imageId)) {
            $imageGroups[$imageId] = @()
        }
        $imageGroups[$imageId] += $image
    }

    # For each ImageID group, filter out <none> tags if real tags exist
    $deduplicatedImages = @()
    foreach ($imageId in $imageGroups.Keys) {
        $imagesForThisId = $imageGroups[$imageId]

        # Separate real tags from <none> tags
        $realTaggedImages = @($imagesForThisId | Where-Object { $_.Tag -ne '<none>' })
        $noneTaggedImages = @($imagesForThisId | Where-Object { $_.Tag -eq '<none>' })

        if ($realTaggedImages.Count -gt 0) {
            # Keep all real tags for this ImageID
            $deduplicatedImages += $realTaggedImages

            if ($noneTaggedImages.Count -gt 0) {
                Write-Log "[$NodeType`Node] Filtered out $($noneTaggedImages.Count) <none> tag(s) for ImageID: $imageId (keeping $($realTaggedImages.Count) real tag(s))"
            }
        }
        else {
            # Only <none> tags exist for this ImageID, keep one representative
            $deduplicatedImages += $imagesForThisId[0]

            if ($imagesForThisId.Count -gt 1) {
                Write-Log "[$NodeType`Node] Kept one representative <none> tag for ImageID: $imageId (had $($imagesForThisId.Count) duplicate(s))"
            }
        }
    }

    # Sort for consistent output
    $deduplicatedImages = $deduplicatedImages | Sort-Object Repository, Tag

    # Ensure we always return an array, even if empty
    if ($null -eq $deduplicatedImages) {
        Write-Log "[$NodeType`Node] All images were <none> tagged or list is empty, returning empty array"
        return @()
    }

    return $deduplicatedImages
}

Export-ModuleMember -Function Get-ContainerImagesInk2s, `
    Remove-Image, `
    Get-PushedContainerImages, `
    Remove-PushedImage, `
    Show-ImageDeletionStatus, `
    Get-ContainerImagesOnLinuxNode, `
    Get-ContainerImagesOnWindowsNode, `
    Write-KubernetesImagesIntoJson, `
    Get-BuildArgs, `
    Get-DockerfileAbsolutePathAndPreCompileFlag, `
    New-WindowsImage, `
    Set-DockerToExperimental, `
    New-DockerManifest, `
    New-DockerManifestAnnotation, `
    Push-DockerManifest
