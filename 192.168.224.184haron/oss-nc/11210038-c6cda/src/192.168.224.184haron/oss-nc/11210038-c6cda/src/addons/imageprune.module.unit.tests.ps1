# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\imageprune.module.psm1" -PassThru -Force).Name
    Import-Module "$PSScriptRoot\oci.module.psm1" -Force

    Mock -ModuleName $moduleName Write-Log { }

    # Writes a minimal Deployment manifest declaring the given images.
    function New-TestManifest {
        param(
            [string] $Path,
            [string[]] $Images
        )

        $parentDir = Split-Path -Path $Path -Parent
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        $lines = @('apiVersion: apps/v1', 'kind: Deployment', 'spec:', '  template:', '    spec:', '      containers:')
        foreach ($image in $Images) {
            $lines += '        - name: container'
            $lines += "          image: $image"
        }

        Set-Content -Path $Path -Value ($lines -join "`n") -Encoding UTF8
    }

    # Builds a plan entry as produced by phase 1 of Import.ps1.
    function New-TestEntry {
        param(
            [string] $Key,
            [string] $Name,
            [string] $Implementation,
            [string] $ImplementationPath,
            [object[]] $Flags = @(),
            [string[]] $LinuxImages = @(),
            [string[]] $WindowsImages = @()
        )

        return [pscustomobject]@{
            Key                = $Key
            Name               = $Name
            Implementation     = $Implementation
            ImplementationPath = $ImplementationPath
            Flags              = $Flags
            LinuxTarNames      = @($LinuxImages | ForEach-Object { ConvertTo-ImageTarFileName -Image $_ })
            WindowsTarNames    = @($WindowsImages | ForEach-Object { ConvertTo-ImageTarFileName -Image $_ -Windows })
        }
    }

    function New-TestFlag {
        param(
            [string] $Name,
            [string[]] $FromFiles = @(),
            [string[]] $Explicit = @()
        )

        $omittedImages = [pscustomobject]@{}
        if ($FromFiles.Count -gt 0) {
            $omittedImages | Add-Member -NotePropertyName 'fromFiles' -NotePropertyValue $FromFiles
        }
        if ($Explicit.Count -gt 0) {
            $omittedImages | Add-Member -NotePropertyName 'explicit' -NotePropertyValue $Explicit
        }

        return [pscustomobject]@{
            name          = $Name
            omittedImages = $omittedImages
        }
    }
}

Describe 'ConvertTo-ImageTarFileName' -Tag 'unit', 'ci', 'addon' {
    It 'mirrors the export sanitization rule' {
        ConvertTo-ImageTarFileName -Image 'quay.io/keycloak/keycloak:26.7.2' |
            Should -Be 'quay.io_keycloak_keycloak_26.7.2.tar'
    }

    It 'prefixes windows images' {
        ConvertTo-ImageTarFileName -Image 'shsk2s.azurecr.io/login:v1.2.0' -Windows |
            Should -Be 'windows_shsk2s.azurecr.io_login_v1.2.0.tar'
    }

    It 'strips characters that are not filename safe' {
        ConvertTo-ImageTarFileName -Image 'repo/name@sha256:abc' |
            Should -Be 'repo_namesha256_abc.tar'
    }
}

Describe 'ConvertTo-OmitComparableImageIdentity' -Tag 'unit', 'ci', 'addon' {
    It 'removes the tag' {
        ConvertTo-OmitComparableImageIdentity -Image 'quay.io/jetstack/cert-manager-controller:v1.21.1' |
            Should -Be 'quay.io/jetstack/cert-manager-controller'
    }

    It 'removes the digest' {
        ConvertTo-OmitComparableImageIdentity -Image 'repo/image@sha256:0123456789abcdef' | Should -Be 'repo/image'
    }

    It 'removes a tag and a digest combined' {
        ConvertTo-OmitComparableImageIdentity -Image 'repo/image:v1.2.3@sha256:0123456789abcdef' | Should -Be 'repo/image'
    }

    It 'keeps a registry port' {
        ConvertTo-OmitComparableImageIdentity -Image 'localhost:5000/repo/image:v1.2.3' | Should -Be 'localhost:5000/repo/image'
    }

    It 'keeps a reference that carries no version' {
        ConvertTo-OmitComparableImageIdentity -Image 'repo/image' | Should -Be 'repo/image'
    }

    It 'keeps repositories apart that only share a prefix' {
        (ConvertTo-OmitComparableImageIdentity -Image 'repo/foo:v1') |
            Should -Not -Be (ConvertTo-OmitComparableImageIdentity -Image 'repo/foo-bar:v1')
    }

    It 'returns an empty identity for an empty reference' {
        ConvertTo-OmitComparableImageIdentity -Image '' | Should -Be ''
    }
}

