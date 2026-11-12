# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator
Param(
    [Parameter(Mandatory)] [string] $OldName,
    [Parameter(Mandatory)] [string] $NewName,
    [ValidateRange(60, 86400)] [int] $TimeoutSeconds = 900,
    [switch] $ShowLogs
)

function Get-NodeRenameRemainingSeconds {
    $remaining = [int][Math]::Ceiling(($script:nodeRenameDeadline - [DateTime]::UtcNow).TotalSeconds)
    if ($remaining -le 0) { throw '[NodeRename] Repair timed out' }
    return $remaining
}

function Invoke-NodeRenameKubectl {
    Param([string[]] $Arguments)
    $result = Invoke-Kubectl -Params (@("--request-timeout=$(Get-NodeRenameRemainingSeconds)s") + $Arguments)
    if (-not $result.Success) {
        throw "[NodeRename] kubectl $($Arguments -join ' ') failed: $($result.Output -join "`n")"
    }
    return ($result.Output -join "`n")
}

function Invoke-NodeRenameRemote {
    Param($Node, [string] $Script, [SecureString] $Token)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script.Replace("`r", '')))
    $result = Invoke-CmdOnVmViaSSHKey -UserName $Node.Username -IpAddress $Node.IpAddress `
        -CmdToExecute "printf '%s' '$encoded' | base64 -d | sudo bash" `
        -ExecutionTimeoutSeconds ([Math]::Min(65535, (Get-NodeRenameRemainingSeconds)))
    $output = ($result.Output -join "`n").Trim()
    if ($Token) { $output = $output.Replace([Net.NetworkCredential]::new('', $Token).Password, '[REDACTED]') }
    if (-not $result.Success) {
        throw "[NodeRename] Remote operation failed (exit code $($result.ExitCode)): $output"
    }
    return $output
}

function Invoke-NodeRenameObject {
    Param($Object, [string[]] $Arguments)
    $path = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($path, ($Object | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        Invoke-NodeRenameKubectl -Arguments ($Arguments + @('-f', $path)) | Out-Null
    } finally {
        Remove-Item -LiteralPath $path -Force
    }
}

function Test-NodeRenameReady {
    Param($Node)
    return @($Node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1
}

function Assert-NodeRenameNoWorkloads {
    Param([string] $Name)
    $pods = Invoke-NodeRenameKubectl @('get', 'pods', '-A', "--field-selector=spec.nodeName=$Name", '-o', 'json') | ConvertFrom-Json
    foreach ($pod in $pods.items) {
        if ($pod.status.phase -in @('Succeeded', 'Failed')) { continue }
        $daemon = @($pod.metadata.ownerReferences | Where-Object { $_.kind -eq 'DaemonSet' -and $_.controller }).Count -gt 0
        if (-not $daemon) { throw "[NodeRename] Node '$Name' carries workload $($pod.metadata.namespace)/$($pod.metadata.name); migrate it before retrying" }
    }
}

function New-NodeRenameReplacement {
    Param($OldNode, [string] $NewName, [bool] $Unschedulable)
    $labels = @{}
    $annotations = @{
        'k2s.io/rename-source-uid' = $OldNode.metadata.uid
        'k2s.io/rename-source-name' = $OldNode.metadata.name
        'k2s.io/rename-original-unschedulable' = $Unschedulable.ToString().ToLowerInvariant()
    }
    foreach ($property in $OldNode.metadata.labels.PSObject.Properties) {
        if ($property.Name -notmatch '(^|\.)(kubernetes\.io|k8s\.io)/' -or
            $property.Name -in @('kubernetes.io/role', 'node-role.kubernetes.io/worker')) {
            $labels[$property.Name] = $property.Value
        }
    }
    foreach ($property in $OldNode.metadata.annotations.PSObject.Properties) {
        if ($property.Name -notmatch '(^|\.)(kubernetes\.io|k8s\.io)/|^flannel\.alpha\.coreos\.com/|^k2s\.io/rename-') {
            $annotations[$property.Name] = $property.Value
        }
    }
    $spec = @{
        podCIDR = $OldNode.spec.podCIDR
        unschedulable = $true
        taints = @($OldNode.spec.taints | Where-Object { $_.key -notmatch '(^|\.)(kubernetes\.io|k8s\.io)/' })
    }
    if ($OldNode.spec.podCIDRs) { $spec.podCIDRs = @($OldNode.spec.podCIDRs) }
    return @{ apiVersion = 'v1'; kind = 'Node'; metadata = @{ name = $NewName; labels = $labels; annotations = $annotations }; spec = $spec }
}

function Restore-NodeRenameOldIdentity {
    Param($Node, [string] $OldName)
    $scriptText = @'
set -eu
openssl verify -CAfile /etc/kubernetes/pki/ca.crt /var/lib/kubelet/pki/kubelet-client-current.pem >/dev/null
subject=$(openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -nameopt RFC2253)
case ",${subject#subject=}," in
    *",CN=system:node:__OLD__,"*) ;;
    *) echo "Old kubelet client identity is unavailable; restore its credentials before retrying" >&2; exit 1 ;;
esac
test -f /var/lib/kubelet/kubeadm-flags.env
if [ ! -e /var/lib/kubelet/k2s-rename-kubeadm-flags.env ]; then
    cp -p /var/lib/kubelet/kubeadm-flags.env /var/lib/kubelet/k2s-rename-kubeadm-flags.env
fi
. /var/lib/kubelet/kubeadm-flags.env
flags=$(printf '%s' "$KUBELET_KUBEADM_ARGS" | sed -E 's/(^|[[:space:]])--hostname-override(=|[[:space:]])[^[:space:]]+//g')
printf 'KUBELET_KUBEADM_ARGS="%s --hostname-override=__OLD__"\n' "$flags" > /var/lib/kubelet/kubeadm-flags.env
systemctl restart kubelet
'@
    Invoke-NodeRenameRemote -Node $Node -Script $scriptText.Replace('__OLD__', $OldName) | Out-Null
}

