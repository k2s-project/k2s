# SPDX-FileCopyrightText: © 2023 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

$logModule = "$PSScriptRoot/../../lib/modules/windows/infra/k2s.infra.module/log/log.module.psm1"
$k8sApiModule = "$PSScriptRoot/../../lib/modules/windows/cluster/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Import-Module $logModule, $k8sApiModule

<#
.DESCRIPTION
Gets the location of manifests to deploy dicom server.
#>
function Get-DicomConfig {
    return "$PSScriptRoot\manifests\dicom"
}


<#
.DESCRIPTION
Gets the location of manifests for the default pv.
#>
function Get-PVConfigDefault {
    return "$PSScriptRoot\manifests\pv-default"
}


<#
.DESCRIPTION
Gets the location of manifests for the pv for the storage addon.
#>
function Get-PVConfigStorage {
    return "$PSScriptRoot\manifests\pv-storage"
}

<#
.DESCRIPTION
Gets the location of manifests for nginx-gw ingress.
#>
function Get-IngressNginxGwConfig {
    return "$PSScriptRoot\manifests\ingress-nginx-gw"
}

<#
.DESCRIPTION
Gets the location of manifests for nginx-gw ingress with Linkerd authorization.
#>
function Get-IngressNginxGwSecureConfig {
    return "$PSScriptRoot\manifests\ingress-nginx-gw-secure"
}

<#
.DESCRIPTION
Writes the usage notes for dicom server user interface for the user.
#>
function Write-UsageForUser {
    @'
                                        USAGE NOTES
 To open dicom server UI, please use one of the options:
 
 Option 1: Access via ingress
 Please install either ingress nginx addon or ingress traefik addon from k2s.
 or you can install them on your own.
 Enable ingress controller via k2s cli
 eg. k2s addons enable ingress nginx
 Once the ingress controller is running in the cluster, run the command to enable dicom
 k2s addons enable dicom
 The orthanc dicom web ui will be accessible on the following URL: https://k2s.cluster.local/dicom/ui/app/
                                        
 Option 2: Port-forwading
 Use port-forwarding to the orthanc dicom web ui using the command below:
 kubectl -n dicom port-forward svc/dicom 8042:8042
 In this case, the orthanc dicom web will be accessible on the following URL: http://localhost:8042/ui/app/
                                        
 DICOM Web APIs are avalaible on the following URL: http(s)://k2s.cluster.local/dicom/dicom-web/
 Example: curl -sS --insecure http://k2s.cluster.local/dicom/dicomweb/studies will return alls studies in the dicom server.
                                        
 By activating this dicom addon you have downloaded at runtime some Orthanc components. 
 Even it is open source, please consider the following license terms for Orthanc components: https://orthanc.uclouvain.be/book/faq/licensing.html 
                                        
'@ -split "`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Waits for the dicom pods to be available.
#>
function Wait-ForDicomAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=dicom' -Namespace 'dicom' -TimeoutSeconds 120)
}

