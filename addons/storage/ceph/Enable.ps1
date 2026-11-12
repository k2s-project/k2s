# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables Ceph CSI storage provisioner addon

.DESCRIPTION
Always provisions a NEW Ceph cluster on a K2s Debian 13 node and deploys the Ceph CSI operator
components for CephFS (file) provisioning without the Rook operator. The Ceph cluster/bootstrap host
is identified by 'clusterHost.node' in ceph-config.json; its IP address and SSH user are resolved
from the K2s cluster descriptor (cluster.json). When 'clusterHost.node' matches the K2s control
plane node name, Ceph is installed on the kubemaster; otherwise on the named node. Additional OSD
hosts can be declared under 'osdHosts' and are prepared automatically. Only Debian 13 nodes are
supported.

.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.

.PARAMETER CephfsPool
CephFS data pool name (default: cephfs_data)

.PARAMETER SetupWindowsNode
If set, exports CephFS over SMB (Ceph mgr/smb) and deploys the SMB CSI driver so Windows pods can consume CephFS.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'CephFS data pool name')]
    [string] $CephfsPool = 'cephfs_data',
    [parameter(Mandatory = $false, HelpMessage = 'Export CephFS over SMB (Ceph mgr/smb) and deploy the SMB CSI driver so Windows pods can consume CephFS')]
    [switch] $SetupWindowsNode = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceding parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$script = $MyInvocation.MyCommand.Name
$infraModule = "$PSScriptRoot/../../../lib/modules/windows/infra/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/windows/cluster/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../../../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$validationModule = "$PSScriptRoot\..\storage-validation.module.psm1"
Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule, $validationModule

Initialize-Logging -ShowLogs:$ShowLogs

# get addon name from folder path
$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

# Validate no conflicting storage implementation is enabled
$conflictError = Test-ConflictingStorageImplementation -RequestedImplementation 'ceph'
if ($conflictError) {
    Write-Log "[$script] ERROR: $conflictError" -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-Error -Code 'storage-conflict' -Message $conflictError) }
        return
    }
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $AddonName })) -eq $true) {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message "Addon '$AddonName' is already enabled, nothing to do." 
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }
  Write-Log $err.Message -Error
  exit 1
}

$setupInfo = Get-SetupInfo

if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon '$AddonName' can only be enabled for 'k2s' setup type."  
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }
  Write-Log $err.Message -Error
  exit 1
}

Write-Log "[Ceph] Enabling Ceph storage addon" -Console


function Convert-ToYamlSingleQuoted {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  return "'" + ($Value -replace "'", "''") + "'"
}

function New-CephStructuredError {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  return (New-Error -Code 'addon-enable-failed' -Message $Message)
}

function Get-CephSmbManifestSourceDir {
  $candidateDirs = @(
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\smb\manifests')),
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'manifests\smb-shared'))
  )

  foreach ($candidateDir in $candidateDirs) {
    if (Test-Path -LiteralPath $candidateDir) {
      return $candidateDir
    }
  }

  return $null
}

function Get-CephSmbSidecarImageOverrides {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir
  )

  $containerToKey = @{
    'csi-provisioner'          = 'provisioner'
    'csi-attacher'             = 'attacher'
    'csi-resizer'              = 'resizer'
    'csi-snapshotter'          = 'snapshotter'
    'node-driver-registrar'    = 'registrar'
    'csi-node-driver-registrar' = 'registrar'
  }
  $images = @{}

  # Prefer Linux/base manifests for sidecar versions used by Ceph CSI controller/node pods.
  # Windows host-process manifests can carry '-hp' variants that are not valid for Linux workloads.
  $yamlFiles = Get-ChildItem -Path $SourceDir -Filter '*.yaml' -Recurse -File |
    Sort-Object -Property @{ Expression = { if ($_.FullName -like '*\base\*') { 0 } else { 1 } } }, FullName

  foreach ($yamlFile in $yamlFiles) {
    $currentContainerName = ''
    foreach ($line in (Get-Content -Path $yamlFile.FullName)) {
      $trimmedLine = $line.Trim()

      if ($trimmedLine -match '^\-\s*name:\s*(?<name>[^#\s]+)') {
        $currentContainerName = $matches['name'].Trim('"', "'")
        continue
      }

      if ([string]::IsNullOrWhiteSpace($currentContainerName)) {
        continue
      }

      if ($trimmedLine -match '^image:\s*(?<image>\S+)') {
        $imageKey = $containerToKey[$currentContainerName]
        if (-not [string]::IsNullOrWhiteSpace($imageKey) -and -not $images.ContainsKey($imageKey)) {
          $images[$imageKey] = $matches['image'].Trim('"', "'")
        }
        $currentContainerName = ''
      }
    }
  }

  if ($images.Count -eq 0) {
    throw "Failed to resolve any shared SMB sidecar images from '$SourceDir'."
  }

  return $images
}

function New-CephDriverImageSetConfigMapYaml {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Namespace,
    [Parameter(Mandatory = $true)]
    [string]$ConfigMapName,
    [Parameter(Mandatory = $true)]
    [hashtable]$ImageOverrides
  )

  $orderedKeys = @('provisioner', 'attacher', 'resizer', 'snapshotter', 'registrar')
  $dataLines = @(
    $orderedKeys |
      Where-Object { $ImageOverrides.ContainsKey($_) -and -not [string]::IsNullOrWhiteSpace($ImageOverrides[$_]) } |
      ForEach-Object { "  ${_}: " + (Convert-ToYamlSingleQuoted -Value $ImageOverrides[$_]) }
  )

  if ($dataLines.Count -eq 0) {
    throw 'No sidecar image override entries were produced for the ceph imageSet ConfigMap.'
  }

  return @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: $ConfigMapName
  namespace: $Namespace
data:
$($dataLines -join "`r`n")
"@
}

