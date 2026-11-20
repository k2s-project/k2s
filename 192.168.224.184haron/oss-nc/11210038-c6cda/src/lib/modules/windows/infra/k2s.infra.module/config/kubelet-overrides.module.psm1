# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$script:k2sKubeletManagedHeader = '# This file is managed by K2s. Do not edit.'
$script:k2sKubeletDropInPath = 'C:\etc\kubernetes\kubelet.conf.d\20-k2s-install-config.conf'

function Get-K2sKubeletOverrideContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $EffectiveInstallConfigPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('linuxControlPlane', 'windowsWorker')]
        [string] $Role
    )

    if (-not (Test-Path -LiteralPath $EffectiveInstallConfigPath -PathType Leaf)) {
        throw "Effective install configuration not found at '$EffectiveInstallConfigPath'"
    }

    try {
        $effectiveConfig = Get-Content -LiteralPath $EffectiveInstallConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to read effective install configuration '$EffectiveInstallConfigPath': $($_.Exception.Message)"
    }

    $overridesProperty = $effectiveConfig.PSObject.Properties['kubeletOverrides']
    if ($null -eq $overridesProperty -or $null -eq $overridesProperty.Value) {
        return $null
    }

    $roleProperty = $overridesProperty.Value.PSObject.Properties[$Role]
    if ($null -eq $roleProperty -or $null -eq $roleProperty.Value -or -not $roleProperty.Value.enabled) {
        return $null
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($script:k2sKubeletManagedHeader)
    $lines.Add('apiVersion: kubelet.config.k8s.io/v1beta1')
    $lines.Add('kind: KubeletConfiguration')

    $roleConfig = $roleProperty.Value.config
    if ($null -ne $roleConfig) {
        if ($null -ne $roleConfig.PSObject.Properties['maxPods']) {
            $lines.Add("maxPods: $($roleConfig.maxPods)")
        }
        Add-K2sKubeletResourceLines -Lines $lines -Config $roleConfig -PropertyName 'systemReserved'
        Add-K2sKubeletResourceLines -Lines $lines -Config $roleConfig -PropertyName 'kubeReserved'
    }

    return [string]::Join("`n", $lines) + "`n"
}

function Add-K2sKubeletResourceLines {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]] $Lines,
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Config,
        [Parameter(Mandatory = $true)]
        [ValidateSet('systemReserved', 'kubeReserved')]
        [string] $PropertyName
    )

    $resourceProperty = $Config.PSObject.Properties[$PropertyName]
    if ($null -eq $resourceProperty -or $null -eq $resourceProperty.Value) {
        return
    }

    $resources = $resourceProperty.Value
    $hasCpu = $null -ne $resources.PSObject.Properties['cpu'] -and -not [string]::IsNullOrEmpty([string]$resources.cpu)
    $hasMemory = $null -ne $resources.PSObject.Properties['memory'] -and -not [string]::IsNullOrEmpty([string]$resources.memory)
    if (-not $hasCpu -and -not $hasMemory) {
        return
    }

    $Lines.Add("${PropertyName}:")
    if ($hasCpu) {
        $Lines.Add("  cpu: $([string]$resources.cpu | ConvertTo-Json -Compress)")
    }
    if ($hasMemory) {
        $Lines.Add("  memory: $([string]$resources.memory | ConvertTo-Json -Compress)")
    }
}

function Test-K2sManagedKubeletDropIn {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
    return $firstLine -eq $script:k2sKubeletManagedHeader
}

function Set-K2sWindowsKubeletOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string] $EffectiveInstallConfigPath,
        [string] $TargetPath = $script:k2sKubeletDropInPath
    )

    $content = Get-K2sKubeletOverrideContent -EffectiveInstallConfigPath $EffectiveInstallConfigPath -Role 'windowsWorker'
    $targetItem = $null
    try {
        $targetItem = Get-Item -LiteralPath $TargetPath -Force -ErrorAction Stop
    }
    catch {
        if ($_.CategoryInfo.Category -ne 'ObjectNotFound') {
            throw "Failed to inspect kubelet drop-in '$TargetPath': $($_.Exception.Message)"
        }
    }

    $targetExists = $null -ne $targetItem
    if ($targetExists -and (($targetItem -isnot [System.IO.FileInfo]) -or (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))) {
        throw "Refusing to use non-regular kubelet drop-in collision '$TargetPath'"
    }

    if ([string]::IsNullOrEmpty($content)) {
        if (-not $targetExists) {
            return $false
        }
        if (-not (Test-K2sManagedKubeletDropIn -Path $TargetPath)) {
            throw "Refusing to remove unmanaged kubelet drop-in '$TargetPath'"
        }

        Remove-Item -LiteralPath $TargetPath -Force -ErrorAction Stop
        Restart-K2sKubeletIfRunning
        return $true
    }

    if ($targetExists -and -not (Test-K2sManagedKubeletDropIn -Path $TargetPath)) {
        throw "Refusing to replace unmanaged kubelet drop-in '$TargetPath'"
    }
    if ($targetExists -and (Get-Content -LiteralPath $TargetPath -Raw -ErrorAction Stop) -ceq $content) {
        return $false
    }

    $targetDirectory = Split-Path -Path $TargetPath -Parent
    New-Item -Path $targetDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $temporaryPath = Join-Path $targetDirectory ('.20-k2s-install-config.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $content, [System.Text.UTF8Encoding]::new($false))
        if ($targetExists) {
            [System.IO.File]::Replace($temporaryPath, $TargetPath, $null)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $TargetPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }

    Restart-K2sKubeletIfRunning
    return $true
}

function Restart-K2sKubeletIfRunning {
    $service = Get-Service -Name 'kubelet' -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -eq 'Running') {
        Restart-Service -Name 'kubelet' -ErrorAction Stop
    }
}

Export-ModuleMember -Function Get-K2sKubeletOverrideContent, Test-K2sManagedKubeletDropIn, Set-K2sWindowsKubeletOverride