Describe 'ConvertTo-OmitComparableImageKey / Get-OmitComparableImageKeyFromTarFileName' -Tag 'unit', 'ci', 'addon' {
    It 'derives the same key from a manifest reference and a differently versioned tar entry' {
        $fromManifest = ConvertTo-OmitComparableImageKey -Image 'quay.io/jetstack/cert-manager-controller:v1.21.1'
        $fromArtifact = Get-OmitComparableImageKeyFromTarFileName -TarFileName 'quay.io_jetstack_cert-manager-controller_v1.20.2.tar'

        $fromManifest | Should -Be $fromArtifact
    }

    It 'derives the same key for identical versions' {
        $fromManifest = ConvertTo-OmitComparableImageKey -Image 'quay.io/keycloak/keycloak:26.7.2'
        $fromArtifact = Get-OmitComparableImageKeyFromTarFileName -TarFileName 'quay.io_keycloak_keycloak_26.7.2.tar'

        $fromManifest | Should -Be $fromArtifact
    }

    It 'derives a different key for a different repository' {
        (ConvertTo-OmitComparableImageKey -Image 'registry.io/repo/foo:v1') |
            Should -Not -Be (Get-OmitComparableImageKeyFromTarFileName -TarFileName 'registry.io_repo_foo-bar_v1.tar')
    }

    It 'ignores the windows prefix' {
        Get-OmitComparableImageKeyFromTarFileName -TarFileName 'windows_shsk2s.azurecr.io_login_v1.2.0.tar' |
            Should -Be (ConvertTo-OmitComparableImageKey -Image 'shsk2s.azurecr.io/login:v9.9.9')
    }

    It 'returns an empty key for an entry without a version segment' {
        Get-OmitComparableImageKeyFromTarFileName -TarFileName 'noversion.tar' | Should -Be ''
    }

    It 'returns an empty key for a non tar entry' {
        Get-OmitComparableImageKeyFromTarFileName -TarFileName 'manifest.json' | Should -Be ''
    }

    It 'returns an empty key for an empty entry' {
        Get-OmitComparableImageKeyFromTarFileName -TarFileName '' | Should -Be ''
    }
}

