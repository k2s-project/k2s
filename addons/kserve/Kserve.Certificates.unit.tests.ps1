# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    . "$PSScriptRoot\Kserve.Helpers.ps1"
    function Invoke-Kubectl { param([string[]] $Params) throw 'Unmocked kubectl invocation' }
    function Write-Log { param($Message, [switch] $Console) }
    function Test-IsAddonEnabled { param($Addon) return $true }

    function New-TestWebhookSecret {
        param([int] $Days = 365)
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        try {
            $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=kserve-webhook-server-service.kserve.svc', $rsa,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $cert = $request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays($Days))
            try {
                $base64 = [Convert]::ToBase64String($cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
                $pem = "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----"
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pem))
                return [pscustomobject]@{
                    metadata = @{ labels = @{ 'app.kubernetes.io/managed-by' = 'k2s-kserve' }; annotations = @{} }
                    data = @{ 'tls.crt' = $encoded; 'tls.key' = 'dGVzdCBrZXk='; 'ca.crt' = $encoded }
                }
            }
            finally { $cert.Dispose() }
        }
        finally { $rsa.Dispose() }
    }

    $script:OldSecret = New-TestWebhookSecret
    $script:NewSecret = New-TestWebhookSecret
    $script:ExpiringSecret = New-TestWebhookSecret -Days 20
}

