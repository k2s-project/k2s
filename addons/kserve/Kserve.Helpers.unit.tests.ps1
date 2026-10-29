# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    . "$PSScriptRoot\Kserve.Helpers.ps1"
    function Invoke-Kubectl { param([string[]] $Params) throw 'Unmocked kubectl invocation' }
    function Write-Log { param($Message, [switch] $Console, [switch] $Error) }
    function Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
}

Describe 'KServe lifecycle' -Tag 'unit', 'ci', 'addon' {
    BeforeEach {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:FailMatch = '^$'
        Mock Write-Log { }
        Mock Update-KserveWebhookCertificate { return 'Y2E=' }
        Mock Set-KserveWebhookCaBundle { }
        Mock Invoke-Kubectl {
            $script:Calls.Add(@($Params))
            $command = $Params -join ' '
            if ($command -match $script:FailMatch) {
                return @{ Success = $false; Output = 'simulated failure' }
            }
            $output = ''
            if ($Params[0] -eq 'version') {
                $output = '{"serverVersion":{"major":"1","minor":"35"}}'
            }
            elseif ($Params[0] -eq 'get') {
                if ($Params[1] -eq 'nodes') {
                    $output = '{"items":[{"metadata":{"name":"linux"},"status":{"allocatable":{"nvidia.com/gpu":"1"}}}]}'
                }
                elseif ($Params[1] -eq 'crd' -or $Params[1] -like '*.serving.kserve.io') {
                    $output = '{"items":[]}'
                }
            }
            return @{ Success = $true; Output = $output }
        }
    }

    It 'installs in stages without starting any models by default' {
        Install-Kserve
        $commands = @($script:Calls | ForEach-Object { $_ -join ' ' })
        $crds = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -match '^apply .*\\crds$' })
        $established = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -match '^wait .*\\crds\\kserve-crds.yaml' })
        $controller = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -match '^apply .*\\controller$' })
        $rollout = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -match '^rollout status deployment/kserve-controller-manager' })
        $runtimes = [array]::FindIndex($commands, [predicate[string]]{ param($line) $line -match '^apply .*\\runtimes$' })
        $crds | Should -BeGreaterThan -1
        $established | Should -BeGreaterThan $crds
        $controller | Should -BeGreaterThan $established
        $rollout | Should -BeGreaterThan $controller
        $runtimes | Should -BeGreaterThan $rollout
        ($commands -match '\\examples\\') | Should -BeNullOrEmpty
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter { $Params -contains '--force-conflicts' }
    }

    It 'starts only the explicitly selected CPU example and waits for its readiness' {
        Install-Kserve -Model qwen-cpu -Proxy none
        Should -Invoke Invoke-Kubectl -Times 1 -ParameterFilter {
            $Params[0] -eq 'apply' -and $Params[-1] -like '*\examples\qwen-cpu'
        }
        Should -Invoke Invoke-Kubectl -Times 1 -ParameterFilter {
            $Params -contains 'inferenceservice/qwen-small-cpu' -and $Params -contains '--timeout=1800s'
        }
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter {
            $Params -contains "$script:KserveManifests\examples\qwen-gpu"
        }
    }

    It 'does not install anything on unsupported Kubernetes versions' {
        Mock Invoke-Kubectl { return @{ Success = $true; Output = '{"serverVersion":{"major":"1","minor":"31+"}}' } } -ParameterFilter { $Params[0] -eq 'version' }
        { Install-Kserve } | Should -Throw '*1.32 or newer*'
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter { $Params[0] -eq 'apply' }
    }

    It 'requires a Linux node' {
        Mock Invoke-Kubectl { return @{ Success = $true; Output = '{"items":[]}' } } -ParameterFilter { $Params[1] -eq 'nodes' }
        { Install-Kserve } | Should -Throw '*Linux node is required*'
    }

    It 'rejects GPU model selection before mutation when no GPU is exposed' {
        Mock Invoke-Kubectl { return @{ Success = $true; Output = '{"items":[{"status":{"allocatable":{}}}]}' } } -ParameterFilter { $Params[1] -eq 'nodes' }
        { Install-Kserve -Model qwen-gpu } | Should -Throw '*No Linux node advertises*'
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter { $Params[0] -eq 'apply' }
    }

    It 'uses addon-owned certificates without invoking cert-manager' {
        Install-Kserve
        Should -Invoke Update-KserveWebhookCertificate -Times 1
        Should -Invoke Set-KserveWebhookCaBundle -Times 1 -ParameterFilter { $CaBundle -eq 'Y2E=' }
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter {
            ($Params -join ' ') -match 'cert-manager|certificate/|issuer/'
        }
    }

    It 'does not install the controller if certificate generation fails' {
        Mock Update-KserveWebhookCertificate { throw 'certificate generation failed' }
        { Install-Kserve } | Should -Throw '*certificate generation failed*'
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter { $Params[0] -eq 'apply' -and $Params[-1] -like '*\controller' }
    }

    It 'refuses a namespace from another installation' {
        Mock Invoke-Kubectl { return @{ Success = $true; Output = '{"metadata":{"labels":{}}}' } } -ParameterFilter {
            $Params[0] -eq 'get' -and $Params -contains 'namespace' -and $Params -contains 'kserve'
        }
        { Install-Kserve } | Should -Throw '*Refusing to take over*'
    }

    It 'refuses CRDs from another installation' {
        Mock Invoke-Kubectl { return @{ Success = $true; Output = '{"items":[{"metadata":{"name":"inferenceservices.serving.kserve.io","labels":{}}}]}' } } -ParameterFilter {
            $Params[0] -eq 'get' -and $Params[1] -eq 'crd'
        }
        { Install-Kserve } | Should -Throw '*Refusing to take over*'
    }

    It 'propagates controller readiness failures without starting a model' {
        $script:FailMatch = '^rollout status deployment/kserve-controller-manager'
        { Install-Kserve -Model qwen-cpu } | Should -Throw '*simulated failure*'
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter {
            $Params[0] -eq 'apply' -and $Params[-1] -like '*\examples\*'
        }
    }

    It 'propagates model download or readiness failures' {
        $script:FailMatch = '^wait .*inferenceservice/qwen-small-cpu'
        { Install-Kserve -Model qwen-cpu } | Should -Throw '*simulated failure*'
    }

    It 'does not silently leave a previously failed example running when retried with model none' {
        Mock Invoke-Kubectl {
            return @{ Success = $true; Output = '{"items":[{"metadata":{"name":"qwen-small-cpu","namespace":"kserve-models-cpu"}}]}' }
        } -ParameterFilter { $Params[0] -eq 'get' -and $Params[1] -eq 'inferenceservices.serving.kserve.io' }
        { Install-Kserve -Model none } | Should -Throw '*Retry the original --model selection*'
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter { $Params[0] -eq 'apply' }
    }

    It 'refuses disabling while custom workloads still need the controller' {
        Mock Invoke-Kubectl {
            return @{ Success = $true; Output = '{"items":[{"metadata":{"name":"custom","namespace":"models","labels":{}}}]}' }
        } -ParameterFilter { $Params[0] -eq 'get' -and $Params[1] -eq 'inferenceservices.serving.kserve.io' }
        { Uninstall-Kserve } | Should -Throw '*Remove custom workloads before disabling*'
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter { $Params[0] -eq 'delete' }
    }

    It 'deletes owned models before their controller and retains CRDs and shared services' {
        Mock Invoke-Kubectl {
            return @{ Success = $true; Output = '{"items":[{"metadata":{"name":"qwen-small-cpu","namespace":"kserve-models-cpu","labels":{"app.kubernetes.io/managed-by":"k2s-kserve"}}}]}' }
        } -ParameterFilter { $Params[0] -eq 'get' -and $Params[1] -eq 'inferenceservices.serving.kserve.io' }
        Uninstall-Kserve
        $deletes = @($script:Calls | Where-Object { $_[0] -eq 'delete' } | ForEach-Object { $_ -join ' ' })
        $deletes.Count | Should -Be 6
        $deletes[0] | Should -Match '^delete inferenceservice qwen-small-cpu '
        $deletes[2] | Should -Match '\\controller$'
        $deletes[4] | Should -Match 'secret kserve-webhook-server-cert k2s-kserve-webhook-next'
        ($deletes -match 'crds|namespace|cert-manager') | Should -BeNullOrEmpty
    }

    It 'leaves the controller running if model deletion fails' {
        Mock Invoke-Kubectl {
            return @{ Success = $true; Output = '{"items":[{"metadata":{"name":"qwen-small-cpu","namespace":"kserve-models-cpu","labels":{"app.kubernetes.io/managed-by":"k2s-kserve"}}}]}' }
        } -ParameterFilter { $Params[0] -eq 'get' -and $Params[1] -eq 'inferenceservices.serving.kserve.io' }
        $script:FailMatch = '^delete inferenceservice'
        { Uninstall-Kserve } | Should -Throw '*simulated failure*'
        Should -Invoke Invoke-Kubectl -Times 0 -ParameterFilter { $Params[0] -eq 'delete' -and $Params[-1] -like '*\controller' }
    }

    It 'cleans up temporary patch files on failure' {
        $script:PatchPath = $null
        Mock Invoke-Kubectl {
            $script:PatchPath = $Params[-1]
            Test-Path -LiteralPath $script:PatchPath | Should -BeTrue
            return @{ Success = $false; Output = 'patch failed' }
        }
        { Invoke-KservePatch -Kind configmap -Name test -Patch @{ data = @{ test = 'value' } } } | Should -Throw '*patch failed*'
        Test-Path -LiteralPath $script:PatchPath | Should -BeFalse
    }

    It 'retains system storage defaults when configuring a CA' {
        Mock Invoke-Kubectl {
            return @{ Success = $true; Output = '{"data":{"cabundle.crt":"test"}}' }
        } -ParameterFilter { $Params[0] -eq 'get' -and $Params -contains 'k2s-kserve-ca' }
        Mock Invoke-Kubectl {
            return @{ Success = $true; Output = '{"data":{"storageInitializer":"{\"image\":\"docker.io/kserve/storage-initializer:v0.21.0\",\"caBundleConfigMapName\":\"\",\"memoryLimit\":\"1Gi\",\"enableModelcar\":true}"}}' }
        } -ParameterFilter { $Params[0] -eq 'get' -and $Params -contains 'inferenceservice-config' }
        Mock Invoke-KservePatch { }
        Set-KserveDownloadConfiguration -Proxy none
        Should -Invoke Invoke-KservePatch -Times 1 -ParameterFilter {
            $Kind -eq 'configmap' -and
            ($Patch.data.storageInitializer | ConvertFrom-Json).memoryLimit -eq '1Gi' -and
            ($Patch.data.storageInitializer | ConvertFrom-Json).caBundleConfigMapName -eq 'k2s-kserve-ca'
        }
    }
}