function Stop-NodeRenameWorkloads {
    Param($Node, [string] $Socket)
    $scriptText = @'
set -eu
systemctl stop kubelet
pods=$(crictl --runtime-endpoint '__SOCKET__' pods -q)
for pod in $pods; do
    crictl --runtime-endpoint '__SOCKET__' stopp "$pod"
done
'@
    Invoke-NodeRenameRemote -Node $Node -Script $scriptText.Replace('__SOCKET__', $Socket) | Out-Null
}

function Remove-NodeRenameFlagsBackup {
    Param($Node)
    $scriptText = @'
set -eu
rm -f -- /var/lib/kubelet/k2s-rename-kubeadm-flags.env
'@
    Invoke-NodeRenameRemote -Node $Node -Script $scriptText | Out-Null
}

function Assert-NodeRenameCertificate {
    Param($Node, [string] $NewName)
    $subject = Invoke-NodeRenameRemote -Node $Node -Script @'
set -eu
openssl verify -CAfile /etc/kubernetes/pki/ca.crt /var/lib/kubelet/pki/kubelet-client-current.pem >/dev/null
openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -nameopt RFC2253
'@
    if ($subject -notmatch "(?:subject=\s*|,)CN=system:node:$([regex]::Escape($NewName))(?:,|$)" -or
        $subject -notmatch '(?:subject=\s*|,)O=system:nodes(?:,|$)') {
        throw "[NodeRename] Kubelet client certificate does not identify system:node:$NewName in system:nodes"
    }
}