function New-CephSmbManifestWorkDir {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Namespace
  )

  $sourceDir = Get-CephSmbManifestSourceDir
  if ([string]::IsNullOrWhiteSpace($sourceDir)) {
    throw 'Shared SMB manifests were not found in either the sibling storage/smb addon or the exported Ceph fallback bundle.'
  }

  $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-smb-kustomize-" + [guid]::NewGuid().ToString())
  New-Item -Path $workDir -ItemType Directory -ErrorAction Stop | Out-Null
  Copy-Item -Path (Join-Path $sourceDir '*') -Destination $workDir -Recurse -Force

  $filesUsingStandaloneNamespace = @(
    'base\csi-smb-controller.yaml',
    'base\csi-smb-node.yaml',
    'base\rbac-csi-smb.yaml',
    'base\storage-classes\template_StorageClass.yaml',
    'windows\csi-smb-node-windows-hp.yaml'
  )

  foreach ($relativePath in $filesUsingStandaloneNamespace) {
    $fullPath = Join-Path $workDir $relativePath
    $content = Get-Content -Path $fullPath -Raw
    $content = $content -replace 'storage-smb', $Namespace
    Set-Content -Path $fullPath -Value $content -Encoding UTF8
  }

  $cephBaseKustomization = @"
# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - rbac-csi-smb.yaml
  - csi-smb-driver.yaml
  - csi-smb-controller.yaml
  - csi-smb-node.yaml
"@
  Set-Content -Path (Join-Path $workDir 'base\kustomization.yaml') -Value $cephBaseKustomization -Encoding UTF8

  return [pscustomobject]@{
    SourceDir = $sourceDir
    WorkDir   = $workDir
  }
}

function New-CephSmbHostShortcut {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ClusterHostIp,
    [Parameter(Mandatory = $true)]
    [string]$ShareName,
    [Parameter(Mandatory = $true)]
    [string]$SmbUser,
    [Parameter(Mandatory = $true)]
    [string]$SmbPassword,
    [Parameter(Mandatory = $true)]
    [string]$WinMountPath
  )

  $sharePath = "\\$ClusterHostIp\$ShareName"
  Write-Log "[CephSMB] Creating host shortcut '$WinMountPath' -> '$sharePath'" -Console

  # Step 1: Disconnect ALL existing Windows SMB sessions to this server.
  # Windows multiplexes all shares over a single authenticated session per server. Once any
  # prior connection (even anonymous/null) is open, subsequent 'net use' calls reuse that
  # session and silently ignore new credentials — causing every auth attempt to fail even
  # with correct credentials. Clean-slate disconnect avoids this session-reuse trap.
  Write-Log "[CephSMB] Disconnecting any existing SMB sessions to '$ClusterHostIp'"
  net use "\\$ClusterHostIp" /delete /y 2>&1 | Out-Null
  Get-SmbGlobalMapping -ErrorAction SilentlyContinue |
    Where-Object { $_.RemotePath -like "\\$ClusterHostIp\*" } |
    Remove-SmbGlobalMapping -Force -ErrorAction SilentlyContinue
  Get-SmbMapping -ErrorAction SilentlyContinue |
    Where-Object { $_.RemotePath -like "\\$ClusterHostIp\*" } |
    Remove-SmbMapping -Force -ErrorAction SilentlyContinue

  # Step 2: Cache credentials in Windows Credential Manager now, BEFORE authenticating.
  # This ensures Explorer can open the UNC path with the right creds on first access even
  # if the SmbGlobalMapping step below fails.
  cmdkey /add:$ClusterHostIp /user:$SmbUser /pass:$SmbPassword 2>&1 | Write-Log
  Write-Log "[CephSMB] Credentials cached for '$ClusterHostIp' in Windows Credential Manager" -Console

  # Step 3: Do NOT create a host-level SMB mapping here.
  # The SMB CSI node plugin creates and owns New-SmbGlobalMapping sessions itself for pod mounts.
  # Pre-establishing an extra mapping from the addon can trigger Windows error 1219 when CSI
  # resolves the username in a different form (for example 'smbuser' vs 'SERVER\smbuser').
  # Keep only the cached credential + symlink so host Explorer access remains convenient.

  if (Test-Path -LiteralPath $WinMountPath) {
    $existingItem = Get-Item -LiteralPath $WinMountPath -ErrorAction SilentlyContinue
    if ($null -ne $existingItem -and ($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      Remove-Item -LiteralPath $WinMountPath -Force -ErrorAction SilentlyContinue
    }
    else {
      Write-Log "[CephSMB] Host shortcut path '$WinMountPath' already exists and is not a symlink; leaving it unchanged." -Console
      return
    }
  }

  # New-Item -ItemType SymbolicLink validates UNC target existence and can fail before
  # credentials are fully applied. mklink creates the link without that upfront UNC check.
  $mklinkCmd = "mklink /D `"$WinMountPath`" `"$sharePath`""
  cmd /c $mklinkCmd 2>&1 | Write-Log
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to create host shortcut '$WinMountPath' with mklink (exit code $LASTEXITCODE)."
  }
  Write-Log "[CephSMB] Host shortcut ready: '$WinMountPath'" -Console
}

