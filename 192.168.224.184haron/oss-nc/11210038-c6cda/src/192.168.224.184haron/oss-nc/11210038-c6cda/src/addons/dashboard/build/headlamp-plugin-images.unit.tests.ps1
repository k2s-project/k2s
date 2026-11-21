# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# ──────────────────────────────────────────────────────────────────────────────
# Offline-packaging consistency guard for the Headlamp plugin supply chain.
#
# These tests fail the build if the three coordinates ever drift apart:
#   1. headlamp-plugins.lock.json            (build inputs / producer)
#   2. addon.manifest.yaml additionalImages  (offline packaging / consumer)
#   3. Get-RegisteredHeadlampPlugins         (runtime injection / consumer)
#
# A mismatch here is exactly the Phase 3 P0 failure mode: an image referenced by
# packaging that the supply chain does not build, or vice versa.
# ──────────────────────────────────────────────────────────────────────────────

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $script:dashboardDir = Split-Path -Parent $PSScriptRoot
    $script:lockPath = Join-Path $PSScriptRoot 'headlamp-plugins.lock.json'
    $script:manifestPath = Join-Path $script:dashboardDir 'addon.manifest.yaml'
    $script:modulePath = Join-Path $script:dashboardDir 'dashboard.module.psm1'

    $script:lock = Get-Content -Raw -Path $script:lockPath | ConvertFrom-Json

    # additionalImages from the manifest (simple line parse — no yaml dependency)
    $script:manifestImages = Get-Content -Path $script:manifestPath |
        Where-Object { $_ -match 'shsk2s\.azurecr\.io/headlamp-plugin-' } |
        ForEach-Object { ($_ -replace '^\s*-\s*', '').Trim() }
}

Describe 'Headlamp plugin lock file' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'declares exactly four plugins' {
        $script:lock.plugins.Count | Should -Be 4
    }

    It 'maps each plugin to a /plugins/<pluginDir> matching the image name' {
        foreach ($p in $script:lock.plugins) {
            $p.pluginDir | Should -Not -BeNullOrEmpty
            $p.image | Should -BeLike "*headlamp-plugin-$($p.name):$($p.version)"
        }
    }

    It 'uses the shsk2s.azurecr.io registry for every image' {
        foreach ($p in $script:lock.plugins) {
            $p.image | Should -BeLike 'shsk2s.azurecr.io/*'
        }
    }
}

Describe 'Headlamp plugin acquisition source (GitHub Release assets)' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'pins prebuilt.url to a headlamp-k8s/plugins GitHub Release asset for every plugin' {
        foreach ($p in $script:lock.plugins) {
            $p.prebuilt.url | Should -Match '^https://github\.com/headlamp-k8s/plugins/releases/download/'
            $p.prebuilt.url | Should -Match "/$([regex]::Escape($p.name))-$([regex]::Escape($p.version))/"
        }
    }

    It 'does not reference ArtifactHub in prebuilt.url' {
        foreach ($p in $script:lock.plugins) {
            $p.prebuilt.url | Should -Not -Match 'artifacthub\.io'
        }
    }

    It 'has no artifacthubPackage field on any plugin (acquisition is GitHub-only)' {
        foreach ($p in $script:lock.plugins) {
            ($p.PSObject.Properties.Name -contains 'artifacthubPackage') | Should -BeFalse
        }
    }

    It 'pins a concrete lower-case hex sha256 (not TO-PIN) for every plugin' {
        foreach ($p in $script:lock.plugins) {
            $p.prebuilt.sha256 | Should -Match '^[0-9a-f]{64}$'
        }
    }
}

Describe 'Lock and addon.manifest.yaml additionalImages parity' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'has a manifest additionalImages entry for every lock image' {
        foreach ($p in $script:lock.plugins) {
            $script:manifestImages | Should -Contain $p.image
        }
    }

    It 'has a lock entry for every manifest plugin image' {
        $lockImages = $script:lock.plugins | ForEach-Object { $_.image }
        foreach ($img in $script:manifestImages) {
            $lockImages | Should -Contain $img
        }
    }
}

Describe 'Vendored plugin bundle (prebuilt.localPath) consistency' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    It 'declares a plugins/<plugin>-<version>.tar.gz localPath for every plugin' {
        foreach ($p in $script:lock.plugins) {
            $p.prebuilt.localPath | Should -Be "plugins/$($p.name)-$($p.version).tar.gz"
        }
    }

    It 'matches prebuilt.sha256 when the vendored tarball is present (skipped until vendored)' {
        foreach ($p in $script:lock.plugins) {
            $vendored = Join-Path $PSScriptRoot $p.prebuilt.localPath
            if (-not (Test-Path $vendored)) {
                continue  # falls back to prebuilt.url until the bundle is committed
            }
            $expected = "$($p.prebuilt.sha256)".ToLowerInvariant()
            if ($expected -eq 'to-pin' -or [string]::IsNullOrWhiteSpace($expected)) {
                continue  # checksum not yet pinned
            }
            $actual = (Get-FileHash -Path $vendored -Algorithm SHA256).Hash.ToLowerInvariant()
            $actual | Should -Be $expected
        }
    }

    It 'has a REUSE .license sidecar for every vendored tarball present' {
        foreach ($p in $script:lock.plugins) {
            $vendored = Join-Path $PSScriptRoot $p.prebuilt.localPath
            if (-not (Test-Path $vendored)) { continue }
            "$vendored.license" | Should -Exist
        }
    }
}

Describe 'Lock and Get-RegisteredHeadlampPlugins parity' -Tag 'unit', 'ci', 'addon', 'dashboard' {
    BeforeAll {
        $script:moduleName = (Import-Module $script:modulePath -PassThru -Force).Name
    }

    It 'registers each lock image under the matching init-container name (pluginDir)' {
        $registered = & (Get-Module $script:moduleName) { Get-RegisteredHeadlampPlugins }
        foreach ($p in $script:lock.plugins) {
            $match = $registered | Where-Object { $_.Name -eq $p.pluginDir }
            $match | Should -Not -BeNullOrEmpty
            $match.Image | Should -Be $p.image
        }
    }

    It 'has no registered plugin without a lock entry' {
        $registered = & (Get-Module $script:moduleName) { Get-RegisteredHeadlampPlugins }
        $lockDirs = $script:lock.plugins | ForEach-Object { $_.pluginDir }
        foreach ($r in $registered) {
            $lockDirs | Should -Contain $r.Name
        }
    }
}



