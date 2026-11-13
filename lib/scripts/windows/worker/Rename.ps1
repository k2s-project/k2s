# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator
Param(
    [Parameter(Mandatory)] [string] $OldName,
    [Parameter(Mandatory)] [string] $NewName,
    [ValidateRange(60, 86400)] [int] $TimeoutSeconds = 900,
    [switch] $Force,
    [switch] $ShowLogs,
    [parameter(HelpMessage = 'If set, the result is sent to the CLI as structured data')]
    [switch] $EncodeStructuredOutput,
    [parameter(HelpMessage = 'Message type of the structured data')]
    [string] $MessageType
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
    Param([string] $Name, [string] $Hint = 'migrate it before retrying')
    $pods = Invoke-NodeRenameKubectl @('get', 'pods', '-A', "--field-selector=spec.nodeName=$Name", '-o', 'json') | ConvertFrom-Json
    foreach ($pod in $pods.items) {
        if ($pod.status.phase -in @('Succeeded', 'Failed')) { continue }
        $daemon = @($pod.metadata.ownerReferences | Where-Object { $_.kind -eq 'DaemonSet' -and $_.controller }).Count -gt 0
        if (-not $daemon) { throw "[NodeRename] Node '$Name' carries workload $($pod.metadata.namespace)/$($pod.metadata.name); $Hint" }
    }
}

