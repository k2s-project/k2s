# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\k8s-api\k8s-api.module.psm1",
    "$PSScriptRoot\..\addons.module.psm1"
. "$PSScriptRoot\Kserve.Certificates.ps1"

$deployment = Invoke-Kubectl -Params 'get', 'deployment/kserve-controller-manager', '-n', 'kserve', '-o', 'json'
$controller = $false
if ($deployment.Success) {
    $state = ($deployment.Output | Out-String) | ConvertFrom-Json -ErrorAction Stop
    $controller = $state.spec.replicas -gt 0 -and $state.status.availableReplicas -ge $state.spec.replicas -and
        $state.status.updatedReplicas -ge $state.spec.replicas -and
        $state.status.observedGeneration -ge $state.metadata.generation
}
$tlsSecret = Invoke-Kubectl -Params 'get', 'secret', 'kserve-webhook-server-cert', '-n', 'kserve', '-o', 'json'
$certificate = $false
if ($tlsSecret.Success) {
    $secret = ($tlsSecret.Output | Out-String) | ConvertFrom-Json -ErrorAction Stop
    $certificate = $secret.metadata.labels.'app.kubernetes.io/managed-by' -eq 'k2s-kserve' -and
        $secret.metadata.annotations.'k2s.kubernetes.io/tls-rotation-pending' -ne 'true' -and
        (Test-KserveWebhookCertificate -Secret $secret)
}
$properties = @(
    (New-AddonStatusProperty -Name 'IsKserveRunning' -Value ($controller -and $certificate) `
        -SuccessMessage 'KServe controller and webhook certificate are ready.' `
        -FailureMessage 'KServe is not ready. Inspect the controller logs and webhook TLS Secret in namespace kserve. Addon-owned certificate checks and renewal run when K2s starts.')
)
$addon = Get-AddonConfig -Name 'kserve'
if ($addon.Model -and $addon.Model -ne 'none') {
    $namespace = 'kserve-models-cpu'
    $name = 'qwen-small-cpu'
    if ($addon.Model -eq 'qwen-gpu') { $namespace = 'kserve-models'; $name = 'qwen-small' }
    $ready = (Invoke-Kubectl -Params 'wait', '-n', $namespace, '--for=condition=Ready', "inferenceservice/$name", '--timeout=5s').Success
    $properties += New-AddonStatusProperty -Name 'IsModelReady' -Value $ready `
        -SuccessMessage "Example model $name is ready." `
        -FailureMessage "Example model $name is not ready. Inspect its pod events and storage-initializer logs in namespace $namespace."
}
return , $properties