Describe 'KServe download inputs' -Tag 'unit', 'ci', 'addon' {
    It 'resolves the host proxy without embedding site-specific addresses' {
        Resolve-KserveProxy -Proxy auto | Should -Be 'http://172.19.1.1:8181'
        Resolve-KserveProxy -Proxy none | Should -BeNullOrEmpty
        Resolve-KserveProxy -Proxy 'http://proxy.example:81' | Should -Be 'http://proxy.example:81'
    }

    It 'rejects credential-bearing proxies and invalid schemes' {
        { Resolve-KserveProxy -Proxy 'http://user:password@proxy.example:81' } | Should -Throw '*without embedded credentials*'
        { Resolve-KserveProxy -Proxy 'socks5://proxy.example:81' } | Should -Throw '*HTTP(S)*'
        { Resolve-KserveProxy -Proxy 'not-a-url' } | Should -Throw '*HTTP(S)*'
    }

    It 'rejects private keys and malformed certificate bundles' {
        $file = Join-Path $TestDrive 'bad.pem'
        Set-Content -LiteralPath $file -Value '-----BEGIN PRIVATE KEY-----'
        { Assert-KserveCaBundle -Path $file } | Should -Throw '*public certificates only*'
        Set-Content -LiteralPath $file -Value 'not a certificate'
        { Assert-KserveCaBundle -Path $file } | Should -Throw '*PEM-encoded*'
    }

    It 'accepts a valid public CA but rejects a leaf certificate' {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        try {
            foreach ($isCa in @($true, $false)) {
                $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    'CN=K2s test', $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                $request.CertificateExtensions.Add(
                    [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($isCa, $false, 0, $true))
                $certificate = $request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(1))
                try {
                    $file = Join-Path $TestDrive 'ca.pem'
                    $base64 = [Convert]::ToBase64String(
                        $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert),
                        [System.Base64FormattingOptions]::InsertLineBreaks)
                    Set-Content -LiteralPath $file -Value "-----BEGIN CERTIFICATE-----`n$base64`n-----END CERTIFICATE-----"
                    if ($isCa) {
                        { Assert-KserveCaBundle -Path $file } | Should -Not -Throw
                    }
                    else {
                        { Assert-KserveCaBundle -Path $file } | Should -Throw '*non-CA*'
                    }
                }

                finally { $certificate.Dispose() }
            }
        }
        finally { $rsa.Dispose() }
    }
}

