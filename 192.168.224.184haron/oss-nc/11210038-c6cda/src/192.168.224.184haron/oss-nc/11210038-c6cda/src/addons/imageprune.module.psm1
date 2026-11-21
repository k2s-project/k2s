# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Image pruning for addon omit options during offline import.

.DESCRIPTION
Implements the data model and the decision logic behind 'k2s addons import --omit'.

Addon manifests declare, per CLI flag, which container images belong to the functionality
that flag omits:

    commands:
      enable:
        cli:
          flags:
            - name: omitKeycloak
              default: false
              omittedImages:
                fromFiles:                       # preferred - images stay declared in the manifests
                  - manifests/keycloak/keycloak.yaml
                  - manifests/keycloak/keycloak-postgres.yaml
                explicit: []                     # escape hatch, e.g. Helm chart internals

The importer resolves those declarations against the freshly extracted manifests layer and
decides which of the per-image tars inside images-linux.tar / images-windows.tar can be
skipped. The OCI artifact itself is never modified, so re-running the import without the
omit option restores the missing images.

Pruning rule (global over the whole import session):
an image may only be skipped when NO imported addon/implementation still requires it.
#>

$infraModule = "$PSScriptRoot\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\addons.module.psm1"
$ociModule = "$PSScriptRoot\oci.module.psm1"

Import-Module $infraModule, $addonsModule, $ociModule

<#
.SYNOPSIS
Reduces a container image reference to its registry + repository identity.
.DESCRIPTION
COMPARISON HELPER - used exclusively to decide whether an omit declaration and an artifact
image denote the same image. It never rewrites a reference: export, the OCI artifact, the
tar entry names and the normal import path keep the full original reference including its
tag/digest.

Strips the tag and/or digest while keeping registry host, port and the full repository path.
Only the last path segment is searched for a tag separator, so a registry port
('localhost:5000/repo/image') is never mistaken for a tag.
.PARAMETER Image
The container image reference, e.g. 'quay.io/jetstack/cert-manager-controller:v1.21.1'.
.EXAMPLE
ConvertTo-OmitComparableImageIdentity -Image 'quay.io/jetstack/cert-manager-controller:v1.21.1'
# -> quay.io/jetstack/cert-manager-controller
#>
function ConvertTo-OmitComparableImageIdentity {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Image
    )

    $reference = "$Image".Trim()
    if ([string]::IsNullOrWhiteSpace($reference)) {
        return ''
    }

    # A digest always terminates the reference, everything from '@' on can be dropped.
    $digestIndex = $reference.IndexOf('@')
    if ($digestIndex -ge 0) {
        $reference = $reference.Substring(0, $digestIndex)
    }

    # A tag may only appear in the last path segment; a ':' before the last '/' is a port.
    $separatorIndex = $reference.LastIndexOf('/')
    $lastSegment = if ($separatorIndex -ge 0) { $reference.Substring($separatorIndex + 1) } else { $reference }
    $tagIndex = $lastSegment.LastIndexOf(':')
    if ($tagIndex -ge 0) {
        $lastSegment = $lastSegment.Substring(0, $tagIndex)
        $reference = if ($separatorIndex -ge 0) { $reference.Substring(0, $separatorIndex + 1) + $lastSegment } else { $lastSegment }
    }

    return $reference.Trim()
}

<#
.SYNOPSIS
Converts an image reference into the comparable identity key used for omit matching.
.DESCRIPTION
COMPARISON HELPER. Applies 'ConvertTo-OmitComparableImageIdentity' and then the very same
sanitization 'ConvertTo-ImageTarFileName' applies, so a key derived from a manifest
reference can be compared with a key derived from an artifact tar entry name.
.PARAMETER Image
The container image reference.
#>
function ConvertTo-OmitComparableImageKey {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Image
    )

    $identity = ConvertTo-OmitComparableImageIdentity -Image $Image
    if ([string]::IsNullOrWhiteSpace($identity)) {
        return ''
    }

    return ($identity -replace '[:/]', '_') -replace '[^a-zA-Z0-9_.-]', ''
}