Describe 'Get-TarEntryName' -Tag 'unit', 'ci', 'addon' {
    # Regression: an addon without a Windows images layer passes $null here. A mandatory
    # [string] parameter rejects that at binding time, which flooded the import output with
    # ParameterArgumentValidationErrorEmptyStringNotAllowed errors.
    It 'returns an empty result for a null path without raising an error' {
        $Error.Clear()
        $result = @(Get-TarEntryName -ArchivePath $null)

        $result.Count | Should -Be 0
        $Error.Count | Should -Be 0
    }

    It 'returns an empty result for an empty path without raising an error' {
        $Error.Clear()
        $result = @(Get-TarEntryName -ArchivePath '')

        $result.Count | Should -Be 0
        $Error.Count | Should -Be 0
    }

    It 'returns an empty result for a non-existing archive without raising an error' {
        $Error.Clear()
        $result = @(Get-TarEntryName -ArchivePath (Join-Path ([System.IO.Path]::GetTempPath()) 'k2s-does-not-exist.tar'))

        $result.Count | Should -Be 0
        $Error.Count | Should -Be 0
    }

    # A corrupt/unreadable archive must never let tar's stderr output leak into the entry
    # list, because a warning line could otherwise be mistaken for an image tar name.
    It 'returns an empty result and no stderr text when the archive cannot be listed' {
        $corruptArchive = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-corrupt-$([guid]::NewGuid().ToString('N')).tar"
        Set-Content -Path $corruptArchive -Value 'this is not a tar archive' -NoNewline

        try {
            $result = @(Get-TarEntryName -ArchivePath $corruptArchive)

            $result.Count | Should -Be 0
        }
        finally {
            Remove-Item -Path $corruptArchive -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns the normalized leaf names of a real archive and ignores directory entries' {
        $workDir = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-tar-$([guid]::NewGuid().ToString('N'))"
        $contentDir = Join-Path $workDir 'images'
        New-Item -ItemType Directory -Path $contentDir -Force | Out-Null
        Set-Content -Path (Join-Path $contentDir 'quay.io_jetstack_cert-manager-controller_v1.21.1.tar') -Value 'x'
        Set-Content -Path (Join-Path $contentDir 'windows_docker.io_library_nginx_1.29.tar') -Value 'x'

        $archive = Join-Path $workDir 'layer.tar'
        $previousLocation = Get-Location
        try {
            Set-Location $workDir
            & tar -cf $archive 'images' | Out-Null
            Set-Location $previousLocation

            $result = @(Get-TarEntryName -ArchivePath $archive)

            $result | Should -Contain 'quay.io_jetstack_cert-manager-controller_v1.21.1.tar'
            $result | Should -Contain 'windows_docker.io_library_nginx_1.29.tar'
            $result | Should -Not -Contain 'images'
        }
        finally {
            Set-Location $previousLocation
            Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'ConvertTo-OmitToken' -Tag 'unit', 'ci', 'addon' {
    It 'parses a bare flag name' {
        $result = @(ConvertTo-OmitToken -Token @('omitCertMgr'))

        $result.Count | Should -Be 1
        $result[0].Flag | Should -Be 'omitCertMgr'
        $result[0].Addon | Should -BeNullOrEmpty
        $result[0].Implementation | Should -BeNullOrEmpty
    }

    It 'parses an addon-scoped token' {
        $result = @(ConvertTo-OmitToken -Token @('security:omitKeycloak'))

        $result[0].Addon | Should -Be 'security'
        $result[0].Implementation | Should -BeNullOrEmpty
        $result[0].Flag | Should -Be 'omitKeycloak'
    }

    It 'parses an implementation-scoped token' {
        $result = @(ConvertTo-OmitToken -Token @('ingress/nginx:omitCertMgr'))

        $result[0].Addon | Should -Be 'ingress'
        $result[0].Implementation | Should -Be 'nginx'
        $result[0].Flag | Should -Be 'omitCertMgr'
    }

    It 'ignores blank tokens' {
        (ConvertTo-OmitToken -Token @('', '   ', $null)).Count | Should -Be 0
    }
}

Describe 'New-AddonImagePrunePlan' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-prune-tests-$([guid]::NewGuid().ToString('N'))"

        $script:certManagerImages = @(
            'quay.io/jetstack/cert-manager-controller:v1.21.1',
            'quay.io/jetstack/cert-manager-webhook:v1.21.1'
        )
        $script:keycloakImages = @('quay.io/keycloak/keycloak:26.7.2', 'docker.io/library/postgres:18.6')
        $script:oauth2Images = @('docker.io/library/redis:8.10.1', 'quay.io/oauth2-proxy/oauth2-proxy:v7.15.4')
        $script:hydraWindowsImages = @('shsk2s.azurecr.io/login:v1.2.0')

        # addons/common is shared between ingress and security, mirroring the real layout
        New-TestManifest -Path "$script:testRoot\common\manifests\certmanager\cert-manager.yaml" -Images $script:certManagerImages
        New-TestManifest -Path "$script:testRoot\security\manifests\keycloak\keycloak.yaml" -Images @($script:keycloakImages[0])
        New-TestManifest -Path "$script:testRoot\security\manifests\keycloak\keycloak-postgres.yaml" -Images @($script:keycloakImages[1])
        New-TestManifest -Path "$script:testRoot\security\manifests\keycloak\oauth2-proxy.yaml" -Images $script:oauth2Images
        New-TestManifest -Path "$script:testRoot\security\manifests\hydra\oauth2-proxy-hydra.yaml" -Images $script:oauth2Images
        New-TestManifest -Path "$script:testRoot\security\manifests\keycloak\windowsprovider\hydra.yaml" -Images $script:hydraWindowsImages
        New-TestManifest -Path "$script:testRoot\dicom\manifests\dicom\postgres-deployment.yaml" -Images @('docker.io/library/postgres:18.6')

        $script:certMgrFlag = New-TestFlag -Name 'omitCertMgr' -FromFiles @('../common/manifests/certmanager/cert-manager.yaml')
        $script:keycloakFlag = New-TestFlag -Name 'omitKeycloak' -FromFiles @('manifests/keycloak/keycloak.yaml', 'manifests/keycloak/keycloak-postgres.yaml')
        $script:oauth2Flag = New-TestFlag -Name 'omitOAuth2Proxy' -FromFiles @('manifests/keycloak/oauth2-proxy.yaml', 'manifests/hydra/oauth2-proxy-hydra.yaml')
        $script:hydraFlag = New-TestFlag -Name 'omitHydra' -FromFiles @('manifests/keycloak/windowsprovider/hydra.yaml')
        $script:policyFlag = New-TestFlag -Name 'omitPolicyEnf' -Explicit @('reg.kyverno.io/kyverno/kyverno:v1.19.0')
    }

    AfterAll {
        Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'image shared between two addons, omitted in one of them' {
        BeforeAll {
            $ingress = New-TestEntry -Key 'ingress/nginx' -Name 'ingress' -Implementation 'nginx' `
                -ImplementationPath "$script:testRoot\ingress\nginx" `
                -Flags @($script:certMgrFlag) `
                -LinuxImages ($script:certManagerImages + 'registry.k8s.io/ingress-nginx/controller:v1.15.1')

            $security = New-TestEntry -Key 'security' -Name 'security' -Implementation 'security' `
                -ImplementationPath "$script:testRoot\security" `
                -Flags @($script:keycloakFlag) `
                -LinuxImages ($script:certManagerImages + $script:keycloakImages)

            # ingress resolves ../common/... relative to its implementation dir
            New-Item -ItemType Directory -Path "$script:testRoot\ingress\nginx" -Force | Out-Null
            New-TestManifest -Path "$script:testRoot\ingress\common\manifests\certmanager\cert-manager.yaml" -Images $script:certManagerImages

            $script:sharedPlan = New-AddonImagePrunePlan -Entries @($ingress, $security) -Omit @('omitCertMgr')
        }

        It 'does not prune the shared image because the other addon requires it' {
            @($script:sharedPlan.Pruned).Count | Should -Be 0
        }

        It 'reports the shared image as retained' {
            @($script:sharedPlan.Retained).Count | Should -Be 2
            @($script:sharedPlan.Retained)[0].RequiredBy | Should -Contain 'security'
        }

        It 'skips nothing for either addon' {
            @($script:sharedPlan.SkipByKey['ingress/nginx'].Linux).Count | Should -Be 0
            @($script:sharedPlan.SkipByKey['security'].Linux).Count | Should -Be 0
        }

        It 'records the omit option as applied' {
            $script:sharedPlan.AppliedOmit | Should -Contain 'omitCertMgr'
        }
    }

    Context 'image omitted by every addon that ships it' {
        BeforeAll {
            $ingress = New-TestEntry -Key 'ingress/nginx' -Name 'ingress' -Implementation 'nginx' `
                -ImplementationPath "$script:testRoot\ingress\nginx" `
                -Flags @($script:certMgrFlag) `
                -LinuxImages ($script:certManagerImages + 'registry.k8s.io/ingress-nginx/controller:v1.15.1')

            $script:soloPlan = New-AddonImagePrunePlan -Entries @($ingress) -Omit @('omitCertMgr')
        }

        It 'prunes the omitted images' {
            @($script:soloPlan.Pruned).Count | Should -Be 2
        }

        It 'adds them to the linux skip set' {
            $skipped = @($script:soloPlan.SkipByKey['ingress/nginx'].Linux)
            $skipped.Count | Should -Be 2
            $skipped | Should -Contain (ConvertTo-ImageTarFileName -Image 'quay.io/jetstack/cert-manager-controller:v1.21.1')
        }

        It 'never prunes images that no flag covers' {
            @($script:soloPlan.SkipByKey['ingress/nginx'].Linux) |
                Should -Not -Contain (ConvertTo-ImageTarFileName -Image 'registry.k8s.io/ingress-nginx/controller:v1.15.1')
        }
    }

    Context 'image shared across unrelated addons (postgres in security and dicom)' {
        BeforeAll {
            $security = New-TestEntry -Key 'security' -Name 'security' -Implementation 'security' `
                -ImplementationPath "$script:testRoot\security" `
                -Flags @($script:keycloakFlag) `
                -LinuxImages $script:keycloakImages

            $dicom = New-TestEntry -Key 'dicom' -Name 'dicom' -Implementation 'dicom' `
                -ImplementationPath "$script:testRoot\dicom" `
                -Flags @() `
                -LinuxImages @('docker.io/library/postgres:18.6')

            $script:crossPlan = New-AddonImagePrunePlan -Entries @($security, $dicom) -Omit @('omitKeycloak')
        }

        It 'prunes keycloak but keeps postgres' {
            $prunedImages = @($script:crossPlan.Pruned | ForEach-Object { $_.Image })

            $prunedImages | Should -Contain 'quay.io/keycloak/keycloak:26.7.2'
            $prunedImages | Should -Not -Contain 'docker.io/library/postgres:18.6'
        }

        It 'reports postgres as required by dicom' {
            $retained = @($script:crossPlan.Retained | Where-Object { $_.Image -eq 'docker.io/library/postgres:18.6' })

            $retained.Count | Should -Be 1
            $retained[0].RequiredBy | Should -Contain 'dicom'
        }
    }

    Context 'image referenced by two flags of the same addon, only one omitted' {
        BeforeAll {
            $security = New-TestEntry -Key 'security' -Name 'security' -Implementation 'security' `
                -ImplementationPath "$script:testRoot\security" `
                -Flags @($script:keycloakFlag, $script:oauth2Flag) `
                -LinuxImages ($script:keycloakImages + $script:oauth2Images)

            $script:intraPlan = New-AddonImagePrunePlan -Entries @($security) -Omit @('omitKeycloak')
        }

        It 'keeps the images of the flag that was not requested' {
            $skipped = @($script:intraPlan.SkipByKey['security'].Linux)

            $skipped | Should -Not -Contain (ConvertTo-ImageTarFileName -Image 'docker.io/library/redis:8.10.1')
            $skipped | Should -Not -Contain (ConvertTo-ImageTarFileName -Image 'quay.io/oauth2-proxy/oauth2-proxy:v7.15.4')
        }

        It 'still prunes the images exclusive to the requested flag' {
            $skipped = @($script:intraPlan.SkipByKey['security'].Linux)

            $skipped | Should -Contain (ConvertTo-ImageTarFileName -Image 'quay.io/keycloak/keycloak:26.7.2')
        }
    }

    Context 'windows images' {
        BeforeAll {
            $security = New-TestEntry -Key 'security' -Name 'security' -Implementation 'security' `
                -ImplementationPath "$script:testRoot\security" `
                -Flags @($script:hydraFlag) `
                -WindowsImages $script:hydraWindowsImages

            $script:windowsPlan = New-AddonImagePrunePlan -Entries @($security) -Omit @('omitHydra')
        }

        It 'adds the image to the windows skip set only' {
            @($script:windowsPlan.SkipByKey['security'].Windows).Count | Should -Be 1
            @($script:windowsPlan.SkipByKey['security'].Linux).Count | Should -Be 0
        }
    }

    Context 'explicit image list (helm chart internals)' {
        BeforeAll {
            $security = New-TestEntry -Key 'security' -Name 'security' -Implementation 'security' `
                -ImplementationPath "$script:testRoot\security" `
                -Flags @($script:policyFlag) `
                -LinuxImages @('reg.kyverno.io/kyverno/kyverno:v1.19.0', 'quay.io/keycloak/keycloak:26.7.2')

            $script:explicitPlan = New-AddonImagePrunePlan -Entries @($security) -Omit @('omitPolicyEnf')
        }

        It 'prunes the explicitly listed image' {
            @($script:explicitPlan.SkipByKey['security'].Linux) |
                Should -Contain (ConvertTo-ImageTarFileName -Image 'reg.kyverno.io/kyverno/kyverno:v1.19.0')
        }

        It 'leaves unrelated images untouched' {
            @($script:explicitPlan.SkipByKey['security'].Linux) |
                Should -Not -Contain (ConvertTo-ImageTarFileName -Image 'quay.io/keycloak/keycloak:26.7.2')
        }
    }

    Context 'scoped omit tokens' {
        BeforeAll {
            New-Item -ItemType Directory -Path "$script:testRoot\ingress\traefik" -Force | Out-Null

            $nginx = New-TestEntry -Key 'ingress/nginx' -Name 'ingress' -Implementation 'nginx' `
                -ImplementationPath "$script:testRoot\ingress\nginx" `
                -Flags @($script:certMgrFlag) `
                -LinuxImages $script:certManagerImages

            $traefik = New-TestEntry -Key 'ingress/traefik' -Name 'ingress' -Implementation 'traefik' `
                -ImplementationPath "$script:testRoot\ingress\traefik" `
                -Flags @($script:certMgrFlag) `
                -LinuxImages $script:certManagerImages

            $script:scopedPlan = New-AddonImagePrunePlan -Entries @($nginx, $traefik) -Omit @('ingress/nginx:omitCertMgr')
        }

        It 'keeps the images because the unscoped implementation still requires them' {
            @($script:scopedPlan.Pruned).Count | Should -Be 0
            @($script:scopedPlan.Retained)[0].RequiredBy | Should -Contain 'ingress/traefik'
        }
    }

    Context 'unknown omit token' {
        BeforeAll {
            $security = New-TestEntry -Key 'security' -Name 'security' -Implementation 'security' `
                -ImplementationPath "$script:testRoot\security" `
                -Flags @($script:keycloakFlag) `
                -LinuxImages $script:keycloakImages

            $script:unknownPlan = New-AddonImagePrunePlan -Entries @($security) -Omit @('omitDoesNotExist')
        }

        It 'reports the token as unmatched' {
            $script:unknownPlan.UnmatchedOmit | Should -Contain 'omitDoesNotExist'
        }

        It 'does not prune anything' {
            @($script:unknownPlan.Pruned).Count | Should -Be 0
        }

        It 'lists the omit options available in the artifact' {
            $script:unknownPlan.AvailableFlags | Should -Contain 'security:omitKeycloak'
        }
    }

    Context 'no omit options requested' {
        It 'imports everything' {
            $security = New-TestEntry -Key 'security' -Name 'security' -Implementation 'security' `
                -ImplementationPath "$script:testRoot\security" `
                -Flags @($script:keycloakFlag) `
                -LinuxImages $script:keycloakImages

            $plan = New-AddonImagePrunePlan -Entries @($security) -Omit @()

            @($plan.Pruned).Count | Should -Be 0
            @($plan.SkipByKey['security'].Linux).Count | Should -Be 0
        }
    }

    Context 'no addons selected' {
        It 'returns an empty plan and reports the token as unmatched' {
            $plan = New-AddonImagePrunePlan -Entries @() -Omit @('omitKeycloak')

            @($plan.Pruned).Count | Should -Be 0
            $plan.UnmatchedOmit | Should -Contain 'omitKeycloak'
        }
    }

    # Regression coverage for defect T16.
    #
    # The omit declarations are resolved from the manifests of the LOCAL working tree, while
    # the images come from the artifact. When an artifact was exported from an older tree its
    # image versions drift, so tag-exact matching silently skipped nothing. The matching is
    # therefore done on the image identity (registry + repository, no tag/digest), while the
    # artifact entry is still filtered by its original, full name.
    Context 'artifact carries a different version than the local manifest (regression T16)' {
        BeforeAll {
            # local manifest declares v1.21.1 ...
            New-Item -ItemType Directory -Path "$script:testRoot\drift\nginx" -Force | Out-Null
            New-TestManifest -Path "$script:testRoot\drift\common\manifests\certmanager\cert-manager.yaml" `
                -Images $script:certManagerImages

            # ... while the artifact ships v1.20.2
            $script:oldCertManagerImages = @(
                'quay.io/jetstack/cert-manager-controller:v1.20.2',
                'quay.io/jetstack/cert-manager-webhook:v1.20.2'
            )

            $ingress = New-TestEntry -Key 'ingress/nginx' -Name 'ingress' -Implementation 'nginx' `
                -ImplementationPath "$script:testRoot\drift\nginx" `
                -Flags @($script:certMgrFlag) `
                -LinuxImages ($script:oldCertManagerImages + 'registry.k8s.io/ingress-nginx/controller:v1.15.1')

            $script:driftPlan = New-AddonImagePrunePlan -Entries @($ingress) -Omit @('omitCertMgr')
        }

        It 'prunes the older artifact images although the manifest declares a newer version' {
            @($script:driftPlan.Pruned).Count | Should -Be 2
        }

        It 'skips the exact artifact tar entries including their original version' {
            $skipped = @($script:driftPlan.SkipByKey['ingress/nginx'].Linux)

            $skipped.Count | Should -Be 2
            $skipped | Should -Contain 'quay.io_jetstack_cert-manager-controller_v1.20.2.tar'
            $skipped | Should -Contain 'quay.io_jetstack_cert-manager-webhook_v1.20.2.tar'
        }

        It 'never rewrites the artifact entry to the manifest version' {
            @($script:driftPlan.SkipByKey['ingress/nginx'].Linux) |
                Should -Not -Contain 'quay.io_jetstack_cert-manager-controller_v1.21.1.tar'
        }

        It 'still leaves images that no flag covers untouched' {
            @($script:driftPlan.SkipByKey['ingress/nginx'].Linux) |
                Should -Not -Contain (ConvertTo-ImageTarFileName -Image 'registry.k8s.io/ingress-nginx/controller:v1.15.1')
        }

        It 'records the omit option as applied' {
            $script:driftPlan.AppliedOmit | Should -Contain 'omitCertMgr'
        }
    }

    Context 'version drift with a shared image (global retention still wins)' {
        BeforeAll {
            New-Item -ItemType Directory -Path "$script:testRoot\driftshared\nginx" -Force | Out-Null
            New-TestManifest -Path "$script:testRoot\driftshared\common\manifests\certmanager\cert-manager.yaml" `
                -Images $script:certManagerImages

            $oldCertManagerImages = @(
                'quay.io/jetstack/cert-manager-controller:v1.20.2',
                'quay.io/jetstack/cert-manager-webhook:v1.20.2'
            )

            $ingress = New-TestEntry -Key 'ingress/nginx' -Name 'ingress' -Implementation 'nginx' `
                -ImplementationPath "$script:testRoot\driftshared\nginx" `
                -Flags @($script:certMgrFlag) `
                -LinuxImages $oldCertManagerImages

            # security ships the very same (old) images but is imported without an omit option
            $security = New-TestEntry -Key 'security' -Name 'security' -Implementation 'security' `
                -ImplementationPath "$script:testRoot\security" `
                -Flags @($script:keycloakFlag) `
                -LinuxImages ($oldCertManagerImages + $script:keycloakImages)

            $script:driftSharedPlan = New-AddonImagePrunePlan -Entries @($ingress, $security) -Omit @('omitCertMgr')
        }

        It 'keeps the shared image because the other addon still requires it' {
            @($script:driftSharedPlan.Pruned).Count | Should -Be 0
            @($script:driftSharedPlan.SkipByKey['ingress/nginx'].Linux).Count | Should -Be 0
            @($script:driftSharedPlan.SkipByKey['security'].Linux).Count | Should -Be 0
        }

        It 'reports the drifted images as retained' {
            @($script:driftSharedPlan.Retained).Count | Should -Be 2
            @($script:driftSharedPlan.Retained)[0].RequiredBy | Should -Contain 'security'
        }
    }

    Context 'identity matching does not widen to different repositories' {
        BeforeAll {
            New-Item -ItemType Directory -Path "$script:testRoot\lookalike\impl" -Force | Out-Null
            New-TestManifest -Path "$script:testRoot\lookalike\impl\manifests\foo.yaml" -Images @('registry.io/repo/foo:v1.0.0')

            $flag = New-TestFlag -Name 'omitFoo' -FromFiles @('manifests/foo.yaml')

            # the artifact contains a DIFFERENT repository that merely shares a prefix
            $entry = New-TestEntry -Key 'lookalike' -Name 'lookalike' -Implementation 'impl' `
                -ImplementationPath "$script:testRoot\lookalike\impl" `
                -Flags @($flag) `
                -LinuxImages @('registry.io/repo/foo-bar:v2.0.0', 'registry.io/repo/foobar:v2.0.0')

            $script:lookalikePlan = New-AddonImagePrunePlan -Entries @($entry) -Omit @('omitFoo')
        }

        It 'does not prune a repository that only shares a prefix' {
            @($script:lookalikePlan.Pruned).Count | Should -Be 0
            @($script:lookalikePlan.SkipByKey['lookalike'].Linux).Count | Should -Be 0
        }
    }

    Context 'digest based reference in the local manifest' {
        BeforeAll {
            New-Item -ItemType Directory -Path "$script:testRoot\digest\impl" -Force | Out-Null
            New-TestManifest -Path "$script:testRoot\digest\impl\manifests\pinned.yaml" `
                -Images @('quay.io/jetstack/cert-manager-controller@sha256:0123456789abcdef')

            $flag = New-TestFlag -Name 'omitCertMgr' -FromFiles @('manifests/pinned.yaml')

            $entry = New-TestEntry -Key 'digest' -Name 'digest' -Implementation 'impl' `
                -ImplementationPath "$script:testRoot\digest\impl" `
                -Flags @($flag) `
                -LinuxImages @('quay.io/jetstack/cert-manager-controller:v1.20.2')

            $script:digestPlan = New-AddonImagePrunePlan -Entries @($entry) -Omit @('omitCertMgr')
        }

        It 'matches the tagged artifact image through the repository identity' {
            @($script:digestPlan.SkipByKey['digest'].Linux) |
                Should -Contain 'quay.io_jetstack_cert-manager-controller_v1.20.2.tar'
        }
    }

    Context 'version drift without an omit option requested' {
        It 'imports everything unchanged' {
            New-Item -ItemType Directory -Path "$script:testRoot\driftnoomit\nginx" -Force | Out-Null
            New-TestManifest -Path "$script:testRoot\driftnoomit\common\manifests\certmanager\cert-manager.yaml" `
                -Images $script:certManagerImages

            $ingress = New-TestEntry -Key 'ingress/nginx' -Name 'ingress' -Implementation 'nginx' `
                -ImplementationPath "$script:testRoot\driftnoomit\nginx" `
                -Flags @($script:certMgrFlag) `
                -LinuxImages @('quay.io/jetstack/cert-manager-controller:v1.20.2')

            $plan = New-AddonImagePrunePlan -Entries @($ingress) -Omit @()

            @($plan.Pruned).Count | Should -Be 0
            @($plan.SkipByKey['ingress/nginx'].Linux).Count | Should -Be 0
        }
    }
}

# Regression coverage for defect C-1.
#
# Import.ps1 replaces the installed addon.manifest.yaml with the manifest carried in the
# artifact while processing the config layer. Before the fix, the omit options were resolved
# AFTER that overwrite, using the destination path - so for artifacts exported before
# 'omittedImages' existed both sources were identical and '--omit' silently did nothing.
#
# The fix snapshots the installed manifest into the per-implementation temp directory before
# any config-layer processing and uses that snapshot as fallback source.
Describe 'Get-OmitFlagsForAddon - installed manifest snapshot (regression C-1)' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        # 'Get-FromYamlFile' shells out to yaml2json.exe, a Go binary that is generated by the
        # build (bin/*.exe is git-ignored) and therefore absent on a plain CI checkout. What
        # these tests cover is the source precedence of Get-OmitFlagsForAddon, not YAML parsing,
        # so the parser is mocked - the same approach addons.module.unit.tests.ps1 uses.
        # The fixtures are written as JSON, which is a subset of YAML, so the mock returns
        # exactly what the real parser (yaml2json.exe piped into ConvertFrom-Json) would.
        Mock -ModuleName $moduleName Get-FromYamlFile {
            return (Get-Content -Path $Path -Raw | ConvertFrom-Json)
        }

        # Builds an addon.manifest fixture declaring the given enable flags. A flag is
        # @{ name = '<flag>'; fromFiles = @(...) }; omit 'fromFiles' for a flag without
        # 'omittedImages' (as carried by artifacts exported before the option existed).
        function New-C1Manifest {
            param(
                [string] $Path,
                [hashtable[]] $Flags
            )

            $flagObjects = @(
                foreach ($flag in $Flags) {
                    $flagObject = [ordered]@{ name = $flag.name; default = $false }
                    if ($flag.ContainsKey('fromFiles')) {
                        $flagObject.omittedImages = [ordered]@{ fromFiles = @($flag.fromFiles) }
                    }
                    $flagObject
                }
            )

            $manifest = [ordered]@{
                apiVersion = 'v1'
                kind       = 'AddonManifest'
                metadata   = [ordered]@{ name = 'security'; description = 'regression fixture' }
                spec       = [ordered]@{
                    implementations = @(
                        [ordered]@{
                            name        = 'security'
                            description = 'regression fixture'
                            commands    = [ordered]@{
                                enable  = [ordered]@{
                                    cli    = [ordered]@{ flags = $flagObjects }
                                    script = [ordered]@{ subPath = 'Enable.ps1' }
                                }
                                disable = [ordered]@{ script = [ordered]@{ subPath = 'Disable.ps1' } }
                            }
                        }
                    )
                }
            }

            $parentDir = Split-Path -Path $Path -Parent
            if (-not (Test-Path $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
            }

            Set-Content -Path $Path -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 10)
        }

        $script:c1Root = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-omit-c1-$([guid]::NewGuid().ToString('N'))"

        # manifest of the local K2s installation - declares omittedImages
        $script:c1Installed = Join-Path $script:c1Root 'installed\addon.manifest.yaml'
        New-C1Manifest -Path $script:c1Installed -Flags @(
            @{ name = 'omitKeycloak'; fromFiles = @('manifests/keycloak/keycloak.yaml') }
        )

        # manifest carried in an OLDER artifact - same flag, but WITHOUT omittedImages
        $script:c1Artifact = Join-Path $script:c1Root 'artifact\addon.manifest.yaml'
        New-C1Manifest -Path $script:c1Artifact -Flags @(
            @{ name = 'omitKeycloak' }
        )

        # destination manifest as it exists on disk before the import starts
        $script:c1Destination = Join-Path $script:c1Root 'addons\security\addon.manifest.yaml'
        New-Item -ItemType Directory -Path (Split-Path $script:c1Destination -Parent) -Force | Out-Null
        Copy-Item -Path $script:c1Installed -Destination $script:c1Destination -Force

        # what Import.ps1 now does first: snapshot into the per-implementation temp dir
        $script:c1Snapshot = Join-Path $script:c1Root 'layer-temp-security\installed-addon.manifest.yaml'
        New-Item -ItemType Directory -Path (Split-Path $script:c1Snapshot -Parent) -Force | Out-Null
        Copy-Item -Path $script:c1Destination -Destination $script:c1Snapshot -Force

        # ...then the config-layer processing overwrites the destination with the artifact manifest
        Copy-Item -Path $script:c1Artifact -Destination $script:c1Destination -Force
    }

    AfterAll {
        Remove-Item -Path $script:c1Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'demonstrates the defect: resolving via the overwritten destination finds no omit options' {
        # This is the pre-fix call site. It must find nothing - that is exactly the bug.
        $flags = @(Get-OmitFlagsForAddon `
                -ArtifactManifestPath $script:c1Artifact `
                -InstalledManifestPath $script:c1Destination `
                -ImplementationName 'security')

        $flags.Count | Should -Be 0 -Because 'the destination manifest was overwritten by the artifact manifest, which has no omittedImages'
    }

    It 'resolves the omit options from the snapshot taken before the overwrite' {
        $flags = @(Get-OmitFlagsForAddon `
                -ArtifactManifestPath $script:c1Artifact `
                -InstalledManifestPath $script:c1Snapshot `
                -ImplementationName 'security')

        $flags.Count | Should -Be 1
        $flags[0].name | Should -Be 'omitKeycloak'
        @($flags[0].omittedImages.fromFiles).Count | Should -Be 1
    }

    It 'still prefers the artifact manifest when it declares omittedImages' {
        # artifact wins over the snapshot, so image tags stay tied to the artifact version
        $artifactWithMetadata = Join-Path $script:c1Root 'artifact2\addon.manifest.yaml'
        New-C1Manifest -Path $artifactWithMetadata -Flags @(
            @{ name = 'omitKeycloak'; fromFiles = @('manifests/keycloak/keycloak.yaml') }
            @{ name = 'omitHydra'; fromFiles = @('manifests/keycloak/windowsprovider/hydra.yaml') }
        )

        $flags = @(Get-OmitFlagsForAddon `
                -ArtifactManifestPath $artifactWithMetadata `
                -InstalledManifestPath $script:c1Snapshot `
                -ImplementationName 'security')

        $flags.Count | Should -Be 2 -Because 'the artifact declares 2 omit options, the snapshot only 1'
    }

    It 'returns nothing when neither source exists' {
        $flags = @(Get-OmitFlagsForAddon `
                -ArtifactManifestPath (Join-Path $script:c1Root 'does-not-exist.yaml') `
                -InstalledManifestPath (Join-Path $script:c1Root 'also-missing.yaml') `
                -ImplementationName 'security')

        $flags.Count | Should -Be 0
    }
}

# Guards the call-site contract in Import.ps1 itself. A pure unit test cannot detect the
# ordering defect because the function signature did not change - only the caller did.
Describe 'Import.ps1 omit resolution call-site contract (regression C-1)' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        $script:importScript = Get-Content "$PSScriptRoot\Import.ps1" -Raw
    }

    It 'passes the installed-manifest snapshot to Get-OmitFlagsForAddon' {
        $script:importScript | Should -Match '-InstalledManifestPath\s+\$installedManifestSnapshot'
    }

    It 'does not pass the destination manifest directly (pre-fix call site)' {
        $script:importScript | Should -Not -Match "-InstalledManifestPath\s+\(Join-Path\s+\`$destinationPath"
    }

    It 'creates the snapshot before the config layer can overwrite the destination manifest' {
        $snapshotIndex = $script:importScript.IndexOf('$installedManifestSnapshot = Join-Path $tempLayerDir')
        $overwriteIndex = $script:importScript.IndexOf('$configManifestPath -Destination')

        $snapshotIndex | Should -BeGreaterThan -1
        $overwriteIndex | Should -BeGreaterThan -1
        $snapshotIndex | Should -BeLessThan $overwriteIndex -Because 'the installed manifest must be captured before any config-layer copy replaces it'
    }

    It 'resolves the omit options after the config layer has been processed' {
        $snapshotIndex = $script:importScript.IndexOf('$installedManifestSnapshot = Join-Path $tempLayerDir')
        $resolveIndex = $script:importScript.IndexOf('Get-OmitFlagsForAddon')

        $resolveIndex | Should -BeGreaterThan $snapshotIndex
    }
}