function Write-CephUsageForUser {
  param(
    [Parameter(Mandatory = $false)]
    [string]$CephfsFilesystem = '',
    [Parameter(Mandatory = $false)]
    [string]$CephfsPool = '',
    [Parameter(Mandatory = $false)]
    [string]$ClusterId = '',
    [Parameter(Mandatory = $false)]
    [string]$StorageClassName = 'ceph-cephfs',
    [Parameter(Mandatory = $false)]
    [string]$DashboardUrl = '',
    [Parameter(Mandatory = $false)]
    [string]$DashboardUser = '',
    [Parameter(Mandatory = $false)]
    [string]$DashboardPassword = ''
  )

  @"

                                        USAGE NOTES
(see
 https://docs.ceph.com/en/latest/):

 Inspect the provisioner workloads with:
     kubectl get pods -n $cephOperatorNamespace
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }

  if (-not [string]::IsNullOrWhiteSpace($DashboardUrl)) {
    # Parse the dashboard host/port so the remote-access hints can reference the concrete
    # node IP and port. The dashboard is served directly by ceph-mgr on the (host-only)
    # node IP, so it is reachable from the K2s Windows host but NOT from other machines
    # on the LAN without a port-forward/tunnel.
    $dashboardHostForForward = '172.19.1.100'
    $dashboardPortForForward = '8443'
    try {
      $parsedDashboardUri = [uri]$DashboardUrl
      if (-not [string]::IsNullOrWhiteSpace($parsedDashboardUri.Host)) { $dashboardHostForForward = $parsedDashboardUri.Host }
      if ($parsedDashboardUri.Port -gt 0) { $dashboardPortForForward = "$($parsedDashboardUri.Port)" }
    }
    catch {
      Write-Log "[Ceph] WARNING: Could not parse dashboard URL '$DashboardUrl' for port-forward hints; using defaults." -Console
    }

    @"

                                     CEPH DASHBOARD
 A new Ceph cluster was provisioned. The Ceph dashboard is available at:

     URL:      $DashboardUrl
     User:     $DashboardUser
     Password: $DashboardPassword

 Store these credentials securely and change the password after first login.

                                     PORT FORWARDING
 The dashboard runs on node $dashboardHostForForward`:$dashboardPortForForward (host-only K2s network). To open it
 via localhost on the K2s host, run this as Administrator:

     netsh interface portproxy add v4tov4 listenport=$dashboardPortForForward listenaddress=127.0.0.1 connectport=$dashboardPortForForward connectaddress=$dashboardHostForForward

 Then browse to: https://localhost:$dashboardPortForForward/
 List rules:  netsh interface portproxy show all
 Remove rule: netsh interface portproxy delete v4tov4 listenport=$dashboardPortForForward listenaddress=127.0.0.1

                                     CEPH CLI ACCESS
 On the Ceph host node you can access the Ceph CLI as follows.

 In case of multi-cluster or non-default config:

     sudo cephadm shell --fsid $ClusterId -c /etc/ceph/ceph.conf -k /etc/ceph/ceph.client.admin.keyring

 Or, if you are only running a single cluster on this host:

     sudo cephadm shell

 Cluster configuration is saved on the host under:

     /var/lib/ceph/$ClusterId/config

 Optionally, enable telemetry to help improve Ceph (see
 https://docs.ceph.com/en/latest/mgr/telemetry/):

     ceph telemetry on
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
  }
}

function Get-CephOperatorNamespace {
  param(
    [Parameter(Mandatory = $true)]
    [string]$OperatorManifestPath
  )

  if (-not (Test-Path $OperatorManifestPath)) {
    throw "Ceph operator manifest not found at '$OperatorManifestPath'"
  }

  $manifestContent = Get-Content -Path $OperatorManifestPath -Raw
  $namespacePattern = '(?ms)^kind:\s*Namespace\s*$.*?^metadata:\s*$.*?^\s*name:\s*(?<namespace>[A-Za-z0-9-]+)\s*$'
  $match = [regex]::Match($manifestContent, $namespacePattern)

  if (-not $match.Success) {
    throw "Failed to derive Ceph operator namespace from '$OperatorManifestPath'"
  }

  return $match.Groups['namespace'].Value
}

function Read-CephConnectionConfig {
  param (
    [pscustomobject]$Config
  )
  # The new-cluster script writes the connection values read back from the freshly provisioned
  # cluster (monitorEndpoints, cephKey, cephfsFilesystem, cephfsPool, clusterId, cephUser) into
  # $Config. Load them into script scope so the CSI secret, CephConnection and StorageClass point
  # at the real cluster. Defaults only cover the rare case where a value is absent.
  $script:cephUser = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephUser)) { "$($Config.cephUser)" } else { 'client.admin' }
  $script:clusterId = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.clusterId)) { "$($Config.clusterId)" } else { 'k2s-ceph' }
  $script:cephfsFilesystem = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephfsFilesystem)) { "$($Config.cephfsFilesystem)" } else { 'cephfs' }
  $script:storageClassName = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.storageClassName)) { "$($Config.storageClassName)" } else { 'ceph-cephfs' }
  $script:storageClassReclaimPolicy = if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.storageClassReclaimPolicy)) { "$($Config.storageClassReclaimPolicy)" } else { 'Delete' }

  if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephfsPool)) { $script:CephfsPool = "$($Config.cephfsPool)" }
  if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.monitorEndpoints)) { $script:MonitorEndpoints = "$($Config.monitorEndpoints)" }
  if ($Config -and -not [string]::IsNullOrWhiteSpace($Config.cephKey)) { $script:AdminKey = "$($Config.cephKey)".Trim() }
}

function Test-CephOsdHostsPreflight {
  param(
    [pscustomobject]$Config,
    [Parameter(Mandatory = $true)]
    [string]$ClusterHostNode,
    [Parameter(Mandatory = $true)]
    [string]$ControlPlaneNodeName
  )

  if ($null -eq $Config -or -not ($Config.PSObject.Properties.Name -contains 'osdHosts') -or $null -eq $Config.osdHosts) {
    return $null
  }

  $osdHosts = @($Config.osdHosts)
  if ($osdHosts.Count -eq 0) {
    return $null
  }

  foreach ($osdHostConfig in $osdHosts) {
    if ($null -eq $osdHostConfig) { continue }

    $osdNodeName = if ($osdHostConfig.PSObject.Properties.Name -contains 'node') { "$($osdHostConfig.node)".Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($osdNodeName)) {
      return "Each osdHosts entry must define a non-empty 'node' value."
    }

    $osdNodeOs = if ($osdHostConfig.PSObject.Properties.Name -contains 'os') { "$($osdHostConfig.os)".Trim().ToLowerInvariant() } else { 'linux' }
    if (-not [string]::IsNullOrWhiteSpace($osdNodeOs) -and $osdNodeOs -ne 'linux') {
      return "OSD host '$osdNodeName' has os '$osdNodeOs'. Only Linux OSD hosts are supported."
    }

    if ($osdNodeName -eq $ClusterHostNode) {
      continue
    }

    $targetNodeConfig = Get-NodeConfig -NodeName $osdNodeName
    if ($null -eq $targetNodeConfig) {
      return "OSD host '$osdNodeName' is not present in cluster.json. Add it first as an existing Hyper-V VM node."
    }

    $nodeType = if ($targetNodeConfig.PSObject.Properties.Name -contains 'NodeType') { "$($targetNodeConfig.NodeType)".Trim() } else { '' }
    if (-not [string]::Equals($nodeType, 'VM-EXISTING', [System.StringComparison]::OrdinalIgnoreCase)) {
      return "OSD host '$osdNodeName' has NodeType '$nodeType'. Ceph OSD provisioning supports only Hyper-V worker nodes (NodeType 'VM-EXISTING')."
    }
  }

  return $null
}

# When the CLI does not pass a -Config object, fall back to the addon config file
# so the documented 'edit ceph-config.json then enable' workflow works.
if ($null -eq $Config) {
  $cephConfigPath = "$PSScriptRoot\config\ceph-config.json"
  if (Test-Path $cephConfigPath) {
    Write-Log "[Ceph] Loading configuration from $cephConfigPath" -Console
    try {
      $Config = Get-Content -Path $cephConfigPath -Raw | ConvertFrom-Json
    }
    catch {
      Write-Log "[Ceph] ERROR: Failed to parse ceph-config.json: $($_.Exception.Message)" -Console -Error
      if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Failed to parse ceph-config.json") }
      }
      exit 1
    }
  }
}


$clusterHostNode = if ($Config -and ($Config.PSObject.Properties.Name -contains 'clusterHost') -and $null -ne $Config.clusterHost -and ($Config.clusterHost.PSObject.Properties.Name -contains 'node')) { "$($Config.clusterHost.node)".Trim() } else { '' }

if ([string]::IsNullOrWhiteSpace($clusterHostNode)) {
  Write-Log "[Ceph] ERROR: 'clusterHost.node' is required in ceph-config.json." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "'clusterHost.node' is required in ceph-config.json") }
  }
  exit 1
}

$controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
if ($clusterHostNode -eq $controlPlaneNodeName) {
  $clusterHostNodeIp = "$(Get-ConfiguredIPControlPlane)".Trim()
  $clusterHostNodeUser = "$(Get-DefaultUserNameControlPlane)".Trim()
  Write-Log "[Ceph] 'clusterHost.node' ('$clusterHostNode') is the K2s control plane node; the Ceph cluster will be installed on the kubemaster (IP $clusterHostNodeIp)." -Console
}
else {
  $targetNodeConfig = Get-NodeConfig -NodeName $clusterHostNode
  if ($null -eq $targetNodeConfig) {
    Write-Log "[Ceph] ERROR: Node '$clusterHostNode' was not found in cluster.json. 'clusterHost.node' must be the K2s control plane node name (e.g. '$controlPlaneNodeName') or the name of a worker node that is part of the K2s cluster." -Console -Error
    if ($EncodeStructuredOutput -eq $true) {
      Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Node '$clusterHostNode' not found in cluster.json") }
    }
    exit 1
  }
  $clusterHostNodeIp = "$($targetNodeConfig.IpAddress)".Trim()
  $clusterHostNodeUser = "$($targetNodeConfig.Username)".Trim()
  Write-Log "[Ceph] The Ceph cluster will be installed on node '$clusterHostNode' (IP $clusterHostNodeIp)." -Console
}

if ([string]::IsNullOrWhiteSpace($clusterHostNodeIp)) {
  Write-Log "[Ceph] ERROR: Could not resolve an IP address for node '$clusterHostNode'." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Could not resolve an IP address for node '$clusterHostNode'") }
  }
  exit 1
}
if ([string]::IsNullOrWhiteSpace($clusterHostNodeUser)) { $clusterHostNodeUser = 'remote' }

# The Ceph host node MUST run Debian 13. Detect the live distribution over SSH and reject anything else.
Write-Log "[Ceph] Validating that node '$clusterHostNode' ($clusterHostNodeIp) runs Debian 13" -Console
$installedDistribution = ''
try {
  $installedDistribution = (Get-InstalledDistribution -UserName $clusterHostNodeUser -IpAddress $clusterHostNodeIp).Trim().ToLowerInvariant()
}
catch {
  Write-Log "[Ceph] ERROR: Could not determine the OS distribution of node '$clusterHostNode' ($clusterHostNodeIp) over SSH: $($_.Exception.Message)" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Could not determine the OS distribution of node '$clusterHostNode'") }
  }
  exit 1
}

if ($installedDistribution -ne 'debian13') {
  Write-Log "[Ceph] ERROR: The Ceph host node '$clusterHostNode' must run Debian 13, but detected '$installedDistribution'. Only Debian 13 nodes are supported." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message "Ceph host node '$clusterHostNode' must run Debian 13 (detected '$installedDistribution')") }
  }
  exit 1
}
Write-Log "[Ceph] Node '$clusterHostNode' runs Debian 13" -Console

$osdHostsPreflightError = Test-CephOsdHostsPreflight -Config $Config -ClusterHostNode $clusterHostNode -ControlPlaneNodeName $controlPlaneNodeName
if (-not [string]::IsNullOrWhiteSpace($osdHostsPreflightError)) {
  Write-Log "[Ceph] ERROR: $osdHostsPreflightError" -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message $osdHostsPreflightError) }
  }
  exit 1
}
Write-Log '[Ceph] OSD host preflight validation passed.' -Console

# Always provision a fresh Ceph cluster on the target Debian 13 node before installing CSI.
$newClusterScript = "$PSScriptRoot\scripts\linux\debian\New-CephCluster.ps1"
if (-not (Test-Path $newClusterScript)) {
  Write-Log "[Ceph] ERROR: New Ceph cluster creation script not found at '$newClusterScript'." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'New Ceph cluster creation script not found') }
  }
  exit 1
}

Write-Log "[Ceph] Dispatching new Ceph cluster creation to '$newClusterScript' (node=$clusterHostNode, ip=$clusterHostNodeIp)" -Console
$clusterCreateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
& $newClusterScript -NodeIp $clusterHostNodeIp -Config $Config -ShowLogs:$ShowLogs
$clusterCreateExitCode = $LASTEXITCODE
$clusterCreateStopwatch.Stop()
Write-Log "[Ceph] Ceph cluster creation phase finished in $([math]::Round($clusterCreateStopwatch.Elapsed.TotalSeconds, 1))s (exit code $clusterCreateExitCode)" -Console
if ($clusterCreateExitCode -ne 0) {
  Write-Log "[Ceph] ERROR: New Ceph cluster creation failed (exit code $clusterCreateExitCode)." -Console -Error
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'New Ceph cluster creation failed') }
  }
  exit 1
}
Write-Log '[Ceph] New Ceph cluster created successfully; continuing with CSI installation' -Console

# The new-cluster script wrote the ACTUAL connection values read back from the freshly provisioned
# cluster (monitorEndpoints, cephKey, cephfsFilesystem, cephfsPool, clusterId, cephUser) into
# $Config. Load them so the CSI installation connects to the real cluster.
Read-CephConnectionConfig -Config $Config

# Apply Ceph CSI operator manifests (CRDs first, then RBAC/operator resources).
# The entire CSI installation is wrapped in a try/catch so any failure is reported and
# exits non-zero. Orphaned OSD virtual disks from a failed run are cleaned up at the start
# of the next enable by the OSD driver (a fresh cluster has zero OSDs, so pre-existing
# ceph-osd-*.vhdx disks are detached and deleted before provisioning).
$cephManifestsDir = "$PSScriptRoot\manifests"
$cephCrdsManifest = "$cephManifestsDir\crds\ceph-crd.yaml"
$cephOperatorManifest = "$cephManifestsDir\operator.yaml"
$cephOperatorNamespace = ''
try {
  $cephOperatorNamespace = Get-CephOperatorNamespace -OperatorManifestPath $cephOperatorManifest
  Write-Log "[Ceph] Using operator namespace '$cephOperatorNamespace' from manifest" -Console

  Write-Log "[Ceph] Applying Ceph CSI CRDs" -Console
  & kubectl apply --server-side -f "$cephCrdsManifest" 2>&1 | Write-Log
  if ($LASTEXITCODE -ne 0) { throw 'Failed to apply Ceph CRDs' }

  Write-Log "[Ceph] Waiting for Ceph CRDs to be established" -Console
  & kubectl wait --for=condition=Established crd/cephconnections.csi.ceph.io crd/clientprofiles.csi.ceph.io crd/clientprofilemappings.csi.ceph.io --timeout=120s 2>&1 | Write-Log
  if ($LASTEXITCODE -ne 0) { throw 'Ceph CRDs were not established in time' }

  Clear-KubectlDiscoveryCache

  # Wait for operator namespace to be fully gone if it is still terminating from a previous disable
  $nsStatus = kubectl get namespace $cephOperatorNamespace --ignore-not-found -o jsonpath='{.status.phase}' 2>$null
  if ($nsStatus -eq 'Terminating') {
    Write-Log "[Ceph] Namespace '$cephOperatorNamespace' is still terminating from a previous run. Waiting for it to be gone..." -Console
    $nsWaitSecs = 120
    $nsElapsed = 0
    while ($nsElapsed -lt $nsWaitSecs) {
      Start-Sleep -Seconds 3
      $nsElapsed += 3
      $nsCheck = kubectl get namespace $cephOperatorNamespace --ignore-not-found -o jsonpath='{.metadata.name}' 2>$null
      if ([string]::IsNullOrWhiteSpace($nsCheck)) {
        Write-Log "[Ceph] Namespace '$cephOperatorNamespace' is gone after ${nsElapsed}s" -Console
        break
      }
    }
    if ($nsElapsed -ge $nsWaitSecs) {
      throw "Namespace '$cephOperatorNamespace' is still terminating; cannot re-enable until it is fully gone"
    }
  }

  # Create a runtime kustomization workspace and inject values from addon config
  $kustomizationWorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("k2s-ceph-kustomize-" + [guid]::NewGuid().ToString())
  New-Item -Path $kustomizationWorkDir -ItemType Directory -ErrorAction Stop | Out-Null
  Copy-Item -Path (Join-Path $cephManifestsDir '*') -Destination $kustomizationWorkDir -Recurse -Force

  # Override ceph-csi-operator sidecar image defaults with versions from the SMB manifests
  # single source of truth to keep ceph and smb sidecars aligned.
  $driverImageSetConfigMapName = 'cephfs-smb-shared-images'
  $smbManifestSourceDir = Get-CephSmbManifestSourceDir
  if ([string]::IsNullOrWhiteSpace($smbManifestSourceDir)) {
    throw 'Shared SMB manifests were not found in either the sibling storage/smb addon or the exported Ceph fallback bundle.'
  }

  $smbSidecarImageOverrides = Get-CephSmbSidecarImageOverrides -SourceDir $smbManifestSourceDir
  $resolvedOverrideKeys = (($smbSidecarImageOverrides.Keys | Sort-Object) -join ', ')
  Write-Log "[Ceph] Resolved SMB sidecar image overrides from '$smbManifestSourceDir' (keys: $resolvedOverrideKeys)" -Console

  $driverImageSetConfigMapPath = Join-Path $kustomizationWorkDir 'cephfs-imageset-configmap.yaml'
  $driverImageSetConfigMapYaml = New-CephDriverImageSetConfigMapYaml -Namespace $cephOperatorNamespace -ConfigMapName $driverImageSetConfigMapName -ImageOverrides $smbSidecarImageOverrides
  Set-Content -Path $driverImageSetConfigMapPath -Value $driverImageSetConfigMapYaml -Encoding UTF8

  $kustomizationPath = Join-Path $kustomizationWorkDir 'kustomization.yaml'
  Add-Content -Path $kustomizationPath -Value "`r`n  - cephfs-imageset-configmap.yaml" -Encoding UTF8

  $monitorList = @()
  foreach ($monitor in ($MonitorEndpoints -split ',')) {
    $trimmed = $monitor.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $monitorList += $trimmed }
  }
  if ($monitorList.Count -eq 0) { throw 'No valid monitor endpoints resolved for CephConnection manifest' }

  $monitorYaml = (($monitorList | ForEach-Object { "    - " + (Convert-ToYamlSingleQuoted -Value $_) }) -join "`r`n")

  $cephConnectionYaml = @"
apiVersion: csi.ceph.io/v1
kind: CephConnection
metadata:
  name: ceph-connection
  namespace: $cephOperatorNamespace
spec:
  monitors:
$monitorYaml
"@
  Set-Content -Path (Join-Path $kustomizationWorkDir 'ceph-connection.yaml') -Value $cephConnectionYaml -Encoding UTF8

  Write-Log "[Ceph] Applying Ceph CSI RBAC and operator resources" -Console
  $kubectlOutput = & kubectl apply -k "$kustomizationWorkDir" 2>&1
  $kubectlOutput | ForEach-Object { Write-Log "[Ceph] kubectl: $_" }
  if ($LASTEXITCODE -ne 0) {
    $errorDetail = ($kubectlOutput | Where-Object { $_ -match 'Error|error|failed|invalid' }) -join '; '
    Write-Log "[Ceph] Kustomize workdir preserved for inspection: $kustomizationWorkDir" -Console
    throw "Failed to apply Ceph CSI RBAC/operator resources: $errorDetail"
  }

  Remove-Item -Path $kustomizationWorkDir -Recurse -Force -ErrorAction SilentlyContinue

  # Create secrets with Ceph credentials
  Write-Log "[Ceph] Creating Ceph credentials secrets" -Console
  $cephfsSecret = @"
apiVersion: v1
kind: Secret
metadata:
  name: ceph-secret
  namespace: $cephOperatorNamespace
type: Opaque
stringData:
  adminID: $cephUser
  adminKey: $AdminKey
  userID: $cephUser
  userKey: $AdminKey
"@
  $cephfsSecret | kubectl apply -f - 2>&1 | ForEach-Object { Write-Log "[Ceph] kubectl: $_" }
  if ($LASTEXITCODE -ne 0) { throw 'Failed to create Ceph credentials secrets' }
  Write-Log "[Ceph] Secrets created successfully" -Console

  # Create StorageClasses
  Write-Log "[Ceph] Creating StorageClasses" -Console
  $cephfsSC = @"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $script:storageClassName
provisioner: cephfs.csi.ceph.com
allowVolumeExpansion: true
reclaimPolicy: $script:storageClassReclaimPolicy
volumeBindingMode: Immediate
parameters:
  clusterID: storage
  fsName: $cephfsFilesystem
  pool: $CephfsPool
  csi.storage.k8s.io/provisioner-secret-name: ceph-secret
  csi.storage.k8s.io/provisioner-secret-namespace: $cephOperatorNamespace
  csi.storage.k8s.io/controller-expand-secret-name: ceph-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: $cephOperatorNamespace
  csi.storage.k8s.io/node-stage-secret-name: ceph-secret
  csi.storage.k8s.io/node-stage-secret-namespace: $cephOperatorNamespace
"@
  $cephfsSC | kubectl apply -f - 2>&1 | ForEach-Object { Write-Log "[Ceph] kubectl: $_" }
  if ($LASTEXITCODE -ne 0) { throw 'Failed to create StorageClasses' }
  Write-Log "[Ceph] StorageClasses created successfully" -Console

  # Wait for Ceph CSI workloads to become ready before reporting success.
  $allReady = $true
  $csiReadinessStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  Write-Log "[Ceph] Waiting for Ceph operator pod readiness" -Console
  $operatorReady = Wait-ForPodCondition -Condition Ready -Label 'control-plane=ceph-csi-op-controller-manager' -Namespace $cephOperatorNamespace -TimeoutSeconds 900
  $allReady = ($allReady -and $operatorReady)

  Write-Log "[Ceph] Waiting for CephFS CSI controller deployment to be created by operator" -Console
  $cephfsCtrlDeploymentName = 'cephfs.csi.ceph.com-ctrlplugin'
  $ctrlDeployTimeoutSeconds = 180
  $ctrlDeployElapsed = 0
  $ctrlDeployExists = $false
  while ($ctrlDeployElapsed -lt $ctrlDeployTimeoutSeconds) {
    $ctrlDeployResult = & kubectl get deployment $cephfsCtrlDeploymentName -n $cephOperatorNamespace --ignore-not-found -o name 2>$null
    if (-not [string]::IsNullOrWhiteSpace($ctrlDeployResult)) {
      $ctrlDeployExists = $true
      break
    }
    Start-Sleep -Seconds 3
    $ctrlDeployElapsed += 3
    if (($ctrlDeployElapsed % 30) -eq 0) {
      Write-Log "[Ceph] Still waiting for CephFS CSI controller deployment '$cephfsCtrlDeploymentName' to be created by operator (${ctrlDeployElapsed}s/${ctrlDeployTimeoutSeconds}s elapsed)" -Console
    }
  }

  if (-not $ctrlDeployExists) {
    $allReady = $false
    Write-Log "[Ceph] ERROR: CephFS CSI controller deployment '$cephfsCtrlDeploymentName' was not created by operator within ${ctrlDeployTimeoutSeconds}s" -Console -Error
    Write-Log "[Ceph] Driver state for troubleshooting:" -Console
    & kubectl get driver cephfs.csi.ceph.com -n $cephOperatorNamespace -o yaml 2>&1 | Write-Log
    Write-Log "[Ceph] Operator logs (last 120 lines):" -Console
    & kubectl logs -n $cephOperatorNamespace -l 'control-plane=ceph-csi-op-controller-manager' --tail=120 2>&1 | Write-Log
  }
  else {
    Write-Log "[Ceph] Waiting for CephFS CSI controller deployment availability" -Console
    & kubectl wait deployment/$cephfsCtrlDeploymentName -n $cephOperatorNamespace --for=condition=Available --timeout=900s 2>&1 | Write-Log
    $allReady = ($allReady -and ($LASTEXITCODE -eq 0))
  }

  Write-Log "[Ceph] Waiting for CephFS CSI nodeplugin pod readiness" -Console
  $cephfsNodeReady = Wait-ForPodCondition -Condition Ready -Label 'app.kubernetes.io/component=cephfs-nodeplugin,app.kubernetes.io/part-of=k2s-ceph-csi' -Namespace $cephOperatorNamespace -TimeoutSeconds 900
  $allReady = ($allReady -and $cephfsNodeReady)

  $csiReadinessStopwatch.Stop()
  Write-Log "[Ceph] Ceph CSI readiness phase finished in $([math]::Round($csiReadinessStopwatch.Elapsed.TotalSeconds, 1))s (allReady=$allReady)" -Console

  if (-not $allReady) {
    throw 'Ceph CSI pods did not become Ready within the timeout. Check kubectl get pods -A and pod logs for details.'
  }
}
catch {
  $csiErrMsg = $_.Exception.Message
  Write-Log "[Ceph] ERROR: $csiErrMsg" -Console -Error

  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message $csiErrMsg) }
  }
  exit 1
}

Write-Log "[Ceph] Ceph CSI pods are Ready" -Console

# Enable SMB access to CephFS for Windows worker node(s). The ceph-csi-operator only reconciles the
# Linux CephFS node plugin, and there is no Windows CephFS CSI node plugin. Windows pods therefore
# consume CephFS over SMB: Ceph's native mgr/smb module (cephadm-managed Samba) exports the CephFS
# volume as an SMB share and the SMB CSI driver provisions PVCs from it. Only run this for a k2s
# cluster that actually has a Windows node.
$smbStorageClassName = ''
if ($SetupWindowsNode -eq $true) {
  if ($setupInfo.LinuxOnly -eq $true) {
    Write-Log '[Ceph] setupWindowsNode flag was provided, but this is a Linux-only setup; skipping Windows Ceph SMB setup.' -Console
  }
  else {
    # Ceph SMB access for Windows pods.
    #
    # Windows pods cannot consume CephFS through the native cephfs.csi.ceph.com nodeplugin. Instead
    # the CephFS filesystem is exported over SMB using Ceph's built-in 'mgr/smb' module
    # (https://docs.ceph.com/en/latest/mgr/smb/): cephadm deploys managed Samba containers on the
    # existing Ceph cluster host that serve the CephFS volume as an SMB share. The SMB CSI driver
    # (smb.csi.k8s.io, reused from the storage/smb addon manifests) then provisions PVCs from that
    # share so both Windows and Linux pods can mount CephFS-backed volumes via a standard PVC.
    #
    # Order (per design): (1) configure the SMB CSI driver, then (2) configure the Ceph mgr/smb
    # cluster + share on the already-running Ceph cluster.

    $smbClusterId       = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and -not [string]::IsNullOrWhiteSpace($Config.smb.clusterId)) { "$($Config.smb.clusterId)" } else { 'k2ssmb' }
    $smbShareId         = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and -not [string]::IsNullOrWhiteSpace($Config.smb.shareId)) { "$($Config.smb.shareId)" } else { 'cephfs' }
    $smbShareName       = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and -not [string]::IsNullOrWhiteSpace($Config.smb.shareName)) { "$($Config.smb.shareName)" } else { $smbShareId }
    $smbStorageClassName = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and -not [string]::IsNullOrWhiteSpace($Config.smb.storageClassName)) { "$($Config.smb.storageClassName)" } else { 'ceph-smb' }
    $smbReclaimPolicy   = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and -not [string]::IsNullOrWhiteSpace($Config.smb.storageClassReclaimPolicy)) { "$($Config.smb.storageClassReclaimPolicy)" } else { 'Delete' }
    $smbPlacementLabel  = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and -not [string]::IsNullOrWhiteSpace($Config.smb.placementLabel)) { "$($Config.smb.placementLabel)" } else { 'smb' }
    $smbSubvolume       = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and -not [string]::IsNullOrWhiteSpace($Config.smb.subvolume)) { "$($Config.smb.subvolume)" } else { 'cross-os' }
    $smbSubvolumeSizeGb = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and $null -ne $Config.smb -and ($Config.smb.PSObject.Properties.Name -contains 'subvolumeSizeInGb') -and [int]$Config.smb.subvolumeSizeInGb -gt 0) { [int]$Config.smb.subvolumeSizeInGb } else { 500 }
    $smbNamespace       = 'storage-smb-ceph'
    $smbWinMountPath    = if ($Config -and $Config.PSObject.Properties.Name -contains 'smb' -and -not [string]::IsNullOrWhiteSpace($Config.smb.winMountPath)) { "$($Config.smb.winMountPath)" } else { 'C:\k8s-ceph-share' }

    # ---- Part 1: Configure the SMB CSI driver from the shared storage/smb manifest source ----
    Write-Log '[CephSMB] Deploying SMB CSI driver' -Console

    $smbNsExists = (Invoke-Kubectl -Params 'get', 'namespace', $smbNamespace, '--ignore-not-found', '--no-headers').Output
    if ([string]::IsNullOrWhiteSpace($smbNsExists)) {
      Write-Log "[CephSMB] Creating namespace '$smbNamespace'" -Console
      (Invoke-Kubectl -Params 'create', 'namespace', $smbNamespace).Output | Write-Log
    }

    $smbManifestWork = $null
    try {
      $smbManifestWork = New-CephSmbManifestWorkDir -Namespace $smbNamespace
    }
    catch {
      Write-Log "[CephSMB] ERROR: $($_.Exception.Message)" -Console -Error
      if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'SMB manifests missing for Ceph Windows setup') }
      }
      exit 1
    }

    $smbManifestsSrcDir = $smbManifestWork.WorkDir
    $smbWindowsDir = Join-Path $smbManifestsSrcDir 'windows'
    Write-Log "[CephSMB] Applying SMB CSI driver manifests from '$($smbManifestWork.SourceDir)' via runtime overlay '$smbWindowsDir' (namespace '$smbNamespace')" -Console
    $smbApply = Invoke-Kubectl -Params 'apply', '-k', $smbWindowsDir
    $smbApply.Output | Write-Log
    if (-not $smbApply.Success) {
      Write-Log '[CephSMB] ERROR: Failed to deploy SMB CSI driver manifests.' -Console -Error
      if ($null -ne $smbManifestWork) {
        Write-Log "[CephSMB] SMB kustomize workdir preserved for inspection: $($smbManifestWork.WorkDir)" -Console
      }
      if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'SMB CSI driver deployment failed') }
      }
      exit 1
    }

    Write-Log '[CephSMB] Waiting for SMB CSI controller and node pods to become Ready' -Console
    Wait-ForPodCondition -Condition Ready -Label 'app=csi-smb-controller' -Namespace $smbNamespace -TimeoutSeconds 900 | Out-Null
    Wait-ForPodCondition -Condition Ready -Label 'app=csi-smb-node'       -Namespace $smbNamespace -TimeoutSeconds 900 | Out-Null
    Wait-ForPodCondition -Condition Ready -Label 'app=csi-smb-node-win'   -Namespace $smbNamespace -TimeoutSeconds 900 | Out-Null
    Write-Log '[CephSMB] SMB CSI driver is Ready' -Console

    # ---- Part 2: Configure the Ceph mgr/smb cluster + share on the existing Ceph cluster ----
    Write-Log '[CephSMB] Configuring Ceph mgr/smb cluster and share on the existing Ceph cluster' -Console

    $newSmbClusterScript = "$PSScriptRoot\scripts\linux\debian\New-CephSmbCluster.ps1"
    if (-not (Test-Path $newSmbClusterScript)) {
      Write-Log "[CephSMB] ERROR: Ceph SMB cluster script not found at '$newSmbClusterScript'." -Console -Error
      if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'Ceph SMB cluster script missing') }
      }
      exit 1
    }

    $smbClusterResult = & $newSmbClusterScript -NodeIp $clusterHostNodeIp `
      -Config $Config `
      -CephfsVolume $script:cephfsFilesystem `
      -SmbClusterId $smbClusterId `
      -SmbShareId $smbShareId `
      -SmbShareName $smbShareName `
      -PlacementLabel $smbPlacementLabel `
      -CephfsSubvolume $smbSubvolume `
      -CephfsSubvolumeSizeInGb $smbSubvolumeSizeGb `
      -ShowLogs:$ShowLogs
    if ($LASTEXITCODE -ne 0 -or $null -eq $smbClusterResult) {
      Write-Log '[CephSMB] ERROR: Ceph mgr/smb cluster configuration failed.' -Console -Error
      if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = (New-CephStructuredError -Message 'Ceph mgr/smb cluster configuration failed') }
      }
      exit 1
    }
    Write-Log '[CephSMB] Ceph mgr/smb cluster and share configured successfully' -Console

    # Create (or update) the smbcreds Secret with the user the mgr/smb cluster was created for.
    Write-Log "[CephSMB] Creating 'smbcreds' Secret in namespace '$smbNamespace'" -Console
    $smbCredsYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: smbcreds
  namespace: $smbNamespace
