# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$infraModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\k2s.infra.module.psm1"
$imageBackupModule = "$PSScriptRoot/../image/ImageBackup.module.psm1"
$pvBackupModule = "$PSScriptRoot/BackupPersistentVolumes.psm1"
$setupInfoModule = "$PSScriptRoot/../setupinfo/setupinfo.module.psm1"
$runningStateModule = "$PSScriptRoot/../runningstate/runningstate.module.psm1"

Import-Module $infraModule, $imageBackupModule, $pvBackupModule, $setupInfoModule, $runningStateModule

$processTools = @'

using System;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace Proc.Tools
{
  public static class exec
  {
	public static int runCommand(string executable, string args = "", string cwd = "", string verb = "runas") {

	  //* Create your Process
	  Process process = new Process();
	  process.StartInfo.FileName = executable;
	  process.StartInfo.UseShellExecute = false;
	  process.StartInfo.CreateNoWindow = true;
	  process.StartInfo.RedirectStandardOutput = true;
	  process.StartInfo.RedirectStandardError = true;
	  process.StartInfo.StandardOutputEncoding = System.Text.Encoding.GetEncoding("UTF-8");
	  AppDomain.CurrentDomain.ProcessExit += (a, b) => process.Kill();
	  Console.CancelKeyPress += (a, b) => process.Kill();

	  //* Optional process configuration
	  if (!String.IsNullOrEmpty(args)) { process.StartInfo.Arguments = args; }
	  if (!String.IsNullOrEmpty(cwd)) { process.StartInfo.WorkingDirectory = cwd; }
	  if (!String.IsNullOrEmpty(verb)) { process.StartInfo.Verb = verb; }

	  //* Set your output and error (asynchronous) handlers
	  process.OutputDataReceived += new DataReceivedEventHandler(OutputHandler);
	  process.ErrorDataReceived += new DataReceivedEventHandler(OutputHandler);

	  //* Start process and handlers
	  process.Start();
	  process.BeginOutputReadLine();
	  process.BeginErrorReadLine();
	  process.WaitForExit();

	  //* Return the commands exit code
	  return process.ExitCode;
	}
	static string CleanInput(string strIn)
	{
		// Replace invalid characters with empty strings.
		try
		{
			if (!string.IsNullOrEmpty(strIn))
				return Regex.Replace(strIn, @"[^\w\.@-d:]", " ",
								 RegexOptions.None, TimeSpan.FromSeconds(1.5));
			else return string.Empty;
		}
		// If we timeout when replacing invalid characters,
		// we should return Empty.
		catch (RegexMatchTimeoutException)
		{
			return String.Empty;
		}
	}
	public static void OutputHandler(object sendingProcess, DataReceivedEventArgs outLine) {
	  //Console.WriteLine(outLine.Data);
	  Console.WriteLine(CleanInput(outLine.Data));
	}
  }
}
'@

Add-Type -TypeDefinition $processTools -Language CSharp

$kubePath = Get-KubePath
$binPath = Get-KubeBinPath
$rootConfig = Get-RootConfigk2s
$productVersion = Get-ProductVersion
$controlPlaneName = Get-ConfigControlPlaneNodeHostname
$systemDriveLetter = Get-SystemDriveLetter
$logFilePath = Get-LogFilePath

$hooksDir = "$kubePath\LocalHooks"

function Get-YamlToolPath {
	param (
		[parameter(Mandatory = $true)]
		[string] $ToolName
	)
	$primaryPath = "$binPath\$ToolName"
	if (Test-Path -Path $primaryPath) {
		return $primaryPath
	}
	$fallbackPath = "$binPath\windowsnode\yaml\$ToolName"
	if (Test-Path -Path $fallbackPath) {
		Write-Log "Using fallback path for $ToolName : $fallbackPath"
		return $fallbackPath
	}
	throw "$ToolName not found at '$primaryPath' or '$fallbackPath'"
}

function Invoke-Cmd {
	param (
		[parameter(Mandatory = $true, HelpMessage = 'Executable to run')]
		[string] $Executable,
		[parameter(Mandatory = $false, HelpMessage = 'Arguments to pass to executable')]
		[string] $Arguments,
		[parameter(Mandatory = $false, HelpMessage = 'Working directory for executable')]
		[string] $WorkingDirectory,
		[parameter(Mandatory = $false, HelpMessage = 'Verb to use for executable')]
		[string] $Verb = 'runas'
	)

	Write-Log "Run command: $Executable $Arguments" -Console
	$rt = [Proc.Tools.exec]::runCommand($Executable, $Arguments, $WorkingDirectory, $Verb)
	if ( $rt -eq 0 ) {
		Write-Log 'Command successfully called'
		return $rt
	}
	else {
		Write-Log 'Error in calling command!'
		throw 'Error: Not possible to call command!'
	}
}

function Export-NotNamespacedResources {
	param (
		[parameter(Mandatory = $true, HelpMessage = 'Location where to install')]
		[string] $FolderOut,
		[Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
		[string] $ExePath
	)
	$jqExe = Get-YamlToolPath -ToolName 'jq.exe'
	$yqExe = Get-YamlToolPath -ToolName 'yq.exe'

	# get all the resources
	Write-Log "Export global (not namespaced) resources from existing cluster" -Console
	$resources = &$ExePath\kubectl.exe api-resources --verbs=list --namespaced=false 2>$null

	# read cluster configuration json
	$excludedresources = 'componentstatuses', 'nodes', 'csinodes'
	$eresources = $rootConfig.backup.excludedclusterresources
	if ( $eresources ) {
		$excludedresources = $eresources.Split(',')
	}

	# convert each line to array
	foreach ($item in $resources) {
		$entry = $item.split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
		if ( $entry[0] -ne 'NAME' ) {
			# check if resource makes sense
			if ($excludedresources -contains $entry[0]) { continue }
			# Write-Log  $entry
			# collect all resources
			$name = $entry[0]

			# check size of items
			$res1 = &$ExePath\kubectl.exe get $name -o json 2>$null
			$nr = $res1 | & $jqExe '.items | length'
			# if no items, export does not make sense
			Write-Log "Items in resource $name -> $nr"
			if ($nr -lt 1) { continue }

			# remove unwanted items
			$filter = 'del(.items[].status,
				.items[].metadata.creationTimestamp,
				.items[].metadata.resourceVersion,
				.items[].metadata.uid,
				.items[].metadata.selfLink,
				.items[].metadata.creationTimestamp,
				.items[].metadata.generation,
				.items[].metadata.ownerReferences,
				.items[].metadata.managedFields,
				.items[].metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
				.items[].spec.finalizers,
				.items[].spec.claimRef,
				.metadata.creationTimestamp,
				.metadata.resourceVersion,
				.metadata.uid,
				.metadata.selfLink,
				.metadata.creationTimestamp,
				.metadata.generation,
				.metadata.ownerReferences,
				.metadata.managedFields)'
			$filter = $filter -replace '\r*\n', ''
			$filter = $filter -replace '"', '\"'
			$res2 = &$ExePath\kubectl.exe get $name -o json 2>$null | & $jqExe $filter
			$res3 = $res2 | & $yqExe eval - -P
			$file = "$FolderOut\\$name.yaml"
			Write-Log " $name -> $file"
			$res3 | Out-File -FilePath $file
		}
	}
}

function Export-NamespacedResources {
	param (
		[parameter(Mandatory = $true, HelpMessage = 'Location where to install')]
		[string] $FolderOut,
		[Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
		[string] $ExePath
	)
	$jqExe = Get-YamlToolPath -ToolName 'jq.exe'
	$yqExe = Get-YamlToolPath -ToolName 'yq.exe'

	# get all the resources
	Write-Log "Export namespaced resources from existing cluster" -Console
	$resources = &$ExePath\kubectl.exe api-resources --verbs=list --namespaced=true 2>$null
	$namespaces = &$ExePath\kubectl.exe get ns --no-headers -o custom-columns=":metadata.name" 2>$null

	# get excluded namespaces
	# default namespaces are only the kubernetes ones, more shall be available in the default config file
	$excludednamespaces = 'kube-flannel', 'kube-node-lease', 'kube-public', 'kube-system', 'k2s-webhook'
	$enspaces = $rootConfig.backup.excludednamespaces
	if ( $enspaces ) {
		$excludednamespaces = $enspaces.Split(',')
	}
	# excluded resource list
	$excludednamespacedresources = @()
	$enamespacedres = $rootConfig.backup.excludednamespacedresources
	if ( $enamespacedres ) {
		$excludednamespacedresources = $enamespacedres.Split(',')
	}

	# iterate over all namespaces
	foreach ($namespace in $namespaces) {
		# check if namespace makes sense
		if ($excludednamespaces -contains $namespace) { continue }

		# create a folder
		$pathNamespace = New-Item "$FolderOut\\$namespace" -Type Directory
		Write-Log $pathNamespace

		# convert each line to array
		foreach ($item in $resources) {
			$entry = $item.split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
			if ( $entry[0] -ne 'NAME' ) {
				$name = $entry[0]
				# Write-Log $entry

				# check if resource needs to be excluded
				if ($excludednamespacedresources -contains $name) { continue }

				# check size of items
				$res1 = &$ExePath\kubectl.exe get $name -n $namespace -o json 2>$null
				$nr = $res1 | & $jqExe '.items | length'
				# if no items, export does not make sense
				Write-Log "Items in resource $name in namespace $namespace -> $nr"
				if ($nr -lt 1) { continue }

				# remove unwanted items
				$filter = 'del(.items[].status,
				.items[].metadata.creationTimestamp,
				.items[].metadata.resourceVersion,
				.items[].metadata.uid,
				.items[].metadata.selfLink,
				.items[].metadata.creationTimestamp,
				.items[].metadata.generation,
				.items[].metadata.ownerReferences,
				.items[].metadata.managedFields,
				.items[].metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
				.items[].spec.finalizers,
				.metadata.creationTimestamp,
				.metadata.resourceVersion,
				.metadata.uid,
				.metadata.selfLink,
				.metadata.creationTimestamp,
				.metadata.generation,
				.metadata.ownerReferences,
				.metadata.managedFields)'
				$filter = $filter -replace '\r*\n', ''
				$filter = $filter -replace '"', '\"'
				# remove unwanted items
				$res2 = &$ExePath\kubectl.exe get $name -n $namespace -o json 2>$null | & $jqExe $filter

				$res3 = $res2 | & $yqExe eval - -P
				$file = "$FolderOut\\$namespace\\$name.yaml"
				Write-Log " $name -> $file"
				$res3 | Out-File -FilePath $file
			}
		}
	}
}

