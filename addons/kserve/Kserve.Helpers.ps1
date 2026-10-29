# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

. "$PSScriptRoot\Kserve.Certificates.ps1"

$script:KserveOwner = 'k2s-kserve'
$script:KserveManifests = Join-Path $PSScriptRoot 'config\manifests'
$script:KserveCrds = @(
    'clusterservingruntimes.serving.kserve.io',
    'clusterstoragecontainers.serving.kserve.io',
    'inferencegraphs.serving.kserve.io',
    'inferenceservices.serving.kserve.io',
    'servingruntimes.serving.kserve.io',
    'trainedmodels.serving.kserve.io'
)

function Invoke-KserveKubectl {
    param([Parameter(Mandatory = $true)][string[]] $Params)

    $result = Invoke-Kubectl -Params $Params
    if (-not $result.Success) {
        throw "[KServe] kubectl $($Params -join ' ') failed: $($result.Output)"
    }
    return ($result.Output | Out-String).Trim()
}

function Invoke-KservePatch {
    param(
        [string] $Kind,
        [string] $Name,
        [string] $Namespace,
        [hashtable] $Patch
    )

    $patchFile = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-kserve-$([guid]::NewGuid()).json"
    try {
        $json = ConvertTo-Json -InputObject $Patch -Depth 30
        [System.IO.File]::WriteAllText($patchFile, $json, [System.Text.UTF8Encoding]::new($false))
        $parameters = @('patch', $Kind, $Name, '--type=merge', '--patch-file', $patchFile)
        if ($Namespace) {
            $parameters += @('-n', $Namespace)
        }
        Invoke-KserveKubectl -Params $parameters | Write-Log
    }
    finally {
        Remove-Item -LiteralPath $patchFile -Force -ErrorAction Stop
    }
}

function Assert-KserveOwnership {
    $namespaceJson = Invoke-KserveKubectl -Params 'get', 'namespace', 'kserve', '--ignore-not-found', '-o', 'json'
    if ($namespaceJson) {
        $namespace = $namespaceJson | ConvertFrom-Json -ErrorAction Stop
        if ($namespace.metadata.labels.'app.kubernetes.io/managed-by' -ne $script:KserveOwner) {
            throw '[KServe] Namespace kserve already exists outside this addon. Refusing to take over another installation.'
        }
    }
    $crds = Invoke-KserveKubectl -Params (@('get', 'crd') + $script:KserveCrds + @('--ignore-not-found', '-o', 'json'))
    foreach ($crd in ($crds | ConvertFrom-Json -ErrorAction Stop).items) {
        if ($crd.metadata.labels.'app.kubernetes.io/managed-by' -ne $script:KserveOwner) {
            throw "[KServe] CRD $($crd.metadata.name) is not owned by this addon. Refusing to take over another installation."
        }
    }
}

function Assert-KserveCaBundle {
    param([Parameter(Mandatory = $true)][string] $Path)

    $pem = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($pem -match 'PRIVATE KEY') {
        throw '[KServe] The CA bundle must contain public certificates only, never private keys.'
    }
    $certificates = [regex]::Matches($pem, '-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----')
    if ($certificates.Count -eq 0) {
        throw '[KServe] The CA bundle must contain PEM-encoded CA certificates.'
    }
    foreach ($match in $certificates) {
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            [Convert]::FromBase64String($match.Groups[1].Value))
        try {
            if ($certificate.NotAfter -lt (Get-Date) -or $certificate.NotBefore -gt (Get-Date)) {
                throw '[KServe] The CA bundle contains a certificate outside its validity period.'
            }
            $constraints = $certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' }
            if (-not $constraints -or -not $constraints.CertificateAuthority) {
                throw '[KServe] The bundle contains a non-CA certificate. Supply approved root/intermediate CA certificates.'
            }
        }
        finally {
            $certificate.Dispose()
        }
    }
}

function Resolve-KserveProxy {
    param([string] $Proxy)
    $proxyUrl = ''
    if ($Proxy -eq 'auto') {
        $proxyUrl = "http://$(Get-ConfiguredKubeSwitchIP):8181"
    }
    elseif ($Proxy -and $Proxy -ne 'none') {
        $proxyUrl = $Proxy
    }
    if ($proxyUrl) {
        $uri = $null
        $valid = [uri]::TryCreate($proxyUrl, [System.UriKind]::Absolute, [ref] $uri)
        if (-not $valid -or $uri.Scheme -notin @('http', 'https') -or -not $uri.Host -or
            $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
            throw '[KServe] Proxy must be an HTTP(S) URL without embedded credentials, auto, or none.'
        }
    }
    return $proxyUrl
}