type: Opaque
stringData:
  username: $($smbClusterResult.SmbUser)
  password: $($smbClusterResult.SmbPassword)
"@
    $smbCredsTemp = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-ceph-smbcreds-$([guid]::NewGuid().ToString()).yaml"
    Set-Content -Path $smbCredsTemp -Value $smbCredsYaml -Encoding utf8
    (Invoke-Kubectl -Params 'apply', '-f', $smbCredsTemp).Output | Write-Log
    Remove-Item -Path $smbCredsTemp -Force -ErrorAction SilentlyContinue

    # Generate the ceph-smb StorageClass from the SMB addon template. The Samba service runs on the
    # Ceph cluster host, so the SMB source is //<cephHostIp>/<shareName>. Keep the default volume
    # folder layout so each provisioned volume uses the SMB CSI driver's standard subdirectory naming
    # instead of the old namespace/name override.
    $templatePath = Join-Path $smbManifestsSrcDir 'base\storage-classes\template_StorageClass.yaml'
    $smbSource    = "//$clusterHostNodeIp/$smbShareName"
    $scContent = (Get-Content -Path $templatePath -Raw) `
      -replace 'SC_NAME',          $smbStorageClassName `
      -replace 'SC_SOURCE',        $smbSource `
      -replace 'SC_RECLAIM_POLICY',$smbReclaimPolicy `
      -replace '(?m)^# mount options.*\r?\nMOUNT_OPTIONS\s*$', ''
    $scTempFile = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-ceph-smb-sc-$([guid]::NewGuid().ToString()).yaml"
    Set-Content -Path $scTempFile -Value $scContent -Encoding utf8
    Write-Log "[CephSMB] Applying StorageClass '$smbStorageClassName' (source: $smbSource)" -Console
    (Invoke-Kubectl -Params 'apply', '-f', $scTempFile).Output | Write-Log
    Remove-Item -Path $scTempFile -Force -ErrorAction SilentlyContinue

    # Create a host-local convenience path to the Ceph SMB share (similar to the standalone SMB
    # addon UX) so users can browse share data from Windows Explorer without entering credentials
    # repeatedly.
    try {
      New-CephSmbHostShortcut -ClusterHostIp $clusterHostNodeIp `
                              -ShareName $smbShareName `
                              -SmbUser $smbClusterResult.SmbUser `
                              -SmbPassword $smbClusterResult.SmbPassword `
                              -WinMountPath $smbWinMountPath
      Set-AddonSetupJsonProperty -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' }) -PropertyName 'CephSmbWinMountPath' -PropertyValue $smbWinMountPath
      Set-AddonSetupJsonProperty -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' }) -PropertyName 'CephSmbSource' -PropertyValue "\\$clusterHostNodeIp\$smbShareName"
    }
    catch {
      Write-Log "[CephSMB] WARNING: Failed to create host shortcut '$smbWinMountPath': $($_.Exception.Message)" -Console
    }

    if ($null -ne $smbManifestWork -and (Test-Path -LiteralPath $smbManifestWork.WorkDir)) {
      Remove-Item -Path $smbManifestWork.WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "[CephSMB] Ceph SMB ready. Use StorageClass '$smbStorageClassName' for CephFS-backed volumes on Windows pods." -Console
  }
}
else {
  Write-Log '[Ceph] Skipping Ceph SMB setup (setupWindowsNode flag not set).' -Console
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' })

# Persist the cephadm cluster public key (read back from the freshly bootstrapped cluster) into the
# addon section of setup.json. It is required later to authorize additional OSD hosts for root SSH
# (prepare-ceph-osd-host.sh) when a new node is added and the ceph Update script runs.
$cephPublicKey = if ($Config -and ($Config.PSObject.Properties.Name -contains 'cephPublicKey')) { "$($Config.cephPublicKey)".Trim() } else { '' }
if (-not [string]::IsNullOrWhiteSpace($cephPublicKey)) {
  Set-AddonSetupJsonProperty -Addon ([pscustomobject] @{Name = $addonName; Implementation = 'ceph' }) -PropertyName 'CephPublicKey' -PropertyValue $cephPublicKey
  Write-Log '[Ceph] Stored cephadm cluster public key in setup.json for future OSD host preparation.' -Console
}

Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path "$PSScriptRoot\hooks" -Filter '*.ps1' | ForEach-Object { $_.FullName })

Write-Log "[Ceph] Addon enabled successfully" -Console

$dashboardUrl = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardUrl')) { "$($Config.dashboardUrl)" } else { '' }
$dashboardUser = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardUser')) { "$($Config.dashboardUser)" } else { '' }
$dashboardPassword = if ($Config -and ($Config.PSObject.Properties.Name -contains 'dashboardPassword')) { "$($Config.dashboardPassword)" } else { '' }

Write-CephUsageForUser -CephfsFilesystem $script:cephfsFilesystem `
                       -CephfsPool $script:CephfsPool `
                       -ClusterId $script:clusterId `
                       -StorageClassName $script:storageClassName `
                       -DashboardUrl $dashboardUrl `
                       -DashboardUser $dashboardUser `
                       -DashboardPassword $dashboardPassword

if ($EncodeStructuredOutput -eq $true) {
    $allStorageClasses = @($script:storageClassName)
    if (-not [string]::IsNullOrWhiteSpace($smbStorageClassName)) { $allStorageClasses += $smbStorageClassName }
    Send-ToCli -MessageType $MessageType -Message @{
        Error = $null
        Status = "Ceph CSI addon enabled successfully"
        AddonName = $addonName
      StorageClasses = $allStorageClasses
    }
}