Describe 'KServe status' -Tag 'unit', 'ci', 'addon' {
    BeforeAll {
        function Get-AddonConfig { param($Name) return @{ Model = 'none' } }
        function New-AddonStatusProperty {
            param($Name, $Value, $SuccessMessage, $FailureMessage)
            return @{ Name = $Name; Value = $Value; Okay = $Value; Message = $(if ($Value) { $SuccessMessage } else { $FailureMessage }) }
        }
        # Exercise the status body without requiring elevation or loading cluster modules.
        $body = (Get-Content -LiteralPath "$PSScriptRoot\Get-Status.ps1" -Raw) -replace '(?im)^#Requires.*$', ''
        $body = $body.Replace('. "$PSScriptRoot\Kserve.Certificates.ps1"', '')
        $script:StatusScript = [scriptblock]::Create($body)
    }

    BeforeEach {
        Mock Import-Module { }
        Mock Get-AddonConfig { return @{ Model = 'none' } }
        Mock Test-KserveWebhookCertificate { return $true }
        Mock Invoke-Kubectl {
            if ($Params[1] -eq 'secret') {
                return @{ Success = $true; Output = '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"k2s-kserve"}},"data":{}}' }
            }
            if ($Params[0] -eq 'get') {
                return @{ Success = $true; Output = '{"metadata":{"generation":2},"spec":{"replicas":1},"status":{"availableReplicas":1,"updatedReplicas":1,"observedGeneration":2}}' }
            }
            return @{ Success = $true; Output = 'condition met' }
        }
    }

    It 'reports a ready controller and webhook' {
        $result = & $script:StatusScript
        $result.Count | Should -Be 1
        $result[0].Okay | Should -BeTrue
    }

    It 'does not report a scaled-to-zero controller as running' {
        Mock Invoke-Kubectl {
            return @{ Success = $true; Output = '{"metadata":{"generation":2},"spec":{"replicas":0},"status":{"availableReplicas":0,"updatedReplicas":0,"observedGeneration":2}}' }
        } -ParameterFilter { $Params[0] -eq 'get' }
        $result = & $script:StatusScript
        $result[0].Okay | Should -BeFalse
    }

    It 'reports API access failures as unhealthy' {
        Mock Invoke-Kubectl { return @{ Success = $false; Output = 'connection refused' } } -ParameterFilter { $Params[0] -eq 'get' }
        $result = & $script:StatusScript
        $result[0].Okay | Should -BeFalse
    }

    It 'reports a missing TLS Secret as unhealthy' {
        Mock Invoke-Kubectl { return @{ Success = $false; Output = 'not found' } } -ParameterFilter { $Params[1] -eq 'secret' }
        $result = & $script:StatusScript
        $result[0].Okay | Should -BeFalse
        Should -Invoke Test-KserveWebhookCertificate -Times 0
    }

    It 'reports an interrupted certificate rotation as unhealthy' {
        Mock Invoke-Kubectl {
            return @{ Success = $true; Output = '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"k2s-kserve"},"annotations":{"k2s.kubernetes.io/tls-rotation-pending":"true"}}}' }
        } -ParameterFilter { $Params[1] -eq 'secret' }
        $result = & $script:StatusScript
        $result[0].Okay | Should -BeFalse
    }

    It 'reports the selected example separately from the controller' {
        Mock Get-AddonConfig { return @{ Model = 'qwen-cpu' } }
        Mock Invoke-Kubectl { return @{ Success = $false; Output = 'not ready' } } -ParameterFilter {
            $Params -contains 'inferenceservice/qwen-small-cpu'
        }
        $result = & $script:StatusScript
        $result.Count | Should -Be 2
        $result[0].Okay | Should -BeTrue
        $result[1].Name | Should -Be 'IsModelReady'
        $result[1].Okay | Should -BeFalse
    }
}