<#
.SYNOPSIS
Derives the comparable identity key of an image tar entry of an images layer.
.DESCRIPTION
COMPARISON HELPER. Removes the optional 'windows_' prefix, the '.tar' suffix and the last
'_' separated segment (the sanitized tag) of an entry name. The entry name itself is never
modified - the caller keeps skipping the exact, original artifact entry.

Because the tar naming rule is lossy this deliberately removes only the LAST segment. An
entry without a version segment yields an empty key and therefore never matches.
.PARAMETER TarFileName
The tar entry name, e.g. 'quay.io_jetstack_cert-manager-controller_v1.20.2.tar'.
#>
function Get-OmitComparableImageKeyFromTarFileName {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TarFileName
    )

    $name = "$TarFileName".Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return ''
    }

    $name = [System.IO.Path]::GetFileName($name)
    if (-not $name.EndsWith('.tar')) {
        return ''
    }

    $name = $name.Substring(0, $name.Length - '.tar'.Length)
    if ($name.StartsWith('windows_')) {
        $name = $name.Substring('windows_'.Length)
    }

    $versionIndex = $name.LastIndexOf('_')
    if ($versionIndex -le 0) {
        return ''
    }

    return $name.Substring(0, $versionIndex)
}

<#
.SYNOPSIS
Parses '-Omit' tokens into structured scope/flag objects.
.DESCRIPTION
Accepted token forms:
  <flagName>                    applies to every imported implementation declaring that flag
  <addon>:<flagName>            applies to all implementations of that addon
  <addon>/<impl>:<flagName>     applies to that implementation only
Matching is case-insensitive.
#>
function ConvertTo-OmitToken {
    param(
        [Parameter(Mandatory = $false)]
        [string[]] $Token = @()
    )

    $parsed = @()

    foreach ($rawToken in @($Token)) {
        $trimmed = "$rawToken".Trim()
        if ($trimmed -eq '') {
            continue
        }

        $addonName = $null
        $implementationName = $null
        $flagName = $trimmed

        if ($trimmed.Contains(':')) {
            $scopeParts = $trimmed -split ':', 2
            $scope = $scopeParts[0].Trim()
            $flagName = $scopeParts[1].Trim()

            if ($scope.Contains('/')) {
                $scopeSegments = $scope -split '/', 2
                $addonName = $scopeSegments[0].Trim()
                $implementationName = $scopeSegments[1].Trim()
            }
            else {
                $addonName = $scope
            }
        }

        if ($flagName -eq '') {
            continue
        }

        $parsed += [pscustomobject]@{
            Raw            = $trimmed
            Addon          = $addonName
            Implementation = $implementationName
            Flag           = $flagName
        }
    }

    return $parsed
}

<#
.SYNOPSIS
Returns the first omit token that applies to the given implementation and flag name.
#>
function Get-MatchingOmitToken {
    param(
        [Parameter(Mandatory = $false)]
        [object[]] $Tokens = @(),
        [Parameter(Mandatory = $true)]
        [object] $Entry,
        [Parameter(Mandatory = $true)]
        [string] $FlagName
    )

    foreach ($token in @($Tokens)) {
        if ($token.Flag -ne $FlagName) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($token.Addon) -and $token.Addon -ne $Entry.Name) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($token.Implementation) -and $token.Implementation -ne $Entry.Implementation) {
            continue
        }

        return $token
    }

    return $null
}

<#
.SYNOPSIS
Returns the omit-capable flags of an addon implementation parsed from addon.manifest.yaml.
#>
function Get-OmitFlagsFromImplementation {
    param(
        [Parameter(Mandatory = $false)]
        [object] $Implementation
    )

    if ($null -eq $Implementation -or
        $null -eq $Implementation.commands -or
        $null -eq $Implementation.commands.enable -or
        $null -eq $Implementation.commands.enable.cli -or
        $null -eq $Implementation.commands.enable.cli.flags) {
        return @()
    }

    return @($Implementation.commands.enable.cli.flags | Where-Object { $null -ne $_.omittedImages })
}