function Wait-ForPodsReady {
    param (
        [string]$namespace,
        [int]$timeoutSeconds = 300,
        [int]$intervalSeconds = 5
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutMs = $timeoutSeconds * 1000
    $ready = $false

    Write-Log "Waiting for all pods in namespace $namespace to be ready..." -Console

    while (-not $ready -and $timer.ElapsedMilliseconds -lt $timeoutMs) {
        $allPodsReady = $true
        
        # Use kubectl directly to check pod status instead of parsing JSON
        $podList = (Invoke-Kubectl -Params 'get', 'pods', '-n', $namespace).Output
        
        if (-not $podList -or $podList -match "No resources found") {
            Write-Log "No pods found in namespace $namespace" -Console
            Start-Sleep -Seconds $intervalSeconds
            continue
        }
        
        # Use kubectl to get each pod's status
        $podNames = @()
        $podLines = $podList -split "`n" | Select-Object -Skip 1
        
        foreach ($line in $podLines) {
            if ($line.Trim()) {
                $parts = $line -split '\s+', 3
                if ($parts.Count -ge 3) {
                    $podName = $parts[0]
                    $podNames += $podName
                }
            }
        }
        
        foreach ($podName in $podNames) {
            # Check if pod is ready using kubectl get pods <podname> -o jsonpath
            $readyResult = Invoke-Kubectl -Params 'get', 'pods', $podName, '-n', $namespace, '-o', 
                      'jsonpath={.status.containerStatuses[*].ready}'
            
            if (-not $readyResult.Success -or $readyResult.Output -match "false" -or $readyResult.Output -eq "") {
                $phaseResult = Invoke-Kubectl -Params 'get', 'pods', $podName, '-n', $namespace, '-o', 
                          'jsonpath={.status.phase}'
                $phase = if ($phaseResult.Success) { $phaseResult.Output } else { "Unknown" }
                          
                Write-Log "Pod $podName is not ready (phase: $phase)" -Console
                $allPodsReady = $false
            } else {
                Write-Log "Pod $podName is ready" -Console
            }
        }

        if ($allPodsReady -and $podNames.Count -gt 0) {
            $ready = $true
        } else {
            Write-Log "Waiting for pods to be ready... (elapsed: $([math]::Round($timer.Elapsed.TotalSeconds))s)" -Console
            Start-Sleep -Seconds $intervalSeconds
        }
    }

    $timer.Stop()
    
    # Final check - if there are no pods, we consider it ready
    $finalPodList = (Invoke-Kubectl -Params 'get', 'pods', '-n', $namespace).Output
    if ($finalPodList -match "No resources found") {
        Write-Log "No pods found in namespace $namespace - considering ready" -Console
        return $true
    }
    
    if (-not $ready) {
        Write-Log "Timed out waiting for pods in namespace $namespace to be ready after $timeoutSeconds seconds" -Error
        return $false
    }
    
    Write-Log "All pods in namespace $namespace are ready!" -Console
    return $true
}

function Restart-PodsWithLinkerdAnnotation {
    param (
        [string]$namespace,
        [int]$timeoutSeconds = 300
    )

    Write-Log "Checking if Linkerd service mesh is enabled..." -Console
    $linkerdEnabled = $false
    
    try {
        $linkerdNamespace = (Invoke-Kubectl -Params 'get', 'namespace', 'linkerd', '--ignore-not-found').Output
        if ($linkerdNamespace -match 'linkerd') {
            $linkerdEnabled = $true
        }
    } catch {
        Write-Log "Linkerd is not installed, skipping annotation handling" -Console
        return $true
    }

    if (-not $linkerdEnabled) {
        Write-Log "Linkerd is not installed, skipping annotation handling" -Console
        return $true
    }

    Write-Log "Linkerd is installed. Adding service mesh annotations to deployments in namespace $namespace" -Console

    # Verify deployments exist before trying to patch them
    $postgresExists = (Invoke-Kubectl -Params 'get', 'deployment', 'postgres', '-n', $namespace, '--ignore-not-found').Success
    $dicomExists = (Invoke-Kubectl -Params 'get', 'deployment', 'dicom', '-n', $namespace, '--ignore-not-found').Success
    
    # Add annotations to PostgreSQL deployment
    if ($postgresExists) {
        $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"5432\"}}}}}'
        Write-Log "Patching postgres deployment with linkerd annotations" -Console
        (Invoke-Kubectl -Params 'patch', 'deployment', 'postgres', '-n', $namespace, '-p', $annotations).Output | Write-Log
    } else {
        Write-Log "PostgreSQL deployment not found in namespace $namespace" -Console
    }

    # Add annotations to dicom/orthanc deployment
    if ($dicomExists) {
        $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"8042,4242\"}}}}}'
        Write-Log "Patching dicom deployment with linkerd annotations" -Console
        (Invoke-Kubectl -Params 'patch', 'deployment', 'dicom', '-n', $namespace, '-p', $annotations).Output | Write-Log
    } else {
        Write-Log "DICOM deployment not found in namespace $namespace" -Console
    }

    if ($postgresExists -or $dicomExists) {
        # Restart rollout to apply annotations and ensure pods are recreated
        Write-Log "Restarting rollout of deployments to apply linkerd annotations..." -Console
        (Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', '-n', $namespace).Output | Write-Log

        # Wait for pods to be ready after annotations are applied
        return (Wait-ForPodsReady -namespace $namespace -timeoutSeconds $timeoutSeconds)
    } else {
        Write-Log "No deployments found to apply Linkerd annotations to" -Console
        return $true
    }
}
