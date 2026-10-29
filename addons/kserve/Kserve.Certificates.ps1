# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$script:KserveCertificateManifests = Join-Path $PSScriptRoot 'config\manifests\certificates'
$script:KserveWebhooks = @(
    'mutatingwebhookconfiguration/inferenceservice.serving.kserve.io',
    'validatingwebhookconfiguration/clusterservingruntime.serving.kserve.io',
    'validatingwebhookconfiguration/inferencegraph.serving.kserve.io',
    'validatingwebhookconfiguration/inferenceservice.serving.kserve.io',
    'validatingwebhookconfiguration/servingruntime.serving.kserve.io',
    'validatingwebhookconfiguration/trainedmodel.serving.kserve.io'
)

function Test-KserveWebhookCertificate {
    param([pscustomobject] $Secret)

    if (-not $Secret.data.'tls.crt' -or -not $Secret.data.'tls.key' -or -not $Secret.data.'ca.crt') {
        return $false
    }
    foreach ($field in @('tls.crt', 'ca.crt')) {
        $pem = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($Secret.data.$field))
        $match = [regex]::Match($pem, '-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----')
        if (-not $match.Success) {
            throw "[KServe] Webhook TLS Secret field $field does not contain a PEM certificate."
        }
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            [Convert]::FromBase64String($match.Groups[1].Value))
        try {
            if ($certificate.NotBefore -gt (Get-Date) -or $certificate.NotAfter -le (Get-Date).AddDays(30)) {
                return $false
            }
        }
        finally { $certificate.Dispose() }
    }
    return $true
}