<#
.SYNOPSIS
Resolves the omit-capable flags for an addon being imported.
.DESCRIPTION
Omit declarations are read from two sources, in this order:

1. The addon.manifest.yaml carried in the artifact's config layer. This matches the
   artifact content exactly and is therefore the most accurate source.
2. The addon.manifest.yaml of the local K2s installation.

The fallback matters: the config layer is a snapshot taken at export time, so artifacts
that were exported before an omit option existed do not declare it. Falling back to the
installed manifest makes '--omit' work with older artifacts as well, which is essential
because re-exporting is impossible in an air-gapped environment.

Resolution of 'omittedImages.fromFiles' always happens against the freshly extracted
manifests, so a declaration that does not fit the artifact content simply resolves to no
images and nothing is pruned (fail-safe).
.PARAMETER ArtifactManifestPath
Path to addon.manifest.yaml extracted from the artifact's config layer (may not exist).
.PARAMETER InstalledManifestPath
Path to addon.manifest.yaml of the local installation (may not exist).
.PARAMETER ImplementationName
Name of the implementation to look up; falls back to the first implementation.
#>
function Get-OmitFlagsForAddon {
    param(
        [Parameter(Mandatory = $false)]
        [string] $ArtifactManifestPath,
        [Parameter(Mandatory = $false)]
        [string] $InstalledManifestPath,
        [Parameter(Mandatory = $false)]
        [string] $ImplementationName
    )

    $sources = @(
        @{ Path = $ArtifactManifestPath; Origin = 'artifact' },
        @{ Path = $InstalledManifestPath; Origin = 'installation' }
    )

    foreach ($source in $sources) {
        if ([string]::IsNullOrWhiteSpace($source.Path) -or -not (Test-Path $source.Path)) {
            continue
        }

        $manifest = $null
        try {
            $manifest = Get-FromYamlFile -Path $source.Path
        }
        catch {
            Write-Log "[Prune] Could not parse '$($source.Path)': $($_.Exception.Message)"
            continue
        }

        if ($null -eq $manifest -or $null -eq $manifest.spec -or $null -eq $manifest.spec.implementations) {
            continue
        }

        $implementation = $null
        if (-not [string]::IsNullOrWhiteSpace($ImplementationName)) {
            $implementation = $manifest.spec.implementations | Where-Object { $_.name -eq $ImplementationName } | Select-Object -First 1
        }
        if ($null -eq $implementation) {
            $implementation = $manifest.spec.implementations | Select-Object -First 1
        }

        $flags = @(Get-OmitFlagsFromImplementation -Implementation $implementation)
        if ($flags.Count -gt 0) {
            Write-Log "[Prune] Using omit options declared by the $($source.Origin) manifest ($($flags.Count) option(s))."
            return $flags
        }
    }

    return @()
}

