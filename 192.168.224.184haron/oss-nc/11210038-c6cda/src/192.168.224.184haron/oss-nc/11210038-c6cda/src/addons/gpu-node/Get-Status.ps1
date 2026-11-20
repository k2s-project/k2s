# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
Import-Module "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'nvidia-device-plugin', '-n', 'gpu-node', '--timeout=5s').Success

$isDevicePluginRunningProp = @{Name = 'IsDevicePluginRunning'; Value = $success; Okay = $success }
if ($isDevicePluginRunningProp.Value -eq $true) {
    $isDevicePluginRunningProp.Message = 'The gpu node is working'
}
else {
    $isDevicePluginRunningProp.Message = "The gpu node is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gpu-node' and 'k2s addons enable gpu-node'"
} 

# DCGM requires NVML which is unavailable via dxcore (GPU-PV). Since K2s only
# supports GPU-PV, DCGM-Exporter is no longer deployed by default. Check
# whether it exists (e.g. from an older enable) and report accordingly.
$dcgmExists = (Invoke-Kubectl -Params 'get', 'daemonset', 'dcgm-exporter', '-n', 'gpu-node', '--no-headers', '--ignore-not-found').Output
$isDCGMExporterRunningProp = @{Name = 'IsDCGMExporterRunning'; Value = $false; Okay = $true }
if ([string]::IsNullOrWhiteSpace($dcgmExists)) {
    $isDCGMExporterRunningProp.Message = 'DCGM-Exporter is not deployed (NVML is unavailable via the dxcore/D3D12 GPU-PV path). GPU workloads are not affected.'
}
else {
    $success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'dcgm-exporter', '-n', 'gpu-node', '--timeout=5s').Success
    $isDCGMExporterRunningProp.Value = $success
    if ($success) {
        $isDCGMExporterRunningProp.Message = 'The DCGM exporter is working'
    }
    else {
        $isDCGMExporterRunningProp.Message = 'The DCGM exporter is deployed but not running. This is expected as NVML cannot access the GPU through the dxcore driver path (WSL2 and Hyper-V GPU-PV). GPU workloads are not affected. Consider disabling and re-enabling the addon to remove the unused DaemonSet.'
    }
} 

$controlPlaneNodeName = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'node-role.kubernetes.io/control-plane', '-o', 'jsonpath={.items[0].metadata.name}').Output
$allGpuNodesRaw = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'gpu=true', '-o', 'jsonpath={.items[*].metadata.name}').Output
$allGpuNodes = if (![string]::IsNullOrWhiteSpace($allGpuNodesRaw)) { $allGpuNodesRaw -split '\s+' } else { @() }

$cpLabeledForGpu = $allGpuNodes -contains $controlPlaneNodeName
$labelsOkay = $allGpuNodes.Count -gt 0
$nodeLabelsMessage = if (!$labelsOkay) {
    'No nodes are labeled with gpu=true. Re-enable the addon to apply GPU labels.'
} elseif ($cpLabeledForGpu) {
    "GPU labels present on control plane '$controlPlaneNodeName' and/or worker nodes"
} else {
    'GPU labels are present on worker nodes only (control plane intentionally unlabeled)'
}
$nodeGpuLabelsProp = @{Name = 'NodeGpuLabels'; Value = $labelsOkay; Okay = $labelsOkay; Message = $nodeLabelsMessage}

# Get allocatable GPU slots across all GPU-labeled nodes
$totalGpuAllocatable = 0
foreach ($gpuNode in $allGpuNodes) {
    $gpuAllocatableRaw = (Invoke-Kubectl -Params 'get', 'node', $gpuNode, '-o', "jsonpath={.status.allocatable['nvidia\.com/gpu']}").Output
    if (![string]::IsNullOrWhiteSpace($gpuAllocatableRaw) -and $gpuAllocatableRaw -match '^\d+$') {
        $totalGpuAllocatable += [int]$gpuAllocatableRaw
    }
}
$slotLabel = if ($totalGpuAllocatable -eq 1) { 'slot' } else { 'slots' }
$gpuAllocatableProp = @{Name = 'GpuAllocatable'; Value = $totalGpuAllocatable -gt 0; Okay = $totalGpuAllocatable -gt 0 }
if ($totalGpuAllocatable -gt 0) {
    $gpuAllocatableProp.Message = "$totalGpuAllocatable GPU $slotLabel available across labeled GPU nodes"
}
else {
    $gpuAllocatableProp.Message = 'No GPU slots available — device plugin may not be ready yet'
}