Describe 'KServe offline configuration assets' -Tag 'unit', 'ci', 'addon' {
    It 'round-trips every staged manifest through the existing config export and import steps' {
        Mock Write-Log { }
        $configStaging = Join-Path $TestDrive 'export-config'
        $implementationPath = Join-Path $TestDrive 'imported-kserve'
        New-Item -ItemType Directory -Path $configStaging, $implementationPath | Out-Null
        $configSubDir = Join-Path $PSScriptRoot 'config'
        foreach ($script in @('Export.ps1', 'Import.ps1')) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                "$PSScriptRoot\..\$script", [ref]$null, [ref]$null)
            $copyStep = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text -like 'if (Test-Path $configSubDir) {*'
            }, $true)
            $copyStep | Should -Not -BeNullOrEmpty
            & ([scriptblock]::Create($copyStep.Extent.Text))
            $configSubDir = Join-Path $configStaging 'config'
        }
        $source = Join-Path $PSScriptRoot 'config\manifests'
        $assets = @(Get-ChildItem -LiteralPath $source -Recurse -File)
        $assets.Count | Should -BeGreaterThan 0
        foreach ($asset in $assets) {
            $relative = $asset.FullName.Substring($PSScriptRoot.Length + 1)
            $restored = Join-Path $implementationPath $relative
            Test-Path -LiteralPath $restored | Should -BeTrue
            (Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $asset.FullName -Algorithm SHA256).Hash
        }
    }
}