function Test-NodeRenameManagedKey {
    Param([string] $Key)
    return $Key -match '(^|\.)(kubernetes\.io|k8s\.io)/'
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
        if (-not (Test-NodeRenameManagedKey -Key $property.Name) -or
            $property.Name -in @('kubernetes.io/role', 'node-role.kubernetes.io/worker')) {
            $labels[$property.Name] = $property.Value
        }
    }
    foreach ($property in $OldNode.metadata.annotations.PSObject.Properties) {
        if (-not (Test-NodeRenameManagedKey -Key $property.Name) -and
            $property.Name -notmatch '^flannel\.alpha\.coreos\.com/|^k2s\.io/rename-') {
            $annotations[$property.Name] = $property.Value
        }
    }
    $spec = @{
        podCIDR = $OldNode.spec.podCIDR
        unschedulable = $true
        taints = @($OldNode.spec.taints | Where-Object { $_ -and -not (Test-NodeRenameManagedKey -Key $_.key) })
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

function Test-NodeRenameControlPlane {
    Param($Node)
    $labels = @($Node.metadata.labels.PSObject.Properties | ForEach-Object { $_.Name })
    return $labels -contains 'node-role.kubernetes.io/control-plane' -or $labels -contains 'node-role.kubernetes.io/master' -or
        $Node.metadata.labels.'kubernetes.io/role' -in @('master', 'control-plane')
}

function Get-NodeRenameInternalIPs {
    Param($Node)
    return @($Node.status.addresses | Where-Object { $_.type -eq 'InternalIP' } | ForEach-Object { $_.address })
}

function Test-NodeRenameOtherNodeAvailable {
    Param($Nodes, $Old, [string] $NewName)
    # Pods that run on the old Node tolerate its taints, for example the OS taint that K2s sets on Windows nodes
    $tolerated = @($Old.spec.taints | Where-Object { $_ } | ForEach-Object { "$($_.key)=$($_.value):$($_.effect)" })
    foreach ($node in $Nodes) {
        if ($node.metadata.name -in @($Old.metadata.name, $NewName)) { continue }
        if ($node.metadata.labels.'kubernetes.io/os' -ne $Old.metadata.labels.'kubernetes.io/os') { continue }
        if (-not (Test-NodeRenameReady $node) -or $node.spec.unschedulable) { continue }
        $blocking = @($node.spec.taints | Where-Object {
                $_ -and $_.effect -in @('NoSchedule', 'NoExecute') -and "$($_.key)=$($_.value):$($_.effect)" -notin $tolerated
            })
        if ($blocking.Count) { continue }
        return $true
    }
    return $false
}

function Get-NodeRenameControlPlaneRoute {
    Param([string] $PodCIDR)
    # Read-only check; returns $null when the route cannot be determined
    if ($PodCIDR -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') { return $null }
    try {
        $result = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "ip route show $PodCIDR" -IgnoreErrors -NoLog
        if (-not $result.Success) { return $null }
        return (($result.Output | Out-String).Trim())
    } catch {
        return $null
    }
}

function Get-NodeRenameLocalHostname {
    return [System.Net.Dns]::GetHostName()
}

function Get-NodeRenameLocalIPs {
    return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
}

function Resolve-NodeRenameTarget {
    Param([string] $OldName, [string] $NewName, $Old, $Replacement)
    $managed = @()
    $descriptorPath = Get-ClusterDescriptorFilePath
    if ($descriptorPath -and (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        $descriptor = Get-Content -LiteralPath $descriptorPath -Raw | ConvertFrom-Json
        $managed = @($descriptor.nodes | Where-Object { $_.Name -in @($OldName, $NewName) })
    }
    if ($managed.Count -gt 1) { throw '[NodeRename] Both the old and the new name are registered as managed workers' }
    if ($managed.Count -eq 1) {
        $entry = $managed[0]
        if ($entry.OS -ne 'linux') { throw "[NodeRename] Additional $($entry.OS) workers are not supported" }
        if ($entry.Role -ne 'worker' -or $entry.NodeType -notin @('HOST', 'VM-EXISTING')) {
            throw "[NodeRename] Unsupported node type '$($entry.NodeType)' with role '$($entry.Role)'"
        }
        $parsedIp = $null
        if (-not $entry.Username -or -not $entry.PodCIDR -or -not [Net.IPAddress]::TryParse([string]$entry.IpAddress, [ref]$parsedIp)) {
            throw '[NodeRename] The managed worker has incomplete connection or PodCIDR metadata'
        }
        return [pscustomobject]@{
            Kind = 'linux'; OS = 'linux'; Name = $entry.Name; NodeType = $entry.NodeType
            IpAddress = $entry.IpAddress; Username = $entry.Username; PodCIDR = $entry.PodCIDR
        }
    }
    if ((Get-ConfigLinuxOnly) -eq $true -and $NewName -ieq (Get-NodeRenameLocalHostname)) {
        throw '[NodeRename] This is a Linux-only installation; the local Windows host is not a cluster Node'
    }
    $node = if ($Old) { $Old } else { $Replacement }
    if (-not $node) { throw "[NodeRename] Node '$OldName' does not exist" }
    if ($node.metadata.labels.'kubernetes.io/os' -ne 'windows') {
        throw "[NodeRename] Node '$($node.metadata.name)' is not managed by K2s: it was not added with 'k2s node add' and is not the local Windows worker"
    }
    $localIps = @(Get-NodeRenameLocalIPs)
    $address = @(Get-NodeRenameInternalIPs -Node $node) | Where-Object { $_ -in $localIps } | Select-Object -First 1
    if (-not $address) {
        throw "[NodeRename] Windows Node '$($node.metadata.name)' is not the local K2s worker host; additional Windows workers are not supported"
    }
    return [pscustomobject]@{
        Kind = 'windows'; OS = 'windows'; Name = $node.metadata.name; NodeType = 'WINDOWS-HOST'
        IpAddress = $address; Username = ''; PodCIDR = $node.spec.podCIDR
    }
}

function Get-NodeRenameServiceSetting {
    Param([string] $Service, [string] $Name, [Microsoft.Win32.RegistryKey] $Hive = [Microsoft.Win32.Registry]::LocalMachine)
    $key = $Hive.OpenSubKey("SYSTEM\CurrentControlSet\Services\$Service\Parameters")
    if (-not $key) { throw "[NodeRename] Service '$Service' has no service parameters" }
    try {
        # Unexpanded, so that a value containing environment variables is written back unchanged
        return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally {
        $key.Dispose()
    }
}

function Set-NodeRenameServiceSetting {
    Param([string] $Service, [string] $Name, $Value, [Microsoft.Win32.RegistryKey] $Hive = [Microsoft.Win32.Registry]::LocalMachine)
    $key = $Hive.OpenSubKey("SYSTEM\CurrentControlSet\Services\$Service\Parameters", $true)
    if (-not $key) { throw "[NodeRename] Service '$Service' has no service parameters" }
    try {
        $key.SetValue($Name, $Value, $key.GetValueKind($Name))
    } finally {
        $key.Dispose()
    }
}

function Set-NodeRenameWindowsIdentity {
    Param([string] $NewName)
    $hostnamePattern = '--hostname-override(?:=|\s+)(?:"[^"]*"|\S+)'
    $proxyParameters = [string](Get-NodeRenameServiceSetting -Service 'kubeproxy' -Name 'AppParameters')
    if ($proxyParameters -notmatch $hostnamePattern) { throw '[NodeRename] kubeproxy has no --hostname-override parameter' }
    $environment = @(Get-NodeRenameServiceSetting -Service 'flanneld' -Name 'AppEnvironmentExtra')
    if (@($environment | Where-Object { $_ -match '^NODE_NAME=' }).Count -ne 1) { throw '[NodeRename] flanneld has no single NODE_NAME setting' }

    Set-NodeRenameServiceSetting -Service 'kubeproxy' -Name 'AppParameters' `
        -Value ([regex]::Replace($proxyParameters, $hostnamePattern, "--hostname-override=$NewName"))
    $updatedEnvironment = [string[]]@($environment | ForEach-Object { if ($_ -match '^NODE_NAME=') { "NODE_NAME=$NewName" } else { $_ } })
    Set-NodeRenameServiceSetting -Service 'flanneld' -Name 'AppEnvironmentExtra' -Value $updatedEnvironment

    $flagsPath = Join-Path (Get-KubeletConfigDir) 'kubeadm-flags.env'
    if (Test-Path -LiteralPath $flagsPath -PathType Leaf) {
        $flags = [IO.File]::ReadAllText($flagsPath)
        $updatedFlags = [regex]::Replace($flags, '--hostname-override=[^\s"]+', "--hostname-override=$NewName")
        if ($updatedFlags -cne $flags) { [IO.File]::WriteAllText($flagsPath, $updatedFlags, [Text.UTF8Encoding]::new($false)) }
    }
}

function Get-NodeRenameWindowsCertificateSubject {
    $path = Join-Path (Get-KubeletConfigDir) 'pki\kubelet-client-current.pem'
    try {
        $match = [regex]::Match([IO.File]::ReadAllText($path), '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----', 'Singleline')
        if (-not $match.Success) { return $null }
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String(($match.Groups[1].Value -replace '\s', '')))
        try { return $certificate.Subject } finally { $certificate.Dispose() }
    } catch {
        # Missing or half-written while the kubelet replaces it
        return $null
    }
}

function Test-NodeRenameCertificateSubject {
    Param([string] $Subject, [string] $NodeName)
    $parts = @($Subject -split '\s*,\s*')
    return $parts -contains "CN=system:node:$NodeName" -and $parts -contains 'O=system:nodes'
}

function Backup-NodeRenameWindowsCredentials {
    Param([string] $NewName)
    if (Test-NodeRenameCertificateSubject -Subject (Get-NodeRenameWindowsCertificateSubject) -NodeName $NewName) { return }
    $kubeletDirectory = Get-KubeletConfigDir
    $files = @(Get-ChildItem -LiteralPath (Join-Path $kubeletDirectory 'pki') -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^kubelet-(client|server)' -or $_.Name -in @('kubelet.crt', 'kubelet.key') })
    if ($files.Count -eq 0) { return }
    $backup = Join-Path $kubeletDirectory "k2s-identity-backup.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    New-Item -Path $backup -ItemType Directory -Force | Out-Null
    foreach ($file in $files) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            # kubelet-client-current.pem is a link to a dated certificate file that is moved below
            [IO.File]::Delete($file.FullName)
        } else {
            [IO.File]::Move($file.FullName, (Join-Path $backup $file.Name))
        }
    }
    Write-Log "[NodeRename] Previous kubelet credentials backed up to $backup" -Console
}

function Invoke-NodeRenameCrictl {
    Param([string[]] $Arguments)
    $binPath = Get-KubeBinPath
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell turns stderr of a native command into a terminating error under 'Stop'
        $ErrorActionPreference = 'Continue'
        $output = & (Join-Path $binPath 'crictl.exe') --config (Join-Path $binPath 'crictl.yaml') @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $lines = @($output | ForEach-Object { "$_" })
    if ($exitCode -ne 0) { throw "[NodeRename] crictl $($Arguments -join ' ') failed (exit code $exitCode): $($lines -join "`n")" }
    return $lines
}

function Wait-NodeRenameWindowsService {
    Param([string] $Name)
    (Get-Service -Name $Name -ErrorAction Stop).WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
}

function Get-NodeRenameKubeletStartScript {
    return Join-Path (Get-KubePath) 'smallsetup\common\StartKubelet.ps1'
}

function Get-NodeRenameKubeletStartScriptBackup {
    return Join-Path (Get-KubeletConfigDir) 'k2s-rename-StartKubelet.ps1'
}

function Restore-NodeRenameWindowsKubeletName {
    $backup = Get-NodeRenameKubeletStartScriptBackup
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { return }
    [IO.File]::Copy($backup, (Get-NodeRenameKubeletStartScript), $true)
    [IO.File]::Delete($backup)
}

function Set-NodeRenameWindowsKubeletName {
    Param([string] $Name)
    # A copy left by an interrupted attempt holds the original script
    Restore-NodeRenameWindowsKubeletName
    $path = Get-NodeRenameKubeletStartScript
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::Default)
    # The start script passes the current host name as the last --hostname-override, which overrides the kubelet flags file
    $hostnameReads = [regex]::Matches($text, '\$hn\s*=\s*\(\$\(hostname\)\)\.ToLower\(\)')
    if ($hostnameReads.Count -ne 1) {
        throw "[NodeRename] The kubelet start script '$path' does not read the host name in the expected way; the old kubelet name cannot be restored"
    }
    [IO.File]::Copy($path, (Get-NodeRenameKubeletStartScriptBackup), $true)
    [IO.File]::WriteAllText($path, $text.Replace($hostnameReads[0].Value, "`$hn = '$Name'"), [Text.Encoding]::Default)
}

function Restore-NodeRenameWindowsOldIdentity {
    Param([string] $OldName)
    Set-NodeRenameWindowsKubeletName -Name $OldName
    foreach ($service in @('kubeproxy', 'kubelet')) { Stop-Service -Name $service -Force -ErrorAction Stop }
    foreach ($service in @('containerd', 'httpproxy', 'flanneld', 'kubelet', 'kubeproxy')) {
        # Start-Service can report a failure for a service that is running afterwards, so the status decides
        Start-Service -Name $service -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        Wait-NodeRenameWindowsService -Name $service
    }
}

function Stop-NodeRenameWindowsServices {
    foreach ($service in @('kubeproxy', 'kubelet')) { Stop-Service -Name $service -Force -ErrorAction Stop }
    if ((Get-Service -Name 'containerd' -ErrorAction Stop).Status -ne 'Running') {
        Start-Service -Name 'containerd' -ErrorAction Stop
        Wait-NodeRenameWindowsService -Name 'containerd'
    }
    # Containers keep running without the kubelet, so stop the remaining pod sandboxes (DaemonSet pods are not drained)
    $sandboxes = @(Invoke-NodeRenameCrictl -Arguments @('pods', '-q')) | Where-Object { $_ -match '^[0-9a-f]{12,64}$' }
    foreach ($sandbox in $sandboxes) { Invoke-NodeRenameCrictl -Arguments @('stopp', $sandbox) | Out-Null }
    Stop-Service -Name 'flanneld' -Force -ErrorAction Stop
}

function Start-NodeRenameWindowsServices {
    foreach ($service in @('containerd', 'httpproxy', 'flanneld', 'kubelet', 'kubeproxy', 'dnsproxy')) {
        if ($service -eq 'containerd') {
            Restart-Service -Name $service -Force -ErrorAction Stop
        } else {
            # httpproxy and dnsproxy do not use the host name and also serve the control plane and the other nodes, so they are
            # started only when they are not running. A start of httpproxy while flanneld is stopped would also trigger the K2s startup recovery.
            # Start-Service can report a failure for a service that is running afterwards, so the status decides.
            Start-Service -Name $service -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        }
        Wait-NodeRenameWindowsService -Name $service
    }
}

function Assert-NodeRenameWindowsServices {
    foreach ($service in @('containerd', 'httpproxy', 'flanneld', 'kubelet', 'kubeproxy', 'dnsproxy')) {
        if ((Get-Service -Name $service -ErrorAction Stop).Status -ne 'Running') { throw "[NodeRename] Service '$service' is not running" }
    }
}

function Wait-NodeRenameWindowsCertificate {
    Param([string] $NewName)
    while ([DateTime]::UtcNow -lt $script:nodeRenameDeadline) {
        if (Test-NodeRenameCertificateSubject -Subject (Get-NodeRenameWindowsCertificateSubject) -NodeName $NewName) { return }
        Start-Sleep -Seconds 2
    }
    throw "[NodeRename] Timed out waiting for the kubelet client certificate of system:node:$NewName; inspect the kubelet log and pending certificate requests ('kubectl get csr')"
}

function Format-NodeRenameSummary {
    Param([string] $OldName, [string] $NewName, $Node, $Target, [bool] $Unschedulable)
    $labels = @($Node.metadata.labels.PSObject.Properties |
            Where-Object { $_ -and (-not (Test-NodeRenameManagedKey -Key $_.Name) -or $_.Name -in @('kubernetes.io/role', 'node-role.kubernetes.io/worker')) } |
            ForEach-Object { "$($_.Name)=$($_.Value)" })
    $taints = @($Node.spec.taints | Where-Object { $_ -and -not (Test-NodeRenameManagedKey -Key $_.key) } |
            ForEach-Object { "$($_.key)=$($_.value):$($_.effect)" })
    $labelText = if ($labels.Count) { $labels -join ', ' } else { 'none' }
    $taintText = if ($taints.Count) { $taints -join ', ' } else { 'none' }
    return "[NodeRename] Renamed $OldName to $NewName ($($Target.OS) worker, type $($Target.NodeType)); PodCIDR $($Node.spec.podCIDR); Ready; " +
        "kubelet certificate verified; preserved labels: $labelText; taints: $taintText; unschedulable: $($Unschedulable.ToString().ToLowerInvariant())"
}

function Write-NodeRenameProgress {
    Param([string] $Message)
    Write-Log "[NodeRename] $Message" -Console
}

function Get-NodeRenameTargetDescription {
    Param($Target)
    if ($Target.Kind -eq 'windows') {
        return "local Windows worker host (IP $($Target.IpAddress), PodCIDR $($Target.PodCIDR))"
    }
    $machine = if ($Target.NodeType -eq 'HOST') { 'a physical host' } else { 'an existing VM' }
    return "additional Linux worker on $machine (IP $($Target.IpAddress), SSH user $($Target.Username), PodCIDR $($Target.PodCIDR))"
}

function Invoke-WorkerRename {
    Param([string] $OldName, [string] $NewName, [int] $TimeoutSeconds = 900, [switch] $Force)
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
        $old = @($nodes | Where-Object { $_.metadata.name -eq $OldName }) | Select-Object -First 1
        $replacement = @($nodes | Where-Object { $_.metadata.name -eq $NewName }) | Select-Object -First 1
        foreach ($node in @($old, $replacement)) {
            if ($node -and (Test-NodeRenameControlPlane -Node $node)) {
                throw "[NodeRename] '$($node.metadata.name)' is a control-plane Node; only worker Nodes can be renamed"
            }
        }
        $target = Resolve-NodeRenameTarget -OldName $OldName -NewName $NewName -Old $old -Replacement $replacement
        $hostname = if ($target.Kind -eq 'windows') { Get-NodeRenameLocalHostname } else { Invoke-NodeRenameRemote -Node $target -Script 'hostname' }
        Write-NodeRenameProgress "Renaming Node '$OldName' to '$NewName'. Target: $(Get-NodeRenameTargetDescription -Target $target)"
        if ($hostname -ine $NewName) { throw "[NodeRename] OS hostname '$hostname' does not match '$NewName'" }
        Write-NodeRenameProgress "The OS hostname of the target is '$hostname' and matches the new name"
        $unschedulable = $null
        if (-not $old) {
            if (-not $replacement -or ($target.Kind -eq 'linux' -and $target.Name -ne $NewName) -or
                $replacement.metadata.annotations.'k2s.io/rename-source-name' -ne $OldName -or
                -not (Test-NodeRenameReady $replacement)) { throw '[NodeRename] Old node is missing and a completed replacement cannot be verified' }
            $ready = $replacement
            Write-NodeRenameProgress "Old Node '$OldName' is already removed and Node '$NewName' is Ready; finishing the earlier rename"
        } else {
            if (-not $old.spec.podCIDR) { throw "[NodeRename] Old Node '$OldName' has no PodCIDR; its identity cannot be replaced" }
            if ($old.metadata.labels.'kubernetes.io/os' -ne $target.OS -or $old.spec.podCIDR -ne $target.PodCIDR -or
                @(Get-NodeRenameInternalIPs -Node $old) -notcontains $target.IpAddress) {
                throw "[NodeRename] Old Node is not the expected managed $($target.OS) worker"
            }
            $oldState = if (Test-NodeRenameReady $old) { 'Ready' } else { 'NotReady' }
            Write-NodeRenameProgress "Old Node '$OldName' is $oldState"
            $reuse = $false
            if ($replacement) {
                $owned = $replacement.metadata.annotations.'k2s.io/rename-source-uid' -eq $old.metadata.uid -and
                    $replacement.metadata.annotations.'k2s.io/rename-source-name' -eq $OldName -and
                    $replacement.spec.podCIDR -eq $old.spec.podCIDR
                $sameMachine = @(Get-NodeRenameInternalIPs -Node $replacement) -contains $target.IpAddress
                $replacementOs = $replacement.metadata.labels.'kubernetes.io/os'
                if ((-not $owned -and -not $sameMachine) -or ($replacementOs -and $replacementOs -ne $target.OS)) {
                    throw '[NodeRename] Replacement name is already in use by another Node'
                }
                if ($owned) {
                    Write-NodeRenameProgress "Node '$NewName' was created by an earlier attempt of this command and is reused"
                } else {
                    Write-NodeRenameProgress "Node '$NewName' was registered by the machine itself with PodCIDR '$($replacement.spec.podCIDR)'; it is replaced by a Node with PodCIDR $($old.spec.podCIDR)"
                }
                if ($Force) { Write-NodeRenameProgress "--force: workloads on Node '$NewName' are not checked" }
                # Everything up to here only reads; the first change follows
                $phase = 'cordoning nodes'
                Invoke-NodeRenameKubectl @('cordon', $NewName) | Out-Null
                if (-not $Force) {
                    Assert-NodeRenameNoWorkloads -Name $NewName -Hint 'migrate it, or rerun with --force to continue without migrating it (the partially registered Node is recreated and its pods are stopped)'
                }
                # A Node this command created is reused; one registered by the machine itself has the wrong PodCIDR and is recreated
                $reuse = $owned
            }
            $saved = $old.metadata.annotations.'k2s.io/rename-original-unschedulable'
            $unschedulable = [bool]$old.spec.unschedulable
            # The marker is written just before the old Node is cordoned. On a Node that was itself a replacement it is a leftover of that rename.
            if ($null -ne $saved -and $old.spec.unschedulable -and -not $old.metadata.annotations.'k2s.io/rename-source-name') {
                $unschedulable = [bool]::Parse($saved)
            }
            $phase = 'cordoning nodes'
            Write-NodeRenameProgress "Cordoning old Node '$OldName'"
            Invoke-NodeRenameKubectl @('annotate', 'node', $OldName, "k2s.io/rename-original-unschedulable=$($unschedulable.ToString().ToLowerInvariant())", '--overwrite') | Out-Null
            Invoke-NodeRenameKubectl @('cordon', $OldName) | Out-Null
            if (-not ($reuse -and (Test-NodeRenameReady $replacement))) {
                $windows = $target.Kind -eq 'windows'
                if (-not $windows) {
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
                }
                if ($old.metadata.annotations.'k2s.io/rename-drained' -ne 'true') {
                    try {
                        $phase = 'restoring old kubelet identity for graceful drain'
                        Write-NodeRenameProgress "Restarting the kubelet under its old name '$OldName', so that the old Node can be drained"
                        if ($windows) { Restore-NodeRenameWindowsOldIdentity -OldName $OldName } else { Restore-NodeRenameOldIdentity -Node $target -OldName $OldName }
                        Invoke-NodeRenameKubectl @('wait', '--for=condition=Ready', "node/$OldName", "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
                        $phase = 'draining old node'
                        $drain = @('drain', $OldName, '--ignore-daemonsets', '--delete-emptydir-data')
                        if (-not (Test-NodeRenameOtherNodeAvailable -Nodes $nodes -Old $old -NewName $NewName)) {
                            # A disruption budget waits for a replacement pod elsewhere, which cannot appear, so the drain would only time out
                            Write-Log "[NodeRename] No other Ready $($target.OS) node can run the pods of $OldName, so PodDisruptionBudgets are not checked; pods are still shut down gracefully" -Console
                            $drain += '--disable-eviction'
                        }
                        Write-NodeRenameProgress "Draining old Node '$OldName' (pod-local emptyDir data is deleted, persistent volumes are kept)"
                        Invoke-NodeRenameKubectl ($drain + "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
                        $phase = 'stopping old workload containers'
                        if ($windows) {
                            Write-NodeRenameProgress 'Stopping kubeproxy, kubelet, the remaining containers and flanneld on this host'
                            Stop-NodeRenameWindowsServices
                        } else {
                            Write-NodeRenameProgress 'Stopping the kubelet and the remaining containers on the worker'
                            Stop-NodeRenameWorkloads -Node $target -Socket $socket
                        }
                    } finally {
                        # The old name is only pinned for the drain; the kubelet must follow the host name again whenever it starts next
                        if ($windows) { Restore-NodeRenameWindowsKubeletName }
                    }
                    Invoke-NodeRenameKubectl @('annotate', 'node', $OldName, 'k2s.io/rename-drained=true', '--overwrite') | Out-Null
                } else {
                    $phase = 'verifying previously drained worker'
                    Write-NodeRenameProgress "Old Node '$OldName' was already drained by an earlier attempt; the drain is not repeated"
                    Assert-NodeRenameNoWorkloads -Name $OldName
                    if ($windows) {
                        Restore-NodeRenameWindowsKubeletName
                        Stop-NodeRenameWindowsServices
                    } else {
                        Stop-NodeRenameWorkloads -Node $target -Socket $socket
                    }
                }
                if ($windows) {
                    $phase = 'updating local Windows identity settings'
                    Write-NodeRenameProgress "Setting '$NewName' in the kubeproxy and flanneld services and the kubelet flags file; moving the old kubelet certificates to a backup folder"
                    Set-NodeRenameWindowsIdentity -NewName $NewName
                    Backup-NodeRenameWindowsCredentials -NewName $NewName
                }
                $phase = 'creating replacement identity'
                if ($replacement -and -not $reuse) {
                    Write-NodeRenameProgress "Deleting the Node '$NewName' that the machine registered itself"
                    Invoke-NodeRenameObject -Object @{ apiVersion = 'v1'; kind = 'DeleteOptions'; preconditions = @{ uid = $replacement.metadata.uid } } -Arguments @('delete', "--raw=/api/v1/nodes/$NewName")
                    Invoke-NodeRenameKubectl @('wait', '--for=delete', "node/$NewName", "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
                    $replacement = $null
                }
                if (-not $replacement) {
                    Write-NodeRenameProgress "Creating Node '$NewName' with PodCIDR $($old.spec.podCIDR)"
                    Invoke-NodeRenameObject -Object (New-NodeRenameReplacement -OldNode $old -NewName $NewName -Unschedulable $unschedulable) -Arguments @('create')
                }
                if ($target.Kind -eq 'windows') {
                    $phase = 'starting local Windows services'
                    Write-NodeRenameProgress "Restarting containerd and starting flanneld, kubelet and kubeproxy on this host; the kubelet requests a certificate for '$NewName'"
                    Start-NodeRenameWindowsServices
                    $phase = 'waiting for the new kubelet certificate'
                    Wait-NodeRenameWindowsCertificate -NewName $NewName
                } else {
                    $phase = 'bootstrapping new kubelet certificates'
                    Write-NodeRenameProgress "Requesting a new kubelet certificate for '$NewName' on the worker"
                    Repair-NodeRenameCertificates -Node $target -NewName $NewName -Socket $socket
                }
                $phase = 'waiting for replacement readiness'
                Write-NodeRenameProgress "Waiting for Node '$NewName' to become Ready"
                Invoke-NodeRenameKubectl @('wait', '--for=condition=Ready', "node/$NewName", "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
            } else {
                Write-NodeRenameProgress "Node '$NewName' is already Ready; drain and certificate replacement were completed by an earlier attempt"
            }
            $ready = Invoke-NodeRenameKubectl @('get', 'node', $NewName, '-o', 'json') | ConvertFrom-Json
        }
        $phase = 'validating replacement identity'
        if (-not (Test-NodeRenameReady $ready) -or $ready.spec.podCIDR -ne $target.PodCIDR -or
            $ready.metadata.labels.'kubernetes.io/os' -ne $target.OS -or
            @(Get-NodeRenameInternalIPs -Node $ready) -notcontains $target.IpAddress) {
            throw '[NodeRename] Replacement readiness, address, OS or PodCIDR validation failed'
        }
        if ($old -and ($ready.spec.podCIDRs -join ',') -ne ($old.spec.podCIDRs -join ',')) {
            throw '[NodeRename] Replacement PodCIDRs do not match the old Node'
        }
        if ($target.Kind -eq 'windows') {
            if (-not (Test-NodeRenameCertificateSubject -Subject (Get-NodeRenameWindowsCertificateSubject) -NodeName $NewName)) {
                throw "[NodeRename] Kubelet client certificate does not identify system:node:$NewName in system:nodes"
            }
            Write-NodeRenameProgress "Node '$NewName' is Ready and its kubelet certificate is issued for system:node:$NewName"
            $phase = 'verifying local Windows services'
            Assert-NodeRenameWindowsServices
        } else {
            Assert-NodeRenameCertificate -Node $target -NewName $NewName
            Write-NodeRenameProgress "Node '$NewName' is Ready and its kubelet certificate is issued for system:node:$NewName"
            $phase = 'updating managed configuration and routes'
            Write-NodeRenameProgress "Updating cluster.json and switching the routes of this host from '$OldName' to '$NewName'"
            if ($old) { Stop-LinuxWorkerNode -NodeName $OldName }
            Update-NodeConfig -Name $target.Name -Updates @{ Name = $NewName }
            if ((Get-NodeConfig -NodeName $NewName).Name -ne $NewName) { throw '[NodeRename] Managed configuration update was not persisted' }
            Start-LinuxWorkerNode -NodeName $NewName -IpAddress $target.IpAddress
        }
        $routeBefore = $null
        if ($old) {
            $phase = 'retiring old identity'
            Write-NodeRenameProgress "Deleting old Node '$OldName'"
            $routeBefore = Get-NodeRenameControlPlaneRoute -PodCIDR $target.PodCIDR
            # Both Nodes hold the same pod network range. flannel on the other nodes would drop its route to that range
            # when a Node it manages disappears, so the old Node is taken out of flannel's management first.
            Invoke-NodeRenameKubectl @('annotate', 'node', $OldName, 'flannel.alpha.coreos.com/kube-subnet-manager-') | Out-Null
            Invoke-NodeRenameObject -Object @{ apiVersion = 'v1'; kind = 'DeleteOptions'; preconditions = @{ uid = $old.metadata.uid } } -Arguments @('delete', "--raw=/api/v1/nodes/$OldName")
            Invoke-NodeRenameKubectl @('wait', '--for=delete', "node/$OldName", "--timeout=$(Get-NodeRenameRemainingSeconds)s") | Out-Null
        }
        $phase = 'restoring scheduling'
        $saved = $ready.metadata.annotations.'k2s.io/rename-original-unschedulable'
        if ($null -ne $saved) { $unschedulable = [bool]::Parse($saved) }
        if ($null -eq $unschedulable) { throw '[NodeRename] The original scheduling state is unknown; the replacement stays cordoned' }
        $schedule = if ($unschedulable) { 'cordon' } else { 'uncordon' }
        Invoke-NodeRenameKubectl @($schedule, $NewName) | Out-Null
        if ($unschedulable) {
            Write-NodeRenameProgress "Node '$NewName' stays cordoned, as the old Node was before the rename"
        } else {
            Write-NodeRenameProgress "Node '$NewName' is schedulable again"
        }
        if ($target.Kind -eq 'linux') {
            # The rename is complete here, so a leftover backup file must not fail it
            try {
                Remove-NodeRenameFlagsBackup -Node $target
            } catch {
                Write-Log "[NodeRename] Could not remove /var/lib/kubelet/k2s-rename-kubeadm-flags.env on the worker; delete it manually: $($_.Exception.Message)" -Console
            }
        }
        $phase = 'removing rename bookkeeping'
        Invoke-NodeRenameKubectl @('annotate', 'node', $NewName, 'k2s.io/rename-source-uid-', 'k2s.io/rename-source-name-', 'k2s.io/rename-original-unschedulable-') | Out-Null
        if ($routeBefore) {
            # flannel reacts to a deleted Node within moments
            Start-Sleep -Seconds 3
            $routeAfter = Get-NodeRenameControlPlaneRoute -PodCIDR $target.PodCIDR
            if ($null -ne $routeAfter -and -not $routeAfter) {
                Write-Log "[NodeRename] WARNING: the control plane no longer has a route to the pod network $($target.PodCIDR) of $NewName. Pods on $NewName may be unreachable from it until flannel on the control plane node is restarted" -Console
            }
        }
        Write-Log (Format-NodeRenameSummary -OldName $OldName -NewName $NewName -Node $ready -Target $target -Unschedulable $unschedulable) -Console
    } catch {
        $reason = ($_.Exception.Message -replace '^\[NodeRename\] ', '').TrimEnd('.')
        $state = if ($phase -eq 'validating target') {
            'No changes were made.'
        } elseif ($phase -eq 'retiring old identity') {
            "Nodes may remain cordoned; the old Node '$OldName' may already be deleted. Inspect target services before retrying the same command."
        } elseif (-not $old -or $phase -in @('restoring scheduling', 'removing rename bookkeeping')) {
            "Node '$NewName' may remain cordoned; the old Node '$OldName' is already deleted. Retry the same command to finish."
        } else {
            "Nodes may remain cordoned; the old Node '$OldName' still exists. Inspect target services before retrying the same command."
        }
        throw "[NodeRename] Rename $OldName -> $NewName failed while ${phase}: $reason. $state"
    }
}

function Invoke-WorkerRenameCommand {
    Param([string] $OldName, [string] $NewName, [int] $TimeoutSeconds = 900, [switch] $Force, [switch] $EncodeStructuredOutput, [string] $MessageType)
    try {
        $env:KUBECONFIG = Join-Path (Get-KubePath) 'config'
        if (-not (Test-Path -LiteralPath $env:KUBECONFIG -PathType Leaf)) {
            throw '[NodeRename] The installation kubeconfig is missing'
        }
        Invoke-WorkerRename -OldName $OldName -NewName $NewName -TimeoutSeconds $TimeoutSeconds -Force:$Force
    } catch {
        $failure = $_.Exception.Message -replace '^\[NodeRename\] ', ''
        Write-Log "[NodeRename] $failure"
        if (-not $EncodeStructuredOutput) { throw }
        # The CLI turns this into its error output and a failing exit code
        Send-ToCli -MessageType $MessageType -Message @{ Error = (New-Error -Severity Error -Code 'node-rename-failed' -Message $failure) }
        return
    }
    if ($EncodeStructuredOutput) { Send-ToCli -MessageType $MessageType -Message @{ Error = $null } }
}

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\linux\common\LinuxWorkerNode.Common.ps1"
Initialize-LinuxWorkerScriptEnvironment -ShowLogs:$ShowLogs
Invoke-WorkerRenameCommand -OldName $OldName -NewName $NewName -TimeoutSeconds $TimeoutSeconds -Force:$Force `
    -EncodeStructuredOutput:$EncodeStructuredOutput -MessageType $MessageType
