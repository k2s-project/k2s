# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Renews the kubernetes certificates
.DESCRIPTION
Renews the kubernetes certificates. The renewal is performed only if the certificate is about to expire.
However, the renewal can be enforced explicitly by the user.
.PARAMETER Force
If set to $true, then the certificate renewal is performed irrespective of expiration.
.EXAMPLE
PS> .\renew.ps1 -Force
#>

param (
    [parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the certificate renewal is performed irrespective of expiration.')]
    [switch] $Force,

    [Parameter(Mandatory = $false, HelpMessage = 'If set to $true, then the logs are written into the console with more verbosity.')]
    [switch] $ShowLogs,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send the result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to true.')]
    [string] $MessageType
)

$infraModule =   "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$global:isControlPlaneStartedByMe = $false
$global:isControlPlaneSwitchCreatedByMe = $false
$global:isWsl = Get-ConfigWslFlag
$global:controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
$global:controlPlaneVMHostNameLower = $global:controlPlaneVMHostName.ToLower()
$global:controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName

function Start-ControlPlaneIfNotRunning {
    if ($global:isWsl) {
        if ((Get-IsWslRunning -Name $controlPlaneNodeName) -ne $true) {
            Write-Log "Starting control plane WSL instance '$global:controlPlaneVMHostName'..."
            Start-WSL
            Wait-ForSSHConnectionToLinuxVMViaSshKey
            $global:isControlPlaneStartedByMe = $true
        }
    } else {
        if ((Get-IsVmRunning -Name $global:controlPlaneVMHostName) -ne $true) {
            Write-Log "Starting control plane VM '$global:controlPlaneVMHostName'..."
            $switchExists = Get-VMSwitch -Name "vEthernet($global:controlPlaneSwitchName)" -ErrorAction SilentlyContinue
            if (-not $switchExists) {
                Write-Log "vEthernet switch '$global:controlPlaneSwitchName' does not exist. Creating it..."
                New-KubeSwitch -Name $global:controlPlaneSwitchName
                Connect-KubeSwitch
                Write-Log "vEthernet switch '$global:controlPlaneSwitchName' created successfully."
                $global:isControlPlaneSwitchCreatedByMe = $true
            } else {
                Write-Log "vEthernet switch '$global:controlPlaneSwitchName' already exists."
            }
            Start-VM -Name $global:controlPlaneVMHostName
            Wait-ForSSHConnectionToLinuxVMViaSshKey
            $global:isControlPlaneStartedByMe = $true

        } else {
            Write-Log "Control plane VM '$global:controlPlaneVMHostName' is already running."
        }
    }
}

function Stop-ControlPlaneIfStartedByThisScript {
    if ($global:isWsl -and $global:isControlPlaneStartedByMe) {
        Write-Log "Stopping control Plane WSL instance '$global:controlPlaneVMHostName' as it was started by the command ..."
        wsl --shutdown
    }

    if($global:isControlPlaneStartedByMe) {
        Write-Log "Stopping control Plane VM instance '$global:controlPlaneVMHostName' as it was started by the command ..."
        Stop-VM -Name $global:controlPlaneVMHostName
    } else {
        Write-Log "Control Plane VM instance '$global:controlPlaneVMHostName' was not started by the command. Not stopping it."
    }

    if($global:isControlPlaneSwitchCreatedByMe) {
        Write-Log "Removing vEthernet switch '$global:controlPlaneSwitchName' as it was created by the command ..."
        Remove-KubeSwitch
    } else {
        Write-Log "vEthernet switch '$global:controlPlaneSwitchName' was not created by the command. Not removing it."
    }
}

function Assert-CertificateExpiry() {
    Write-Log "Checking certificate expiration on the control plane..."
    $command = "sudo kubeadm certificates check-expiration -o json"
    $output = (Invoke-CmdOnControlPlaneViaSSHKey $command).Output

    $certificatesInfo = $output | ConvertFrom-Json
     Write-Log "Certificate Expiration Info"
    $certificatesInfo.certificates | ForEach-Object {
        Write-Log "Name: $($_.name), Expiration Date: $($_.expirationDate), Residual Time: $($_.residualTime), Missing: $($_.missing)"
    }

    $expiredCertificates = $certificatesInfo.certificates | Where-Object {
        $_.residualTime -le 0 -or $_.missing -eq $true
    }

    if ($expiredCertificates) {
        Write-Log "[Warning] The following certificates have expired or are missing:" -Console
        $expiredCertificates | ForEach-Object {
            Write-Log "Certificate Name: $($_.name), Expiration Date: $($_.expirationDate), Missing: $($_.missing)" -Console
        }
        return $false
    }
    Write-Log "All certificates are valid and not expired." -Console
    return $true
}

function Assert-KubeApiServerHealth {
    param (
        [int] $MaxWaitSeconds = 300,
        [int] $RetryIntervalSeconds = 10
    )

    Write-Log "Checking if kube-apiserver is ready and available..."

    $elapsedTime = 0
    while ($elapsedTime -lt $MaxWaitSeconds) {
        $command = "curl -k -s -o /dev/null -w '%{http_code}' https://localhost:6443/readyz"

        $responseCode = (Invoke-CmdOnControlPlaneViaSSHKey $command).Output

        if ($responseCode -eq "200") {
            Write-Log "kube-apiserver is ready and available." -Console
            return $true
        }

        Write-Log "kube-apiserver is not ready yet. Retrying in $RetryIntervalSeconds seconds..."
        Start-Sleep -Seconds $RetryIntervalSeconds
        $elapsedTime += $RetryIntervalSeconds
    }

    Write-Log "[ERROR] kube-apiserver did not become ready within $MaxWaitSeconds seconds." -Console
    return $false
}

function Send-ErrorToCli {
    Param(
        [string]$ErrorMessage
    )
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'certificate-renew-failure' -Message $ErrorMessage
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $ErrorMessage -Error
}

function Restart-ControlPlaneNode {
    Write-Log "Restarting Control Plane Node" -Console
    if ($global:isWsl) {
        wsl --shutdown
        Start-WSL
    } else {
        Stop-VM -Name $global:controlPlaneVMHostName -Force -WarningAction SilentlyContinue
        Start-VM -Name $global:controlPlaneVMHostName
    }
    Wait-ForSSHConnectionToLinuxVMViaSshKey
}

function Restart-ControlPlaneServicesSoftly {
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo touch /etc/kubernetes/manifests/etcd.yaml').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo touch /etc/kubernetes/manifests/kube-controller-manager.yaml').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo touch /etc/kubernetes/manifests/kubec-scheduler.yaml').Output | Write-Log
    Write-Log 'Control plane pods restarted...' -Console
}