function Set-KserveWebhookCaBundle {
    param([Parameter(Mandatory = $true)][string] $CaBundle, [switch] $IncludeExisting)

    foreach ($resource in $script:KserveWebhooks) {
        $json = Invoke-KserveKubectl -Params 'get', $resource, '--ignore-not-found', '-o', 'json'
        if (-not $json) { continue }
        $webhook = $json | ConvertFrom-Json -ErrorAction Stop
        if ($webhook.metadata.labels.'app.kubernetes.io/managed-by' -ne 'k2s-kserve') {
            throw "[KServe] Refusing to change an unowned webhook configuration: $resource."
        }
        foreach ($entry in $webhook.webhooks) {
            $bundle = $CaBundle
            if ($IncludeExisting -and $entry.clientConfig.caBundle) {
                $oldCa = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($entry.clientConfig.caBundle))
                $newCa = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($CaBundle))
                $bundle = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$oldCa`n$newCa"))
            }
            $entry.clientConfig | Add-Member -NotePropertyName caBundle -NotePropertyValue $bundle -Force
        }
        $kind, $name = $resource -split '/', 2
        Invoke-KservePatch -Kind $kind -Name $name -Patch @{ webhooks = @($webhook.webhooks) }
    }
}

function Update-KserveWebhookCertificate {
    param([switch] $Force)

    $mutex = [System.Threading.Mutex]::new($false, 'Global\K2s-Kserve-Webhook-TLS')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] {
            $locked = $true
            Write-Log '[KServe] Recovering an interrupted webhook certificate operation' -Console
        }
        if (-not $locked) {
            throw '[KServe] Another webhook certificate operation is running. Retry after it completes.'
        }
        return Invoke-KserveWebhookCertificateUpdate -Force:$Force
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Complete-KserveWebhookCertificateRotation {
    param([Parameter(Mandatory = $true)][string] $CaBundle)

    $deployment = Invoke-KserveKubectl -Params 'get', 'deployment', 'kserve-controller-manager', '-n', 'kserve', '--ignore-not-found', '-o', 'name'
    if ($deployment) {
        Invoke-KserveKubectl -Params 'rollout', 'restart', 'deployment/kserve-controller-manager', '-n', 'kserve' | Write-Log
        Invoke-KserveKubectl -Params 'rollout', 'status', 'deployment/kserve-controller-manager', '-n', 'kserve', '--timeout=300s' | Write-Log
    }
    Set-KserveWebhookCaBundle -CaBundle $CaBundle
    Invoke-KservePatch -Kind secret -Name kserve-webhook-server-cert -Namespace kserve -Patch @{
        metadata = @{ annotations = @{ 'k2s.kubernetes.io/tls-rotation-pending' = $null } }
    }
    Invoke-KserveKubectl -Params 'delete', 'job', 'k2s-kserve-certgen', '-n', 'kserve', '--ignore-not-found', '--wait=true', '--timeout=60s' | Write-Log
    Invoke-KserveKubectl -Params 'delete', 'secret', 'k2s-kserve-webhook-next', '-n', 'kserve', '--ignore-not-found' | Write-Log
}

function Invoke-KserveWebhookCertificateUpdate {
    param([switch] $Force)

    $json = Invoke-KserveKubectl -Params 'get', 'secret', 'kserve-webhook-server-cert', '-n', 'kserve', '--ignore-not-found', '-o', 'json'
    $previous = $null
    if ($json) {
        $previous = $json | ConvertFrom-Json -ErrorAction Stop
        if ($previous.metadata.labels.'app.kubernetes.io/managed-by' -ne 'k2s-kserve') {
            throw '[KServe] Refusing to replace a webhook TLS Secret not owned by this addon.'
        }
        if (-not $Force -and (Test-KserveWebhookCertificate -Secret $previous)) {
            if ($previous.metadata.annotations.'k2s.kubernetes.io/tls-rotation-pending' -eq 'true') {
                Complete-KserveWebhookCertificateRotation -CaBundle $previous.data.'ca.crt'
            }
            else {
                Set-KserveWebhookCaBundle -CaBundle $previous.data.'ca.crt'
            }
            return $previous.data.'ca.crt'
        }
    }

    Write-Log '[KServe] Generating an addon-owned webhook certificate' -Console
    Invoke-KserveKubectl -Params 'apply', '--server-side', '-k', $script:KserveCertificateManifests | Write-Log
    Invoke-KserveKubectl -Params 'delete', 'job', 'k2s-kserve-certgen', '-n', 'kserve', '--ignore-not-found', '--wait=true', '--timeout=60s' | Write-Log
    Invoke-KserveKubectl -Params 'delete', 'secret', 'k2s-kserve-webhook-next', '-n', 'kserve', '--ignore-not-found' | Write-Log
    Invoke-KserveKubectl -Params 'apply', '-f', "$script:KserveCertificateManifests\job.yaml" | Write-Log
    try {
        Invoke-KserveKubectl -Params 'wait', '-n', 'kserve', '--for=condition=Complete', 'job/k2s-kserve-certgen', '--timeout=240s' | Write-Log
    }
    catch {
        $failure = $_
        $logs = Invoke-Kubectl -Params 'logs', '-n', 'kserve', 'job/k2s-kserve-certgen'
        Write-Log "[KServe] Certificate generation diagnostics: $($logs.Output)" -Console
        throw $failure
    }
    $nextJson = Invoke-KserveKubectl -Params 'get', 'secret', 'k2s-kserve-webhook-next', '-n', 'kserve', '-o', 'json'
    $next = $nextJson | ConvertFrom-Json -ErrorAction Stop
    $secret = @{
        apiVersion = 'v1'
        kind = 'Secret'
        type = 'kubernetes.io/tls'
        metadata = @{
            name = 'kserve-webhook-server-cert'
            namespace = 'kserve'
            labels = @{ 'app.kubernetes.io/managed-by' = 'k2s-kserve' }
            annotations = @{ 'k2s.kubernetes.io/tls-rotation-pending' = 'true' }
        }
        data = @{ 'tls.crt' = $next.data.'tls.crt'; 'tls.key' = $next.data.'tls.key'; 'ca.crt' = $next.data.ca }
    }
    $secretObject = $secret | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    if (-not (Test-KserveWebhookCertificate -Secret $secretObject)) {
        throw '[KServe] Certificate generation returned incomplete or expiring TLS material.'
    }
    $caBundle = $secret.data.'ca.crt'
    # Keep every previously trusted generation, including an interrupted rotation.
    Set-KserveWebhookCaBundle -CaBundle $caBundle -IncludeExisting

    $file = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-kserve-tls-$([guid]::NewGuid()).json"
    try {
        [System.IO.File]::WriteAllText($file, ($secret | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
        Invoke-KserveKubectl -Params 'apply', '--server-side', '-f', $file | Write-Log
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }

    Complete-KserveWebhookCertificateRotation -CaBundle $caBundle
    return $caBundle
}