function Set-KserveDownloadConfiguration {
    param([string] $Proxy, [string] $CaBundle)

    $proxyUrl = Resolve-KserveProxy -Proxy $Proxy
    $environment = @(
        @{ name = 'HTTP_PROXY'; value = $proxyUrl },
        @{ name = 'HTTPS_PROXY'; value = $proxyUrl },
        @{ name = 'http_proxy'; value = $proxyUrl },
        @{ name = 'https_proxy'; value = $proxyUrl },
        @{ name = 'NO_PROXY'; value = 'localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local' },
        @{ name = 'no_proxy'; value = 'localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local' }
    )
    Invoke-KservePatch -Kind clusterstoragecontainer -Name default -Patch @{
        spec = @{ container = @{ env = $environment } }
    }

    if ($CaBundle) {
        Assert-KserveCaBundle -Path $CaBundle
        $caJson = Invoke-KserveKubectl -Params 'create', 'configmap', 'k2s-kserve-ca', '-n', 'kserve', "--from-file=cabundle.crt=$CaBundle", '--dry-run=client', '-o', 'json'
        $ca = $caJson | ConvertFrom-Json -ErrorAction Stop
        $ca | Add-Member -NotePropertyName metadata -NotePropertyValue @{
            name = 'k2s-kserve-ca'
            namespace = 'kserve'
            labels = @{ 'app.kubernetes.io/managed-by' = $script:KserveOwner }
        } -Force
        $file = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-kserve-ca-$([guid]::NewGuid()).json"
        try {
            [System.IO.File]::WriteAllText($file, ($ca | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
            Invoke-KserveKubectl -Params 'apply', '--server-side', '-f', $file | Write-Log
        }
        finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction Stop
        }
    }

    # Keep an already configured approved CA on re-enable; disable retains this ConfigMap.
    $existingCa = Invoke-KserveKubectl -Params 'get', 'configmap', 'k2s-kserve-ca', '-n', 'kserve', '--ignore-not-found', '-o', 'json'
    if ($existingCa) {
        $configJson = Invoke-KserveKubectl -Params 'get', 'configmap', 'inferenceservice-config', '-n', 'kserve', '-o', 'json'
        $storage = ($configJson | ConvertFrom-Json -ErrorAction Stop).data.storageInitializer | ConvertFrom-Json -ErrorAction Stop
        $storage.caBundleConfigMapName = 'k2s-kserve-ca'
        Invoke-KservePatch -Kind configmap -Name inferenceservice-config -Namespace kserve -Patch @{
            data = @{ storageInitializer = ($storage | ConvertTo-Json -Depth 20 -Compress) }
        }
    }
}

function Install-Kserve {
    param(
        [ValidateSet('none', 'qwen-cpu', 'qwen-gpu')][string] $Model = 'none',
        [string] $Proxy = 'auto',
        [string] $CaBundle
    )

    Assert-KserveOwnership
    if ($CaBundle) { Assert-KserveCaBundle -Path $CaBundle }
    $null = Resolve-KserveProxy -Proxy $Proxy

    $existingApi = Invoke-KserveKubectl -Params 'get', 'crd', 'inferenceservices.serving.kserve.io', '--ignore-not-found', '-o', 'name'
    if ($existingApi) {
        $examples = Invoke-KserveKubectl -Params 'get', 'inferenceservices.serving.kserve.io', '--all-namespaces',
            '-l', "app.kubernetes.io/managed-by=$script:KserveOwner", '-o', 'json'
        foreach ($example in ($examples | ConvertFrom-Json -ErrorAction Stop).items) {
            $matchingCpu = $Model -eq 'qwen-cpu' -and $example.metadata.name -eq 'qwen-small-cpu' -and $example.metadata.namespace -eq 'kserve-models-cpu'
            $matchingGpu = $Model -eq 'qwen-gpu' -and $example.metadata.name -eq 'qwen-small' -and $example.metadata.namespace -eq 'kserve-models'
            if (-not $matchingCpu -and -not $matchingGpu) {
                throw '[KServe] A previous installation left model workloads. Retry the original --model selection, or remove those workloads while the controller is running before changing selection.'
            }
        }
    }

    if ($Model -ne 'none') {
        $namespace = 'kserve-models-cpu'
        $name = 'qwen-small-cpu'
        if ($Model -eq 'qwen-gpu') { $namespace = 'kserve-models'; $name = 'qwen-small' }
        $existingNamespace = Invoke-KserveKubectl -Params 'get', 'namespace', $namespace, '--ignore-not-found', '-o', 'json'
        if ($existingNamespace -and ($existingNamespace | ConvertFrom-Json -ErrorAction Stop).metadata.labels.'app.kubernetes.io/managed-by' -ne $script:KserveOwner) {
            throw "[KServe] Model namespace $namespace is not owned by this addon. Choose --model none and deploy your own InferenceService instead."
        }
    }

    $versionJson = Invoke-KserveKubectl -Params 'version', '-o', 'json'
    $version = ($versionJson | ConvertFrom-Json -ErrorAction Stop).serverVersion
    if ([int]$version.major -lt 1 -or ([int]$version.major -eq 1 -and [int]($version.minor -replace '\D.*$', '') -lt 32)) {
        throw '[KServe] Kubernetes 1.32 or newer is required.'
    }
    $nodes = Invoke-KserveKubectl -Params 'get', 'nodes', '-l', 'kubernetes.io/os=linux', '-o', 'json'
    $linuxNodes = @((($nodes | ConvertFrom-Json -ErrorAction Stop).items))
    if ($linuxNodes.Count -eq 0) {
        throw '[KServe] A Linux node is required.'
    }
    if ($Model -eq 'qwen-gpu') {
        $gpuNodes = @($linuxNodes | Where-Object { [int]$_.status.allocatable.'nvidia.com/gpu' -gt 0 })
        if ($gpuNodes.Count -eq 0) {
            throw '[KServe] No Linux node advertises nvidia.com/gpu. Configure compatible NVIDIA drivers, container toolkit and device plugin first.'
        }
    }

    Write-Log '[KServe] Installing CRDs and waiting for discovery' -Console
    Invoke-KserveKubectl -Params 'apply', '--server-side', '-f', "$script:KserveManifests\namespace.yaml" | Write-Log
    Invoke-KserveKubectl -Params 'apply', '--server-side', '-k', "$script:KserveManifests\crds" | Write-Log
    Invoke-KserveKubectl -Params 'wait', '--for=condition=Established', '-f', "$script:KserveManifests\crds\kserve-crds.yaml", '--timeout=120s' | Write-Log
    $webhookCa = Update-KserveWebhookCertificate

    Write-Log '[KServe] Installing the Standard-mode controller' -Console
    Invoke-KserveKubectl -Params 'apply', '--server-side', '-k', "$script:KserveManifests\controller" | Write-Log
    Set-KserveWebhookCaBundle -CaBundle $webhookCa
    Set-KserveDownloadConfiguration -Proxy $Proxy -CaBundle $CaBundle
    # Configuration is read at startup; also covers retrying a partially completed installation.
    Invoke-KserveKubectl -Params 'rollout', 'restart', 'deployment/kserve-controller-manager', '-n', 'kserve' | Write-Log
    Invoke-KserveKubectl -Params 'rollout', 'status', 'deployment/kserve-controller-manager', '-n', 'kserve', '--timeout=300s' | Write-Log
    foreach ($webhook in $script:KserveWebhooks) {
        Invoke-KserveKubectl -Params 'wait', '--for=jsonpath={.webhooks[0].clientConfig.caBundle}', $webhook, '--timeout=180s' | Write-Log
    }
    Invoke-KserveKubectl -Params 'apply', '--server-side', '-k', "$script:KserveManifests\runtimes" | Write-Log

    if ($Model -ne 'none') {
        Write-Log "[KServe] Starting $Model; this explicitly downloads public model weights unless storageUri was changed to pre-staged storage" -Console
        Invoke-KserveKubectl -Params 'apply', '--server-side', '-k', "$script:KserveManifests\examples\$Model" | Write-Log
        Invoke-KserveKubectl -Params 'wait', '-n', $namespace, '--for=condition=Ready', "inferenceservice/$name", '--timeout=1800s' | Write-Log
    }
}

function Uninstall-Kserve {
    Assert-KserveOwnership
    $resources = @()
    foreach ($kind in @('inferenceservices', 'inferencegraphs', 'trainedmodels', 'servingruntimes')) {
        $json = Invoke-KserveKubectl -Params 'get', "$kind.serving.kserve.io", '--all-namespaces', '-o', 'json'
        $items = @((($json | ConvertFrom-Json -ErrorAction Stop).items))
        foreach ($item in $items) {
            $ownedExample = $kind -eq 'inferenceservices' -and (
                ($item.metadata.name -eq 'qwen-small-cpu' -and $item.metadata.namespace -eq 'kserve-models-cpu') -or
                ($item.metadata.name -eq 'qwen-small' -and $item.metadata.namespace -eq 'kserve-models')
            ) -and $item.metadata.labels.'app.kubernetes.io/managed-by' -eq $script:KserveOwner
            if (-not $ownedExample) {
                throw "[KServe] $kind $($item.metadata.namespace)/$($item.metadata.name) still exists. Remove custom workloads before disabling; their finalizers need the controller."
            }
            $resources += $item
        }
    }
    foreach ($item in $resources) {
        Invoke-KserveKubectl -Params 'delete', 'inferenceservice', $item.metadata.name, '-n', $item.metadata.namespace, '--wait=true', '--timeout=180s' | Write-Log
    }
    Invoke-KserveKubectl -Params 'delete', '--ignore-not-found', '--timeout=180s', '-k', "$script:KserveManifests\runtimes" | Write-Log
    Invoke-KserveKubectl -Params 'delete', '--ignore-not-found', '--timeout=180s', '-k', "$script:KserveManifests\controller" | Write-Log
    Invoke-KserveKubectl -Params 'delete', 'job', 'k2s-kserve-certgen', '-n', 'kserve', '--ignore-not-found', '--wait=true', '--timeout=60s' | Write-Log
    Invoke-KserveKubectl -Params 'delete', 'secret', 'kserve-webhook-server-cert', 'k2s-kserve-webhook-next', '-n', 'kserve', '--ignore-not-found' | Write-Log
    Invoke-KserveKubectl -Params 'delete', '--ignore-not-found', '-k', $script:KserveCertificateManifests | Write-Log
    Write-Log '[KServe] Retained CRDs, namespaces, model storage and approved download CA bundle. Model pods, controller and addon-owned webhook TLS resources have been removed.' -Console
}