function Invoke-CertificateRenewalForControlPlanePods {
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo kubeadm certs renew all').Output | Write-Log
    Write-Log 'Certificates of control plane pods renewed...' -Console
    Restart-ControlPlaneNode
}

function Invoke-CertificateRenewalForKubeletInControlPlane {
    $backupDir = "/etc/kubernetes/backup"
    $createBackupDirCmd = "sudo mkdir -p $backupDir"

    (Invoke-CmdOnControlPlaneViaSSHKey $createBackupDirCmd).Output | Write-Log

    $deleteExistingKubeletConfBackupCmd = "if [ -f $backupDir/kubelet.conf.bak ]; then sudo rm -f $backupDir/kubelet.conf.bak; fi"
    (Invoke-CmdOnControlPlaneViaSSHKey $deleteExistingKubeletConfBackupCmd).Output | Write-Log

    $backupKubeletConfCmd = "sudo cp /etc/kubernetes/kubelet.conf $backupDir/kubelet.conf.bak"
    (Invoke-CmdOnControlPlaneViaSSHKey $backupKubeletConfCmd).Output | Write-Log

    $deleteKubeletConfCmd = "sudo rm -f /etc/kubernetes/kubelet.conf"
    (Invoke-CmdOnControlPlaneViaSSHKey $deleteKubeletConfCmd).Output | Write-Log

    $deleteExistingKubeletClientBackupCmd = "if ls $backupDir/kubelet-client* 1> /dev/null 2>&1; then sudo rm -f $backupDir/kubelet-client*; fi"
    (Invoke-CmdOnControlPlaneViaSSHKey $deleteExistingKubeletClientBackupCmd).Output | Write-Log

    $backupKubeletClientCmd = "sudo cp /var/lib/kubelet/pki/kubelet-client* $backupDir/"
    (Invoke-CmdOnControlPlaneViaSSHKey $backupKubeletClientCmd).Output | Write-Log

    $deleteKubeletClientCmd = "sudo rm -f /var/lib/kubelet/pki/kubelet-client*"
    (Invoke-CmdOnControlPlaneViaSSHKey $deleteKubeletClientCmd).Output | Write-Log

    $generateKubeletConfCmd = "sudo kubeadm kubeconfig user --org system:nodes --client-name system:node:$global:controlPlaneVMHostNameLower > /tmp/kubelet.conf"
    (Invoke-CmdOnControlPlaneViaSSHKey $generateKubeletConfCmd).Output | Write-Log

    $copyKubeletConfCmd = "sudo cp /tmp/kubelet.conf /etc/kubernetes/kubelet.conf"
    (Invoke-CmdOnControlPlaneViaSSHKey $copyKubeletConfCmd).Output | Write-Log

    $setPermissionsCmd = "sudo chmod 600 /etc/kubernetes/kubelet.conf"
    (Invoke-CmdOnControlPlaneViaSSHKey $setPermissionsCmd).Output | Write-Log

    Write-Log "Kubelet certificates renewed and kubelet configuration updated successfully." -Console
}