function Import-NotNamespacedResources {
	param (
		[Parameter(Mandatory = $true, HelpMessage = 'Location where to get the not namespaced resources')]
		[string] $folderResources,
		[Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
		[string] $ExePath,
		[Parameter(Mandatory = $false, HelpMessage = 'If set to true, any error during resource import will cause the operation to fail immediately')]
		[bool] $ErrorOnFailure = $false,
		[Parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[bool] $ShowLogs = $false,
		[Parameter(Mandatory = $false, HelpMessage = 'Resource types (file base names) that are skipped here and restored later by the caller')]
		[string[]] $DeferredResourceTypes = @()
	)

    Write-Log "Import not namespaced resources from existing cluster"

    $errors = @()
    $warnings = @()

    if (-not (Test-Path $folderResources)) {
        Write-Log "No cluster-scoped resources to restore"
        return @{ Errors = @(); Warnings = @() }
    }

    # Define restoration order for cluster-scoped resources
    $orderedResourceTypes = @(
        'customresourcedefinitions',
        'clusterroles',
        'clusterrolebindings',
        'priorityclasses',
        'storageclasses',
        'ingressclasses',
        'volumesnapshotclasses',
        'mutatingwebhookconfigurations',
        'validatingwebhookconfigurations',
        'clusterissuers'  # cert-manager CRD-based resources
    )

    # Apply resources in order
    foreach ($resourceType in $orderedResourceTypes) {
        $file = Join-Path $folderResources "$resourceType.yaml"
        if ($DeferredResourceTypes -contains $resourceType) {
            if (Test-Path $file) {
                Write-Log "[Restore] Deferring cluster resource: $resourceType (applied after addon re-enablement)"
            }
            continue
        }
        if (Test-Path $file) {
            Write-Log "[Restore] Applying cluster resource: $resourceType"
            $output = & "$ExePath\kubectl.exe" apply --server-side --force-conflicts -f $file 2>&1
            $exitCode = $LASTEXITCODE

            if ($ShowLogs) { Write-Log $output }

            $hasError = ($exitCode -ne 0) -or
                        ($output -match "^error:") -or
                        ($output -match "Error from server")

            if ($hasError) {
                # Treat 'Error from server (Invalid)' as warning — e.g. addon CRDs with encoding issues
                # that will be properly recreated when the addon is re-enabled
                $isInvalidError = $output -match "Error from server \(Invalid\)"
                if ($isInvalidError) {
                    $msg = "[Restore] Warning: Some resources in $resourceType.yaml were invalid and skipped (will be recreated by addons)"
                    Write-Log $msg -Console
                    Write-Log $output
                    $warnings += $msg
                }
                else {
                    $msg = "Failed to apply cluster resource file $resourceType.yaml"
                    Write-Log $msg
                    Write-Log $output
                    $errors += $msg
                    if ($ErrorOnFailure) { throw $msg }
                }
            }
        }
    }

    # Apply remaining unordered resources
    Get-ChildItem -Path $folderResources -Filter *.yaml | ForEach-Object {
        if ($orderedResourceTypes -notcontains $_.BaseName -and $DeferredResourceTypes -notcontains $_.BaseName) {
            $file = $_.FullName
            Write-Log "[Restore] Applying cluster resource: $($_.BaseName)"
            $output = & "$ExePath\kubectl.exe" apply --server-side --force-conflicts -f $file 2>&1
            $exitCode = $LASTEXITCODE

            if ($ShowLogs) { Write-Log $output }

            $hasError = ($exitCode -ne 0) -or
                        ($output -match "^error:") -or
                        ($output -match "Error from server") -or
                        ($output -match "no matches for kind") -or
                        ($output -match "resource mapping not found")

            if ($hasError) {
                $isInvalidError = $output -match "Error from server \(Invalid\)"
                if ($isInvalidError) {
                    $msg = "[Restore] Warning: Some resources in $($_.Name) were invalid and skipped (will be recreated by addons)"
                    Write-Log $msg -Console
                    Write-Log $output
                    $warnings += $msg
                }
                else {
                    $msg = "Failed to apply cluster resource file $($_.Name)"
                    Write-Log $msg
                    Write-Log $output
                    $errors += $msg
                    if ($ErrorOnFailure) { throw $msg }
                }
            }
        }
    }

    return @{ Errors = $errors; Warnings = $warnings }
}

function Import-NamespacedResources {
	param (
		[Parameter(Mandatory = $true, HelpMessage = 'Location where to get the namespaced resources')]
		[string] $folderNamespaces,
		[Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
		[string] $ExePath,
		[Parameter(Mandatory = $false, HelpMessage = 'If set to true, any error during resource import will cause the operation to fail immediately')]
		[bool] $ErrorOnFailure = $false,
		[Parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[bool] $ShowLogs = $false
	)

    Write-Log "Import namespaced resources from existing cluster"

    $errors = @()
    $warnings = @()
    $webhookFailures = @()  # Track resources that failed due to missing webhooks

    if (-not (Test-Path $folderNamespaces)) {
        Write-Log "No namespaced resources to restore"
        return @{ Errors = @(); Warnings = @(); WebhookFailures = @() }
    }

    # Define restoration order within each namespace
    $orderedResourceTypes = @(
        'serviceaccounts',
        'secrets',
        'configmaps',
        'persistentvolumeclaims',
        'roles',
        'rolebindings',
        'services',
        'deployments',
        'statefulsets',
        'daemonsets',
        'jobs',
        'cronjobs',
        'pods',
        'ingresses',
        'certificates',
        'certificaterequests',
        'issuers'
    )

    Get-ChildItem -Path $folderNamespaces -Directory | ForEach-Object {
        $namespace = $_.Name
        Write-Log "Import namespace: $namespace"

        # Ensure namespace exists
        $nsCheck = & "$ExePath\kubectl.exe" get namespace $namespace 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  Namespace '$namespace' does not exist, creating it..."
            $nsCreate = & "$ExePath\kubectl.exe" create namespace $namespace 2>&1
            if ($LASTEXITCODE -ne 0) {
                $msg = "Failed to create namespace '$namespace': $nsCreate"
                Write-Log $msg
                $errors += $msg
                if ($ErrorOnFailure) { throw $msg }
                return
            }
            Write-Log "  Namespace '$namespace' created successfully"
        }

        # Apply resources in order
        foreach ($resourceType in $orderedResourceTypes) {
            $file = Join-Path $_.FullName "$resourceType.yaml"
            if (Test-Path $file) {
                Write-Log "[Restore] Applying $resourceType in namespace $namespace"
                $output = & "$ExePath\kubectl.exe" apply --server-side --force-conflicts -f $file -n $namespace 2>&1
                $exitCode = $LASTEXITCODE

                if ($ShowLogs) { Write-Log $output }

                $isWebhookError = $output -match "failed calling webhook" -or
                                  $output -match "webhook.*not found"

                $hasError = ($exitCode -ne 0) -or
                            ($output -match "^error:") -or
                            ($output -match "Error from server")

                if ($hasError) {
                    if ($isWebhookError) {
                        $msg = "⚠️  Webhook validation failed for $resourceType in namespace $namespace (addon may need to be re-enabled)"
                        Write-Log $msg
                        Write-Log $output
                        $webhookFailures += @{
                            Namespace = $namespace
                            ResourceType = $resourceType
                            File = $file
                        }
                        $warnings += $msg
                    }
                    else {
                        $msg = "Failed to apply $resourceType.yaml in namespace $namespace"
                        Write-Log $msg
                        Write-Log $output
                        $errors += $msg
                        if ($ErrorOnFailure) { throw $msg }
                    }
                }
            }
        }

        # Apply remaining unordered resources
        Get-ChildItem -Path $_.FullName -Filter *.yaml | ForEach-Object {
            if ($orderedResourceTypes -notcontains $_.BaseName) {
                $file = $_.FullName
                Write-Log "[Restore] Applying $($_.BaseName) in namespace $namespace"
                $output = & "$ExePath\kubectl.exe" apply --server-side --force-conflicts -f $file -n $namespace 2>&1
                $exitCode = $LASTEXITCODE

                if ($ShowLogs) { Write-Log $output }

                $hasError = ($exitCode -ne 0) -or
                            ($output -match "^error:") -or
                            ($output -match "Error from server")

                if ($hasError) {
                    $msg = "Failed to apply $($_.Name) in namespace $namespace"
                    Write-Log $msg
                    Write-Log $output
                    $errors += $msg
                    if ($ErrorOnFailure) { throw $msg }
                }
            }
        }
    }

    return @{ Errors = $errors; Warnings = $warnings; WebhookFailures = $webhookFailures }
}

function Invoke-RestoreKubectl {
	param (
		[Parameter(Mandatory = $true)]
		[string] $ExePath,
		[Parameter(Mandatory = $true)]
		[string[]] $Arguments
	)
	$output = & "$ExePath\kubectl.exe" @Arguments 2>&1
	$exitCode = $LASTEXITCODE
	# ToString() keeps each stderr line as plain text (Out-String would decorate the first one with PowerShell error details)
	$text = (@($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
	return [pscustomobject]@{ Output = $text; ExitCode = $exitCode }
}

<#
.SYNOPSIS
Restores backed-up ClusterIssuers once cert-manager is available again.
.DESCRIPTION
ClusterIssuers are validated by the fail-closed cert-manager admission webhook, so they cannot be applied
before addon re-enablement has installed cert-manager. Readiness is checked with the existing
Wait-ForCertManagerAvailable ('cmctl check api', which performs a dry-run Certificate create through the webhook).
Issuers are created, not applied: ClusterIssuers that already exist (e.g. created by the re-enabled addons of the
new version) are left unchanged, so only issuers lost during the upgrade are restored. This is idempotent.
Returns the list of error messages; it is empty when there is nothing to restore or the restore succeeded.
#>
function Restore-DeferredClusterIssuers {
	param (
		[Parameter(Mandatory = $true, HelpMessage = 'Location of the backed-up not namespaced resources')]
		[string] $folderResources,
		[Parameter(Mandatory = $true, HelpMessage = 'Directory containing kubectl.exe of the current cluster')]
		[string] $ExePath
	)

	$file = Join-Path $folderResources 'clusterissuers.yaml'
	if (-not (Test-Path $file)) {
		return @()
	}

	Write-Log '[Restore] Restoring deferred cluster resource: clusterissuers' -Console

	$webhook = Invoke-RestoreKubectl -ExePath $ExePath -Arguments @('get', 'deployment', 'cert-manager-webhook', '-n', 'cert-manager', '--ignore-not-found', '-o', 'name')
	if ($webhook.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($webhook.Output)) {
		return @("Backed-up ClusterIssuers were not restored: cert-manager is not installed after addon re-enablement. $($webhook.Output)".Trim())
	}

	$certManagerReady = $false
	try {
		$certManagerReady = (Wait-ForCertManagerAvailable) -eq $true
	}
	catch {
		Write-Log "[Restore] cert-manager readiness check failed: $_"
	}
	if (-not $certManagerReady) {
		return @('Backed-up ClusterIssuers were not restored: the cert-manager API/webhook did not become ready')
	}

	$result = Invoke-RestoreKubectl -ExePath $ExePath -Arguments @('create', '-f', $file)
	Write-Log $result.Output
	$outputLines = @($result.Output -split '\r?\n')
	$alreadyExisting = @($outputLines | Where-Object { $_ -match '^Error from server \(AlreadyExists\)' })
	$failures = @($outputLines | Where-Object { ($_ -match '^error:' -or $_ -match '^Error from server') -and $_ -notmatch '^Error from server \(AlreadyExists\)' })
	if ($failures.Count -gt 0 -or ($result.ExitCode -ne 0 -and $alreadyExisting.Count -eq 0)) {
		return @("Backed-up ClusterIssuers could not be restored: $($result.Output)")
	}
	foreach ($line in $alreadyExisting) {
		Write-Log "[Restore] Keeping existing ClusterIssuer: $line"
	}

	Write-Log '[Restore] Backed-up ClusterIssuers restored' -Console
	return @()
}





function Assert-UpgradeVersionIsValid {
	param (
		[parameter(Mandatory = $true, HelpMessage = 'Version installed')]
		[string] $VersionInstalled,
		[parameter(Mandatory = $true, HelpMessage = 'Version to be used')]
		[string] $VersionToBeUsed,
		[parameter(Mandatory = $false, HelpMessage = 'Force upgrade')]
		[switch] $Force = $false
	)
	Write-Log 'Asserting upgrade version is valid..'

	$VersionInstalled = $VersionInstalled.Trim()
	$VersionToBeUsed = $VersionToBeUsed.Trim()

	$versionRegex = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'

	if (-not ($VersionInstalled -match $versionRegex)) {
		Write-Log "The format of the currently installed version is invalid: current='$VersionInstalled', valid='1.22.333'"
		return $false
	}
	if (-not ($VersionToBeUsed -match $versionRegex)) {
		Write-Log "The format of the upgrade version is invalid: upgrade-version='$VersionToBeUsed', valid='1.22.333'"
		return $false
	}

	$currentVersion = [System.Version]::Parse($VersionInstalled)
	$nextVersion = [System.Version]::Parse($VersionToBeUsed)

	if ($nextVersion -le $currentVersion) {
		Write-Log "The upgrade version must be greater than the current version: current='$VersionInstalled', upgrade-version='$VersionToBeUsed'"
		return $false
	}

	if ($Force) {
		Write-Log "Force flag set - allowing upgrade from $VersionInstalled to $VersionToBeUsed" -Console
		return $true
	}

	if ($nextVersion.Major -gt $currentVersion.Major) {
		return $true
	}

	return $nextVersion.Major -eq $currentVersion.Major -and $nextVersion.Minor - $currentVersion.Minor -le 1
}

function Get-TempPath {
	# create temp path
	$temp = [System.IO.Path]::GetTempPath()
	[string] $name = [System.Guid]::NewGuid()
	$joined = (Join-Path $temp $name)
	$path = New-Item -ItemType Directory -Path $joined
	$path.FullName
}

function Export-ClusterResources {
	param (
		[Parameter(Mandatory = $true, HelpMessage = 'Skip move of resources during upgrade')]
		[switch]
		$SkipResources,
		[Parameter(Mandatory = $true, HelpMessage = 'Directory where to store resources')]
		[string]
		$PathResources,
		[Parameter(Mandatory = $true, HelpMessage = 'Directory where current cluster is installed')]
		[string]$ExePath
	)
	Write-Log 'Check if existing resources need to be exported'
	# takeover resources
	if ( -not $SkipResources ) {
		Write-Log "Existing resources will be exported to '$PathResources'"
		Write-Log "Directory '$PathResources'. Here all resources will be dumped"

		# export no namespaced resources
		$dir1 = Join-Path $PathResources 'NotNamespaced'
		$null = New-Item -ItemType Directory -Path $dir1
		Export-NotNamespacedResources -FolderOut $dir1 -ExePath $ExePath

		# export namespaced resources
		$dir2 = Join-Path $PathResources 'Namespaced'
		$null = New-Item -ItemType Directory -Path $dir2
		Export-NamespacedResources -FolderOut $dir2 -ExePath $ExePath
	}
}

function Remove-ExportedClusterResources {
	param (
		[Parameter(Mandatory = $false, HelpMessage = 'Path where resources are available')]
		[string]
		$PathResources,
		[Parameter(Mandatory = $false, HelpMessage = 'Delete resource files after upgrade')]
		[switch]
		$DeleteFiles = $false
	)
	# delete resources
	if ( $DeleteFiles ) {
		if ( $PathResources -and (Test-Path $PathResources) ) {
			Remove-Item $PathResources -Recurse
		}
	}   
}

function Enable-ClusterIsRunning {
	param (
		[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[switch] $ShowLogs = $false
	)
	Write-Log 'Check K2s cluster is running' -Console

	$setupInfo = Get-SetupInfo
	$clusterState = Get-RunningState -SetupName $setupInfo.Name

	if ($clusterState.IsRunning -ne $true) {
		$argsCall = 'start'
		if ( $ShowLogs ) { $argsCall += ' -o' }
		$installedK2sExe = "$(Get-ClusterInstalledFolder)\k2s.exe"
		if (-not (Test-Path $installedK2sExe)) {
			throw "Error: Installed k2s.exe not found at '$installedK2sExe'. Cannot start cluster before upgrade."
		}
		$rt = Invoke-Cmd -Executable $installedK2sExe -Arguments $argsCall
		if ( $rt -eq 0 ) {
			Write-Log 'Start call of cluster successfully called'
		}
		else {
			Write-Log 'Error in calling start on K2s!'
			throw 'Error: Not possible to start existing cluster!'
		}
	}
}

function Get-ClusterInstalledFolder {
	$installFolder = Get-ConfigInstallFolder
	if ( [string]::IsNullOrEmpty($installFolder) ) {
		# we assume it is the old default
		$installFolder = 'C:\k'
	}
	return $installFolder
}

function Get-ClusterCurrentVersion {
	$currentVersion = Get-ConfigProductVersion
	if ( [string]::IsNullOrEmpty($currentVersion) ) {
		# we assume it is the old default
		$currentVersion = '0.5'
	}
	return $currentVersion
}

function Assert-UpgradeOperation {
    param(
        [parameter(Mandatory = $false)]
        [switch] $Force = $false
    )

    $installFolder = Get-ClusterInstalledFolder
    $currentVersion = Get-ClusterCurrentVersion
    $nextVersion = $productVersion

    Write-Log "Preparing steps to upgrade from K2s version: $currentVersion ($installFolder) to K2s version: $nextVersion ($kubePath)" -Console

    # First check - folder paths MUST be different regardless of Force flag
	$localKubePath = Get-KubePath 
    if ($localKubePath -eq $installFolder) {
        throw 'Current cluster is available from same folder, upgrade makes no sense!'
    }

    # Second check - only k2s setup type is supported
    $K8sSetup = Get-ConfigSetupType
    if ($K8sSetup -ne 'k2s') {
        throw 'Upgrade only supported in the default variant!'
    }

    # Version validation - can be bypassed with Force flag
    $validUpgrade = Assert-UpgradeVersionIsValid -VersionInstalled $currentVersion -VersionToBeUsed $nextVersion -Force:$Force
    if (-not $validUpgrade) {
		throw "Upgrade not supported from $currentVersion to $nextVersion. Minor version increase must be consecutive unless upgrading to a newer major version!"
    }

    # if(!(Restart-ClusterIfBuildVersionMismatch -CurrentVersion $currentVersion -NextVersion $nextVersion -InstallFolder $installFolder -KubePath $kubePath)) {
    #     return $false
    # }

    Write-Log "Upgrade to the next minor version: $nextVersion"
    return $true
}

function Restart-ClusterIfBuildVersionMismatch {
	param (
		[string] $currentVersion,
		[string] $nextVersion,
		[string] $installFolder,
		[string] $kubePath
	)

	# Parse the version strings into major, minor, and patch components
	$currentVersionParsed = [System.Version]::Parse($currentVersion)
	$nextVersionParsed = [System.Version]::Parse($nextVersion)
	
	# Minor version is the same or increased by one
	if ($currentVersionParsed.Minor -eq $nextVersionParsed.Minor) {
		# If the patch version are different stop restart the cluster
		if ($currentVersionParsed.Build -ne $nextVersionParsed.Build) {
			Write-Log "Only build version mismatch: Current version is $currentVersion and next version is $nextVersion. Therefore only cluster restart is necessary." -Console
			RestartCluster -CurrentKubePath $installFolder -NextVersionKubePath $kubePath
			return $false
		}
		return $false
	}
	return $true
}

function RestartCluster {
	param (
		[string] $CurrentKubePath,
		[string] $NextVersionKubePath
	)
	$setupInfo = Get-SetupInfo
	$clusterState = Get-RunningState -SetupName $setupInfo.Name

	if ($clusterState.IsRunning -ne $true) {
		Write-Log 'Cluster is not running, no need to restart' -Console
		return
	}

	Write-Log 'Restarting the cluster..' -Console
	$currentExe = "$CurrentKubePath\k2s.exe"
	if (-not (Test-Path -Path $currentExe)) {
		Write-Log "K2s exe: '$currentExe' does not exist. Skipping stop." -Console
		return
	}
	   
	$stopArgsCall = 'stop'
	$rt = Invoke-Cmd -Executable $currentExe -Arguments $stopArgsCall
	if ( $rt -eq 0 ) {
		Write-Log 'Stop of cluster successfully called'  -Console
	} else {
		 throw 'Error: Not possible to stop existing cluster!'
	}

	$nextVersionExe = "$NextVersionKubePath\k2s.exe"
	if (-not (Test-Path -Path $nextVersionExe)) {
		Write-Log "K2s exe: '$nextVersionExe' does not exist. Skipping start." -Console
		return
	}
	   
	$startArgsCall = 'start'
	$rt = Invoke-Cmd -Executable $nextVersionExe -Arguments $startArgsCall
	if ( $rt -eq 0 ) {
		Write-Log 'Start of cluster successfully called'
	} else {
		throw 'Error: Not possible to start cluster!'
	}
}

function Invoke-ClusterUninstall {
	param (
		[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[switch] $ShowLogs = $false,
		[Parameter(Mandatory = $false, HelpMessage = 'Delete package files after upgrade')]
		[switch] $DeleteFiles = $false
	)
	Write-Log 'Uninstall existing cluster' -Console
	$installFolder = Get-ClusterInstalledFolder  
	$argsCall = 'uninstall'
	if ( $ShowLogs ) { $argsCall += ' -o' }
	if ( $DeleteFiles ) { $argsCall += ' -d' }
	Write-Log "Uninstall with arguments: $installFolder\k2s.exe $argsCall"
	$texe = "$installFolder\k2s.exe"
	# Check if the k2s exe exists
	if (-not (Test-Path -Path $texe)) {
		Write-Log "K2s exe: '$texe' does not exist. Skipping uninstallation." -Console
		return
	}
	$rt = Invoke-Cmd -Executable $texe -Arguments $argsCall
	if ( $rt -eq 0 ) {
		Write-Log 'Uninstall of cluster successfully called'
	}
	else {
		Write-Log 'Error in calling uninstall on K2s!'
		throw 'Error: Not possible to uninstall old version!'
	}
}

function Get-KubeBinPathGivenKubePath {
	param(
		[string] $KubePathLocal
	)    
	if (Test-Path "$KubePathLocal\bin\kube") {
		return "$KubePathLocal\bin\kube"
	}
	if (Test-Path "$KubePathLocal\bin\exe") {
		return "$KubePathLocal\bin\exe"
	}
	throw "Kube bin path not found in $KubePathLocal"
}

function Wait-ForAPIServerInGivenKubePath {
	param(
		[string] $KubePathLocal
	)
	$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
	$iteration = 0
	$kubeToolsPath = Get-KubeBinPathGivenKubePath -KubePathLocal $KubePathLocal
	while ($true) {
		$iteration++
		# try to apply the flannel resources
		$ErrorActionPreference = 'Continue'
		$result = $(echo yes | &"$kubeToolsPath\kubectl.exe" wait --timeout=60s --for=condition=Ready -n kube-system "pod/kube-apiserver-$($controlPlaneVMHostName.ToLower())" 2>&1)
		$ErrorActionPreference = 'Stop'
		if ($result -match 'condition met') {
			break;
		}
		if ($iteration -eq 10) {
			Write-Log $result -Error
			throw $result
		}
		Start-Sleep 2
	}
	if ($iteration -eq 1) {
		Write-Log 'API Server running, no waiting needed'
	}
	else {
		Write-Log 'API Server now running'
	}
}
function Invoke-ClusterInstall {
	param (
		[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[switch] $ShowLogs = $false,
		[parameter(Mandatory = $false, HelpMessage = 'Config file for setting up new cluster')]
		[string] $Config,
		[parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
		[string] $Proxy,
		[Parameter(Mandatory = $false, HelpMessage = 'Delete package files after upgrade')]
		[switch] $DeleteFiles = $false,
		[parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
		[string] $MasterVMMemory,
		[parameter(Mandatory = $false, HelpMessage = 'Enable dynamic memory for master VM')]
		[switch] $EnableDynamicMemory = $false,
		[parameter(Mandatory = $false, HelpMessage = 'Minimum memory for master VM when dynamic memory is enabled')]
		[string] $MasterVMMemoryMin,
		[parameter(Mandatory = $false, HelpMessage = 'Maximum memory for master VM when dynamic memory is enabled')]
		[string] $MasterVMMemoryMax,
		[parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
		[string] $MasterVMProcessorCount,
		[parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
		[string] $MasterDiskSize,
		[parameter(Mandatory = $false, HelpMessage = 'Path to install k2s from')]
		[string] $K2sPathToInstallFrom
	)
   
	Write-Log 'Install cluster with the new version' -Console

	# Refresh PATH for current session to avoid stale k2s entries
	$env:PATH = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
			[Environment]::GetEnvironmentVariable("Path", "User")

	Write-Log "Using k2sPath: $K2sPathToInstallFrom" -Console
	if ([string]::IsNullOrEmpty($K2sPathToInstallFrom)) {
		$K2sPathToInstallFrom =  Get-KubePath
	}
	# copy executable since else we get ACCESS DENIED
	$texe = "$K2sPathToInstallFrom\k2sx.exe"
	Copy-Item "$K2sPathToInstallFrom\k2s.exe" -Destination $texe -Force -PassThru

	# The K2S_SETUP_CONFIG_DIR override (set by 'k2s system upgrade') points to the setup
	# config dir of the OLD installation. It is only needed to analyze and uninstall the old
	# cluster, which is done by now. The NEW version must be installed with the configuration
	# of its own package, therefore the override is cleared BEFORE the new k2s.exe is
	# started - otherwise the child process would inherit it and write its setup.json to the
	# old location. The package's cfg/config.json is never modified.
	if ($env:K2S_SETUP_CONFIG_DIR) {
		Write-Log "[Upgrade] Clearing setup config dir override '$env:K2S_SETUP_CONFIG_DIR' of the old installation" -Console
		Remove-Item -Path 'Env:\K2S_SETUP_CONFIG_DIR' -ErrorAction SilentlyContinue
		$newSetupConfigDir = Update-SetupConfigDir
		Write-Log "[Upgrade] New installation will use setup config dir '$newSetupConfigDir'" -Console
	}

	# start new executable and do an install
	$argsCall = 'install'
	if ( $ShowLogs ) { $argsCall += ' -o' }
	if ( -not [string]::IsNullOrEmpty($Config) ) { $argsCall += " --config `"$Config`"" }
	if ( -not [string]::IsNullOrEmpty($Proxy) ) { $argsCall += " --proxy $Proxy" }
	if ( $DeleteFiles ) { $argsCall += ' -d' }
	$argsCall += ' --append-log'
	if ( -not [string]::IsNullOrEmpty($MasterVMProcessorCount) ) { $argsCall += " --master-cpus $MasterVMProcessorCount" }

	# Handle memory configuration
	if ( -not [string]::IsNullOrEmpty($MasterVMMemory) ) {
		$argsCall += " --master-memory $MasterVMMemory"
	}

	# Handle dynamic memory configuration
	if ( $EnableDynamicMemory ) {
		if ( -not [string]::IsNullOrEmpty($MasterVMMemoryMin) ) {
			$argsCall += " --master-memory-min $MasterVMMemoryMin"
		}
		if ( -not [string]::IsNullOrEmpty($MasterVMMemoryMax) ) {
			$argsCall += " --master-memory-max $MasterVMMemoryMax"
		}
	}

	if ( -not [string]::IsNullOrEmpty($MasterDiskSize) ) { $argsCall += " --master-disk $MasterDiskSize" }
	Write-Log "Install with arguments: $K2sPathToInstallFrom\k2s $argsCall"
	$rt = Invoke-Cmd -Executable $texe -Arguments $argsCall
	if ( $rt -eq 0 ) {
		Write-Log 'Install of cluster successfully called'
	}
	else {
		Write-Log 'Error in calling install on K2s!'
		# remove temporary executable
		if (Test-Path $texe) {
			Remove-Item $texe -verbose
		}
		throw 'Error: Not possible to install new version!'
	}

	# remove temporary executable
	if (Test-Path $texe) {
		Remove-Item $texe -verbose
	}
}

function Assert-YamlTools {
	param (
		[parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
		[string] $Proxy
	)
	Write-Log 'Check if existing yaml tools are available' -Console

	if ((Test-Path -Path "$binPath\jq.exe") -ne $true) {
		&$kubePath\smallsetup\windowsnode\downloader\DownloadYamlTools.ps1 -Proxy $Proxy -Deploy
		&$kubePath\smallsetup\windowsnode\publisher\PublishYamlTools.ps1
	}
}

function Get-LinuxVMCores {
	$cores = Get-VMProcessor $controlPlaneName
	return $cores.Count.ToString()
}

function Get-LinuxVMMemory {
	$memory = Get-VMMemory $controlPlaneName
	$memoryConfig = @{
		Startup = [math]::round($memory.Startup / 1GB, 2).ToString() + 'GB'
		DynamicMemoryEnabled = $memory.DynamicMemoryEnabled
	}

	if ($memory.DynamicMemoryEnabled) {
		$memoryConfig.Minimum = [math]::round($memory.Minimum / 1GB, 2).ToString() + 'GB'
		$memoryConfig.Maximum = [math]::round($memory.Maximum / 1GB, 2).ToString() + 'GB'
	}

	return $memoryConfig
}

function Get-LinuxVMStorageSize {
	$disksize = Get-VM $controlPlaneName | ForEach-Object { $Vm = $_; $_.HardDrives[0] } | ForEach-Object {
		$GetVhd = Get-VHD -Path $_.Path 
		[pscustomobject]@{
			Vm            = $Vm.Name
			Name          = $_.Name
			Type          = $GetVhd.VhdType
			ProvisionedGB = ($GetVhd.Size / 1GB)
			CommittedGB   = ($GetVhd.FileSize / 1GB)
		}
	}
	return $disksize.ProvisionedGB.ToString() + 'GB'
}

function Backup-LogFile {
	param (
		[parameter(Mandatory = $false, HelpMessage = 'Name of the backup file')]
		[string] $LogFile
	)  

	Write-Log "Backup log file to $LogFile" -Console
	
	$oldLogFile = "$($systemDriveLetter)$(Get-LogFilePathPart)"
	if (Test-Path -Path $oldLogFile) {
		Copy-Item $oldLogFile -Destination $LogFile
	}
}

function Restore-LogFile {
	param (
		[parameter(Mandatory = $false, HelpMessage = 'Name of the backup file')]
		[string] $LogFile
	)
	Write-Log "Restore log file $LogFile" -Console

	if (Test-Path -Path $LogFile) {
		$file = Split-Path $LogFile -Leaf
		$restore = Join-Path -Path (Get-ConfiguredLogDirectory) -ChildPath $file
		Copy-Item -Path $LogFile -Destination $restore
	}
}

function Get-ProductVersionGivenKubePath {
	param (
		[Parameter(Mandatory = $false)]
		[string]$KubePathLocal = $(throw 'KubePath not specified')        
	)
	return "$(Get-Content -Raw -Path "$KubePathLocal\VERSION")".Trim()
}


function Restore-MergeLogFiles {
	Write-Log "Merge all logs to $logFilePath" -Console
	$logRoot = Get-ConfiguredLogDirectory
	$merge = Join-Path -Path $logRoot -ChildPath 'k2supgrade.log'
	$intermediate = Join-Path -Path $logRoot -ChildPath 'k2s*.log'

	try {
		# Ensure UTF-8 even for legacy encodings
		$intermediateContent = Get-Content -Path $intermediate
		$logFileContent = Get-Content -Path $logFilePath
		$mergedContent = $intermediateContent + $logFileContent
		$mergedContent | Set-Content -Path $merge -Encoding utf8
	}
	catch {
		Write-Log 'An ERROR occurred in Restore-MergeLogFiles:' -Console
		Write-Log $_.ScriptStackTrace -Console
		Write-Log $_ -Console
		throw $_
	}
}

function Write-RefreshEnvVariablesGivenKubePath {
	param (
		[Parameter(Mandatory = $false)]
		[string]$KubePathLocal = $(throw 'KubePath not specified')        
	)
	Write-Log ' ' -Console
	Write-Log '   Update and or check PATH environment variable for proper usage:' -Console
	Write-Log ' ' -Console
	Write-Log "   Powershell: '$KubePathLocal\smallsetup\helpers\RefreshEnv.ps1'" -Console
	Write-Log "   Command Prompt: '$KubePathLocal\smallsetup\helpers\RefreshEnv.cmd'" -Console
	Write-Log '   Or open new shell' -Console
	Write-Log ' ' -Console
}

function Invoke-UpgradeBackupRestoreHooks {
	param (
		[parameter(Mandatory = $false)]
		[ValidateSet('Backup', 'Restore')]
		[string]$HookType = $(throw 'Hook type not specified'),
		[Parameter(Mandatory = $false)]
		[string]$BackupDir = $(throw 'Back-up directory not specified'),
		[parameter()]
		[string] $AdditionalHooksDir = '',
		[parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
		[switch] $ShowLogs = $false
	)

	$hooksFilter = "*.$HookType.ps1"

	Write-Log "Executing cluster resource hooks with hook type '$HookType'.."

	$executionCount = 0

	Get-ChildItem -Path $hooksDir -Filter $hooksFilter -Force -ErrorAction SilentlyContinue | ForEach-Object {
		Write-Log "  Executing '$($_.FullName)'.."
		& "$($_.FullName)" -BackupDir $BackupDir -ShowLogs:$ShowLogs
		$executionCount++
	}

	if ($AdditionalHooksDir -ne '') {
		Get-ChildItem -Path $AdditionalHooksDir -Filter $hooksFilter -Force -ErrorAction SilentlyContinue | ForEach-Object {
			Write-Log "  Executing '$($_.FullName)'.."
			& "$($_.FullName)" -BackupDir $BackupDir -ShowLogs:$ShowLogs
			$executionCount++
		}
	}

	if ($executionCount -eq 0) {
		Write-Log 'No back-up/restore hooks found.'
	}
}

function Backup-EffectiveInstallConfig {
	param(
		[Parameter(Mandatory = $true)]
		[string] $BackupDir
	)

	$setupConfigPath = Get-SetupConfigFilePath
	if (-not (Test-Path -LiteralPath $setupConfigPath -PathType Leaf)) {
		return ''
	}

	$setupConfig = Get-Content -LiteralPath $setupConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
	$snapshotProperty = $setupConfig.PSObject.Properties['EffectiveInstallConfigPath']
	if ($null -eq $snapshotProperty -or [string]::IsNullOrWhiteSpace([string]$snapshotProperty.Value)) {
		return ''
	}

	$sourcePath = [string]$snapshotProperty.Value
	if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
		Write-Log "[KubeletOverrides] Previous effective install configuration '$sourcePath' is missing; upgrade will continue without overrides." -Console
		return ''
	}

	$null = New-Item -ItemType Directory -Path $BackupDir -Force -ErrorAction Stop
	$targetPath = Join-Path $BackupDir 'effective-install-config.previous.json'
	$temporaryPath = Join-Path $BackupDir ".effective-install-config-$([guid]::NewGuid().ToString('N')).tmp"
	$sourceAcl = Get-Acl -LiteralPath $sourcePath -ErrorAction Stop
	$sourceStream = $null
	$targetStream = $null
	$promoted = $false
	try {
		try {
			$sourceStream = [System.IO.File]::Open($sourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
			$targetStream = New-Object System.IO.FileStream($temporaryPath, [System.IO.FileMode]::CreateNew, [System.Security.AccessControl.FileSystemRights]::FullControl, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough, $sourceAcl)
			$sourceStream.CopyTo($targetStream)
			$targetStream.Flush($true)
		}
		finally {
			if ($null -ne $targetStream) { $targetStream.Dispose() }
			if ($null -ne $sourceStream) { $sourceStream.Dispose() }
		}
		if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
			[System.IO.File]::Replace($temporaryPath, $targetPath, $null)
		}
		else {
			[System.IO.File]::Move($temporaryPath, $targetPath)
		}
		$promoted = $true
		return $targetPath
	}
	finally {
		if (-not $promoted -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
			Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
		}
	}
}

function Resolve-UpgradeInstallConfig {
	param(
		[string] $RequestedConfig,
		[string] $PreviousConfig,
		[switch] $Rollback
	)

	if ($Rollback) {
		return $PreviousConfig
	}
	if (-not [string]::IsNullOrWhiteSpace($RequestedConfig)) {
		return $RequestedConfig
	}
	return $PreviousConfig
}

function Remove-SetupConfigIfExisting {
	$setupConfigPath = Get-SetupConfigFilePath
	
	if (Test-Path $setupConfigPath) {
		Write-Log "Setup config still existing at '$setupConfigPath', deleting it.."
		Remove-Item -Path $setupConfigPath -Force | Out-Null
	}
}
function PrepareClusterUpgrade {
	param(
		[switch] $ShowProgress,
		[switch] $SkipResources,
		[switch] $SkipImages,
		[switch] $ShowLogs,
		[string] $Proxy,
		[string] $BackupDir,
		[switch] $Force,
		[string] $AdditionalHooksDir,
		[ref] $coresVM,
		[ref] $memoryVM,
		[ref] $storageVM,
		[ref] $enabledAddonsList,
		[ref] $hooksBackupPath,
		[ref] $logFilePathBeforeUninstall,
		[ref] $imagesBackupPath,
		[ref] $pvBackupPath
	)
	try {
		# start progress
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Gathering upgrade information...' -Id 1 -Status '0/10' -PercentComplete 0 -CurrentOperation 'Starting upgrade'
		}

		# check if cluster is installed
		$setupInfo = Get-SetupInfo
		if (!$($setupInfo.Name)) {
			$msg = 'No upgrade possible, since no previous version of K2s is installed.'
			Write-Progress -Activity $msg -Id 1 -Status '10/10' -PercentComplete 100 -CurrentOperation 'Upgrade successfully finished'
			Write-Log $msg -Console
			return $false
		}
		if ($setupInfo.Name -ne 'k2s') {
			throw "Upgrade is only available for 'k2s' setup"
		}

		# retrieve folder where current K2s package is located
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Checking if cluster is installed..' -Id 1 -Status '1/10' -PercentComplete 10 -CurrentOperation 'Cluster availability'
		}

		if(!(Assert-UpgradeOperation -Force:$Force))
		{
			return $false
		}

		# check cluster is running
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Checking cluster state..' -Id 1 -Status '2/10' -PercentComplete 20 -CurrentOperation 'Starting cluster, please wait..'
		}

		Enable-ClusterIsRunning -ShowLogs:$ShowLogs

		# capture enabled addons list before upgrade for post-upgrade notification
		$enabledAddonsList.Value = Get-EnabledAddons
		if ($enabledAddonsList.Value.Count -gt 0) {
			Write-Log "Captured $($enabledAddonsList.Value.Count) enabled addon(s) for post-upgrade notification" -Console
		}

		# keep current settings from cluster
		$coresVM.Value = Get-LinuxVMCores
		$memoryVM.Value = Get-LinuxVMMemory
		$storageVM.Value = Get-LinuxVMStorageSize

		# Log current VM settings
		$memoryInfo = "Cores: $($coresVM.Value), Memory: $($memoryVM.Value.Startup) GB"
		if ($memoryVM.Value.DynamicMemoryEnabled) {
			$memoryInfo += " (Dynamic Memory: Min=$($memoryVM.Value.Minimum), Max=$($memoryVM.Value.Maximum))"
		} else {
			$memoryInfo += " (Static Memory)"
		}
		$memoryInfo += ", Storage: $($storageVM.Value) GB"
		Write-Log "Current settings for the Linux VM: $memoryInfo" -Console

		# check for yaml tools
		Assert-YamlTools -Proxy $Proxy

		# export cluster resources
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Check if resources need to be exported..' -Id 1 -Status '3/10' -PercentComplete 30 -CurrentOperation 'Starting cluster, please wait..'
		}

		# kube tools folder changed from bin\exe to bin\kube
		$currentKubeToolsFolder = "$(Get-ClusterInstalledFolder)\bin\kube"
		if (!(Test-Path $currentKubeToolsFolder)) {
			$currentKubeToolsFolder = "$(Get-ClusterInstalledFolder)\bin\exe"
		}
		Export-ClusterResources -SkipResources:$SkipResources -PathResources $BackupDir -ExePath $currentKubeToolsFolder

		# Invoke backup hooks for cluster resources (e.g., SMB shares)
		$hooksBackupPath.Value = Join-Path $BackupDir 'hooks'
		Invoke-UpgradeBackupRestoreHooks -HookType Backup -BackupDir $hooksBackupPath.Value -ShowLogs:$ShowLogs -AdditionalHooksDir $AdditionalHooksDir

		# backup persistent volumes
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Backing up persistent volumes..' -Id 1 -Status '4/10' -PercentComplete 40 -CurrentOperation 'Backing up PVs, please wait..'
		}

		try {
			Write-Log "Starting PV backup process..." -Console
			$pvBackupPath.Value = Join-Path $BackupDir 'pv'
			$pvBackupResult = Backup-AllPersistentVolumes -ExportPath $pvBackupPath.Value
			
			if ($pvBackupResult) {
				$successCount = ($pvBackupResult.GetEnumerator() | Where-Object { $_.Value -eq $true }).Count
				Write-Log "PV backup completed: $successCount PV(s) backed up successfully" -Console
			} else {
				Write-Log "No persistent volumes found to backup" -Console
				$pvBackupPath.Value = ""  # No PVs to backup
			}
		}
		catch {
			Write-Log "Warning: PV backup failed - $_. Continuing with upgrade..." -Console
			$pvBackupPath.Value = ""  # Mark as failed
		}

		# backup user application images
		if ($SkipImages) {
			Write-Log "Skipping image backup as requested" -Console
			$imagesBackupPath.Value = ""  # Explicitly skipped
		} else {
			if ($ShowProgress -eq $true) {
				Write-Progress -Activity 'Backing up user application images..' -Id 1 -Status '4.5/10' -PercentComplete 45 -CurrentOperation 'Backing up images, please wait..'
			}
			
			try {
				Write-Log "Starting image backup process..." -Console
				$imagesBackupPath.Value = Join-Path $BackupDir 'images'

				# Resolve crictl from PATH (installed cluster's bin is still on PATH at upgrade time).
				$upgradeCrictlExe = Get-CrictlExePath
				$upgradeCrictlConfig = Join-Path (Split-Path $upgradeCrictlExe -Parent) 'crictl.yaml'
				Write-Log "[ImageBackup] Using crictl: $upgradeCrictlExe" -Console
				
				# Check disk space before proceeding
				$userImages = Get-K2sImageList -CrictlExePath $upgradeCrictlExe -CrictlConfigPath $upgradeCrictlConfig
				if ($userImages.Count -gt 0) {
					$hasSufficientSpace = Test-BackupDiskSpace -BackupDirectory $imagesBackupPath.Value -Images $userImages
					if (-not $hasSufficientSpace) {
						Write-Log "Warning: Insufficient disk space for image backup. Skipping image backup." -Console
					} else {
						Write-Log "Starting backup of $($userImages.Count) user images..." -Console
						$imageBackupResult = Backup-K2sImages -BackupDirectory $imagesBackupPath.Value -Images $userImages -CrictlExePath $upgradeCrictlExe -CrictlConfigPath $upgradeCrictlConfig
						
						if ($imageBackupResult.Success) {
							Write-Log "Image backup completed successfully" -Console
							Write-Log "Actually backed up: $($imageBackupResult.Images.Count) images" -Console
							Write-Log "Failed images: $($imageBackupResult.FailedImages.Count)" -Console
						} else {
							Write-Log "Image backup completed with some failures. Check backup logs for details." -Console
						}
					}
				} else {
					Write-Log "No user application images found to backup" -Console
					$imagesBackupPath.Value = ""  # No images to backup
				}
			}
			catch {
				Write-Log "Warning: Image backup failed - $_. Continuing with upgrade..." -Console
				$imagesBackupPath.Value = ""  # Mark as failed
			}
		}

		# backup log file
		$logFilePathBeforeUninstall.Value = Join-Path $BackupDir 'k2s-before-uninstall.log'
		Backup-LogFile -LogFile $logFilePathBeforeUninstall.Value
		return $true
	}
	catch {
		Write-Log 'An ERROR occurred:' -Console
		Write-Log $_.ScriptStackTrace -Console
		Write-Log $_ -Console
		throw $_
	}
}

function PerformClusterUpgrade {
	param(
		[switch] $ShowProgress,
		[switch] $DeleteFiles,
		[switch] $ShowLogs,
		[switch] $ExecuteHooks,
		[string] $K2sPathToInstallFrom,
		[string] $Config,
		[string] $Proxy,
		[string] $BackupDir,
		[string] $AdditionalHooksDir,
		[hashtable] $memoryVM,
		[string] $coresVM,
		[string] $storageVM,
		[System.Collections.ArrayList] $enabledAddonsList,
		[string] $hooksBackupPath,
		[string] $logFilePathBeforeUninstall,
		[string] $imagesBackupPath,
		[string] $pvBackupPath,
		[switch] $skipImages,
		[switch] $skipResources,
		[ref] $resourceRestoreErrors
	)
	try {
		# uninstall of old cluster
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Uninstall cluster..' -Id 1 -Status '5/10' -PercentComplete 50 -CurrentOperation 'Uninstalling cluster, please wait..'
		}
		Invoke-ClusterUninstall -ShowLogs:$ShowLogs -DeleteFiles:$DeleteFiles

		$logFilePath = Get-LogFilePath

		# ensure UTF-8 even for legacy encodings
		Get-Content $logFilePath -Encoding utf8 | Out-File $logFilePath -Encoding utf8

		# setup config might be still there if previous version stored the setup config in a different location
		Remove-SetupConfigIfExisting

		Start-Sleep -s 1

		# install of new cluster
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Install cluster..' -Id 1 -Status '6/10' -PercentComplete 60 -CurrentOperation 'Installing cluster, please wait..'
		}
		  # Check if K2sPathToInstallFrom is null or empty and assign kubePath if so.
		if ([string]::IsNullOrEmpty($K2sPathToInstallFrom)) {
			$K2sPathToInstallFrom =  Get-KubePath
		}

		# Prepare memory parameters for reinstall
		$installParams = @{
			K2sPathToInstallFrom = $K2sPathToInstallFrom
			ShowLogs = $ShowLogs
			Config = $Config
			Proxy = $Proxy
			DeleteFiles = $DeleteFiles
			MasterVMProcessorCount = $coresVM
			MasterDiskSize = $storageVM
		}

		# Add memory configuration
		if ($null -ne $memoryVM -and $memoryVM -is [hashtable]) {
			if (-not [string]::IsNullOrEmpty($memoryVM.Startup)) {
				$installParams.MasterVMMemory = $memoryVM.Startup
			}
			if ($memoryVM.DynamicMemoryEnabled -eq $true) {
				$installParams.EnableDynamicMemory = $true
				if (-not [string]::IsNullOrEmpty($memoryVM.Minimum)) {
					$installParams.MasterVMMemoryMin = $memoryVM.Minimum
				}
				if (-not [string]::IsNullOrEmpty($memoryVM.Maximum)) {
					$installParams.MasterVMMemoryMax = $memoryVM.Maximum
				}
			}
		} elseif (-not [string]::IsNullOrEmpty($memoryVM)) {
			# Legacy string format
			$installParams.MasterVMMemory = $memoryVM
		}

		Invoke-ClusterInstall @installParams
		Enable-ClusterIsRunning -ShowLogs:$ShowLogs
		Wait-ForAPIServerInGivenKubePath -KubePath $K2sPathToInstallFrom

		# restore user application images FIRST - before importing resources to avoid image pulls
		if (-not [string]::IsNullOrEmpty($imagesBackupPath) -and (Test-Path $imagesBackupPath)) {
			if ($ShowProgress -eq $true) {
				Write-Progress -Activity 'Restoring user application images..' -Id 1 -Status '6.5/10' -PercentComplete 65 -CurrentOperation 'Restoring images, please wait..'
			}
			
			try {
				Write-Log "Starting image restore process (before resource import to avoid image pulls)..." -Console
				$imageRestoreResult = Restore-K2sImages -BackupDirectory $imagesBackupPath
				
				if ($imageRestoreResult.Success) {
					Write-Log "Successfully restored $($imageRestoreResult.RestoredImages.Count) user application images" -Console
				} else {
					Write-Log "Image restore completed with some failures. Check restore logs for details." -Console
				}
				
				# Cleanup old backups (retain for 7 days by default)
				try {
					Remove-OldImageBackups -BackupDirectory (Split-Path $imagesBackupPath -Parent) -RetentionDays 7
				}
				catch {
					Write-Log "Warning: Failed to cleanup old image backups - $_" -Console
				}
			}
			catch {
				Write-Log "Warning: Image restore failed - $_. Images may be pulled manually during resource import." -Console
			}
		} else {
			Write-Log "No image backup found or images were skipped during backup" -Console
		}

		# Invoke restore hooks for cluster resources (e.g., SMB shares)
		if ($ExecuteHooks -eq $true) {
			Write-Log "Executing cluster resource restore hooks"
			Invoke-UpgradeBackupRestoreHooks -HookType Restore -BackupDir $hooksBackupPath -ShowLogs:$ShowLogs -AdditionalHooksDir $AdditionalHooksDir
		} else {
			Write-Log "Skipping restore hooks (rollback mode)"
		}

		# restore persistent volumes
		if (-not [string]::IsNullOrEmpty($pvBackupPath) -and (Test-Path $pvBackupPath)) {
			if ($ShowProgress -eq $true) {
				Write-Progress -Activity 'Restoring persistent volumes..' -Id 1 -Status '7/10' -PercentComplete 70 -CurrentOperation 'Restoring PVs, please wait..'
			}
			
			try {
				Write-Log "Starting PV restore process..." -Console
				$pvRestoreResult = Restore-AllPersistentVolumes -BackupPath $pvBackupPath -Force
				
				if ($pvRestoreResult) {
					$successCount = ($pvRestoreResult.GetEnumerator() | Where-Object { $_.Value -eq $true }).Count
					Write-Log "Successfully restored $successCount persistent volume(s)" -Console
				} else {
					Write-Log "No persistent volumes were restored" -Console
				}
			}
			catch {
				Write-Log "Warning: PV restore failed - $_. Continuing with upgrade..." -Console
			}
		} else {
			Write-Log "No PV backup found or PVs were skipped during backup" -Console
		}

		$kubeExeFolder = Get-KubeBinPathGivenKubePath -KubePathLocal $K2sPathToInstallFrom
		
		# import of resources - images are already restored, so no pulls needed
		if ($skipResources) {
			Write-Log 'Skipping resource import as requested' -Console
		} else {
			if ($ShowProgress -eq $true) {
				Write-Progress -Activity 'Apply not namespaced resources on cluster..' -Id 1 -Status '8/10' -PercentComplete 80 -CurrentOperation 'Apply not namespaced resources, please wait..'
			}
			# ClusterIssuers need the cert-manager webhook, which is installed later by addon re-enablement
			Import-NotNamespacedResources -folderResources (Join-Path $BackupDir 'NotNamespaced') -ExePath $kubeExeFolder -DeferredResourceTypes @('clusterissuers')
			
			if ($ShowProgress -eq $true) {
				Write-Progress -Activity 'Apply namespaced resources on cluster..' -Id 1 -Status '8.5/10' -PercentComplete 85 -CurrentOperation 'Apply namespaced resources, please wait..'
			}
			Import-NamespacedResources -folderNamespaces (Join-Path $BackupDir 'Namespaced') -ExePath $kubeExeFolder
		}

		# re-enable previously enabled addons
		$addonsReenabledSuccessfully = @()
		$addonsReenabledFailed = @()
		if ($null -ne $enabledAddonsList -and $enabledAddonsList.Count -gt 0) {
			if ($ShowProgress -eq $true) {
				Write-Progress -Activity 'Re-enabling previously enabled addons..' -Id 1 -Status '9/10' -PercentComplete 90 -CurrentOperation 'Re-enabling addons, please wait..'
			}
			Write-Log "Re-enabling $($enabledAddonsList.Count) previously enabled addon(s)..." -Console
			
			foreach ($addon in $enabledAddonsList) {
				$addonConfig = [pscustomobject]@{
					Name = $addon.Name
				}
				# Handle implementations if present
				if ($null -ne $addon.Implementations -and $addon.Implementations.Count -gt 0) {
					$addonConfig | Add-Member -MemberType NoteProperty -Name 'Implementation' -Value $addon.Implementations[0]
				}
				
				$addonDisplay = $addon.Name
				if ($null -ne $addon.Implementations -and $addon.Implementations.Count -gt 0) {
					$addonDisplay += " ($($addon.Implementations -join ', '))"
				}
				
				try {
					Enable-AddonFromConfig -Config $addonConfig
					$addonsReenabledSuccessfully += $addonDisplay
				}
				catch {
					Write-Log "Warning: Failed to re-enable addon '$addonDisplay': $_" -Console
					$addonsReenabledFailed += $addonDisplay
				}
			}
		}

		$restoreErrors = @()
		if (-not $skipResources) {
			try {
				$restoreErrors = @(Restore-DeferredClusterIssuers -folderResources (Join-Path $BackupDir 'NotNamespaced') -ExePath $kubeExeFolder)
			}
			catch {
				# a ClusterIssuer restore failure must not trigger an upgrade rollback
				$restoreErrors = @("Backed-up ClusterIssuers were not restored: $_")
			}
			foreach ($restoreError in $restoreErrors) {
				Write-Log "[Restore] ERROR: $restoreError" -Console
			}
		}
		if ($null -ne $resourceRestoreErrors) {
			$resourceRestoreErrors.Value = $restoreErrors
		}
		
		# show completion
		if ($ShowProgress -eq $true) {
			Write-Progress -Activity 'Gathering executed upgrade information..' -Id 1 -Status '10/10' -PercentComplete 100 -CurrentOperation 'Upgrade successfully finished'
		}

		# restore log files
		Restore-LogFile -LogFile $logFilePathBeforeUninstall

		if ($ExecuteHooks -eq $true) {
			# final message
			Write-Log "Upgraded successfully to K2s version: $(Get-ProductVersion) ($(Get-KubePath))" -Console

			# notify user about addon re-enablement results
			if ($addonsReenabledSuccessfully.Count -gt 0 -or $addonsReenabledFailed.Count -gt 0) {
				Write-Log '' -Console
				Write-Log '********************************************************************************************' -Console
				Write-Log '** ADDON RE-ENABLEMENT SUMMARY                                                            **' -Console
				Write-Log '********************************************************************************************' -Console
				
				if ($addonsReenabledSuccessfully.Count -gt 0) {
					Write-Log "** Successfully re-enabled $($addonsReenabledSuccessfully.Count) addon(s):" -Console
					foreach ($addonDisplay in $addonsReenabledSuccessfully) {
						Write-Log "**   + $addonDisplay" -Console
					}
				}
				
				if ($addonsReenabledFailed.Count -gt 0) {
					Write-Log "** Failed to re-enable $($addonsReenabledFailed.Count) addon(s):" -Console
					foreach ($addonDisplay in $addonsReenabledFailed) {
						Write-Log "**   - $addonDisplay" -Console
					}
					Write-Log '**                                                                                        **' -Console
					Write-Log '** To manually re-enable failed addon(s), run:                                           **' -Console
					Write-Log '**   k2s addons enable <addon-name>                                                       **' -Console
				}
				
				Write-Log '**                                                                                        **' -Console
				Write-Log '** NOTE: Addon data/persistence is NOT restored during upgrade.                          **' -Console
				Write-Log '** To backup/restore addon data, use:                                                     **' -Console
				Write-Log '**   k2s addons export / k2s addons import                                                **' -Console
				Write-Log '********************************************************************************************' -Console
			}
		} else {
			Write-Log "Rolled back to K2s version: $(Get-ProductVersionGivenKubePath -KubePathLocal $K2sPathToInstallFrom) ($K2sPathToInstallFrom)" -Console
		}

		if ($restoreErrors.Count -gt 0) {
			$clusterIssuersBackup = Join-Path (Join-Path $BackupDir 'NotNamespaced') 'clusterissuers.yaml'
			Write-Log '' -Console
			Write-Log '********************************************************************************************' -Console
			Write-Log '** RESOURCE RESTORE ERRORS                                                                **' -Console
			Write-Log '********************************************************************************************' -Console
			foreach ($restoreError in $restoreErrors) {
				Write-Log "**   - $restoreError" -Console
			}
			Write-Log "** The backup directory is kept: $BackupDir" -Console
			Write-Log '** After cert-manager is available, restore the missing backed-up ClusterIssuers with:' -Console
			Write-Log "**   kubectl create -f `"$clusterIssuersBackup`"" -Console
			Write-Log '********************************************************************************************' -Console
		}

		# info on env variables
		Write-RefreshEnvVariablesGivenKubePath -KubePathLocal $K2sPathToInstallFrom
	}
	catch {
		Write-Log 'An ERROR occurred:'
		Write-Log $_.ScriptStackTrace
		Write-Log $_
		throw $_
	}
}

function Invoke-ImageBackup {
	param(
		[Parameter(Mandatory = $true, HelpMessage = 'Directory to store backed up images')]
		[string] $BackupDirectory,

		[Parameter(Mandatory = $false, HelpMessage = 'Exclude addon images from backup')]
		[switch] $ExcludeAddonImages,

		[Parameter(Mandatory = $false, HelpMessage = 'Path to crictl executable')]
		[string] $CrictlExePath = '',

		[Parameter(Mandatory = $false, HelpMessage = 'Path to crictl config')]
		[string] $CrictlConfigPath = ''
	)

    Write-Log "Starting image backup..." -Console

    try {
        # Resolve crictl paths if not provided
        if ([string]::IsNullOrWhiteSpace($CrictlExePath)) {
            $CrictlExePath = Get-CrictlExePath
            $crictlDir = Split-Path $CrictlExePath -Parent
            $CrictlConfigPath = Join-Path $crictlDir 'crictl.yaml'
        }
        Write-Log "Using crictl from: $CrictlExePath" -Console

        # Get images based on filtering options
        # System images are already excluded by default
        # ExcludeAddonImages further filters out addon namespace images for system backup
        $images = Get-K2sImageList -ExcludeAddonImages:$ExcludeAddonImages -CrictlExePath $CrictlExePath -CrictlConfigPath $CrictlConfigPath

        if ($images.Count -eq 0) {
            Write-Log "No images found to backup" -Console
            return @{
                Success = $true
                Images = @()
                FailedImages = @()
                Message = "No images to backup"
            }
        }

        # Check disk space
        $hasSufficientSpace = Test-BackupDiskSpace -BackupDirectory $BackupDirectory -Images $images
        if (-not $hasSufficientSpace) {
            Write-Log "Warning: Insufficient disk space for image backup. Skipping." -Console
            return @{
                Success = $false
                Images = @()
                FailedImages = @()
                Error = "Insufficient disk space"
            }
        }

        # Perform backup
        $backupResult = Backup-K2sImages -BackupDirectory $BackupDirectory -Images $images -CrictlExePath $CrictlExePath -CrictlConfigPath $CrictlConfigPath

        return $backupResult
    }
    catch {
        Write-Log "Error during image backup: $_" -Console
        throw $_
    }
}

function Invoke-PVBackup {
	param(
		[Parameter(Mandatory = $true, HelpMessage = 'Directory where persistent volume backups will be stored')]
		[string] $BackupDirectory
	)

    Write-Log "Starting persistent volume backup..." -Console

    try {
		$excludeNames = @()
		$excludePVs = $rootConfig.backup.excludedAddonPersistentVolumes
		if ($excludePVs) {
			$excludeNames = $excludePVs.Split(',')
		}

        Write-Log "Excluding addon-managed PVs: $($excludeNames -join ', ')" -Console

        # Invoke the core backup function
        $backupResult = Backup-AllPersistentVolumes -ExportPath $BackupDirectory -ExcludeNames $excludeNames

        if ($backupResult) {
            $successCount = ($backupResult.GetEnumerator() | Where-Object { $_.Value -eq $true }).Count
            Write-Log "PV backup completed: $successCount PV(s) backed up successfully" -Console

            return @{
                Success = $true
                BackedUpCount = $successCount
                Details = $backupResult
            }
        }
        else {
            Write-Log "No persistent volumes found to backup" -Console
            return @{
                Success = $true
                BackedUpCount = 0
                Details = @{}
                Message = "No PVs to backup"
            }
        }
    }
    catch {
        Write-Log "Error during PV backup: $_" -Console
        throw $_
    }
}

function Invoke-PVRestore {
	param(
		[Parameter(Mandatory = $true, HelpMessage = 'Directory containing persistent volume backups')]
		[string] $BackupDirectory,

		[Parameter(Mandatory = $false, HelpMessage = 'Force restore even if conflicts detected')]
		[switch] $Force,

		[Parameter(Mandatory = $false, HelpMessage = 'Fail immediately on any restore error')]
		[switch] $ErrorOnFailure
	)

    Write-Log "Starting persistent volume restore..." -Console

    try {
        # Check if PV backup directory exists
        if (-not (Test-Path $BackupDirectory)) {
            Write-Log "No PV backup directory found at: $BackupDirectory" -Console
            return @{
                Success = $true
                RestoredCount = 0
                Details = @{}
                Message = "No PV backups to restore"
            }
        }

        # Invoke the core restore function
        $restoreResult = Restore-AllPersistentVolumes -BackupPath $BackupDirectory -Force:$Force

        if ($restoreResult) {
            $successCount = ($restoreResult.GetEnumerator() | Where-Object { $_.Value -eq $true }).Count
            $failCount = ($restoreResult.GetEnumerator() | Where-Object { $_.Value -eq $false }).Count
            Write-Log "PV restore completed: $successCount PV(s) restored successfully, $failCount failed" -Console

            if ($ErrorOnFailure -and $failCount -gt 0) {
                throw "PV restore failed: $failCount PV(s) could not be restored"
            }

            return @{
                Success = ($failCount -eq 0)
                RestoredCount = $successCount
                FailedCount = $failCount
                Details = $restoreResult
            }
        }
        else {
            Write-Log "No persistent volumes found to restore" -Console
            return @{
                Success = $true
                RestoredCount = 0
                FailedCount = 0
                Details = @{}
                Message = "No PVs to restore"
            }
        }
    }
    catch {
        Write-Log "Error during PV restore: $_" -Console
        throw $_
    }
}

function Invoke-ImageRestore {
    param(
        [Parameter(Mandatory = $true, HelpMessage = 'Directory containing backed up images')]
        [string] $BackupDirectory,

        [Parameter(Mandatory = $false, HelpMessage = 'Fail immediately on any restore error')]
        [switch] $ErrorOnFailure
    )

    Write-Log "Starting image restore..." -Console

    try {
        # Check if image backup directory exists
        if (-not (Test-Path $BackupDirectory)) {
            Write-Log "No image backup directory found at: $BackupDirectory" -Console
            return @{
                Success = $true
                RestoredImages = @()
                FailedImages = @()
                Message = "No image backups to restore"
            }
        }

        # Check for manifest (it's created as manifest.json by Backup-K2sImages)
        $manifestPath = Join-Path $BackupDirectory "manifest.json"
        if (-not (Test-Path $manifestPath)) {
            Write-Log "No image manifest found at: $manifestPath" -Console
            return @{
                Success = $true
                RestoredImages = @()
                FailedImages = @()
                Message = "No image manifest to restore"
            }
        }

        Write-Log "Found image manifest at: $manifestPath" -Console

        # Perform restore
        $restoreResult = Restore-K2sImages -BackupDirectory $BackupDirectory -ManifestPath $manifestPath

        if ($restoreResult.RestoredImages.Count -gt 0) {
            Write-Log "Successfully restored $($restoreResult.RestoredImages.Count) image(s)" -Console
        }

        if ($restoreResult.FailedImages.Count -gt 0) {
            Write-Log "Warning: Failed to restore $($restoreResult.FailedImages.Count) image(s)" -Console

            if ($ErrorOnFailure) {
                throw "Image restore failed: $($restoreResult.FailedImages.Count) image(s) could not be restored"
            }
        }

        return $restoreResult
    }
    catch {
        Write-Log "Error during image restore: $_" -Console
        throw $_
    }
}


Export-ModuleMember -Function Assert-UpgradeOperation, Enable-ClusterIsRunning, Assert-YamlTools, Export-ClusterResources, `
    Invoke-ClusterUninstall, Invoke-ClusterInstall, Import-NotNamespacedResources, Import-NamespacedResources, Remove-ExportedClusterResources, `
    Get-LinuxVMCores, Get-LinuxVMMemory, Get-LinuxVMStorageSize, Get-ClusterInstalledFolder, Backup-LogFile, Restore-LogFile, Restore-MergeLogFiles, `
    Invoke-UpgradeBackupRestoreHooks, Backup-EffectiveInstallConfig, Resolve-UpgradeInstallConfig, Remove-SetupConfigIfExisting, Get-TempPath, Wait-ForAPIServerInGivenKubePath, Get-KubeBinPathGivenKubePath, `
    Write-RefreshEnvVariablesGivenKubePath, Get-ProductVersionGivenKubePath, PrepareClusterUpgrade, PerformClusterUpgrade, Invoke-ImageBackup, Invoke-PVBackup, `
    Invoke-ImageRestore, Invoke-PVRestore