<#
.SYNOPSIS
Resolves the container images covered by a CLI flag's 'omittedImages' declaration.
.PARAMETER Flag
The flag object as parsed from addon.manifest.yaml.
.PARAMETER BaseDirectory
Base directory used to resolve relative 'fromFiles' entries (the addon implementation dir).
#>
function Get-OmittedImagesForFlag {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Flag,
        [Parameter(Mandatory = $true)]
        [string] $BaseDirectory
    )

    if ($null -eq $Flag -or $null -eq $Flag.omittedImages) {
        return @()
    }

    $specification = $Flag.omittedImages
    $images = @()

    if ($specification.fromFiles) {
        $images += @(Get-ImagesFromYamlFiles -YamlFiles @($specification.fromFiles) -BaseDirectory $BaseDirectory)
    }

    if ($specification.explicit) {
        $images += @($specification.explicit)
    }

    $images = @($images |
        ForEach-Object { "$_".Trim().Trim("`"'").Trim() } |
        Where-Object { $_ -ne '' } |
        Select-Object -Unique)

    if ($images.Count -eq 0) {
        return @()
    }

    return @(Remove-VersionlessImages -Images $images)
}

<#
.SYNOPSIS
Builds a global image pruning plan for an addon import session.
.DESCRIPTION
For every implementation i:
    A_i = images present in i's layers (tar entry names)
    O_i = images covered by the omit options the user requested for i
    K_i = images covered by i's omit options the user did NOT request
    R_i = A_i - (O_i - K_i)          # what i still requires

Globally:
    A = union of A_i, R = union of R_i, P = A - R
Each layer then imports A_i - P.

Because images that no flag covers can never enter O_i, they can never be pruned. And
because P subtracts the union of all R_i, an image shared by several addons survives as
long as a single imported addon still needs it.
.PARAMETER Entries
Plan entries. Each entry must expose: Key, Name, Implementation, ImplementationPath,
Flags, LinuxTarNames, WindowsTarNames.
.PARAMETER Omit
Requested omit tokens (see ConvertTo-OmitToken).
#>
function New-AddonImagePrunePlan {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]] $Entries = @(),
        [Parameter(Mandatory = $false)]
        [string[]] $Omit = @()
    )

    $plan = [ordered]@{
        SkipByKey      = @{}
        Pruned         = @()
        Retained       = @()
        AppliedOmit    = @()
        UnmatchedOmit  = @()
        AvailableFlags = @()
        Warnings       = @()
    }

    $omitTokens = @(ConvertTo-OmitToken -Token $Omit)

    foreach ($entry in @($Entries)) {
        $plan.SkipByKey[$entry.Key] = @{ Linux = @(); Windows = @() }
    }

    if ($null -eq $Entries -or @($Entries).Count -eq 0) {
        $plan.UnmatchedOmit = @($omitTokens | ForEach-Object { $_.Raw })
        return $plan
    }

    $allFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $requiredFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $omittedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $matchedTokens = New-Object 'System.Collections.Generic.HashSet[string]'
    $fileToImages = @{}
    $omittedByFile = @{}
    $requiredByFile = @{}
    $availableFlags = @()

    foreach ($entry in @($Entries)) {
        $entryFiles = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($tarName in (@($entry.LinuxTarNames) + @($entry.WindowsTarNames))) {
            if (-not [string]::IsNullOrWhiteSpace($tarName)) {
                [void]$entryFiles.Add($tarName)
                [void]$allFiles.Add($tarName)
            }
        }

        $entryOmitted = New-Object 'System.Collections.Generic.HashSet[string]'
        $entryKept = New-Object 'System.Collections.Generic.HashSet[string]'

        # Index this entry's artifact files by image identity (registry + repository, without
        # tag/digest). The omit declarations are resolved from the local working tree, whose
        # image versions may differ from the versions carried by the artifact.
        $entryFilesByIdentity = @{}
        foreach ($entryFile in $entryFiles) {
            $identityKey = Get-OmitComparableImageKeyFromTarFileName -TarFileName $entryFile
            if ([string]::IsNullOrWhiteSpace($identityKey)) {
                continue
            }
            if (-not $entryFilesByIdentity.ContainsKey($identityKey)) {
                $entryFilesByIdentity[$identityKey] = @()
            }
            if ($entryFilesByIdentity[$identityKey] -notcontains $entryFile) {
                $entryFilesByIdentity[$identityKey] += $entryFile
            }
        }

        foreach ($flag in @($entry.Flags)) {
            if ($null -eq $flag -or $null -eq $flag.omittedImages) {
                continue
            }

            $availableFlags += "$($entry.Key):$($flag.name)"

            $flagImages = @(Get-OmittedImagesForFlag -Flag $flag -BaseDirectory $entry.ImplementationPath)
            if ($flagImages.Count -eq 0) {
                $plan.Warnings += "[Prune] Omit option '$($flag.name)' of '$($entry.Key)' declares 'omittedImages' but no image reference could be resolved - not pruning for this option."
                continue
            }

            $flagFiles = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($image in $flagImages) {
                # Exact match first (same version in manifest and artifact), then fall back to
                # the image identity so a version drift between the local manifest and the
                # artifact does not silently disable the omit option. The matched artifact
                # entry always keeps its original tag - only the decision is version agnostic.
                $matchedFiles = @()

                foreach ($candidate in @(
                        (ConvertTo-ImageTarFileName -Image $image),
                        (ConvertTo-ImageTarFileName -Image $image -Windows))) {
                    if ($entryFiles.Contains($candidate)) {
                        $matchedFiles += $candidate
                    }
                }

                if ($matchedFiles.Count -eq 0) {
                    $identityKey = ConvertTo-OmitComparableImageKey -Image $image
                    if (-not [string]::IsNullOrWhiteSpace($identityKey) -and $entryFilesByIdentity.ContainsKey($identityKey)) {
                        $matchedFiles = @($entryFilesByIdentity[$identityKey])
                        Write-Log "[Prune] '$($entry.Key)': '$image' matched $($matchedFiles.Count) artifact image(s) by identity '$identityKey' (different version in the artifact)."
                    }
                }

                foreach ($candidate in $matchedFiles) {
                    [void]$flagFiles.Add($candidate)

                    if (-not $fileToImages.ContainsKey($candidate)) {
                        $fileToImages[$candidate] = @()
                    }
                    if ($fileToImages[$candidate] -notcontains $image) {
                        $fileToImages[$candidate] += $image
                    }
                }
            }

            $matchingToken = Get-MatchingOmitToken -Tokens $omitTokens -Entry $entry -FlagName $flag.name

            if ($null -ne $matchingToken) {
                [void]$matchedTokens.Add($matchingToken.Raw)

                if ($flagFiles.Count -eq 0) {
                    Write-Log "[Prune] '$($entry.Key)': omit option '$($flag.name)' requested, but none of its images are part of this artifact - nothing to skip."
                }

                foreach ($file in $flagFiles) {
                    [void]$entryOmitted.Add($file)

                    if (-not $omittedByFile.ContainsKey($file)) {
                        $omittedByFile[$file] = @()
                    }
                    $origin = "$($entry.Key) (--omit $($flag.name))"
                    if ($omittedByFile[$file] -notcontains $origin) {
                        $omittedByFile[$file] += $origin
                    }
                }
            }
            else {
                foreach ($file in $flagFiles) {
                    [void]$entryKept.Add($file)
                }
            }
        }

        # R_i = A_i - (O_i - K_i)
        foreach ($file in $entryFiles) {
            if ($entryOmitted.Contains($file) -and -not $entryKept.Contains($file)) {
                continue
            }

            [void]$requiredFiles.Add($file)

            if (-not $requiredByFile.ContainsKey($file)) {
                $requiredByFile[$file] = @()
            }
            if ($requiredByFile[$file] -notcontains $entry.Key) {
                $requiredByFile[$file] += $entry.Key
            }
        }

        foreach ($file in $entryOmitted) {
            [void]$omittedFiles.Add($file)
        }
    }

    # P = A - R, with a conservative guard against sanitization collisions
    $prunableFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($file in $allFiles) {
        if ($requiredFiles.Contains($file)) {
            continue
        }

        # The guard protects against sanitization collisions, i.e. two genuinely DIFFERENT
        # images mapping onto the same tar name. Several references of the same image
        # (e.g. two versions of cert-manager) are not a collision, so compare identities.
        if ($fileToImages.ContainsKey($file)) {
            $distinctIdentities = @($fileToImages[$file] |
                ForEach-Object { ConvertTo-OmitComparableImageKey -Image $_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique)

            if ($distinctIdentities.Count -gt 1) {
                $plan.Warnings += "[Prune] '$file' maps to more than one image reference ($($fileToImages[$file] -join ', ')) - keeping it to stay on the safe side."
                continue
            }
        }

        [void]$prunableFiles.Add($file)
    }

    foreach ($entry in @($Entries)) {
        $plan.SkipByKey[$entry.Key] = @{
            Linux   = @(@($entry.LinuxTarNames) | Where-Object { $_ -and $prunableFiles.Contains($_) })
            Windows = @(@($entry.WindowsTarNames) | Where-Object { $_ -and $prunableFiles.Contains($_) })
        }
    }

    foreach ($file in $omittedFiles) {
        $displayName = $file
        if ($fileToImages.ContainsKey($file)) {
            $displayName = $fileToImages[$file] -join ', '
        }

        if ($prunableFiles.Contains($file)) {
            $plan.Pruned += [pscustomobject]@{
                Image     = $displayName
                File      = $file
                OmittedBy = @($omittedByFile[$file])
            }
        }
        else {
            $plan.Retained += [pscustomobject]@{
                Image      = $displayName
                File       = $file
                OmittedBy  = @($omittedByFile[$file])
                RequiredBy = @($requiredByFile[$file])
            }
        }
    }

    foreach ($token in @($omitTokens)) {
        if ($matchedTokens.Contains($token.Raw)) {
            $plan.AppliedOmit += $token.Raw
        }
        else {
            $plan.UnmatchedOmit += $token.Raw
        }
    }

    $plan.AvailableFlags = @($availableFlags | Select-Object -Unique | Sort-Object)

    return $plan
}