Describe 'Independent KServe webhook certificates' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
        $script:Commands = [System.Collections.Generic.List[string]]::new()
        $script:Patches = [System.Collections.Generic.List[object]]::new()
        $script:ExistingSecret = ''
        $script:Deployment = ''
        $script:WebhookCa = $script:OldSecret.data.'ca.crt'
        $script:FailurePattern = '^$'
        $script:AppliedSecret = $null
        $script:SecretFile = $null
        Mock Write-Log { }
        Mock Invoke-Kubectl { return @{ Success = $true; Output = 'certificate job diagnostics' } }
        Mock Invoke-KservePatch {
            $script:Commands.Add("patch $Kind/$Name")
            $script:Patches.Add(@{ Kind = $Kind; Name = $Name; Patch = $Patch })
        }
        Mock Invoke-KserveKubectl {
            $command = $Params -join ' '
            $script:Commands.Add($command)
            if ($command -match $script:FailurePattern) { throw 'simulated certificate failure' }
            if ($Params[0] -eq 'get' -and $Params[1] -eq 'secret') {
                if ($Params[2] -eq 'kserve-webhook-server-cert') { return $script:ExistingSecret }
                return (@{ data = @{
                    'tls.crt' = $script:NewSecret.data.'tls.crt'
                    'tls.key' = $script:NewSecret.data.'tls.key'
                    ca = $script:NewSecret.data.'ca.crt'
                } } | ConvertTo-Json -Depth 10)
            }
            if ($Params[0] -eq 'get' -and $Params[1] -eq 'deployment') { return $script:Deployment }
            if ($Params[0] -eq 'get' -and $Params[1] -like '*webhookconfiguration/*') {
                return (@{
                    metadata = @{ labels = @{ 'app.kubernetes.io/managed-by' = 'k2s-kserve' } }
                    webhooks = @(
                        @{ name = 'first'; clientConfig = @{ service = @{ path = '/first' }; caBundle = $script:WebhookCa } },
                        @{ name = 'second'; clientConfig = @{ service = @{ path = '/second' }; caBundle = $script:WebhookCa } }
                    )
                } | ConvertTo-Json -Depth 10)
            }
            if ($Params[0] -eq 'apply' -and $Params[-1] -like '*k2s-kserve-tls-*.json') {
                $script:SecretFile = $Params[-1]
                $script:AppliedSecret = Get-Content -LiteralPath $script:SecretFile -Raw | ConvertFrom-Json
            }
            return ''
        }
    }

    It 'creates a TLS Secret and patches every entry in all six webhook configurations' {
        $ca = Update-KserveWebhookCertificate
        $ca | Should -Be $script:NewSecret.data.'ca.crt'
        $script:AppliedSecret.type | Should -Be 'kubernetes.io/tls'
        $script:AppliedSecret.data.'tls.key' | Should -Be $script:NewSecret.data.'tls.key'
        $script:AppliedSecret.metadata.annotations.'k2s.kubernetes.io/tls-rotation-pending' | Should -Be 'true'
        Test-Path -LiteralPath $script:SecretFile | Should -BeFalse
        $webhookPatches = @($script:Patches | Where-Object Kind -Like '*webhookconfiguration')
        $webhookPatches.Count | Should -Be 12
        @($webhookPatches | Where-Object Kind -EQ 'mutatingwebhookconfiguration').Count | Should -Be 2
        @($webhookPatches | Where-Object Kind -EQ 'validatingwebhookconfiguration').Count | Should -Be 10
        foreach ($patch in $webhookPatches[-6..-1]) {
            $patch.Patch.webhooks.Count | Should -Be 2
            foreach ($entry in $patch.Patch.webhooks) { $entry.clientConfig.caBundle | Should -Be $ca }
            $patch.Patch.webhooks[0].clientConfig.service.path | Should -Be '/first'
            $patch.Patch.webhooks[1].clientConfig.service.path | Should -Be '/second'
        }
    }

    It 'reuses a healthy certificate without running a generation Job' {
        $script:ExistingSecret = $script:OldSecret | ConvertTo-Json -Depth 10
        Update-KserveWebhookCertificate | Should -Be $script:OldSecret.data.'ca.crt'
        Should -Invoke Invoke-KserveKubectl -Times 0 -ParameterFilter { $Params[0] -eq 'apply' }
        Should -Invoke Invoke-KserveKubectl -Times 0 -ParameterFilter { $Params[0] -eq 'rollout' }
    }

    It 'retains old trust until the replacement controller rollout has completed' {
        $script:ExistingSecret = $script:OldSecret | ConvertTo-Json -Depth 10
        $script:Deployment = 'deployment.apps/kserve-controller-manager'
        $null = Update-KserveWebhookCertificate -Force
        $commands = $script:Commands.ToArray()
        $firstPatch = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -like 'patch *webhookconfiguration/*' })
        $secretApply = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -like 'apply *k2s-kserve-tls-*.json' })
        $rollout = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -like 'rollout status *' })
        $lastPatch = [array]::FindLastIndex($commands, [predicate[string]]{ param($line) $line -like 'patch *webhookconfiguration/*' })
        $firstPatch | Should -BeLessThan $secretApply
        $secretApply | Should -BeLessThan $rollout
        $rollout | Should -BeLessThan $lastPatch
        $first = $script:Patches[0].Patch.webhooks[0].clientConfig.caBundle
        $pem = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($first))
        ([regex]::Matches($pem, 'BEGIN CERTIFICATE')).Count | Should -Be 2
        $script:Patches[-2].Patch.webhooks[0].clientConfig.caBundle | Should -Be $script:NewSecret.data.'ca.crt'
    }

    It 'preserves all previously trusted generations when retrying a forced rotation' {
        $script:ExistingSecret = $script:NewSecret | ConvertTo-Json -Depth 10
        $old = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($script:OldSecret.data.'ca.crt'))
        $new = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($script:NewSecret.data.'ca.crt'))
        $script:WebhookCa = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$old`n$new"))
        $null = Update-KserveWebhookCertificate -Force
        $bundle = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($script:Patches[0].Patch.webhooks[0].clientConfig.caBundle))
        ([regex]::Matches($bundle, 'BEGIN CERTIFICATE')).Count | Should -Be 3
    }

    It 'keeps overlapping trust and the recovery marker when controller rollout fails' {
        $script:Deployment = 'deployment.apps/kserve-controller-manager'
        $script:FailurePattern = '^rollout status'
        { Update-KserveWebhookCertificate -Force } | Should -Throw '*simulated certificate failure*'
        $script:Patches.Count | Should -Be 6
        Should -Invoke Invoke-KservePatch -Times 0 -ParameterFilter { $Kind -eq 'secret' }
        $script:AppliedSecret.metadata.annotations.'k2s.kubernetes.io/tls-rotation-pending' | Should -Be 'true'
    }

    It 'resumes an interrupted rollout before removing the old CA without generating again' {
        $pending = $script:NewSecret | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $pending.metadata.annotations | Add-Member -NotePropertyName 'k2s.kubernetes.io/tls-rotation-pending' -NotePropertyValue 'true'
        $script:ExistingSecret = $pending | ConvertTo-Json -Depth 10
        $script:Deployment = 'deployment.apps/kserve-controller-manager'
        $null = Update-KserveWebhookCertificate
        Should -Invoke Invoke-KserveKubectl -Times 0 -ParameterFilter { $Params[0] -eq 'apply' }
        Should -Invoke Invoke-KserveKubectl -Times 1 -ParameterFilter { $Params[0] -eq 'rollout' -and $Params[1] -eq 'status' }
        $commands = $script:Commands.ToArray()
        $rollout = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -like 'rollout status *' })
        $patch = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -like 'patch *webhookconfiguration/*' })
        $patch | Should -BeGreaterThan $rollout
        Should -Invoke Invoke-KservePatch -Times 1 -ParameterFilter {
            $Kind -eq 'secret' -and $Patch.metadata.annotations.ContainsKey('k2s.kubernetes.io/tls-rotation-pending') -and
            $null -eq $Patch.metadata.annotations.'k2s.kubernetes.io/tls-rotation-pending'
        }
    }

    It 'leaves existing TLS untouched and surfaces Job diagnostics when generation fails' {
        $script:FailurePattern = '^wait .*job/k2s-kserve-certgen'
        { Update-KserveWebhookCertificate -Force } | Should -Throw '*simulated certificate failure*'
        $script:AppliedSecret | Should -BeNullOrEmpty
        $script:Patches.Count | Should -Be 0
        Should -Invoke Invoke-Kubectl -Times 1 -ParameterFilter { $Params[0] -eq 'logs' }
    }

    It 'rejects incomplete generated TLS material before changing trust or the serving Secret' {
        Mock Invoke-KserveKubectl { return '{"data":{}}' } -ParameterFilter {
            $Params[0] -eq 'get' -and $Params[1] -eq 'secret' -and $Params[2] -eq 'k2s-kserve-webhook-next'
        }
        { Update-KserveWebhookCertificate -Force } | Should -Throw '*incomplete or expiring*'
        $script:AppliedSecret | Should -BeNullOrEmpty
        $script:Patches.Count | Should -Be 0
    }

    It 'rejects a Secret owned by another installation before mutation' {
        $script:ExistingSecret = '{"metadata":{"labels":{}}}'
        { Update-KserveWebhookCertificate -Force } | Should -Throw '*not owned by this addon*'
        Should -Invoke Invoke-KserveKubectl -Times 0 -ParameterFilter { $Params[0] -eq 'apply' -or $Params[0] -eq 'delete' }
    }

    It 'rejects an unowned webhook configuration' {
        Mock Invoke-KserveKubectl { return '{"metadata":{"labels":{}},"webhooks":[]}' }
        { Set-KserveWebhookCaBundle -CaBundle 'Y2E=' } | Should -Throw '*unowned webhook configuration*'
        Should -Invoke Invoke-KservePatch -Times 0
    }

    It 'checks missing, healthy and near-expiry certificate state' {
        Test-KserveWebhookCertificate -Secret ([pscustomobject]@{ data = @{} }) | Should -BeFalse
        Test-KserveWebhookCertificate -Secret $script:OldSecret | Should -BeTrue
        Test-KserveWebhookCertificate -Secret $script:ExpiringSecret | Should -BeFalse
    }

    It 'also renews when the CA expires before the serving certificate' {
        $secret = $script:NewSecret | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $secret.data.'ca.crt' = $script:ExpiringSecret.data.'ca.crt'
        Test-KserveWebhookCertificate -Secret $secret | Should -BeFalse
    }
}

Describe 'KServe certificate lifecycle hooks' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
        Mock Write-Log { }
        Mock Test-IsAddonEnabled { return $true }
        Mock Update-KserveWebhookCertificate { return 'Y2E=' }
    }

    It 'checks certificates on start without forcing rotation' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\hooks\Setup-Kserve.AfterStart.ps1", [ref]$null, [ref]$null)
        $body = $ast.EndBlock.Statements[-1].Extent.Text
        & ([scriptblock]::Create($body))
        Should -Invoke Update-KserveWebhookCertificate -Times 1 -ParameterFilter { -not $Force }
    }

    It 'does not rotate when the addon is disabled' {
        Mock Test-IsAddonEnabled { return $false }
        foreach ($path in Get-ChildItem "$PSScriptRoot\hooks\*.ps1") {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$null, [ref]$null)
            & ([scriptblock]::Create($ast.EndBlock.Statements[-1].Extent.Text))
        }
        Should -Invoke Update-KserveWebhookCertificate -Times 0
    }

    It 'propagates hook renewal failures' {
        Mock Update-KserveWebhookCertificate { throw 'rotation failed' }
        $ast = [System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\hooks\Setup-Kserve.AfterStart.ps1", [ref]$null, [ref]$null)
        { & ([scriptblock]::Create($ast.EndBlock.Statements[-1].Extent.Text)) } | Should -Throw '*rotation failed*'
    }

    It 'uses only the existing AfterStart hook event' {
        $hooks = @(Get-ChildItem "$PSScriptRoot\hooks\*.ps1")
        $hooks.Count | Should -Be 1
        $hooks[0].Name | Should -Be 'Setup-Kserve.AfterStart.ps1'
    }
}