function Invoke-CertificateRenewalInControlPlane {
    Invoke-CertificateRenewalForKubeletInControlPlane
    Invoke-CertificateRenewalForControlPlanePods
    $healthStatus = Assert-KubeApiServerHealth
    if ($healthStatus -eq $false) {
        $errMsg = "kube-apiserver is not healthy after certificate renewal in time"
        Send-ErrorToCli -ErrorMessage $errMsg
        return $false
    }
    return $true
}

function Invoke-KubeConfigRefreshOnHost {
    Write-Log "Refreshing kubeconfig on host..." -Console
    Copy-KubeConfigFromControlPlaneNode
    Add-K8sContext
}

function Invoke-WebhookCertificateRenewal {
    Write-Log "Renewing clusterip-webhook certificate..." -Console

    # Trigger a rollout restart so the init container generates a fresh certificate
    $restartCmd = 'kubectl rollout restart deployment/clusterip-webhook -n k2s-webhook'
    $restartResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $restartCmd -Timeout 30 -IgnoreErrors:$true
    Write-Log "Webhook rollout restart: $($restartResult.Output)"
    if (-not $restartResult.Success) {
        Write-Log "[Warning] Failed to restart webhook deployment" -Console
        return $false
    }

    # Wait for the rollout to complete
    Write-Log "Waiting for webhook deployment to become ready..."
    $statusCmd = 'kubectl rollout status deployment/clusterip-webhook -n k2s-webhook --timeout=120s'
    $statusResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $statusCmd -Timeout 150 -IgnoreErrors:$true
    Write-Log "Webhook rollout status: $($statusResult.Output)"
    if (-not $statusResult.Success) {
        Write-Log "[Warning] Webhook deployment did not become ready after restart" -Console
        return $false
    }

    # Validate that caBundle has been set by the init container
    $caBundleCmd = "kubectl get mutatingwebhookconfiguration k2s-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}'"
    $caBundleResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute $caBundleCmd -Timeout 30 -IgnoreErrors:$true
    if (-not $caBundleResult.Success) {
        Write-Log "[Warning] Failed to query webhook caBundle" -Console
        return $false
    }
    $caBundle = ($caBundleResult.Output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($caBundle)) {
        Write-Log "[Warning] Webhook caBundle is empty after renewal - webhook may not be operational" -Console
        return $false
    }

    Write-Log "ClusterIP webhook certificate renewed successfully" -Console
    return $true
}


try {
    Start-ControlPlaneIfNotRunning

    $noErrorsOccurred = $true
    $certificatesValid = Assert-CertificateExpiry

    if (($certificatesValid -eq $false) -or ($Force -eq $true)) {
        if ($Force -eq $true) {
            Write-Log "Triggering forced certificate renewal." -Console
        }
        $noErrorsOccurred = Invoke-CertificateRenewalInControlPlane
        if ($noErrorsOccurred -eq $true) {
            Invoke-KubeConfigRefreshOnHost
        }
    }

    # Renew webhook certificate (restart deployment so init container generates fresh cert)
    if ($noErrorsOccurred -eq $true) {
        $webhookExists = (Invoke-CmdOnControlPlaneViaSSHKey 'kubectl get deployment clusterip-webhook -n k2s-webhook --no-headers 2>/dev/null' -IgnoreErrors).Output
        if (-not [string]::IsNullOrWhiteSpace($webhookExists)) {
            $webhookResult = Invoke-WebhookCertificateRenewal
            if ($webhookResult -eq $false) {
                Write-Log "[Warning] Webhook certificate renewal had issues - see logs above" -Console
            }
        } else {
            Write-Log "ClusterIP webhook deployment not found - skipping webhook certificate renewal" -Console
        }
    }

    if ($EncodeStructuredOutput -and $noErrorsOccurred) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null}
    }

}
finally {
    Stop-ControlPlaneIfStartedByThisScript
}