# Get GPU slots in use across all GPU-labeled nodes
$totalGpuInUse = 0
foreach ($gpuNode in $allGpuNodes) {
    $gpuInUseRaw = (Invoke-Kubectl -Params 'get', 'pods', '--all-namespaces', '--field-selector', "status.phase=Running,spec.nodeName=$gpuNode", '-o', "jsonpath={range .items[*]}{range .spec.containers[*]}{.resources.limits['nvidia\.com/gpu']}{' '}{end}{end}").Output
    $gpuInUseRaw -split '\s+' | ForEach-Object {
        if ($_ -match '^\d+$') { $totalGpuInUse += [int]$_ }
    }
}
$inUseLabel = if ($totalGpuInUse -eq 1) { 'slot' } else { 'slots' }
$gpuInUseProp = @{Name = 'GpuInUse'; Value = $true; Okay = $true }
$gpuInUseProp.Message = "$totalGpuInUse of $totalGpuAllocatable GPU $inUseLabel in use"

# Check for external GPU-capable worker nodes
$externalGpuNodes = $allGpuNodes | Where-Object { $_ -ne $controlPlaneNodeName }
$externalGpuWorkersProp = @{Name = 'ExternalGpuWorkers'; Value = $true; Okay = $true }
if ($externalGpuNodes.Count -gt 0) {
    $nodeListStr = $externalGpuNodes -join ', '
    $externalGpuWorkersProp.Message = "$($externalGpuNodes.Count) external GPU worker(s): $nodeListStr"
} else {
    $externalGpuWorkersProp.Message = 'No external GPU workers configured (workers with NVIDIA GPUs are automatically configured when added)'
}

# Build per-node GPU slot details for external workers
$externalNodeProps = @()
foreach ($extNode in $externalGpuNodes) {
    # Get allocatable GPU slots for this node
    $extGpuAllocatable = 0
    $extGpuAllocatableRaw = (Invoke-Kubectl -Params 'get', 'node', $extNode, '-o', "jsonpath={.status.allocatable['nvidia\.com/gpu']}").Output
    if (![string]::IsNullOrWhiteSpace($extGpuAllocatableRaw) -and $extGpuAllocatableRaw -match '^\d+$') {
        $extGpuAllocatable = [int]$extGpuAllocatableRaw
    }

    # Get GPU slots in use on this specific node (Running pods scheduled to this node)
    $extGpuInUse = 0
    $extGpuInUseRaw = (Invoke-Kubectl -Params 'get', 'pods', '--all-namespaces', '--field-selector', "status.phase=Running,spec.nodeName=$extNode", '-o', "jsonpath={range .items[*]}{range .spec.containers[*]}{.resources.limits['nvidia\.com/gpu']}{' '}{end}{end}").Output
    $extGpuInUseRaw -split '\s+' | ForEach-Object {
        if ($_ -match '^\d+$') { $extGpuInUse += [int]$_ }
    }

    $extSlotLabel = if ($extGpuAllocatable -eq 1) { 'slot' } else { 'slots' }
    $extNodeProp = @{Name = "ExternalNode_$extNode"; Value = $true; Okay = $extGpuAllocatable -gt 0 }
    if ($extGpuAllocatable -gt 0) {
        $extNodeProp.Message = "  -> ${extNode}: $extGpuInUse of $extGpuAllocatable GPU $extSlotLabel in use"
    } else {
        $extNodeProp.Message = "  -> ${extNode}: No GPU slots registered (device plugin may not be ready)"
    }
    $externalNodeProps += $extNodeProp
}

$resultProps = @($isDevicePluginRunningProp, $isDCGMExporterRunningProp, $nodeGpuLabelsProp, $gpuAllocatableProp, $gpuInUseProp, $externalGpuWorkersProp) + $externalNodeProps
return $resultProps