<#
.SYNOPSIS
Writes a human readable summary of an image pruning plan to the console/log.
#>
function Write-AddonImagePrunePlan {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Plan
    )

    foreach ($warning in @($Plan.Warnings)) {
        Write-Log $warning -Console
    }

    foreach ($token in @($Plan.UnmatchedOmit)) {
        Write-Log "[Prune] WARNING: '--omit $token' did not match any addon selected for import - ignoring it." -Console
        if (@($Plan.AvailableFlags).Count -gt 0) {
            Write-Log "[Prune] Omit options available in this artifact: $(@($Plan.AvailableFlags) -join ', ')" -Console
        }
        else {
            Write-Log '[Prune] This artifact does not declare any omit options.' -Console
        }
    }

    if (@($Plan.AppliedOmit).Count -gt 0) {
        Write-Log "[Prune] Applied omit options: $(@($Plan.AppliedOmit) -join ', ')" -Console
    }

    foreach ($entry in @($Plan.Pruned)) {
        Write-Log "[Prune] SKIPPED  $($entry.Image)" -Console
        Write-Log "[Prune]          omitted by : $(@($entry.OmittedBy) -join ', ')" -Console
    }

    foreach ($entry in @($Plan.Retained)) {
        Write-Log "[Prune] RETAINED $($entry.Image)" -Console
        Write-Log "[Prune]          omitted by : $(@($entry.OmittedBy) -join ', ')" -Console
        Write-Log "[Prune]          required by: $(@($entry.RequiredBy) -join ', ')" -Console
    }

    if (@($Plan.Pruned).Count -gt 0) {
        Write-Log "[Prune] $(@($Plan.Pruned).Count) image(s) will not be imported. Re-run 'k2s addons import' without the omit option to add them later - the OCI artifact is unchanged." -Console
    }
}

Export-ModuleMember -Function ConvertTo-OmitComparableImageIdentity, ConvertTo-OmitComparableImageKey,
    Get-OmitComparableImageKeyFromTarFileName, ConvertTo-OmitToken, Get-MatchingOmitToken, Get-OmitFlagsFromImplementation,
Get-OmitFlagsForAddon, Get-OmittedImagesForFlag, New-AddonImagePrunePlan, Write-AddonImagePrunePlan

