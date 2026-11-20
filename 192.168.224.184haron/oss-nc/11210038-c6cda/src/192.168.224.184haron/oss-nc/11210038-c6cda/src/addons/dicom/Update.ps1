# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

param (
    [switch]$SkipLinkerdRestart
)

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"
Import-Module $addonsModule, $dicomModule

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

Update-IngressForAddon -Addon ([pscustomobject] @{Name = $addonName })

$bStorageAddonEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage' })
$dicomAttributes = Get-AddonConfig -Name $addonName
Write-Log "Storage usage: $($dicomAttributes.StorageUsage) and storage addon enabled: $bStorageAddonEnabled" 
if ($dicomAttributes.StorageUsage -ne 'storage' -and $bStorageAddonEnabled) {
	Write-Log ' ' -Console
	Write-Log '!!!! DICOM addon is enabled. Please disable and enable DICOM addon again for a change in storage !!!!' -Console
	Write-Log ' ' -Console
}

$EnhancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnhancedSecurityEnabled) {
        Write-Log "Updating dicom addon to be part of service mesh" -Console
        
        # Always restart pods when enhanced security is enabled, regardless of SkipLinkerdRestart
        # Use the new function to handle linkerd annotations and pod restarts reliably
        $linkerdHandlingSuccess = Restart-PodsWithLinkerdAnnotation -namespace 'dicom' -timeoutSeconds 300
        if (!$linkerdHandlingSuccess) {
            Write-Log "Warning: Failed to apply Linkerd annotations or pods did not become ready in time!" -Error
            # Continue execution but log the warning
        } else {
            Write-Log "Successfully updated DICOM pods with Linkerd service mesh annotations" -Console
        }

        # Check if annotations were applied using safer jsonpath approach
        $maxAttempts = 30
        $attempt = 0
        $hasAnnotations = $false
        
        Write-Log "Verifying Linkerd annotations were applied correctly..." -Console
        
        do {
            $attempt++
            
            # Check dicom deployment
            $dicomInject = $null
            $dicomDeploymentResult = Invoke-Kubectl -Params 'get', 'deployment', 'dicom', '-n', 'dicom', 
                '--ignore-not-found', '-o', 'jsonpath={.spec.template.metadata.annotations.linkerd\.io/inject}'
            
            if ($dicomDeploymentResult.Success) {
                $dicomInject = $dicomDeploymentResult.Output
            }
            
            # Check postgres deployment
            $postgresInject = $null
            $postgresDeploymentResult = Invoke-Kubectl -Params 'get', 'deployment', 'postgres', '-n', 'dicom', 
                '--ignore-not-found', '-o', 'jsonpath={.spec.template.metadata.annotations.linkerd\.io/inject}'
            
            if ($postgresDeploymentResult.Success) {
                $postgresInject = $postgresDeploymentResult.Output
            }
            
            # Check if both have the correct annotation
            $hasAnnotations = ($dicomInject -eq 'enabled' -and $postgresInject -eq 'enabled')
            
            if (-not $hasAnnotations) {
                Write-Log "Waiting for annotations to be applied (attempt $attempt of $maxAttempts)..." -Console
                Start-Sleep -Seconds 2
            }
        } while (-not $hasAnnotations -and $attempt -lt $maxAttempts)

        if (-not $hasAnnotations) {
            Write-Log "Warning: Timeout waiting for Linkerd patches to be fully applied" -Error
            # Don't throw an exception, continue with warning
        }
    } else {
        Write-Log "Updating dicom addon to not be part of service mesh" -Console
        
        # Check if deployments exist
        $dicomExists = (Invoke-Kubectl -Params 'get', 'deployment', 'dicom', '-n', 'dicom', '--ignore-not-found').Success
        $postgresExists = (Invoke-Kubectl -Params 'get', 'deployment', 'postgres', '-n', 'dicom', '--ignore-not-found').Success
        
        if ($dicomExists) {
            $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/opaque-ports\":null,\"linkerd.io/inject\":null}}}}}'
            Write-Log "Removing Linkerd annotations from dicom deployment" -Console
            (Invoke-Kubectl -Params 'patch', 'deployment', 'dicom', '-n', 'dicom', '-p', $annotations).Output | Write-Log
        }
        
        if ($postgresExists) {
            $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/opaque-ports\":null,\"linkerd.io/inject\":null}}}}}'
            Write-Log "Removing Linkerd annotations from postgres deployment" -Console
            (Invoke-Kubectl -Params 'patch', 'deployment', 'postgres', '-n', 'dicom', '-p', $annotations).Output | Write-Log
        }

        if ($dicomExists -or $postgresExists) {
            # Check annotations were removed using safer jsonpath approach
            $maxAttempts = 30
            $attempt = 0
            $hasNoAnnotations = $false
            
            do {
                $attempt++
                $dicomHasAnnotation = $false
                $postgresHasAnnotation = $false
                
                if ($dicomExists) {
                    $dicomInject = (Invoke-Kubectl -Params 'get', 'deployment', 'dicom', '-n', 'dicom', 
                        '-o', 'jsonpath={.spec.template.metadata.annotations.linkerd\.io/inject}', '--ignore-not-found').Output
                    $dicomHasAnnotation = -not [string]::IsNullOrEmpty($dicomInject)
                }
                
                if ($postgresExists) {
                    $postgresInject = (Invoke-Kubectl -Params 'get', 'deployment', 'postgres', '-n', 'dicom', 
                        '-o', 'jsonpath={.spec.template.metadata.annotations.linkerd\.io/inject}', '--ignore-not-found').Output
                    $postgresHasAnnotation = -not [string]::IsNullOrEmpty($postgresInject)
                }
                
                $hasNoAnnotations = (-not $dicomHasAnnotation -and -not $postgresHasAnnotation)
                
                if (-not $hasNoAnnotations) {
                    Write-Log "Waiting for annotations to be removed (attempt $attempt of $maxAttempts)..." -Console
                    Start-Sleep -Seconds 2
                }
            } while (-not $hasNoAnnotations -and $attempt -lt $maxAttempts)
            
            if (-not $hasNoAnnotations) {
                Write-Log "Warning: Timeout waiting for Linkerd annotations to be removed" -Error
                # Don't throw an exception, continue with warning
            }
            
            # Restart deployments to apply changes if not skipped
            if (-not $SkipLinkerdRestart) {
                Write-Log "Restarting deployments to apply annotation changes..." -Console
                (Invoke-Kubectl -Params 'rollout', 'restart', 'deployment', '-n', 'dicom').Output | Write-Log
            } else {
                Write-Log "Skipping deployment restart (SkipLinkerdRestart is set)" -Console
            }
        } else {
            Write-Log "No deployments found in dicom namespace to update" -Console
        }
    }
# End of the Linkerd check

# Verify deployments are running properly
Write-Log "Verifying deployments are running properly..." -Console
$rolloutStatus = Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'dicom', '--timeout', '60s'
$rolloutStatus.Output | Write-Log

if (!$rolloutStatus.Success) {
	Write-Log "Error: DICOM deployments are not running properly" -Error
	
	# Get more information about the deployments
	Write-Log "Checking deployment status..." -Console
	$deploymentStatus = Invoke-Kubectl -Params 'get', 'deployments', '-n', 'dicom'
	if ($deploymentStatus.Success) {
		$deploymentStatus.Output | Write-Log
	}
	
	# Check for any problematic pods
	Write-Log "Checking pod status..." -Console
	$podStatus = Invoke-Kubectl -Params 'get', 'pods', '-n', 'dicom'
	if ($podStatus.Success) {
		$podStatus.Output | Write-Log
	}
	
	# This might be a critical error in an update, but we don't exit to avoid breaking the cluster completely
	Write-Log "Warning: DICOM update may not have completed successfully. Please check the logs for more details." -Error
}