function Repair-NodeRenameCertificates {
    Param($Node, [string] $NewName, [string] $Socket)
    $token = ''
    $secureToken = $null
    $remoteDirectory = ''
    $localPath = [IO.Path]::GetTempFileName()
    try {
        $ttl = Get-NodeRenameRemainingSeconds
        $join = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "sudo kubeadm token create --ttl $($ttl)s --print-join-command"
        if (-not $join.Success) { throw '[NodeRename] Could not create a short-lived bootstrap token' }
        $match = [regex]::Match(($join.Output -join "`n").Trim(), '^kubeadm join ([a-zA-Z0-9.:\[\]-]+) --token ([a-z0-9]{6}\.[a-z0-9]{16}) --discovery-token-ca-cert-hash (sha256:[a-f0-9]{64})$')
        if (-not $match.Success) { throw '[NodeRename] Control plane returned an invalid bootstrap command' }
        $token = $match.Groups[2].Value
        $secureToken = ConvertTo-SecureString -String $token -AsPlainText -Force
        $configuration = @{
            apiVersion = 'kubeadm.k8s.io/v1beta4'; kind = 'JoinConfiguration'
            caCertPath = '/etc/kubernetes/pki/ca.crt'
            nodeRegistration = @{
                name = $NewName; criSocket = $Socket
                kubeletExtraArgs = @(
                    @{ name = 'node-ip'; value = $Node.IpAddress },
                    @{ name = 'config-dir'; value = '/etc/kubernetes/kubelet.conf.d' }
                )
            }
            discovery = @{ bootstrapToken = @{
                apiServerEndpoint = $match.Groups[1].Value; token = $token; caCertHashes = @($match.Groups[3].Value)
            } }
        }
        [IO.File]::WriteAllText($localPath, ($configuration | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $directoryResult = Invoke-CmdOnVmViaSSHKey -UserName $Node.Username -IpAddress $Node.IpAddress `
            -CmdToExecute 'umask 077; mktemp -d /tmp/k2s-node-rename.XXXXXXXX' -ExecutionTimeoutSeconds ([Math]::Min(65535, (Get-NodeRenameRemainingSeconds)))
        if (-not $directoryResult.Success) { throw '[NodeRename] Could not create private bootstrap directory' }
        $remoteDirectory = ($directoryResult.Output -join "`n").Trim()
        if ($remoteDirectory -notmatch '^/tmp/k2s-node-rename\.[a-zA-Z0-9]{8}$') {
            $remoteDirectory = ''
            throw '[NodeRename] Invalid remote bootstrap directory'
        }
        Copy-ToRemoteComputerViaSshKey -Source $localPath -Target "$remoteDirectory/join.json" -UserName $Node.Username -IpAddress $Node.IpAddress
        $scriptText = @'
set -eu
systemctl stop kubelet
umask 077
backup=$(mktemp -d /var/lib/kubelet/k2s-identity-backup.XXXXXXXX)
for file in /etc/kubernetes/kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf /var/lib/kubelet/pki/kubelet-client* /var/lib/kubelet/pki/kubelet-server* /var/lib/kubelet/pki/kubelet.crt /var/lib/kubelet/pki/kubelet.key; do
    if [ -e "$file" ] || [ -L "$file" ]; then
        mv -- "$file" "$backup/"
    fi
done
echo "Previous kubelet credentials backed up to $backup"
kubeadm join phase kubelet-start --config '__DIRECTORY__/join.json'
deadline=$((SECONDS + __TIMEOUT__))
while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f /var/lib/kubelet/pki/kubelet-client-current.pem ]; then
        subject=$(openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -subject -nameopt RFC2253)
        case ",${subject#subject=}," in
            *",CN=system:node:__NEW__,"*)
                openssl verify -CAfile /etc/kubernetes/pki/ca.crt /var/lib/kubelet/pki/kubelet-client-current.pem
                exit 0 ;;
        esac
    fi
    sleep 2
done
echo "Timed out waiting for the new kubelet client certificate; inspect kubelet logs and pending CSRs" >&2
exit 1
'@
        $scriptText = $scriptText.Replace('__DIRECTORY__', $remoteDirectory).Replace('__TIMEOUT__', [string](Get-NodeRenameRemainingSeconds)).Replace('__NEW__', $NewName)
        Invoke-NodeRenameRemote -Node $Node -Script $scriptText -Token $secureToken | Write-Log
    } finally {
        Remove-Item -LiteralPath $localPath -Force
        if ($remoteDirectory) {
            $cleanup = Invoke-CmdOnVmViaSSHKey -UserName $Node.Username -IpAddress $Node.IpAddress `
                -CmdToExecute "rm -f -- '$remoteDirectory/join.json' && rmdir -- '$remoteDirectory'" -ExecutionTimeoutSeconds 10
            if (-not $cleanup.Success) { Write-Log "[NodeRename] Could not remove temporary bootstrap config at $remoteDirectory" -Console }
        }
        if ($token) {
            $revoke = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "sudo kubeadm token delete $($token.Split('.')[0])"
            if (-not $revoke.Success) { Write-Log '[NodeRename] Could not revoke bootstrap token; it expires automatically' -Console }
        }
        if ($secureToken) { $secureToken.Dispose() }
    }
}

function Invoke-LinuxWorkerRename {
    Param([string] $OldName, [string] $NewName, [int] $TimeoutSeconds = 900)
    $OldName = $OldName.ToLowerInvariant()
    $NewName = $NewName.ToLowerInvariant()
    foreach ($name in @($OldName, $NewName)) {
        if ($name.Length -gt 253 -or $name -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' -or
            @($name.Split('.') | Where-Object { $_.Length -gt 63 -or $_ -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' }).Count) {
            throw "[NodeRename] Invalid node name '$name'"
        }
    }
    if ($OldName -eq $NewName) { throw '[NodeRename] Old and new names must differ' }
    $script:nodeRenameDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $phase = 'validating target'
    try {
        $nodes = (Invoke-NodeRenameKubectl @('get', 'nodes', '-o', 'json') | ConvertFrom-Json).items
        $old = @($nodes | Where-Object { $_.metadata.name -eq $OldName })
        $replacement = @($nodes | Where-Object { $_.metadata.name -eq $NewName })
        $descriptor = Get-Content -LiteralPath (Get-ClusterDescriptorFilePath) -Raw | ConvertFrom-Json
        $managed = @($descriptor.nodes | Where-Object { $_.Name -in @($OldName, $NewName) })
        if ($managed.Count -ne 1) { throw '[NodeRename] Expected exactly one managed worker descriptor for the old or new identity' }
        $target = $managed[0]
        if ($target.OS -ne 'linux' -or $target.Role -ne 'worker' -or $target.NodeType -notin @('HOST', 'VM-EXISTING') -or
            -not $target.Username -or -not $target.PodCIDR) { throw '[NodeRename] Only managed Linux workers with complete connection metadata are supported' }
        $parsedIp = $null
        if (-not [Net.IPAddress]::TryParse($target.IpAddress, [ref]$parsedIp)) { throw '[NodeRename] Invalid managed worker IP address' }
        $hostname = Invoke-NodeRenameRemote -Node $target -Script 'hostname'
        if ($hostname -ine $NewName) { throw "[NodeRename] OS hostname '$hostname' does not match '$NewName'; no identity changes made" }
        if ($old.Count -eq 0) {
            if ($replacement.Count -ne 1 -or $target.Name -ne $NewName -or
                $replacement[0].metadata.annotations.'k2s.io/rename-source-name' -ne $OldName -or
                -not (Test-NodeRenameReady $replacement[0])) { throw '[NodeRename] Old node is missing and a completed replacement cannot be verified' }
            $ready = $replacement[0]
        } else {
            $old = $old[0]
            if ($old.metadata.labels.'kubernetes.io/os' -ne 'linux' -or
                $old.metadata.labels.PSObject.Properties.Name -contains 'node-role.kubernetes.io/control-plane' -or
                $old.metadata.labels.PSObject.Properties.Name -contains 'node-role.kubernetes.io/master' -or
                $old.metadata.labels.'kubernetes.io/role' -in @('master', 'control-plane') -or
                $old.spec.podCIDR -ne $target.PodCIDR -or
                @($old.status.addresses | Where-Object { $_.type -eq 'InternalIP' -and $_.address -eq $target.IpAddress }).Count -ne 1) {
                throw '[NodeRename] Old Node is not the expected managed Linux worker'
            }
            if ($replacement.Count) {
                $replacement = $replacement[0]
                if ($replacement.metadata.annotations.'k2s.io/rename-source-uid' -ne $old.metadata.uid -or
                    $replacement.metadata.annotations.'k2s.io/rename-source-name' -ne $OldName -or
                    $replacement.spec.podCIDR -ne $old.spec.podCIDR -or
                    $replacement.metadata.labels.'kubernetes.io/os' -notin @($null, 'linux')) { throw '[NodeRename] Replacement name is already in use by another Node' }
                Invoke-NodeRenameKubectl @('cordon', $NewName) | Out-Null
                Assert-NodeRenameNoWorkloads -Name $NewName
            } else {
                $replacement = $null
            }
            $saved = $old.metadata.annotations.'k2s.io/rename-original-unschedulable'
            $unschedulable = [bool]$old.spec.unschedulable
            if ($null -ne $saved) { $unschedulable = [bool]::Parse($saved) }
            Invoke-NodeRenameKubectl @('annotate', 'node', $OldName, "k2s.io/rename-original-unschedulable=$($unschedulable.ToString().ToLowerInvariant())", '--overwrite') | Out-Null
            Invoke-NodeRenameKubectl @('cordon', $OldName) | Out-Null
            if (-not $replacement -or -not (Test-NodeRenameReady $replacement)) {
                $socket = Invoke-NodeRenameRemote -Node $target -Script @'
set -eu
if grep -qs crio.sock /var/lib/kubelet/instance-config.yaml /var/lib/kubelet/kubeadm-flags.env; then
    echo unix:///run/crio/crio.sock
elif grep -qs containerd.sock /var/lib/kubelet/instance-config.yaml /var/lib/kubelet/kubeadm-flags.env; then
    echo unix:///run/containerd/containerd.sock
else
    echo "Cannot identify configured container runtime" >&2; exit 1
fi
'@
                if ($socket -notin @('unix:///run/crio/crio.sock', 'unix:///run/containerd/containerd.sock')) { throw '[NodeRename] Unsupported runtime socket' }
                $runtimeService = if ($socket -eq 'unix:///run/crio/crio.sock') { 'crio' } else { 'containerd' }
                Invoke-NodeRenameRemote -Node $target -Script "set -eu`nsystemctl start $runtimeService" | Out-Null
                if ($old.metadata.annotations.'k2s.io/rename-drained' -ne 'true') {
                    $phase = 'restoring old kubelet identity for graceful drain'
                    Restore-NodeRenameOldIdentity -Node $target -OldName $OldName
                    Invoke-NodeRenameKubectl @('wait', '--for=condition=Ready', "node/$OldName", "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
                    $phase = 'draining old node'
                    Write-Log '[NodeRename] Graceful drain permits deletion of pod-local emptyDir data; persistent volumes are retained' -Console
                    Invoke-NodeRenameKubectl @('drain', $OldName, '--ignore-daemonsets', '--delete-emptydir-data', "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
                    $phase = 'stopping old workload containers'
                    Stop-NodeRenameWorkloads -Node $target -Socket $socket
                    Invoke-NodeRenameKubectl @('annotate', 'node', $OldName, 'k2s.io/rename-drained=true', '--overwrite') | Out-Null
                } else {
                    $phase = 'verifying previously drained worker'
                    Assert-NodeRenameNoWorkloads -Name $OldName
                    Stop-NodeRenameWorkloads -Node $target -Socket $socket
                }
                $phase = 'creating replacement identity'
                if (-not $replacement) {
                    Invoke-NodeRenameObject -Object (New-NodeRenameReplacement -OldNode $old -NewName $NewName -Unschedulable $unschedulable) -Arguments @('create')
                }
                $phase = 'bootstrapping new kubelet certificates'
                Repair-NodeRenameCertificates -Node $target -NewName $NewName -Socket $socket
                $phase = 'waiting for replacement readiness'
                Invoke-NodeRenameKubectl @('wait', '--for=condition=Ready', "node/$NewName", "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
            }
            $ready = Invoke-NodeRenameKubectl @('get', 'node', $NewName, '-o', 'json') | ConvertFrom-Json
        }
        $phase = 'validating replacement identity'
        if (-not (Test-NodeRenameReady $ready) -or $ready.spec.podCIDR -ne $target.PodCIDR -or
            $ready.metadata.labels.'kubernetes.io/os' -ne 'linux' -or
            @($ready.status.addresses | Where-Object { $_.type -eq 'InternalIP' -and $_.address -eq $target.IpAddress }).Count -ne 1) {
            throw '[NodeRename] Replacement readiness, address, OS or PodCIDR validation failed'
        }
        if ($old -and ($ready.spec.podCIDRs -join ',') -ne ($old.spec.podCIDRs -join ',')) {
            throw '[NodeRename] Replacement PodCIDRs do not match the old Node'
        }
        Assert-NodeRenameCertificate -Node $target -NewName $NewName
        $phase = 'updating managed configuration and routes'
        if ($old) { Stop-LinuxWorkerNode -NodeName $OldName }
        Update-NodeConfig -Name $target.Name -Updates @{ Name = $NewName }
        if ((Get-NodeConfig -NodeName $NewName).Name -ne $NewName) { throw '[NodeRename] Managed configuration update was not persisted' }
        Start-LinuxWorkerNode -NodeName $NewName -IpAddress $target.IpAddress
        if ($old) {
            $phase = 'retiring old identity'
            Invoke-NodeRenameObject -Object @{ apiVersion = 'v1'; kind = 'DeleteOptions'; preconditions = @{ uid = $old.metadata.uid } } -Arguments @('delete', "--raw=/api/v1/nodes/$OldName")
            Invoke-NodeRenameKubectl @('wait', '--for=delete', "node/$OldName", "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
        }
        $phase = 'restoring scheduling'
        $unschedulable = [bool]::Parse($ready.metadata.annotations.'k2s.io/rename-original-unschedulable')
        $schedule = if ($unschedulable) { 'cordon' } else { 'uncordon' }
        Invoke-NodeRenameKubectl @($schedule, $NewName) | Out-Null
        # The rename is complete here, so a leftover backup file must not fail it
        try {
            Remove-NodeRenameFlagsBackup -Node $target
        } catch {
            Write-Log "[NodeRename] Could not remove /var/lib/kubelet/k2s-rename-kubeadm-flags.env on the worker; delete it manually: $($_.Exception.Message)" -Console
        }
        Write-Log "[NodeRename] Renamed $OldName to $NewName; kubelet certificate verified and replacement Ready" -Console
    } catch {
        throw "[NodeRename] Rename $OldName -> $NewName failed while ${phase}: $($_.Exception.Message). Nodes may remain cordoned; inspect target services before retrying the same command."
    }
}

$ErrorActionPreference = 'Stop'
try {
    . "$PSScriptRoot\common\LinuxWorkerNode.Common.ps1"
    Initialize-LinuxWorkerScriptEnvironment -ShowLogs:$ShowLogs
    $env:KUBECONFIG = Join-Path (Get-KubePath) 'config'
    if (-not (Test-Path -LiteralPath $env:KUBECONFIG -PathType Leaf)) {
        throw '[NodeRename] The installation kubeconfig is missing'
    }
    Invoke-LinuxWorkerRename -OldName $OldName -NewName $NewName -TimeoutSeconds $TimeoutSeconds
} catch {
    Write-Log "[NodeRename] $($_.Exception.Message)" -Console
    exit 1
}
