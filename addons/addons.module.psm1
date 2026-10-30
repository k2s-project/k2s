# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$infraModule = "$PSScriptRoot\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$pathModule = "$PSScriptRoot\..\lib\modules\windows\infra\k2s.infra.module\path\path.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$nodeModule = "$PSScriptRoot/../lib/modules/windows/node/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $pathModule

$ConfigKey_EnabledAddons = 'EnabledAddons'
$hooksDir = "$PSScriptRoot\hooks"
$backupFileName = 'backup_addons.json'
$cmctlExe = "$(Get-KubeBinPath)\cmctl.exe"

function Get-FileName {
	param (
		[Parameter(Mandatory = $false)]
		[string]
		$FilePath = $(throw 'FilePath not specified')
	)
	return [System.IO.Path]::GetFileName($FilePath)
}

function Invoke-Script {
	param (
		[parameter(Mandatory = $false)]
		[string] $FilePath = $(throw 'FilePath not specified')
	)
	if ((Test-Path $FilePath) -ne $true) {
		throw "Path to '$FilePath' not existing"
	}
	& $FilePath
}

function Get-AddonsConfig {
	return (Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key $ConfigKey_EnabledAddons)
}

function Get-ScriptRoot {
	return $PSScriptRoot
}

function Enable-AddonFromConfig {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Config = $(throw 'Config object not specified'),
		[Parameter(Mandatory = $false)]
		[string] $Root = $null
	)
	if ($null -eq $Config.Name) {
		Write-Warning "Invalid addon config '$Config' found, skipping it."
		return
	}
	# Check if root is null or empty and assign Get-ScriptRoot if so
	if ([string]::IsNullOrEmpty($Root)) {
		$Root = Get-ScriptRoot
	}

	$dirName = $Config.Name
	$addonName = $Config.Name
	if ($null -ne $Config.Implementation) {
		$dirName += "\$($Config.Implementation)"
		$addonName += " $($Config.Implementation)"
	}

	$enableCmdPath = "$Root\$dirName\Enable.ps1"

	if ((Test-Path $enableCmdPath) -ne $true) {
		Write-Warning "Addon '$($Config.Name)' seems to be deprecated, skipping it."
		return
	}

	Write-Log "Re-enabling addon '$addonName'.."

	$enableParameters = @{}
	$selectorProperty = $Config.PSObject.Properties['InfraNodeSelector']
	if ($null -ne $selectorProperty -and -not [string]::IsNullOrWhiteSpace([string]$selectorProperty.Value)) {
		# Saved options are replayed only together with a saved selector; configs without one re-enable exactly as before.
		$replayProperties = switch ($Config.Name) {
			'monitoring' { @('OmitGrafana', 'Ingress') }
			'logging' { @('OmitOpensearch', 'StorageNode', 'Ingress') }
			'registry' { @('StorageNode', 'Ingress') }
			'ingress' { @('OmitCertMgr') }
			default { @() }
		}
		foreach ($propertyName in $replayProperties) {
			$property = $Config.PSObject.Properties[$propertyName]
			if ($null -ne $property) { $enableParameters[$propertyName] = $property.Value }
		}
		$enableParameters['InfraNodeSelector'] = [string]$selectorProperty.Value
		if ($Config.Name -eq 'registry') { $enableParameters['Ingress'] = 'none' }
	}
	& $enableCmdPath @enableParameters

	Write-Log "Addon '$addonName' re-enabled."
}

function Invoke-BackupRestoreHooks {
	param (
		[parameter(Mandatory = $false)]
		[ValidateSet('Backup', 'Restore')]
		[string]$HookType = $(throw 'Hook type not specified'),
		[Parameter(Mandatory = $false)]
		[string]$BackupDir = $(throw 'Back-up directory not specified')
	)
	if ((Test-Path -Path $hooksDir) -ne $true) {
		Write-Log 'Addons hooks dir not existing, skipping..'
		return
	}

	$hooksFilter = "*.$HookType.ps1"

	Write-Log "Executing addons hooks with hook type '$HookType'.."

	$executionCount = 0

	Get-ChildItem -Path $hooksDir -Filter $hooksFilter -Force | ForEach-Object {
		Write-Log "  Executing '$($_.FullName)'.."
		& "$($_.FullName)" -BackupDir $BackupDir
		$executionCount++
	}

	if ($executionCount -eq 0) {
		Write-Log 'No back-up/restore hooks found.'
	}
}

function ConvertTo-NewConfigStructure {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Config = $(throw 'Config not specified.')
	)
	$newConfig = [System.Collections.ArrayList]@()

	foreach ($addon in $Config) {
		$newAddon = $addon
		if ($addon -is [string]) {
			switch ($addon) {
				'gateway-nginx' { $newAddon = [pscustomobject]@{Name = 'gateway-api' } }
				'ingress-nginx' { $newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = @('nginx') } }
				'traefik' { $newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = @('traefik') } }
				'metrics-server' { $newAddon = [pscustomobject]@{Name = 'metrics' } }
				Default { $newAddon = [pscustomobject]@{Name = $addon } }
			}

			Write-Information "Config for addon '$addon' migrated."
		}
		elseif ($addon -is [pscustomobject]) {
			switch ($($addon.Name)) {
				'gateway-nginx' { 
					$newAddon = [pscustomobject]@{Name = 'gateway-api' } 
					Write-Information "Config for addon '$($addon.Name)' migrated."
				}
				'ingress-nginx' { 
					$newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = 'nginx' }
					Write-Information "Config for addon '$($addon.Name)' migrated."                
				}
				'traefik' { 
					$newAddon = [pscustomobject]@{Name = 'ingress'; Implementation = 'traefik' } 
					Write-Information "Config for addon '$($addon.Name)' migrated."
				}
				'metrics-server' { 
					$newAddon = [pscustomobject]@{Name = 'metrics' } 
					Write-Information "Config for addon '$($addon.Name)' migrated."
				}
				'smb-share' { 
					$newAddon = [pscustomobject]@{Name = 'storage'; SmbHostType = $addon.SmbHostType } 
					Write-Information "Config for addon '$($addon.Name)' migrated."
				}
			}
		}
		elseif ($addon -isnot [pscustomobject]) {
			throw "Unexpected addon config type '$($addon.GetType().Name)'"
		}

		$newConfig.Add($newAddon) > $null
	}

	return $newConfig
}

function Find-AddonManifests {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory not specified')
	)
	return Get-ChildItem -File -Recurse -Depth 1 -Path $Directory -Filter 'addon.manifest.yaml' | ForEach-Object { $_.FullName }
}

function Get-EnabledAddons {   

	Write-Log 'Getting enabled addons..'

	$config = Get-AddonsConfig

	$enabledAddons = [System.Collections.ArrayList]@()

	if ($null -eq $config) {
		Write-Log 'No addons config found'

		return , $enabledAddons
	}

	Write-Log 'Addons config found'

	$config | ForEach-Object {
		$addon = $_
		Write-Log "found addon '$($_.Name)'"
		$alreadyExistingAddon = $enabledAddons | Where-Object { $_.Name -eq $addon.Name }
		if ($alreadyExistingAddon) {
			$alreadyExistingAddon.Implementations.Add($addon.Implementation) | Out-Null
		}
		else {
			if ($null -eq $addon.Implementation) {
				$enabledAddons.Add([pscustomobject]@{ Name = $addon.Name }) | Out-Null
			}
			else {
				$enabledAddons.Add([pscustomobject]@{ Name = $addon.Name; Implementations = [System.Collections.ArrayList]@($addon.Implementation) }) | Out-Null
			}
		}
	}

	return , $enabledAddons
}

<#
.SYNOPSIS
	Adds an enabled addon to setup.json
.DESCRIPTION
	Adds an addon to json array "EnabledAddons" in Setup.json. If the array is not present, then it is created and then the enabled addon
	into the array. The addon object must contain a 'Name' property
.PARAMETER Addon
	The addon object containing a 'Name' property
.EXAMPLE
	Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'dashboard' })
#>
function Add-AddonToSetupJson() {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)
	if ($Addon -eq $null) {
		throw 'Addon not specified'
	}
	if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
		throw "Addon does not contain a property with name 'Name'"
	}

	$filePath = Get-SetupConfigFilePath
	$parsedSetupJson = Get-Content -Raw $filePath | ConvertFrom-Json
	$placementIntent = @($parsedSetupJson.AddonPlacementIntents) | Where-Object { $null -ne $_ -and $_.Name -eq $Addon.Name -and [string]$_.Implementation -eq [string]$Addon.Implementation } | Select-Object -First 1
	if ($placementIntent -and -not $Addon.PSObject.Properties['InfraNodeSelector']) {
		$Addon | Add-Member -NotePropertyName InfraNodeSelector -NotePropertyValue $placementIntent.InfraNodeSelector
	}

	$enabledAddonMemberExists = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
	if (!$enabledAddonMemberExists) {
		$parsedSetupJson = $parsedSetupJson | Add-Member -NotePropertyMembers @{EnabledAddons = @() } -PassThru
	}

	$addonAlreadyExists = $parsedSetupJson.EnabledAddons | Where-Object { $_.Name -eq $Addon.Name }
	if ($addonAlreadyExists) {
		if ($null -ne $Addon.Implementation) {
			$implementationAlreadyExists = $parsedSetupJson.EnabledAddons | Where-Object { ($_.Name -eq $Addon.Name) -and ($_.Implementation -eq $Addon.Implementation) }
			if (!$implementationAlreadyExists) {
				$parsedSetupJson.EnabledAddons += $Addon
				$parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
			}
		}
	}
	else {
		$parsedSetupJson.EnabledAddons += $Addon
		$parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
	}
	if ($placementIntent) { Set-AddonPlacementIntent -Addon $Addon -Clear }
}

function New-AddonPlacementManifest {
	param (
		[Parameter(Mandatory = $true)]
		[string]$AddonName,
		[Parameter(Mandatory = $true)]
		[string]$ManifestDirectory,
		[Parameter(Mandatory = $true)]
		[string]$Selector,
		[switch]$SelectorsOnly
	)

	$k2sExe = Join-Path (Split-Path $PSScriptRoot -Parent) 'k2s.exe'
	if (-not (Test-Path -LiteralPath $k2sExe)) {
		throw "K2s executable was not found at '$k2sExe'."
	}
	$outputPath = Join-Path ([System.IO.Path]::GetTempPath()) "k2s-placement-$([System.Guid]::NewGuid().ToString('N')).yaml"
	try {
		$renderOptions = @()
		if ($SelectorsOnly) { $renderOptions += '--selectors-only' }
		if ($SelectorsOnly -and $AddonName -eq 'dashboard') { $renderOptions += @('--helm-path', (Join-Path (Get-KubeBinPath) 'helm.exe')) }
		if ($AddonName -eq 'dashboard') {
			& $k2sExe addons __render-placement-manifests --addon-name $AddonName --input-file (Join-Path $ManifestDirectory 'values.yaml') --selector $Selector --output $outputPath @renderOptions
		}
		else {
			& $k2sExe addons __render-placement-manifests --addon-name $AddonName --manifest-directory $ManifestDirectory --selector $Selector --output $outputPath @renderOptions
		}
		if ($LASTEXITCODE -ne 0) { throw "Could not render addon '$AddonName' for infrastructure placement." }
		return $outputPath
	}
	catch {
		Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
		throw
	}
}

function New-AddonPlacementInput {
	param ([string]$AddonName, [string]$Path, [string]$Selector, [switch]$Kustomize, [string]$StorageNode = '')
	$inputPath = $Path
	$temporaryInput = $null
	$outputPath = [System.IO.Path]::GetTempFileName()
	try {
		if ($Kustomize) {
			$built = Invoke-Kubectl -Params 'kustomize', $Path
			if (-not $built.Success) { throw "Could not build owning Kustomize input '$Path': $($built.Output)" }
			$temporaryInput = [System.IO.Path]::GetTempFileName()
			Set-Content -LiteralPath $temporaryInput -Value $built.Output -Encoding UTF8
			$inputPath = $temporaryInput
		}
		$k2sExe = Join-Path (Split-Path $PSScriptRoot -Parent) 'k2s.exe'
		& $k2sExe addons __render-placement-manifests --addon-name $AddonName --input-file $inputPath --selector $Selector --storage-node $StorageNode --output $outputPath
		if ($LASTEXITCODE -ne 0) { throw "Could not render owning placement input for '$AddonName'." }
		$selectorsPath = [System.IO.Path]::GetTempFileName()
		try {
			& $k2sExe addons __render-placement-manifests --addon-name $AddonName --input-file $inputPath --selector $Selector --storage-node $StorageNode --output $selectorsPath --selectors-only
			if ($LASTEXITCODE -ne 0) { throw "Could not inspect effective selectors for '$AddonName'." }
			$hasMatchingNodes = $true
			foreach ($effectiveSelector in @(Get-Content -Raw -LiteralPath $selectorsPath | ConvertFrom-Json)) {
				$nodes = Invoke-Kubectl -Params 'get', 'nodes', '-l', $effectiveSelector, '-o', 'name'
				if (-not $nodes.Success) { throw "Could not check nodes for '$effectiveSelector': $($nodes.Output)" }
				if ([string]::IsNullOrWhiteSpace([string]$nodes.Output)) { $hasMatchingNodes = $false }
			}
		}
		finally { Remove-Item -LiteralPath $selectorsPath -Force -ErrorAction SilentlyContinue }
		return [pscustomobject]@{ Path = $outputPath; HasMatchingNodes = $hasMatchingNodes }
	}
	catch { Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue; throw }
	finally { if ($temporaryInput) { Remove-Item -LiteralPath $temporaryInput -Force -ErrorAction SilentlyContinue } }
}

function Assert-AddonPlacementHost {
	param ([string]$Selector, [string]$NodeName, [string]$Reason)
	if ([string]::IsNullOrWhiteSpace($Selector)) { return }
	$nodeResult = Invoke-Kubectl -Params 'get', 'node', $NodeName, '-o', 'json'
	if (-not $nodeResult.Success) { throw "Could not validate required host '$NodeName': $($nodeResult.Output)" }
	$node = $nodeResult.Output | ConvertFrom-Json
	$requirements = ConvertFrom-AddonInfrastructureSelector -Selector $Selector
	foreach ($entry in $requirements.GetEnumerator()) {
		$label = $node.metadata.labels.PSObject.Properties | Where-Object { $_.Name -ceq $entry.Key }
		if ($null -eq $label -or [string]$label.Value -cne $entry.Value) {
			throw "Infrastructure selector '$Selector' excludes required host '$NodeName' ($Reason). Choose compatible labels; placement does not migrate data or host prerequisites."
		}
	}
}

function Assert-SharedInfrastructurePlacement {
	param ([string]$Name, [string]$Selector, [string]$Namespace, [string]$Deployment)
	$owners = @(Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key 'SharedInfrastructurePlacement')
	$owner = $owners | Where-Object { $null -ne $_ -and $_.Name -eq $Name } | Select-Object -First 1
	if (-not $Selector -and -not $owner) { return }
	$deploymentNames = @($Deployment)
	if ($Name -eq 'cert-manager') { $deploymentNames += @('cert-manager-cainjector', 'cert-manager-webhook') }
	$existing = Invoke-Kubectl -Params (@('get', 'deployment') + $deploymentNames + @('-n', $Namespace, '--ignore-not-found', '-o', 'json'))
	if (-not $existing.Success) { throw "Cannot inspect shared infrastructure '$Name': $($existing.Output)" }
	$workloads = @()
	if (-not [string]::IsNullOrWhiteSpace([string]$existing.Output)) {
		$resource = $existing.Output | ConvertFrom-Json -ErrorAction Stop
		$workloads = if ($resource.PSObject.Properties['items']) { @($resource.items) } else { @($resource) }
	}
	if ($owner -and (ConvertTo-CanonicalAddonSelector $owner.InfraNodeSelector) -cne (ConvertTo-CanonicalAddonSelector $Selector)) {
		$consumers = @(Get-AddonsConfig | Where-Object { $_.Name -in @('ingress', 'security') })
		if ($workloads.Count -or $consumers.Count) { throw "Shared infrastructure '$Name' already owns selector '$($owner.InfraNodeSelector)'; requested '$Selector'. Use the same selector or explicitly uninstall all consumers and the shared service before changing placement." }
		Set-SharedInfrastructurePlacement -Name $Name -Selector $Selector
	}
	foreach ($workload in $workloads) {
		if (-not $Selector) { continue }
		$drift = @(Get-AddonSelectorDrift -RequestedSelector $Selector -EffectiveNodeSelector $workload.spec.template.spec.nodeSelector)
		if ($drift.Count) { throw "Shared infrastructure '$Name' exists without compatible placement. Explicitly uninstall its consumers before enabling '$Selector'." }
	}
}

function Invoke-AddonStorageProof {
	param ([string]$VolumeJson, [string]$NodeJson)
	$volumePath = [System.IO.Path]::GetTempFileName()
	$nodePath = [System.IO.Path]::GetTempFileName()
	try {
		Set-Content -LiteralPath $volumePath -Value $VolumeJson -Encoding utf8
		Set-Content -LiteralPath $nodePath -Value $NodeJson -Encoding utf8
		$k2sExe = Join-Path (Split-Path $PSScriptRoot -Parent) 'k2s.exe'
		& $k2sExe addons __render-placement-manifests --existing-volume $volumePath --storage-host $nodePath
		if ($LASTEXITCODE -ne 0) { throw 'Existing PV topology is incompatible with the required storage host. Placement does not migrate data.' }
	}
	finally { Remove-Item -LiteralPath $volumePath, $nodePath -Force -ErrorAction SilentlyContinue }
}

function Assert-AddonStoragePlacement {
	param ([string]$Namespace, [string[]]$VolumeNames, [string]$NodeName)
	$node = Invoke-Kubectl -Params 'get', 'node', $NodeName, '-o', 'json'
	if (-not $node.Success) { throw "Cannot inspect storage host '$NodeName': $($node.Output)" }
	$claims = Invoke-Kubectl -Params 'get', 'pvc', '-n', $Namespace, '--ignore-not-found', '-o', 'json'
	if (-not $claims.Success) { throw "Cannot inspect existing storage claims in '$Namespace': $($claims.Output)" }
	$claimList = $claims.Output | ConvertFrom-Json -ErrorAction Stop
	$names = @($VolumeNames) + @($claimList.items | ForEach-Object { $_.spec.volumeName } | Where-Object { $_ })
	foreach ($volumeName in @($names | Select-Object -Unique)) {
		$volume = Invoke-Kubectl -Params 'get', 'pv', $volumeName, '--ignore-not-found', '-o', 'json'
		if (-not $volume.Success) { throw "Cannot inspect PV '$volumeName': $($volume.Output)" }
		if (-not [string]::IsNullOrWhiteSpace([string]$volume.Output)) { Invoke-AddonStorageProof -VolumeJson $volume.Output -NodeJson $node.Output }
	}
}

function Set-SharedInfrastructurePlacement {
	param ([string]$Name, [string]$Selector)
	$filePath = Get-SetupConfigFilePath
	$config = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
	$owners = @($config.SharedInfrastructurePlacement | Where-Object { $null -ne $_ -and $_.Name -ne $Name })
	$owners += [pscustomobject]@{Name = $Name; InfraNodeSelector = $Selector}
	$config | Add-Member -NotePropertyName SharedInfrastructurePlacement -NotePropertyValue $owners -Force
	$config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $filePath -Force
}

function Invoke-AddonOwnedApply {
	param ([string]$AddonName, [string]$Path, [string]$Selector = '', [switch]$Kustomize, [switch]$ServerSide)
	$placement = $null
	$params = @('apply')
	if ($ServerSide) { $params += '--server-side', '--force-conflicts' }
	try {
		if ($Selector) {
			$placement = New-AddonPlacementInput -AddonName $AddonName -Path $Path -Selector $Selector -Kustomize:$Kustomize
			$params += @('-f', $placement.Path)
		} else {
			$inputMode = if ($Kustomize) { '-k' } else { '-f' }
			$params += @($inputMode, $Path)
		}
		$result = Invoke-Kubectl -Params $params
		if (-not $result.Success) {
			# Without a selector the original apply only logged its output; strictness applies to placement-constrained applies.
			if ($Selector) { throw "Addon '$AddonName' owning apply failed: $($result.Output)" }
			Write-Log "[Placement] WARNING Addon '$AddonName' apply failed, continuing: $($result.Output)"
		}
		return $result
	}
	finally { if ($placement) { Remove-Item -LiteralPath $placement.Path -Force -ErrorAction SilentlyContinue } }
}

function Test-AddonPlacementIntent {
	param ([string]$Name, [string]$Implementation = '', [string]$Selector)
	if (-not $Selector) { return $false }
	$intents = @(Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key 'AddonPlacementIntents')
	$intent = $intents | Where-Object { $null -ne $_ -and $_.Name -eq $Name -and [string]$_.Implementation -eq $Implementation } | Select-Object -First 1
	return ($null -ne $intent -and (ConvertTo-CanonicalAddonSelector $intent.InfraNodeSelector) -ceq (ConvertTo-CanonicalAddonSelector $Selector))
}

function Get-AddonPlacementOwnerOptions {
	param ([string]$Name, [string]$Implementation = '', [System.Collections.IDictionary]$BoundParameters, [hashtable]$Defaults)
	$schemas = @{
		'ingress/nginx' = @{OmitCertMgr = 'bool'}
		'ingress/nginx-gw' = @{OmitCertMgr = 'bool'}
		'ingress/traefik' = @{OmitCertMgr = 'bool'}
		'registry/' = @{StorageNode = 'string'; Ingress = 'ingress'}
		'logging/' = @{StorageNode = 'string'; Ingress = 'ingress'; OmitOpensearch = 'bool'}
		'monitoring/' = @{OmitGrafana = 'bool'; Ingress = 'ingress'}
	}
	$schema = $schemas["$Name/$Implementation"]
	$result = @{}
	foreach ($key in $Defaults.Keys) { $result[$key] = $Defaults[$key] }
	if ($null -eq $schema) { throw "No placement owner option schema for '$Name/$Implementation'." }
	$saved = Get-AddonConfig -Name $Name -Implementation $Implementation
	$isIntent = $null -eq $saved
	if ($isIntent) {
		$saved = @(Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key 'AddonPlacementIntents') |
			Where-Object { $null -ne $_ -and $_.Name -eq $Name -and [string]$_.Implementation -eq $Implementation } | Select-Object -First 1
	}
	if ($null -eq $saved) { return $result }
	foreach ($key in $schema.Keys) {
		$property = $saved.PSObject.Properties[$key]
		if ($null -eq $property) {
			if ($isIntent -and $Name -eq 'monitoring' -and $key -eq 'OmitGrafana' -and -not $BoundParameters.ContainsKey($key)) {
				throw "Addon 'monitoring' OmitGrafana is missing from incomplete installation intent. Retry with the original --omitGrafana=true or --omitGrafana=false, or disable monitoring before changing it."
			}
			continue
		}
		$value = $property.Value
		if ($schema[$key] -eq 'bool') {
			if ($value -isnot [bool]) { throw "Addon '$Name' saved $key must be a boolean. Disable the addon to clean up incomplete installation intent before retrying." }
		} else {
			if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { throw "Addon '$Name' saved $key is invalid. Disable the addon before retrying." }
			if ($schema[$key] -eq 'ingress') {
				$value = $value.ToLowerInvariant()
				if ($value -notin @('none', 'nginx', 'nginx-gw', 'traefik')) { throw "Addon '$Name' saved $key mode is invalid. Disable the addon before retrying." }
			}
		}
		$explicit = $BoundParameters.ContainsKey($key)
		$requested = $BoundParameters[$key]
		if ($BoundParameters.ContainsKey('Config') -and $null -ne $BoundParameters['Config']) {
			$configProperty = $BoundParameters['Config'].PSObject.Properties[$key]
			if ($null -ne $configProperty) { $explicit = $true; $requested = $configProperty.Value }
		}
		if ($explicit) {
			if ($schema[$key] -eq 'bool') {
				if ($requested -isnot [bool] -and $requested -isnot [System.Management.Automation.SwitchParameter]) { throw "Addon '$Name' explicit $key must be a boolean." }
				$requested = [bool]$requested
			}
			elseif ($schema[$key] -eq 'ingress') { $requested = ([string]$requested).ToLowerInvariant() }
			if ($requested -cne $value) { throw "Addon '$Name' $key conflicts with incomplete installation intent or saved owner configuration. Retry with the saved option or disable the addon before changing it." }
		}
		$result[$key] = $value
	}
	return $result
}

function Get-AddonEffectiveInfrastructureSelector {
	param ([string]$Name, [string]$Selector = '', [string]$Implementation = '')
	$config = Get-AddonConfig -Name $Name -Implementation $Implementation
	if ($null -eq $config) {
		$intents = @(Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key 'AddonPlacementIntents') | Where-Object { $null -ne $_ -and $_.Name -eq $Name }
		if ($Implementation -and @($intents | Where-Object { [string]$_.Implementation -ne $Implementation }).Count) {
			throw "Addon '$Name' has incomplete installation intent for another implementation. Disable that implementation before changing it."
		}
		$intent = $intents | Where-Object { [string]$_.Implementation -eq $Implementation } | Select-Object -First 1
		if ($intent) {
			if ($Selector -and (ConvertTo-CanonicalAddonSelector $Selector) -cne (ConvertTo-CanonicalAddonSelector $intent.InfraNodeSelector)) { throw "Addon '$Name' has incomplete installation intent '$($intent.InfraNodeSelector)'. Retry with that selector or disable the addon before changing it." }
			return [string]$intent.InfraNodeSelector
		}
		return $Selector
	}
	if (-not [string]::IsNullOrWhiteSpace($Selector)) {
		$conflict = Get-AddonPlacementSelectorConflictMessage -Name $Name -Implementation $Implementation -RequestedSelector $Selector
		if ($conflict) { throw $conflict }
		return $Selector
	}
	$property = $config.PSObject.Properties['InfraNodeSelector']
	if ($null -ne $property) { return [string]$property.Value }
	return ''
}

function ConvertTo-CanonicalAddonSelector {
	param ([string]$Selector)
	$requirements = ConvertFrom-AddonInfrastructureSelector -Selector $Selector
	return ($requirements.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','
}

function Set-AddonPlacementIntent {
	param ([pscustomobject]$Addon, [switch]$Clear)
	$filePath = Get-SetupConfigFilePath
	$config = Get-Content -Raw -LiteralPath $filePath | ConvertFrom-Json
	$intents = @($config.AddonPlacementIntents | Where-Object { $null -ne $_ -and -not ($_.Name -eq $Addon.Name -and [string]$_.Implementation -eq [string]$Addon.Implementation) })
	if (-not $Clear) { $intents += $Addon }
	$config | Add-Member -NotePropertyName AddonPlacementIntents -NotePropertyValue $intents -Force
	$config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $filePath -Force
}

function Invoke-AddonEnableTransaction {
	param (
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Addon,
		[Parameter(Mandatory = $false)]
		[string]$Selector = '',
		[Parameter(Mandatory = $false)]
		[bool]$HasMatchingNodes = $true,
		[Parameter(Mandatory = $true)]
	[scriptblock]$Apply,
		[Parameter(Mandatory = $true)]
		[scriptblock]$Wait,
		[Parameter(Mandatory = $true)]
		[scriptblock]$Update,
		[scriptblock]$ConfigurePending = {},
		[Parameter(Mandatory = $true)]
		[scriptblock]$Rollback
	)

	if ($Selector) { Set-AddonPlacementIntent -Addon $Addon }
	try {
		$applyResult = & $Apply
		if ($null -eq $applyResult -or $applyResult.Success -ne $true) {
			$applyOutput = if ($null -ne $applyResult) { [string]$applyResult.Output } else { 'no result returned' }
			throw "Manifest apply failed: $applyOutput"
		}
		if ($HasMatchingNodes -and (& $Wait) -ne $true) {
			throw 'Required addon workloads did not become Ready.'
		}
		if (-not $HasMatchingNodes) {
			& $ConfigurePending
			Write-Log "[Placement] Addon '$($Addon.Name)' was enabled with selector '$Selector'; no nodes currently match, so its Pods will remain Pending until a matching node is available." -Console
		}
		else {
			& $Update
		}
		Add-AddonToSetupJson -Addon $Addon
		if ($Selector) { Set-AddonPlacementIntent -Addon $Addon -Clear }
	}
	catch {
		$failure = $_.Exception.Message
		try {
			$rollbackResult = & $Rollback
		}
		catch {
			$rollbackResult = [pscustomobject]@{ Success = $false; Output = $_.Exception.Message }
		}
		if ($null -ne $rollbackResult -and $rollbackResult.Success -eq $true) {
			try {
				Remove-AddonFromSetupJson -Addon $Addon
				if ($Selector) { Set-AddonPlacementIntent -Addon $Addon }
			}
			catch {
				throw "$failure Rollback completed, but addon state cleanup failed: $($_.Exception.Message)"
			}
			throw $failure
		}

		$rollbackOutput = if ($null -ne $rollbackResult) { [string]$rollbackResult.Output } else { 'no result returned' }
		if (-not [string]::IsNullOrWhiteSpace($Selector)) {
			try {
				Set-AddonPlacementIntent -Addon $Addon
			}
			catch {
				throw "$failure Rollback failed, and selector state could not be retained: $($_.Exception.Message)"
			}
			throw "$failure Rollback failed; infrastructure placement was retained as incomplete installation intent in setup.json to protect remaining workloads. $rollbackOutput"
		}
		throw "$failure Rollback failed; remaining workload cleanup is required before retrying. $rollbackOutput"
	}
}

function ConvertFrom-AddonInfrastructureSelector {
	param ([string]$Selector)
	$requirements = [System.Collections.Generic.SortedDictionary[string,string]]::new([System.StringComparer]::Ordinal)
	if (-not [string]::IsNullOrWhiteSpace($Selector)) {
		foreach ($requirement in $Selector.Split(',')) {
			$separator = $requirement.IndexOf('=')
			if ($separator -lt 1) { throw "Invalid infrastructure selector requirement '$requirement'." }
			$key = $requirement.Substring(0, $separator).Trim()
			$value = $requirement.Substring($separator + 1).Trim()
			if ($key.Length -eq 0 -or $value.Contains('=')) { throw "Invalid infrastructure selector requirement '$requirement'." }
			if ($requirements.ContainsKey($key) -and $requirements[$key] -cne $value) { throw "Conflicting infrastructure selector requirement '$key'." }
			$requirements[$key] = $value
		}
	}
	return ,$requirements
}

function Get-AddonPlacementSelectorConflictMessage {
	param (
		[string]$Implementation = '',
		[Parameter(Mandatory = $true)]
		[string]$Name,
		[Parameter(Mandatory = $true)]
		[AllowEmptyString()]
		[string]$RequestedSelector
	)
	if ([string]::IsNullOrWhiteSpace($RequestedSelector)) {
		return ''
	}
	$addonConfig = Get-AddonConfig -Name $Name -Implementation $Implementation
	$savedProperty = if ($null -ne $addonConfig) { $addonConfig.PSObject.Properties['InfraNodeSelector'] } else { $null }
	$savedSelector = if ($null -ne $savedProperty) { [string]$savedProperty.Value } else { '' }
	if ([string]::IsNullOrWhiteSpace($savedSelector)) {
		return "Addon '$Name' is already enabled without saved infrastructure placement. Disable it and re-enable it with the requested selector; placement changes are not applied in place."
	}
	$savedRequirements = ConvertFrom-AddonInfrastructureSelector -Selector $savedSelector
	$requestedRequirements = ConvertFrom-AddonInfrastructureSelector -Selector $RequestedSelector
	$savedCanonical = ($savedRequirements.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','
	$requestedCanonical = ($requestedRequirements.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','
	if ($savedCanonical -ceq $requestedCanonical) {
		return ''
	}
	return "Addon '$Name' is already enabled with infrastructure node selector '$savedSelector'. Disable it and re-enable it with the new selector; placement changes are not applied in place."
}

function Get-AddonBackupInfrastructureSelector {
	param (
		[Parameter(Mandatory = $true)]
		[string]$BackupDir
	)
	if ([string]::IsNullOrWhiteSpace($BackupDir)) {
		return ''
	}
	$manifestPath = Join-Path $BackupDir 'backup.json'
	if (-not (Test-Path -LiteralPath $manifestPath)) {
		return ''
	}
	$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -ErrorAction Stop
	$selectorProperty = $manifest.PSObject.Properties['infraNodeSelector']
	if ($null -eq $selectorProperty) {
		$selectorProperty = $manifest.PSObject.Properties['InfraNodeSelector']
	}
	if ($null -eq $selectorProperty) {
		return ''
	}
	return [string]$selectorProperty.Value
}

function Test-AddonInfrastructureSelectorOnCluster {
	param (
		[Parameter(Mandatory = $true)]
		[string]$Name,
		[Parameter(Mandatory = $true)]
		[string]$Selector
	)
	if ([string]::IsNullOrWhiteSpace($Selector)) {
		return $true
	}
	$manifestDirectory = Join-Path $PSScriptRoot "$Name/manifests"
	if ($Name -eq 'dashboard') { $manifestDirectory = Join-Path $manifestDirectory 'chart' }
	$selectorPath = New-AddonPlacementManifest -AddonName $Name -ManifestDirectory $manifestDirectory -Selector $Selector -SelectorsOnly
	try {
		$effectiveSelectors = @(Get-Content -LiteralPath $selectorPath -Raw | ConvertFrom-Json)
		if ($effectiveSelectors.Count -eq 0) { throw "No effective infrastructure workload selectors were rendered for '$Name'." }
		foreach ($effectiveSelector in $effectiveSelectors) {
			$nodes = Invoke-Kubectl -Params 'get', 'nodes', '-l', $effectiveSelector, '-o', 'name'
			if (-not $nodes.Success) {
				throw "Could not validate infrastructure selector '$effectiveSelector' against the destination cluster: $($nodes.Output)"
			}
			if ([string]::IsNullOrWhiteSpace([string]$nodes.Output)) {
				Write-Log "[Placement] No destination nodes currently match '$effectiveSelector'; matching infrastructure Pods will remain Pending until a node is available." -Console
				return $false
			}
		}
		return $true
	}
	finally {
		Remove-Item -LiteralPath $selectorPath -Force -ErrorAction SilentlyContinue
	}
}

function Get-AddonSelectorDrift {
	param (
		[Parameter(Mandatory = $true)]
		[string]$RequestedSelector,
		[Parameter(Mandatory = $false)]
		$EffectiveNodeSelector
	)

	$effectiveRequirements = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
	if ($null -ne $EffectiveNodeSelector) {
		foreach ($property in $EffectiveNodeSelector.PSObject.Properties) {
			$effectiveRequirements[$property.Name] = [string]$property.Value
		}
	}

	$drift = @()
	$requestedRequirements = ConvertFrom-AddonInfrastructureSelector -Selector $RequestedSelector
	foreach ($requirement in $requestedRequirements.GetEnumerator()) {
		if (-not $effectiveRequirements.ContainsKey($requirement.Key) -or $effectiveRequirements[$requirement.Key] -cne $requirement.Value) {
			$drift += "$($requirement.Key)=$($requirement.Value)"
		}
	}
	return $drift
}

<#
.SYNOPSIS
	Removes an enabled addon from setup.json
.DESCRIPTION
	From an addon from json array "EnabledAddons" in Setup.json. If the array is empty after the remove operation,
	then the json array is removed from Setup.json
.PARAMETER Name
	Name of the enabled addon
.EXAMPLE
	Remove-AddonFromSetupJson -Addon -Addon ([pscustomobject] @{Name = 'DummyAddon' })
#>
function Remove-AddonFromSetupJson {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)
	if ($Addon -eq $null) {
		throw 'Addon not specified'
	}
	if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
		throw "Addon does not contain a property with name 'Name'"
	}

	Write-Log "Removing '$($Addon.Name)' from addons config.."

	$filePath = Get-SetupConfigFilePath
	$parsedSetupJson = Get-Content -Raw $filePath | ConvertFrom-Json
	if ($parsedSetupJson.PSObject.Properties['AddonPlacementIntents']) {
		$parsedSetupJson.AddonPlacementIntents = @($parsedSetupJson.AddonPlacementIntents | Where-Object { $null -ne $_ -and -not ($_.Name -eq $Addon.Name -and [string]$_.Implementation -eq [string]$Addon.Implementation) })
		$parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
	}

	$addonsMember = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
	if ($null -eq $addonsMember) {
		Write-Log 'No addons config found, skipping'
		return
	}

	$enabledAddons = $parsedSetupJson.EnabledAddons
	$newEnabledAddons = $enabledAddons

	$addonExists = $enabledAddons | Where-Object { $_.Name -eq $Addon.Name }
	if ($addonExists) {
		if ($null -ne $Addon.Implementation) {
			$implementationExists = $addonExists | Where-Object { $_.Implementation -eq $Addon.Implementation }
			if ($implementationExists) {
				$newEnabledAddons = @($enabledAddons | Where-Object { $_.Implementation -ne $Addon.Implementation })
			}
		}
		else {
			$hasImplementationProperty = $addonExists | Where-Object { $null -ne $_.Implementation }
			if (!$hasImplementationProperty) {
				$newEnabledAddons = @($enabledAddons | Where-Object { $_.Name -ne $Addon.Name })
			}
			else {
				throw "More than one implementation of addon '$($Addon.Name)'. Please specify the implementation!"
			}
		}
	}
	else {
		if ($null -ne $Addon.Implementation) {
			$name += " $($Addon.Implementation)"
		}
		Write-Log "Addon '$name' not found in addons config, skipping"
	}
		
	if ($newEnabledAddons) {
		$parsedSetupJson.EnabledAddons = $newEnabledAddons
	}
	else {
		$parsedSetupJson.PSObject.Properties.Remove($ConfigKey_EnabledAddons)
	}
	$parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
}

function Install-DebianPackages {
	param (
		[parameter()]
		[string] $addon,
		[parameter()]
		[string] $implementation = '',
		[parameter()]
		[string[]]$packages
	)

	$dirName = $addon
	if (($implementation -ne '') -and ($implementation -ne $addon)) {
		$dirName += "_$implementation"
	}

	foreach ($package in $packages) {
		if (!(Get-DebianPackageAvailableOffline -addon $addon -implementation $implementation -package $package)) {
			(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .${dirName}/${package} && cd .${dirName}/${package} && sudo chown -R _apt:root .").Output | Write-Log
			(Invoke-CmdOnControlPlaneViaSSHKey -Retries 2 -Timeout 2 -CmdToExecute "cd .${dirName}/${package} && sudo apt-get download $package" -RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install').Output | Write-Log
			(Invoke-CmdOnControlPlaneViaSSHKey `
				-Retries 2 `
				-Timeout 2 `
				-CmdToExecute "cd .${dirName}/${package} && sudo DEBIAN_FRONTEND=noninteractive apt-get --reinstall install -y --no-install-recommends --no-install-suggests --simulate ./${package}*.deb | grep 'Inst ' | cut -d ' ' -f 2 | sort -u | xargs sudo apt-get download" `
				-RepairCmd 'sudo dpkg --configure -a; sudo apt --fix-broken install').Output | Write-Log
		}

		Write-Log "Installing $package offline."
		(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo dpkg -i .${dirName}/${package}/*.deb 2>&1").Output | Write-Log
	}
}

function Get-DebianPackageAvailableOffline {
	param (
		[parameter()]
		[string] $addon,
		[parameter()]
		[string] $implementation = '',
		[parameter()]
		[string]$package
	)

	$dirName = $addon
	if (($implementation -ne '') -and ($implementation -ne $addon)) {
		$dirName += "_$implementation"
	}

	# TODO: NOTE: DO NOT USE `ExecCmdMaster` here to get the return value.
	ssh.exe -n -o StrictHostKeyChecking=no -i (Get-SSHKeyControlPlane) (Get-ControlPlaneRemoteUser) "[ -d .${dirName}/${package} ]"
	if (!$?) {
		return $false
	}

	Write-Log "$package available offline."

	return $true
}

<#
.SYNOPSIS
	Checks if a specific addon is enabled.
.DESCRIPTION
	Checks if a specific addon is enabled by looking up the given name in the list of enabled addons config.
.PARAMETER Name
	Name of the addon in question
#>
function Test-IsAddonEnabled {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)
	if ($Addon -eq $null) {
		throw 'Addon not specified'
	}
	if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
		throw "Addon does not contain a property with name 'Name'"
	}

	$enabledAddons = Get-AddonsConfig
	foreach ($enabledAddon in $enabledAddons) {
		if ($enabledAddon.Name -eq $Addon.Name) {
			if ($null -eq $Addon.Implementation) {
				return $true
			}

			if ($enabledAddon.Implementation -eq $Addon.Implementation) {
				return $true
			} 

			return $false
		}    
	}
	
	return $false
}

<#
.SYNOPSIS
	Invokes addons hooks.
.DESCRIPTION
	Invokes all addons hooks matching the hook type.
.PARAMETER HookType
	The type of hook, e.g. 'AfterStart' after starting the cluster
#>
function Invoke-AddonsHooks {
	param (
		[parameter(Mandatory = $false)]
		[ValidateSet('AfterStart', 'BeforeUninstall', 'AfterUninstall')]
		[string]$HookType = $(throw 'No hook type specified')
	)
	if ((Test-Path -Path $hooksDir) -ne $true) {
		Write-Log 'Addons hooks dir not existing, skipping..'
		return
	}

	$hooksFilter = "*.$HookType.ps1"

	Write-Log "Executing addons hooks with hook type '$HookType'..."

	$executionCount = 0

	Get-ChildItem -Path $hooksDir -Filter $hooksFilter -Force | ForEach-Object {
		Write-Log "  Executing $($_.FullName) ..."
		Invoke-Script -FilePath $_.FullName
		$executionCount++
	}

	if ($executionCount -eq 0) {
		Write-Log 'No addons hooks found.'
	}

	if ($HookType -eq 'AfterUninstall') {
		if (Test-Path $hooksDir) {
			Remove-Item -Path "$hooksDir" -Force -Recurse -ErrorAction SilentlyContinue
		}
	}
}

<#
.SYNOPSIS
	Copies script files to the hooks directory.
.DESCRIPTION
	Copies given script files to the addons hooks directory.
.PARAMETER Scripts
	Array of script file paths
#>
function Copy-ScriptsToHooksDir {
	param (
		[Parameter(ValueFromPipeline, Mandatory = $false)]
		[System.Collections.ArrayList]$ScriptPaths = $(throw 'No script file paths specified')
	)
	process {
		if ((Test-Path -Path $hooksDir) -ne $true) {
			Write-Log 'Addons hooks dir not existing, creating it..'
			New-Item -Path $hooksDir -ItemType Directory -Force | Out-Null
		}

		Write-Log 'Copying addons hooks..'

		foreach ($path in $ScriptPaths) {
			if ((Test-Path -Path $path) -ne $true) {
				Write-Warning "Cannot copy addon hook '$path' because it does not exist."
				continue
			}

			$sourceFileName = Get-FileName -FilePath $path
			$targetPath = "$hooksdir\$sourceFileName"

			Copy-Item -Path $path -Destination $targetPath -Force

			Write-Log "  Hook '$sourceFileName' copied."
		}
	}
}

<#
.SYNOPSIS
	Remove script files from the hooks directory
.DESCRIPTION
	Removes script files from the hooks directory
.PARAMETER ScriptNames
	Array of script file names to be removed from the hooks directory
#>
function Remove-ScriptsFromHooksDir {
	param (
		[Parameter(ValueFromPipeline, Mandatory = $false)]
		[System.Collections.ArrayList]$ScriptNames = $(throw 'No script file names specified')
	)
	process {
		if ((Test-Path -Path $hooksDir) -ne $true) {
			Write-Log 'Addons hooks dir not existing, nothing to remove.'
			return
		}

		Write-Log 'Removing addons hooks..'

		foreach ($name in $ScriptNames) {
			$path = "$hooksdir\$name"

			if ((Test-Path -Path $path) -ne $true) {
				Write-Warning "Cannot remove addon hook '$path' because it does not exist."
				continue
			}

			Remove-Item -Path $path -Force

			Write-Log "  Hook '$name' removed."
		}
	}
}

<#
.SYNOPSIS
	Loads the config of a given addon.
.DESCRIPTION
	Loads and returns the config of a given addon if existing. Otherwise, returns $null.
.PARAMETER Name
	Name of the addon in question
#>
function Get-AddonConfig {
	param (
		[parameter(Mandatory = $false)]
		[string] $Name = $(throw 'Name not specified'),
		[string] $Implementation = ''
	)
	$addons = Get-AddonsConfig
	foreach ($addon in $addons) {
		if ($addon.Name -eq $Name -and (-not $Implementation -or $addon.Implementation -eq $Implementation)) {
			return $addon
		}
	}
	return $null
}

function Get-AddonInfrastructurePlacementStatus {
	param (
		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	$addonConfig = Get-AddonConfig -Name $Name
	if ($null -eq $addonConfig) {
		$addonConfig = @(Get-ConfigValue -Path (Get-SetupConfigFilePath) -Key 'AddonPlacementIntents') | Where-Object { $null -ne $_ -and $_.Name -eq $Name } | Select-Object -First 1
		if ($null -eq $addonConfig) { return @() }
	}
	$selectorProperty = $addonConfig.PSObject.Properties['InfraNodeSelector']
	if ($null -eq $selectorProperty -or [string]::IsNullOrWhiteSpace([string]$selectorProperty.Value)) {
		return @()
	}

	$selector = [string]$selectorProperty.Value
	$workloads = @()
	if ($Name -eq 'metrics') {
		$workloads = @(@{ Name = 'metrics-server'; Namespace = 'metrics' })
	}
	elseif ($Name -eq 'dashboard') {
		$workloads = @(@{ Name = 'headlamp'; Namespace = 'dashboard' })
	}
	else {
		return Get-AddonOwnedPlacementStatus -Name $Name -Config $addonConfig -Selector $selector
	}

	$properties = @(@{ Name = 'Infrastructure node selector'; Value = $selector; Okay = $null })
	foreach ($workload in $workloads) {
		$deploymentResult = Invoke-Kubectl -Params 'get', 'deployment', $workload.Name, '-n', $workload.Namespace, '-o', 'json'
		if (-not $deploymentResult.Success) {
			$message = "Could not inspect deployment '$($workload.Name)' to determine its effective node selector. kubectl output: $($deploymentResult.Output)"
			$properties += @{ Name = "Infrastructure placement - $($workload.Name)"; Value = 'Unable to inspect workload selector'; Okay = $false; Message = $message }
			continue
		}

		try {
			$deployment = $deploymentResult.Output | ConvertFrom-Json -ErrorAction Stop
			$nodeSelector = $deployment.spec.template.spec.nodeSelector
			$requirements = @($nodeSelector.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" })
			if ($requirements.Count -eq 0) {
				throw 'The workload Pod template has no nodeSelector.'
			}
			$effectiveSelector = $requirements -join ','
		}
		catch {
			$message = "Could not determine the effective node selector for deployment '$($workload.Name)': $($_.Exception.Message)"
			$properties += @{ Name = "Infrastructure placement - $($workload.Name)"; Value = 'Unable to inspect workload selector'; Okay = $false; Message = $message }
			continue
		}
		$selectorDrift = @(Get-AddonSelectorDrift -RequestedSelector $selector -EffectiveNodeSelector $nodeSelector)
		if ($selectorDrift.Count -gt 0) {
			$message = "Deployment '$($workload.Name)' does not enforce saved selector '$selector'; missing or weakened requirements: $($selectorDrift -join ', ')."
			$properties += @{ Name = "Infrastructure placement - $($workload.Name)"; Value = 'Incorrect placement'; Okay = $false; Message = $message }
			continue
		}

		$nodes = Invoke-Kubectl -Params 'get', 'nodes', '-l', $effectiveSelector, '-o', 'name'
		if ($nodes.Success) {
			$hasMatchingNodes = -not [string]::IsNullOrWhiteSpace([string]$nodes.Output)
			$placementValue = if ($hasMatchingNodes) { "Matching nodes for $effectiveSelector" } else { 'No matching nodes' }
			$placementMessage = if ($hasMatchingNodes) {
				"The actual Pod template selector for '$($workload.Name)' matches one or more nodes."
			}
			else {
				"No nodes currently match '$effectiveSelector'; replacement Pods for '$($workload.Name)' will remain Pending until a matching node is available."
			}
			$properties += @{ Name = "Infrastructure placement - $($workload.Name)"; Value = $placementValue; Okay = [bool]$hasMatchingNodes; Message = $placementMessage }
		}
		else {
			$message = "Could not check nodes for '$effectiveSelector'. kubectl output: $($nodes.Output)"
			$properties += @{ Name = "Infrastructure placement - $($workload.Name)"; Value = 'Unable to check matching nodes'; Okay = $false; Message = $message }
		}
	}

	return $properties
}

function Get-AddonOwnedPlacementStatus {
	param ([string]$Name, [pscustomobject]$Config, [string]$Selector)
	$namespaces = switch ($Name) {
		'ingress' { switch ($Config.Implementation) { 'nginx' { 'ingress-nginx' }; 'traefik' { 'ingress-traefik' }; 'nginx-gw' { 'nginx-gw' } }; 'external-dns'; 'cert-manager' }
		default { $Name }
	}
	$properties = @(@{Name = 'Infrastructure node selector'; Value = $Selector; Okay = $null})
	foreach ($namespace in $namespaces) {
		$kinds = @('deployment,statefulset,job,cronjob')
		if ($Name -eq 'monitoring') { $kinds += 'prometheus,alertmanager' }
		if ($namespace -eq 'nginx-gw') { $kinds += 'nginxproxy' }
		foreach ($kind in $kinds) {
			$result = Invoke-Kubectl -Params 'get', $kind, '-n', $namespace, '-o', 'json'
			if (-not $result.Success) {
				$properties += @{Name = "Infrastructure placement - $namespace/$kind"; Value = 'Unable to inspect owner'; Okay = $false; Message = [string]$result.Output}
				continue
			}
			foreach ($owner in @((ConvertFrom-Json -InputObject $result.Output -ErrorAction Stop).items)) {
				if ($null -eq $owner) { continue }
				$podSpec = switch ($owner.kind) {
					'Prometheus' { $owner.spec }; 'Alertmanager' { $owner.spec }
					'NginxProxy' { $owner.spec.kubernetes.deployment.pod }
					'CronJob' { $owner.spec.jobTemplate.spec.template.spec }
					default { $owner.spec.template.spec }
				}
				if ($podSpec.securityContext.windowsOptions.hostProcess) { continue }
				$identity = "$($owner.kind)/$($owner.metadata.name)"
				$effective = @($podSpec.nodeSelector.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ','
				$drift = @(Get-AddonSelectorDrift -RequestedSelector $Selector -EffectiveNodeSelector $podSpec.nodeSelector)
				$properties += @{Name = "Effective node selector - $identity"; Value = $effective; Okay = $null}
				if ($drift.Count) {
					$properties += @{Name = "Infrastructure placement - $identity"; Value = 'Incorrect placement'; Okay = $false; Message = "Owner does not enforce saved requirements: $($drift -join ', ')."}
					continue
				}
				$nodes = Invoke-Kubectl -Params 'get', 'nodes', '-l', $effective, '-o', 'name'
				$matching = $nodes.Success -and -not [string]::IsNullOrWhiteSpace([string]$nodes.Output)
				$value = if (-not $nodes.Success) { 'Unable to check matching nodes' } elseif ($matching) { 'Matching nodes available' } else { 'No matching nodes' }
				$properties += @{Name = "Infrastructure placement - $identity"; Value = $value; Okay = [bool]$matching; Message = 'Label eligibility is not readiness: taints, affinity, resources and storage can still leave Pods Pending. There is no fallback.'}
			}
		}
	}
	return $properties
}

<#
.SYNOPSIS
Creates an addons backup

.DESCRIPTION
Creates an addons backup with the following steps:
- loads addons config
- migrates config to current structure
- creates config backup
- invokes the addons backup hooks for addon-specific backup tasks, e.g. creating data backup

.PARAMETER BackupDir
Directory where the addons backup shall be stored to
#>
function Backup-Addons {
	param (
		[Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to (gets created if not existing).')]
		[string]$BackupDir = $(throw 'Please specify the back-up directory.')
	)
	Write-Log 'Loading and migrating addons config..'
	$config = Get-AddonsConfig

	if ($null -eq $config) {
		Write-Log 'No addons to back-up, skipping.'
		return
	}

	if ((Test-Path $BackupDir) -ne $true) {
		Write-Log 'Addons backup dir not existing, creating it..'
		New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
	}

	$([array]$migratedConfig = ConvertTo-NewConfigStructure -Config $config) 6>&1 | ForEach-Object { Write-Log $_ }

	$backupContentRoot = [pscustomobject]@{Config = $migratedConfig }
	$backupFilePath = (Join-Path $BackupDir $backupFileName)

	$backupContentRoot | ConvertTo-Json -Depth 100 | Set-Content -Force $backupFilePath -Confirm:$false

	Write-Log "Addons config migrated and saved to '$backupFilePath'."

	# Copy backup and restore addon hooks for cluster upgrade
	# Why only backup and restore script being copied?
	# As remaining scripts(AfterStart,..) will be copied during re-enabling of addon.
	# NOTE!! If we copy earlier then it interferes with installation procedure.
	foreach ($addonConfig in $backupContentRoot.Config) {
		if ($null -eq $addonConfig.Name) {
			Write-Warning "Invalid addon config '$addonConfig' found, skipping it."
			continue
		}

		$root = Get-ScriptRoot
		$addonHookPath = "$root\$($addonConfig.Name)\hooks"
		if ((Test-Path $addonHookPath) -ne $true) {
			Write-Warning "Addon '$($addonConfig.Name)' no hooks found under $addonHookPath, skipping it."
			continue
		}

		Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path "$addonHookPath" | Where-Object { $_.Name -match 'BackUp|Restore' } | ForEach-Object { $_.FullName })
	}

	Write-Log 'Backing-up addons data..'

	Invoke-BackupRestoreHooks -HookType Backup -BackupDir $BackupDir

	Write-Log 'Addons data backed-up.'
}

<#
.SYNOPSIS
Restores addons from backup

.DESCRIPTION
Restores addons from addons config backup with the following steps:
- loads the config backup
- enables all configured addons
- invokes the addons restore hooks for addon-specific restore tasks, e.g. restoring data from backup

.PARAMETER BackupDir
Directory where the addons backup is located

.NOTES
- addons-specific config section gets passed to the addons restore hooks
- if addons appear to be obsolete, i.e. addons do not exist in the current version, the restore of obsolete addons will be skipped
#>
function Restore-Addons {
	param (
		[Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
		[string]$BackupDir = $(throw 'Please specify the back-up directory.'),
		[Parameter(Mandatory = $false, HelpMessage = 'Specifies whether to restore the addons or avoid it.')]
		[switch] $AvoidRestore,
		[Parameter(Mandatory = $false)]
		[string] $Root = $null
	)
	Write-Log 'Restoring addons..'

	$backupFilePath = (Join-Path $BackupDir $backupFileName)

	if ((Test-Path $backupFilePath) -ne $true) {
		Write-Log 'Addons config file back-up not found, skipping.'
		return
	}

	$backupContentRoot = Get-Content $backupFilePath -Raw | ConvertFrom-Json
	   
	# Conditionally invoke Invoke-BackupRestoreHooks based on the AvoidRestore parameter
	if ($AvoidRestore -eq $false) {
		foreach ($addonConfig in $backupContentRoot.Config) {
			Enable-AddonFromConfig -Config $addonConfig
		}
		Write-Log 'Restoring addons data..'
		Invoke-BackupRestoreHooks -HookType Restore -BackupDir $BackupDir
	}
	else {
		foreach ($addonConfig in $backupContentRoot.Config) {
			Enable-AddonFromConfig -Config $addonConfig -Root $Root
		}
		Write-Log 'Skipping restoring addons data.'
	}

	Write-Log 'Addons fully restored.'
}

function Get-AddonStatus {
	Param(
		[parameter(Mandatory = $false, HelpMessage = 'Name of the addon')]
		[string] $Name = $(throw 'Name not specified'),
		[parameter(Mandatory = $false, HelpMessage = 'Directory path of the addon')]
		[string] $Directory = $(throw 'Directory not specified')
	)
	$status = @{Error = $null }

	if ((Test-Path -Path $Directory) -ne $true) {
		$status.Error = New-Error -Severity Warning -Code (Get-ErrCodeAddonNotFound) -Message "Addon '$Name' not found in directory '$Directory'."
		return $status
	}

	$addonStatusScript = "$Directory\Get-Status.ps1"
	if ((Test-Path -Path $addonStatusScript) -ne $true) {
		$status.Error = New-Error -Severity Warning -Code 'no-addon-status' -Message "Addon '$Name' does not provide detailed status information."
		return $status
	}

	$systemError = Test-SystemAvailability -Structured
	if ($systemError) {
		$status.Error = $systemError
		return $status
	}

	$isEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = $Name })

	$status.Enabled = $isEnabled
	if ($isEnabled -ne $true) {
		$placementProps = @(Get-AddonInfrastructurePlacementStatus -Name $Name)
		if ($placementProps.Count -gt 0) { $status.Props = $placementProps }
		return $status
	}

	$status.Props = Invoke-Script -FilePath $addonStatusScript
	if ($Name -notin @('metrics', 'dashboard')) {
		$placementProps = @(Get-AddonInfrastructurePlacementStatus -Name $Name)
		if ($placementProps.Count -gt 0) { $status.Props = @($status.Props) + $placementProps }
	}

	return $status
}

function Get-ErrCodeAddonAlreadyDisabled { 'addon-already-disabled' }

function Get-ErrCodeAddonAlreadyEnabled { 'addon-already-enabled' }

function Get-ErrCodeAddonEnableFailed { 'addon-enable-failed' }

function Get-ErrCodeAddonNotFound { 'addon-not-found' }

function Get-ErrCodeInvalidParameter { 'addon-invalid-parameter' }

function Add-HostEntries {
	param (
		[Parameter(Mandatory = $false)]
		[string]
		$Url = $(throw 'Url not specified')
	)
	Write-Log "Adding host entry for '$Url'.." -Console

	# add in control plane
	$hostEntry = "$(Get-ConfiguredIPControlPlane) $Url"
	(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -qxF `'$hostEntry`' /etc/hosts || echo $hostEntry | sudo tee -a /etc/hosts").Output | Write-Log

	$hostFile = 'C:\Windows\System32\drivers\etc\hosts'

	# add in host
	$hostEntryPattern = '^\s*' + [regex]::Escape($hostEntry) + '\s*$'
	$hostEntryExists = $false
	if (Test-Path $hostFile) {
		$hostEntryExists = @((Get-Content -Path $hostFile -ErrorAction SilentlyContinue) | Where-Object { $_ -match $hostEntryPattern }).Count -gt 0
	}

	if (-not $hostEntryExists) {
		Add-Content -Path $hostFile -Value $hostEntry
	}
}

<#
.SYNOPSIS
    Adds a static host entry to the CoreDNS hosts block.
.DESCRIPTION
    Injects "ipAddress hostname" into the CoreDNS ConfigMap hosts {} block,
    anchored after the existing k2s.cluster.local line. Idempotent: no-op when
    the hostname is already present.
#>
function Add-CoreDNSHostEntry {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Hostname
    )
    $ipAddress = Get-ConfiguredIPControlPlane
    Write-Log "Adding '$ipAddress $Hostname' to CoreDNS hosts block.." -Console

    $result = Invoke-Kubectl -Params 'get', 'configmap', 'coredns', '-n', 'kube-system', '-o', 'jsonpath={.data.Corefile}'
    if (-not $result.Success) {
        throw "[CoreDNS] Failed to read CoreDNS ConfigMap: $($result.Output)"
    }

    $corefile = $result.Output -replace "`r", ''
    if ($corefile -match [regex]::Escape($Hostname)) {
        Write-Log "[CoreDNS] '$Hostname' already in CoreDNS hosts block, skipping"
        return
    }

    $injected = $false
    $newLines = foreach ($line in ($corefile -split "`n")) {
        $line
        if (-not $injected -and $line -match [regex]::Escape('k2s.cluster.local')) {
            "    $ipAddress $Hostname"
            $injected = $true
        }
    }

    if (-not $injected) {
        throw "[CoreDNS] Anchor 'k2s.cluster.local' not found in CoreDNS Corefile; cannot add entry"
    }

    $newCorefile = $newLines -join "`n"
    $patch = [ordered]@{ data = [ordered]@{ Corefile = $newCorefile } } | ConvertTo-Json -Compress -Depth 5
    $patchFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($patchFile, $patch, [System.Text.Encoding]::UTF8)
        $patchResult = Invoke-Kubectl -Params 'patch', 'configmap', 'coredns', '-n', 'kube-system', '--type=merge', "--patch-file=$patchFile"
        if (-not $patchResult.Success) {
            throw "[CoreDNS] Failed to patch CoreDNS ConfigMap: $($patchResult.Output)"
        }
    }
    finally {
        Remove-Item -Path $patchFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "'$ipAddress $Hostname' added to CoreDNS hosts block" -Console
}

<#
.SYNOPSIS
    Removes a static host entry from the CoreDNS hosts block.
.DESCRIPTION
    Deletes the line containing Hostname from the CoreDNS ConfigMap hosts {} block.
    Reverse operation of Add-CoreDNSHostEntry; intended to be called on addon disable.
    Uses kubectl patch --type=merge so the update is atomic. Idempotent: no-op when the
    hostname is not present.
#>
function Remove-CoreDNSHostEntry {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Hostname
    )
    Write-Log "Removing '$Hostname' from CoreDNS hosts block.." -Console

    $result = Invoke-Kubectl -Params 'get', 'configmap', 'coredns', '-n', 'kube-system', '-o', 'jsonpath={.data.Corefile}'
    if (-not $result.Success) {
        throw "[CoreDNS] Failed to read CoreDNS ConfigMap: $($result.Output)"
    }

    $corefile = $result.Output -replace "`r", ''
    if ($corefile -notmatch [regex]::Escape($Hostname)) {
        Write-Log "[CoreDNS] '$Hostname' not found in CoreDNS hosts block, skipping"
        return
    }

    $newCorefile = ($corefile -split "`n" | Where-Object { $_ -notmatch [regex]::Escape($Hostname) }) -join "`n"

    $patch = [ordered]@{ data = [ordered]@{ Corefile = $newCorefile } } | ConvertTo-Json -Compress -Depth 5
    $patchFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($patchFile, $patch, [System.Text.Encoding]::UTF8)
        $patchResult = Invoke-Kubectl -Params 'patch', 'configmap', 'coredns', '-n', 'kube-system', '--type=merge', "--patch-file=$patchFile"
        if (-not $patchResult.Success) {
            throw "[CoreDNS] Failed to patch CoreDNS ConfigMap: $($patchResult.Output)"
        }
    }
    finally {
        Remove-Item -Path $patchFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "'$Hostname' removed from CoreDNS hosts block" -Console
}

function Update-Addons {
	param (
		[Parameter(Mandatory = $false)]
		[string]
		$AddonName = $(throw 'Addon name not specified')
	)
	Write-Log "Adapting addons called from addon '$AddonName'" -Console

	$addons = Get-AddonsConfig

	if ($null -eq $addons) {
		Write-Log 'No addons to adapt, skipping' -Console
		return
	}

	$addons | ForEach-Object {
		# Not for addons with the name from input
		if ($_.Name -ne $AddonName) {
			$addon = $_.Name
			$addonConfig = Get-AddonConfig -Name $addon
			if ($null -eq $addonConfig) {
				Write-Log "Addon '$($addon.Name)' not found in config, skipping.." -Console
				return
			}

			$props = Get-AddonProperties -Addon ([pscustomobject] @{ Name = $addonConfig.Name; Implementation = $addonConfig.Implementation })

			if (Test-Path -Path "$PSScriptRoot\$($props.Directory)\Update.ps1") {
				&"$PSScriptRoot\$($props.Directory)\Update.ps1"
			}
		}
	}
	Write-Log 'Addons have been adapted' -Console
}

function Get-AddonProperties {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)
	if ($Addon -eq $null) {
		throw 'Addon not specified'
	}
	if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
		throw "Addon does not contain a property with name 'Name'"
	}

	$addonName = $Addon.Name
	$directory = $Addon.Name
	if ($null -ne $Addon.Implementation) {
		$addonName += " $($Addon.Implementation)"
		$directory += "\$($Addon.Implementation)"
	}

	return [pscustomobject]@{Name = $addonName; Directory = $directory }
}

<#
.DESCRIPTION
Updates the ingress manifest for an addon based on the ingress controller detected in the cluster.
#>
function Update-IngressForAddon {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	if (Test-NginxIngressControllerAvailability) {
		Remove-IngressForTraefik -Addon $Addon
		Remove-IngressForNginxGateway -Addon $Addon
		Update-IngressForNginx -Addon $Addon
	}
	elseif (Test-TraefikIngressControllerAvailability) {
		Remove-IngressForNginx -Addon $Addon
		Remove-IngressForNginxGateway -Addon $Addon
		Update-IngressForTraefik -Addon $Addon
	}
	elseif( Test-NginxGatewayAvailability) {
		Remove-IngressForTraefik -Addon $Addon
		Remove-IngressForNginx -Addon $Addon
		Update-IngressForNginxGateway -Addon $Addon
	}
	else {
		Remove-IngressForNginx -Addon $Addon
		Remove-IngressForTraefik -Addon $Addon
		Remove-IngressForNginxGateway -Addon $Addon
	}
}

<#
.DESCRIPTION
Determines if Nginx ingress controller is deployed in the cluster
#>
function Test-NginxIngressControllerAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-nginx', '-o', 'yaml').Output 
	if ("$existingServices" -match '.*ingress-nginx-controller.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if Traefik ingress controller is deployed in the cluster
#>
function Test-TraefikIngressControllerAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'ingress-traefik', '-o', 'yaml').Output
	if ("$existingServices" -match '.*traefik.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if Nginx gateway controller is deployed in the cluster
#>
function Test-NginxGatewayAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'nginx-gw', '-o', 'yaml').Output
	if ("$existingServices" -match '.*nginx.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if KeyCloak is deployed in the cluster
#>
function Test-KeyCloakServiceAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'security', '-o', 'yaml').Output
	if ("$existingServices" -match '.*keycloak.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if linkerd service is deployed in the cluster
#>
function Test-LinkerdServiceAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'linkerd', '-o', 'yaml').Output
	if ("$existingServices" -match '.*linkerd.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Determines if trust manager service is deployed in the cluster
#>
function Test-TrustManagerServiceAvailability {
	$existingServices = (Invoke-Kubectl -Params 'get', 'service', '-n', 'cert-manager', '-o', 'yaml').Output
	if ("$existingServices" -match '.*trust-manager*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Enables a ingress addon based on the input
#>
function Enable-IngressAddon([string]$Ingress) {
	switch ($Ingress) {
		'nginx' {
			&"$PSScriptRoot\ingress\nginx\Enable.ps1"
			break
		}
		'nginx-gw' {
			&"$PSScriptRoot\ingress\nginx-gw\Enable.ps1"
			break
		}
		'traefik' {
			&"$PSScriptRoot\ingress\traefik\Enable.ps1"
			break
		}
	}
}

<#
.DESCRIPTION
Creates a CA certificate ConfigMap for nginx-gw BackendTLSPolicy validation.
This function extracts the self-signed certificate from a backend service pod 
and creates a ConfigMap that can be referenced by BackendTLSPolicy.
.PARAMETER Namespace
The namespace where the pod and ConfigMap should be created
.PARAMETER PodLabel
The label selector to find the pod (e.g., 'app.kubernetes.io/name=kong')
.PARAMETER Port
The port number where the service is running with TLS (e.g., 8443)
.PARAMETER ConfigMapName
The name of the ConfigMap to create (e.g., 'kong-ca-cert','argocd-ca-cert')
#>
function New-BackendCACertConfigMap {
	param (
		[Parameter(Mandatory = $true)]
		[string]$Namespace,
		[Parameter(Mandatory = $true)]
		[string]$PodLabel,
		[Parameter(Mandatory = $true)]
		[int]$Port,
		[Parameter(Mandatory = $true)]
		[string]$ConfigMapName
	)
	
	Write-Log "Extracting CA certificate for BackendTLSPolicy from pod with label '$PodLabel' in namespace '$Namespace'" -Console
	
	# Wait for pod to be ready
	$waitResult = Wait-ForPodCondition -Label $PodLabel -Namespace $Namespace -Condition 'Ready' -TimeoutSeconds 60
	if (-not $waitResult) {
		throw "Pod with label '$PodLabel' in namespace '$Namespace' did not become ready within 60 seconds. Please use kubectl describe for more details."
	}
	
	# Get pod name
	$pod = (Invoke-Kubectl -Params 'get', 'pods', '-n', $Namespace, '-l', $PodLabel, '-o', 'jsonpath={.items[0].metadata.name}').Output
	
	if ($pod) {
		try {
			# Extract certificate from pod
			$certPath = [System.IO.Path]::GetTempPath() + "$ConfigMapName.crt"
			$extractCmd = "echo | openssl s_client -connect localhost:$Port 2>&1 | openssl x509 -outform PEM"
			
			# Get container name from pod spec (first container that's not linkerd-proxy or linkerd-init)
			$containerResult = (Invoke-Kubectl -Params 'get', 'pod', $pod, '-n', $Namespace, '-o', "jsonpath={.spec.containers[?(@.name!='linkerd-proxy')].name}")
			$containerName = if ($containerResult.Success -and $containerResult.Output) { 
				($containerResult.Output -split '\s+')[0] 
			} else { 
				$null 
			}
			
			if ($containerName) {
				Write-Log "Using container '$containerName' from pod '$pod'" -Console
				$cert = (Invoke-Kubectl -Params 'exec', '-n', $Namespace, $pod, '-c', $containerName, '--', 'sh', '-c', $extractCmd).Output
			} else {
				# Fallback to not specifying container (single container pods)
				$cert = (Invoke-Kubectl -Params 'exec', '-n', $Namespace, $pod, '--', 'sh', '-c', $extractCmd).Output
			}
			
			$cert | Out-File -FilePath $certPath -Encoding ascii
			
			# Create ConfigMap with the certificate
			(Invoke-Kubectl -Params 'create', 'configmap', $ConfigMapName, '-n', $Namespace, "--from-file=ca.crt=$certPath", '--dry-run=client', '-o', 'yaml').Output | & kubectl apply -f -
			
			# Clean up temp file
			Remove-Item -Path $certPath -ErrorAction SilentlyContinue
			
			Write-Log "CA certificate ConfigMap '$ConfigMapName' created successfully in namespace '$Namespace'" -Console
		}
		catch {
			Write-Log "Warning: Could not extract certificate from pod '$pod': $_" -Console
		}
	}
}

<#
.DESCRIPTION
Gets the location of traefik ingress yaml
#>
function Get-IngressTraefikConfig {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory of the ingress traefik config')
	)
	return "$PSScriptRoot\$Directory\manifests\ingress-traefik"
}

<#
.DESCRIPTION
Gets the location of nginx ingress yaml
#>
function Get-IngressNginxConfigDirectory {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory of the ingress nginx config')
	)
	return "$PSScriptRoot\$Directory\manifests\ingress-nginx"
}

<#
.DESCRIPTION
Gets the location of nginx ingress gateway yaml
#>
function Get-IngressNginxGatewayConfig {
	return 'ingress-nginx-gw'
}

<#
.DESCRIPTION
Gets the location of nginx secure ingress yaml
#>
function Get-IngressNginxGatewaySecureConfig {
	return 'ingress-nginx-gw-secure'
}

<#
.DESCRIPTION
Gets the location of nginx secure ingress yaml
#>
function Get-IngressNginxSecureConfig {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory of the ingress nginx secure config')
	)
	return "$PSScriptRoot\$Directory\manifests\ingress-nginx-secure"
}

function Test-HydraAvailability {
	$existingDeployments = (Invoke-Kubectl -Params 'get', 'deployment', '-n', 'security', '-o', 'yaml').Output
	if ("$existingDeployments" -match '.*hydra.*') {
		return $true
	}
	return $false
}

<#
.DESCRIPTION
Deploys the addon's ingress manifest for Nginx ingress controller
#>
function Update-IngressForNginx {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)
	$props = Get-AddonProperties -Addon $Addon
	$kustomizationDir = ''

	# Store each result separately for debugging
	$keycloakAvailable = Test-KeyCloakServiceAvailability
	Write-Log "KeyCloak available: $keycloakAvailable" -Console
	
	# Always evaluate Hydra availability
	$hydraAvailable = Test-HydraAvailability
	Write-Log "Hydra available: $hydraAvailable" -Console

	if ($keycloakAvailable -or $hydraAvailable) {
		Write-Log "  Applying secure nginx ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressNginxSecureConfig -Directory $props.Directory
		# check if $kustomizationDir does not exist
		if (!(Test-Path -Path $kustomizationDir)) {
			Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
			$kustomizationDir = Get-IngressNginxConfigDirectory -Directory $props.Directory
		}
	}
	else {
		Write-Log "  Applying nginx ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressNginxConfigDirectory -Directory $props.Directory
	}
	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console

	Write-Log '  [Webhook probe] Waiting for nginx admission webhook to accept connections (up to 120s)...' -Console
	$probeWaited = 0
	$probeMaxWait = 120
	do {
		$probeResult = Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir, '--dry-run=server'
		$outputText = ($probeResult.Output | ForEach-Object { "$_" }) -join "`n"
		if ($probeResult.Success -and $outputText -notmatch 'connection refused' -and $outputText -notmatch 'deadline exceeded') {
			Write-Log "  [Webhook probe] Webhook is accepting connections after ${probeWaited}s" -Console
			break
		}
		$notReadyReason = if ($outputText -match 'deadline exceeded') { 'deadline exceeded' } else { 'connection refused' }
		Write-Log "  [Webhook probe] Webhook not ready at ${probeWaited}s ($notReadyReason) - waiting 5s..." -Console
		Start-Sleep -Seconds 5
		$probeWaited += 5
	} while ($probeWaited -lt $probeMaxWait)
	if ($probeWaited -ge $probeMaxWait) {
		Write-Log '  [Webhook probe] WARNING: webhook did not become reachable within 120s; apply attempts will likely fail' -Console
	}

	# Retry logic: the admission webhook may transiently reject the ingress if the
	# controller has not yet fully loaded the ConfigMap (e.g. annotations-risk-level).
	$maxRetries = 3
	$retryDelay = 10
	$applied = $false
	for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
		$result = Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir
		if ($result.Success) {
			Write-Log "  Successfully applied ingress manifest for $($props.Name)" -Console
			$applied = $true
			break
		}
		Write-Log "  WARNING: Failed to apply ingress manifest for $($props.Name) (attempt $attempt/$maxRetries): $($result.Output)" -Console
		if ($attempt -lt $maxRetries) {
			Write-Log "  Retrying in $retryDelay seconds..." -Console
			Start-Sleep -Seconds $retryDelay
		}
	}
	if (-not $applied) {
		Write-Log "  ERROR: Failed to apply ingress manifest for $($props.Name) after $maxRetries attempts" -Console
		throw "[Ingress-Nginx] Failed to apply ingress manifest for '$($props.Name)' after $maxRetries attempts. " +
			"Check kubectl output above and nginx admission webhook availability."
	}
}

<#
.DESCRIPTION
Delete the addon's ingress manifest for Nginx ingress controller
#>
function Remove-IngressForNginx {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon

	# Check whether the nginx Ingress resource is actually deployed in the cluster.
	# The source manifest directories always exist on disk, so Test-Path on the
	# kustomization folder is not a reliable indicator — we must query the cluster.
	$nginxIngressExists = (Invoke-Kubectl -Params 'get', 'ingress', 'dashboard-nginx-cluster-local', '-n', 'dashboard', '--ignore-not-found').Output
	if ($nginxIngressExists) {
		# Both the standard (ingress-nginx) and secure (ingress-nginx-secure) variants
		# deploy an Ingress with the identical name 'dashboard-nginx-cluster-local'.
		# Delete both kustomizations with --ignore-not-found — whichever was applied will
		# be removed; the other delete is a safe no-op.
		$standardNginxConfig = Get-IngressNginxConfigDirectory -Directory $props.Directory
		$secureNginxConfig = Get-IngressNginxSecureConfig -Directory $props.Directory

		Write-Log "  Deleting nginx ingress manifest for $($props.Name)..." -Console
		Invoke-Kubectl -Params 'delete', '-k', $standardNginxConfig, '--ignore-not-found' | Out-Null
		Invoke-Kubectl -Params 'delete', '-k', $secureNginxConfig, '--ignore-not-found' | Out-Null
	}
	else {
		Write-Log "  No nginx ingress resource found for $($props.Name) in cluster, skipping delete."
	}
}

<#
.DESCRIPTION
Deploys the addon's ingress manifest for Traefik ingress controller
#>
function Update-IngressForTraefik {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon
	$kustomizationDir = ''

	$keycloakAvailable = Test-KeyCloakServiceAvailability
	Write-Log "KeyCloak available: $keycloakAvailable"

	$hydraAvailable = Test-HydraAvailability
	Write-Log "Hydra available: $hydraAvailable"

	if ($keycloakAvailable -or $hydraAvailable) {
		Write-Log "  Applying secure traefik ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressTraefikSecureConfig -Directory $props.Directory
		# check if $kustomizationDir does not exist
		if (!(Test-Path -Path $kustomizationDir)) {
			Write-Log "  Applying traefik ingress manifest for $($props.Name)..." -Console
			$kustomizationDir = Get-IngressTraefikConfig -Directory $props.Directory
		}
	}
	else {
		Write-Log "  Applying traefik ingress manifest for $($props.Name)..." -Console
		$kustomizationDir = Get-IngressTraefikConfig -Directory $props.Directory
	}

	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console
	$result = Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir
	if ($result.Success) {
		Write-Log "  Successfully applied ingress manifest for $($props.Name)" -Console
	}
	else {
		Write-Log "  ERROR: Failed to apply ingress manifest for $($props.Name): $($result.Output)" -Console
	}
}

<#
.DESCRIPTION
Delete the addon's ingress manifest for Traefik ingress controller
#>
function Remove-IngressForTraefik {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon

	# Check whether the traefik Ingress resource is actually deployed in the cluster.
	# The source manifest directories always exist on disk, so Test-Path on the
	# kustomization folder is not a reliable indicator — we must query the cluster.
	$traefikIngressExists = (Invoke-Kubectl -Params 'get', 'ingress', 'dashboard-traefik-cluster-local', '-n', 'dashboard', '--ignore-not-found').Output
	if ($traefikIngressExists) {
		# Both the standard (ingress-traefik) and secure (ingress-traefik-secure) variants
		# deploy an Ingress with the identical name 'dashboard-traefik-cluster-local'.
		# We cannot reliably determine which variant was applied by checking disk paths
		# (both directories always exist in the repo).
		# Solution: delete both kustomizations with --ignore-not-found — whichever was
		# applied will be removed; the other delete is a safe no-op.
		$standardTraefikConfig = Get-IngressTraefikConfig -Directory $props.Directory
		$secureTraefikConfig = Get-IngressTraefikSecureConfig -Directory $props.Directory

		Write-Log "  Deleting traefik ingress manifest for $($props.Name)..." -Console
		Invoke-Kubectl -Params 'delete', '-k', $standardTraefikConfig, '--ignore-not-found' | Out-Null
		Invoke-Kubectl -Params 'delete', '-k', $secureTraefikConfig, '--ignore-not-found' | Out-Null
	}
	else {
		Write-Log "  No traefik ingress resource found for $($props.Name) in cluster, skipping delete."
	}
}

<#
.DESCRIPTION
Deploys the addon's ingress manifest for ingress nginx gateway controller
#>
function Update-IngressForNginxGateway {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon
	$kustomizationDir = ''

	$keycloakAvailable = Test-KeyCloakServiceAvailability
	Write-Log "KeyCloak available: $keycloakAvailable"

	$hydraAvailable = Test-HydraAvailability
	Write-Log "Hydra available: $hydraAvailable"

	if ($keycloakAvailable -or $hydraAvailable) {
		Write-Log "  Applying secure nginx ingress gateway manifest for $($props.Name)..." -Console
		$ingressDir = Get-IngressNginxGatewaySecureConfig
		$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
		# check if $kustomizationDir does not exist
		if (!(Test-Path -Path $kustomizationDir)) {
			Write-Log "  Applying nginx ingress gateway manifest for $($props.Name)..." -Console
			$ingressDir = Get-IngressNginxGatewayConfig
			$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
		}
	}
	else {
		Write-Log "  Applying nginx ingress gateway manifest for $($props.Name)..." -Console
		$ingressDir = Get-IngressNginxGatewayConfig
		$kustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$ingressDir"
	}

	Write-Log "   Apply in cluster folder: $($kustomizationDir)" -Console

	$maxRetries = 3
	$retryDelay = 10
	$applied = $false
	for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
		$result = Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir, '--request-timeout=30s'
		if ($result.Success) {
			Write-Log "  Successfully applied ingress manifest for $($props.Name)" -Console
			$applied = $true
			break
		}
		Write-Log "  WARNING: Failed to apply ingress manifest for $($props.Name) (attempt $attempt/$maxRetries): $($result.Output)" -Console
		if ($attempt -lt $maxRetries) {
			Write-Log "  Retrying in $retryDelay seconds..." -Console
			Start-Sleep -Seconds $retryDelay
		}
	}
	if (-not $applied) {
		Write-Log "  ERROR: Failed to apply ingress manifest for $($props.Name) after $maxRetries attempts" -Console
		throw "[Ingress-NginxGw] Failed to apply ingress manifest for '$($props.Name)' after $maxRetries attempts. " +
			"Check kubectl output above and API server availability."
	}
}

<#
.DESCRIPTION
Delete the addon's ingress manifest for Gateway fabric controller
#>
function Remove-IngressForNginxGateway {
	param (
		[Parameter(Mandatory = $false)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.')
	)

	$props = Get-AddonProperties -Addon $Addon

	# Check whether the nginx-gw HTTPRoute resource is actually deployed in the cluster.
	# The source manifest directories always exist on disk, so Test-Path on the
	# kustomization folder is not a reliable indicator — we must query the cluster.
	# IMPORTANT: HTTPRoute is a CRD; when nginx-gw is NOT installed the CRD itself does
	# not exist and kubectl exits with a non-zero code, writing an error like
	# "the server doesn't have a resource type 'httproute'" to stderr (merged via 2>&1
	# into .Output).  We must therefore check BOTH Success=true AND non-empty Output to
	# avoid treating an API-discovery error as "resource exists".
	$gwRouteResult = Invoke-Kubectl -Params 'get', 'httproute', 'dashboard-nginx-gw-cluster-local', '-n', 'dashboard', '--ignore-not-found'
	if ($gwRouteResult.Success -and $gwRouteResult.Output) {
		# Both the standard (ingress-nginx-gw) and secure (ingress-nginx-gw-secure) variants
		# deploy resources with identical names (HTTPRoute + ReferenceGrant).
		# We cannot reliably determine which variant was applied by checking disk paths
		# (both directories always exist in the repo).
		# Solution: delete both kustomizations with --ignore-not-found — whichever was
		# applied will be removed; the other delete is a safe no-op.
		$standardIngressDir = Get-IngressNginxGatewayConfig
		$standardKustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$standardIngressDir"
		$secureIngressDir = Get-IngressNginxGatewaySecureConfig
		$secureKustomizationDir = "$PSScriptRoot\$($props.Directory)\manifests\$secureIngressDir"

		Write-Log "  Deleting gateway manifest for $($props.Name)..." -Console
		Invoke-Kubectl -Params 'delete', '-k', $standardKustomizationDir, '--ignore-not-found' | Out-Null
		Invoke-Kubectl -Params 'delete', '-k', $secureKustomizationDir, '--ignore-not-found' | Out-Null
	}
	else {
		Write-Log "  No nginx gateway route resource found for $($props.Name) in cluster, skipping delete."
	}
}

<#
.DESCRIPTION
Enables a storage addon based on the input
#>
function Enable-StorageAddon([string]$Storage) {
	switch ($Storage) {
		'smb' {
			&"$PSScriptRoot\storage\smb\Enable.ps1"
			break
		}
	}
}

function Get-AddonNameFromFolderPath {
	param (
		[string]$BaseFolderPath
	)

	# Split the path into an array of folder names
	$pathParts = $BaseFolderPath -split '\\'

	# Find the index of the 'addons' folder
	$addonsIndex = $pathParts.IndexOf('addons')

	# Check if 'addons' is found and there is a next folder
	if ($addonsIndex -ne -1 -and $addonsIndex -lt ($pathParts.Length - 1)) {
		# Return the next folder name after 'addons'
		return $pathParts[$addonsIndex + 1]
	}
	else {
		Write-Error "'addons' folder not found or no folder after 'addons'."
		return $null
	}
}

function Resolve-AddonImportPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AddonName,
        [Parameter(Mandatory = $false)]
        [string]$AddonImplementation
    )

    # Guard against artifacts whose addon-name annotation already carries the implementation
	# as its final segment (e.g. name 'storage ceph' + implementation 'ceph'). Appending the
	# implementation again would create a doubly-nested path such as addons/storage/ceph/ceph.
	if (-not [string]::IsNullOrWhiteSpace($AddonImplementation)) {
		$nameSegments = $AddonName -split '\s+' | Where-Object { $_ -ne '' }
		if ($nameSegments.Count -gt 1 -and $nameSegments[-1] -eq $AddonImplementation) {
			$AddonName = ($nameSegments[0..($nameSegments.Count - 2)] -join ' ')
		}
	}

	if ([string]::IsNullOrWhiteSpace($AddonImplementation) -or $AddonImplementation -eq $AddonName) {
		return @{
			BaseAddonName      = $AddonName
			ImplementationName = $null
		}
    }

    return @{
		BaseAddonName      = $AddonName
		ImplementationName = $AddonImplementation
    }
}

<#
.DESCRIPTION
Gets the location of traefik secure ingress yaml
#>
function Get-IngressTraefikSecureConfig {
	param (
		[Parameter(Mandatory = $false)]
		[string]$Directory = $(throw 'Directory of the ingress traefik secure config')
	)
	return "$PSScriptRoot\$Directory\manifests\ingress-traefik-secure"
}

function Write-BrowserWarningForUser {
	@'
Be aware: Browsers keep track on several security-related properties of web sites.
If you cannot access your site, then please delete the HSTS settings for your site (e.g. 'k2s.cluster.local')
here: chrome://net-internals/#hsts (works in Chrome and Edge) and try again.
  
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

<#
.DESCRIPTION
Extracts container images from YAML files referenced in additionalImagesFiles
#>
function Get-ImagesFromYamlFiles {
    param(
        [string[]]$YamlFiles,
        [string]$BaseDirectory
    )
    
    $allImages = @()
    
    foreach ($yamlFile in $YamlFiles) {
        if ([System.IO.Path]::IsPathRooted($yamlFile)) {
            $filePath = $yamlFile
        } else {
            $filePath = Join-Path $BaseDirectory $yamlFile
            $filePath = [System.IO.Path]::GetFullPath($filePath)
        }
        
        if (Test-Path $filePath) {
            Write-Log "Extracting images from $filePath"
            try {
                $content = Get-Content -Path $filePath -Raw
                $allImages += Get-ImagesFromYaml -YamlContent $content
            }
            catch {
                Write-Log "Warning: Failed to parse YAML file $filePath`: $($_.Exception.Message)"
            }
        } else {
            Write-Log "Warning: YAML file not found: $filePath"
        }
    }
    
    return $allImages | Select-Object -Unique | Where-Object { $_ -ne '' }
}

<#
.DESCRIPTION
Extracts container images from YAML content using pattern matching
#>
function Get-ImagesFromYaml {
    param([string]$YamlContent)
    
    $images = @()
    $lines = $YamlContent -split "`n"
    
    foreach ($line in $lines) {
        if ($line -match '^\s*image:\s*(.+)$') {
            $imageValue = ($matches[1] -split '#')[0].Trim().Trim('"').Trim("'")
            if ($imageValue -ne '') { $images += $imageValue }
        } elseif ($line -match '--[a-zA-Z-]+=([a-zA-Z0-9\.\-_/]+/[a-zA-Z0-9\.\-_/]+:[a-zA-Z0-9\.\-_]+)') {
            $imageValue = $matches[1].Trim()
            if ($imageValue -ne '' -and $imageValue.Contains('/') -and $imageValue.Contains(':')) { $images += $imageValue }
        }
    }
    
    return $images
}

<#
.DESCRIPTION
Removes versionless images when versioned equivalents exist
#>
function Remove-VersionlessImages {
    param([string[]]$Images)
    
    if (-not $Images) { return @() }
    
    $versioned = @{}
    $result = @()
    
    foreach ($image in $Images) {
        if ($image -match '^(.+):(.+)$' -and $matches[2].Trim()) {
            $versioned[$matches[1]] = $image
        }
    }
    
    foreach ($image in $Images) {
        if ($image -match '^(.+):(.+)$' -and $matches[2].Trim()) {
            if ($result -notcontains $image) { $result += $image }
        } elseif (-not $versioned.ContainsKey($image)) {
            if ($result -notcontains $image) { $result += $image }
        } else {
            Write-Log "Skipping versionless '$image' - using versioned '$($versioned[$image])'"
        }
    }
    
    return $result
}

<#
.SYNOPSIS
Gets the path to cert-manager manifest file.
.DESCRIPTION
Returns the absolute path to the cert-manager YAML manifest in the common addon folder.
#>
function Get-CertManagerConfig {
    return "$PSScriptRoot\common\manifests\certmanager\cert-manager.yaml"
}

<#
.SYNOPSIS
Gets the path to CA ClusterIssuer manifest file.
.DESCRIPTION
Returns the absolute path to the CA ClusterIssuer YAML manifest in the common addon folder.
#>
function Get-CAIssuerConfig {
    return "$PSScriptRoot\common\manifests\certmanager\ca-issuer.yaml"
}

<#
.SYNOPSIS
Downloads cmctl.exe CLI tool for cert-manager.
.DESCRIPTION
Downloads the cmctl.exe binary from the URL specified in addon.manifest.yaml.
Skips download if file already exists.
.PARAMETER ManifestPath
Path to the addon manifest YAML file containing download specifications.
.PARAMETER K2sRoot
Root directory of the K2s installation.
.PARAMETER Proxy
Optional proxy server to use for download.
#>
function Install-CmctlCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,
        
        [Parameter(Mandatory = $true)]
        [string] $K2sRoot,
        
        [Parameter(Mandatory = $false)]
        [string] $Proxy
    )
    $manifest = Get-FromYamlFile -Path $ManifestPath
    
    # Get the first implementation (nginx) which contains the cmctl download specification
    $windowsCurlPackages = $manifest.spec.implementations[0].offline_usage.windows.curl
    
    if (!$windowsCurlPackages) {
        return
    }
    foreach ($package in $windowsCurlPackages) {
		$destination = [string]$package.destination
        $url = $package.url
		$urlPath = ($url -split '\?')[0]
		$urlFileName = [System.IO.Path]::GetFileName($urlPath)

		if ($destination -notmatch '(?i)cmctl\.exe' -and $urlFileName -notmatch '(?i)^cmctl') {
			continue
		}

        if ($url -match '\.(zip|tar\.gz|tgz)(\?.*)?$') {
            Write-Log "Skipping archive package '$url' - handled by dedicated installer." -Console
            continue
        }

        $destination = "$K2sRoot\$destination"
        # Normalize path to ensure Test-Path works correctly
        $destination = [System.IO.Path]::GetFullPath($destination)
        
        if (Test-Path $destination) {
            Write-Log "File $destination already exists. Skipping download." -Console
            continue
        }
        Write-Log 'Downloading cert-manager CLI tools' -Console
        Invoke-DownloadFile $destination $url $true -ProxyToUse $Proxy
    }
}

<#
.SYNOPSIS
Installs cert-manager controllers in the cluster.
.DESCRIPTION
Applies cert-manager YAML manifest, waits for API readiness, and ensures
CRDs are fully established before returning. Throws on failure.
#>
function Install-CertManagerControllers {
    [CmdletBinding()]
	param([string]$InfraNodeSelector = '')

	Assert-SharedInfrastructurePlacement -Name 'cert-manager' -Selector $InfraNodeSelector -Namespace 'cert-manager' -Deployment 'cert-manager'
	if ($InfraNodeSelector) {
		$placement = New-AddonPlacementInput -AddonName 'certmanager' -Path (Get-CertManagerConfig) -Selector $InfraNodeSelector
		try {
			Set-SharedInfrastructurePlacement -Name 'cert-manager' -Selector $InfraNodeSelector
			$result = Invoke-Kubectl -Params 'apply', '--server-side', '-f', $placement.Path
			if (-not $result.Success) { throw "cert-manager apply failed: $($result.Output)" }
			if (-not $placement.HasMatchingNodes) { return $false }
			if (-not (Wait-ForCertManagerAvailable)) { throw 'cert-manager is not ready; shared placement is retained for retry.' }
			return $true
		}
		finally { Remove-Item -LiteralPath $placement.Path -Force -ErrorAction SilentlyContinue }
	}

    # Pre-pull cert-manager images on the control-plane node before applying
    # manifests so all pods start from cache and never race against a readiness
    # deadline waiting for a cold network pull from quay.io.
    Write-Log '[CertManager] Pre-pulling cert-manager images on control-plane node' -Console
    $certManagerConfig = Get-CertManagerConfig
    $certManagerImages = Get-ImagesFromYaml -YamlContent (Get-Content -Path $certManagerConfig -Raw) | Select-Object -Unique
    
    foreach ($image in $certManagerImages) {
        $inspectResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "sudo crictl inspecti '$image' >/dev/null 2>&1" -IgnoreErrors
        if ($inspectResult.Success -eq $true) {
            Write-Log "[CertManager] Image '$image' is already cached on control-plane node, skipping pull" -Console
            continue
        }

        Write-Log "[CertManager] Pre-pulling image: $image" -Console
        $pullResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute "sudo timeout 300 crictl pull '$image' 2>&1" -IgnoreErrors
        if ($pullResult.Success -eq $true) {
            Write-Log "[CertManager] Pre-pull succeeded: $image"
        }
        else {
            Write-Log "[CertManager] WARNING: Pre-pull of '$image' failed (will fall back to runtime pull): $($pullResult.Output)" -Console
        }
    }

    Write-Log 'Installing cert-manager' -Console
    (Invoke-Kubectl -Params 'apply', '-f', $certManagerConfig).Output | Write-Log

    Write-Log 'Waiting for cert-manager APIs to be ready, be patient!' -Console
    $certManagerStatus = Wait-ForCertManagerAvailable
    
    if ($certManagerStatus -ne $true) {
        throw "cert-manager is not ready. Please use cmctl.exe to investigate.`nInstallation of 'cert-manager' failed."
    }

    Write-Log '[CertManager] Waiting for cert-manager CRDs to be fully established' -Console
    $crdWaitResult = Invoke-Kubectl -Params 'wait', '--for=condition=Established', 'crd/clusterissuers.cert-manager.io', 'crd/certificates.cert-manager.io', '--timeout=120s'
    if ($crdWaitResult.Success -ne $true) {
        Write-Log "[CertManager] CRD wait output: $($crdWaitResult.Output)" -Console
        $crdStatus = (Invoke-Kubectl -Params 'get', 'crd', 'clusterissuers.cert-manager.io', 'certificates.cert-manager.io', '-o=wide').Output
        Write-Log "[CertManager] CRD status: $crdStatus" -Console
        throw "cert-manager CRDs did not become Established within 120s. CRD status: $crdStatus"
    }
    Write-Log '[CertManager] cert-manager CRDs are established' -Console

    # kubectl caches API discovery and HTTP responses locally. Even after CRDs
    # are Established, the cache will lack cert-manager.io/v1. Clear cache before
    # EACH probe because if the API server discovery hasn't updated yet when kubectl
    # re-fetches, the fresh-but-incomplete response gets cached again.
    Write-Log '[CertManager] Waiting for kubectl to recognize cert-manager CRDs' -Console
    $discoveryReady = $false
    for ($d = 1; $d -le 30; $d++) {
        Clear-KubectlDiscoveryCache
        $probe = Invoke-Kubectl -Params 'get', 'clusterissuers', '--no-headers', '--ignore-not-found'
        if ($probe.Success -eq $true) {
            Write-Log '[CertManager] kubectl can see cert-manager CRDs' -Console
            $discoveryReady = $true
            break
        }
        Write-Log "[CertManager] Discovery probe attempt $d/30 failed, retrying in 2s..." -Console
        Start-Sleep -Seconds 2
    }
    if (-not $discoveryReady) {
        Write-Log '[CertManager] WARNING: kubectl could not discover cert-manager CRDs within 60s' -Console
    }
}

<#
.SYNOPSIS
Initializes CA ClusterIssuer for cert-manager.
.DESCRIPTION
Applies CA ClusterIssuer manifest with retry logic, waits for root certificate creation,
and renews all existing certificates using the new CA.
#>
function Initialize-CACertificateIssuer {
    [CmdletBinding()]
    param()

    Write-Log 'Configuring CA ClusterIssuer' -Console
    $caIssuerConfig = Get-CAIssuerConfig

    $maxRetries = 5
    $retryDelay = 10
    $applied = $false
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Log "[CertManager] Applying CA issuer manifest (attempt $attempt/$maxRetries)" -Console
        # Clear kubectl cache before each attempt so stale cached discovery
        # responses don't prevent recognition of cert-manager CRD types
        Clear-KubectlDiscoveryCache
        $result = Invoke-Kubectl -Params 'apply', '--server-side', '--force-conflicts', '-f', $caIssuerConfig
        Write-Log "[CertManager] kubectl apply output: $($result.Output)"
        if ($result.Success -eq $true) {
            $applied = $true
            break
        }
        Write-Log "[CertManager] kubectl apply failed (attempt $attempt/$maxRetries): $($result.Output)" -Console
        if ($attempt -lt $maxRetries) {
            Start-Sleep -Seconds $retryDelay
        }
    }

    if (-not $applied) {
        throw "Failed to apply CA issuer manifest after $maxRetries attempts. Last output: $($result.Output)"
    }

    Write-Log 'Waiting for CA root certificate to be created' -Console
    $caCreated = Wait-ForCARootCertificate
    
    if ($caCreated -ne $true) {
        throw "CA root certificate 'ca-issuer-root-secret' not found.`nInstallation of 'cert-manager' failed."
    }

    # Capture the current CA content before renewal to detect rotation.
    $previousCaHash = Get-CARootCertificateHash

    # Write-Log 'Renewing old Certificates using the new CA Issuer' -Console
    Update-CertificateResources

    Wait-ForCARootCertificateRotation -PreviousHash $previousCaHash
}

<#
.DESCRIPTION
Waits for the cert-manager API to be available.
#>
function Wait-ForCertManagerAvailable {
    param(
        [string]$WaitTimeout = '10m'
    )
    $out = &$cmctlExe check api --wait=$WaitTimeout
    if ($out -match 'The cert-manager API is ready') {
        return $true
    }
	Write-Log "cmctl check api failed: $out"
    return $false
}

<#
.DESCRIPTION
Marks all cert-manager Certificate resources for renewal.
#>
function Update-CertificateResources {
    &$cmctlExe renew --all --all-namespaces
}

<#
.DESCRIPTION
Waits for the kubernetes secret 'ca-issuer-root-secret' in the namespace 'cert-manager' to be created.
#>
function Wait-ForCARootCertificate(
    [int]$SleepDurationInSeconds = 10,
    [int]$NumberOfRetries = 30) {
    for (($i = 1); $i -le $NumberOfRetries; $i++) {
        $out = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'secrets', 'ca-issuer-root-secret', '-o=jsonpath="{.metadata.name}"', '--ignore-not-found').Output
        if ($out -match 'ca-issuer-root-secret') {
            Write-Log "'ca-issuer-root-secret' created and ready for use."
            return $true
        }
        Write-Log "Retry {$i}: 'ca-issuer-root-secret' not yet created. Will retry after $SleepDurationInSeconds Seconds" -Console
        Start-Sleep -Seconds $SleepDurationInSeconds
    }

    # Dump diagnostics on failure
    Write-Log '[CertManager] ca-issuer-root-secret was not created. Collecting diagnostics...' -Console
    $certStatus = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'certificates', 'k2s-self-signed-ca', '-o=yaml', '--ignore-not-found').Output
    Write-Log "[CertManager] Certificate resource status: $certStatus" -Console
    $issuerStatus = (Invoke-Kubectl -Params 'get', 'clusterissuers', 'k2s-boot-strapper-issuer', '-o=yaml', '--ignore-not-found').Output
    Write-Log "[CertManager] ClusterIssuer status: $issuerStatus" -Console
    $cmPods = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'pods', '-o=wide').Output
    Write-Log "[CertManager] cert-manager pods: $cmPods" -Console
    $cmEvents = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'events', '--sort-by=.lastTimestamp').Output
    Write-Log "[CertManager] cert-manager events: $cmEvents" -Console

    return $false
}

# Returns the current CA content, or an empty string when it is unavailable.
function Get-CARootCertificateHash {
    $out = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'secrets', 'ca-issuer-root-secret', '-o', 'jsonpath', '--template', '{.data.ca\.crt}').Output
    if ([string]::IsNullOrWhiteSpace($out)) {
        return ''
    }
    return $out
}

# Waits for CA content to change after renewal, without blocking fresh installs.
function Wait-ForCARootCertificateRotation(
    [string]$PreviousHash,
    [int]$SleepDurationInSeconds = 5,
    [int]$NumberOfRetries = 12) {
    if ([string]::IsNullOrWhiteSpace($PreviousHash)) {
        Write-Log '[CertManager] No previous CA root certificate content captured; skipping rotation wait.'
        return $true
    }

    for ($i = 1; $i -le $NumberOfRetries; $i++) {
        $currentHash = Get-CARootCertificateHash
        if (-not [string]::IsNullOrWhiteSpace($currentHash) -and $currentHash -ne $PreviousHash) {
            Write-Log '[CertManager] CA root certificate rotation detected; proceeding with import.'
            return $true
        }
        if ($i -lt $NumberOfRetries) {
            Write-Log "Retry {$i}: CA root certificate not yet rotated. Will retry after $SleepDurationInSeconds Seconds" -Console
            Start-Sleep -Seconds $SleepDurationInSeconds
        }
    }

    Write-Log '[CertManager] CA root certificate rotation was not detected within the retry budget. Proceeding with import anyway; the imported CA may be stale until the next renewal cycle completes.' -Console
    return $false
}

function Remove-Cmctl {
    Write-Log "Removing $cmctlExe.."
    Remove-Item -Path $cmctlExe -Force -ErrorAction SilentlyContinue
}

function Get-TrustedRootStoreLocation {
    return 'Cert:\LocalMachine\Root'
}

function Get-CAIssuerName {
    return 'K2s Self-Signed CA'
}

function Test-CertificateProviderAvailable {
	try {
		$null = Get-PSDrive -Name 'Cert' -ErrorAction Stop
		return $true
	}
	catch {
		return $false
	}
}

function Import-CertificateToTrustedRootStore {
	param(
		[Parameter(Mandatory = $true)]
		[string]$CertificatePath,
		[Parameter(Mandatory = $true)]
		[string]$CertStoreLocation
	)

	if (-not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
		throw "Certificate file does not exist: '$CertificatePath'"
	}

	if (Test-CertificateProviderAvailable) {
		Import-Certificate -FilePath $CertificatePath -CertStoreLocation $CertStoreLocation -ErrorAction Stop | Out-Null
		return
	}

	$certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)
	$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
		[System.Security.Cryptography.X509Certificates.StoreName]::Root,
		[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
	)

	try {
		$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
		$store.Add($certificate)
	}
	finally {
		$store.Close()
		$certificate.Dispose()
	}
}

function Remove-CertificateFromTrustedRootStore {
	param(
		[Parameter(Mandatory = $true)]
		[string]$IssuerName,
		[Parameter(Mandatory = $true)]
		[string]$TrustedRootStoreLocation
	)

	if (Test-CertificateProviderAvailable) {
		Get-ChildItem -Path $TrustedRootStoreLocation | Where-Object { $_.Subject -match $IssuerName } | Remove-Item
		return
	}

	$store = [System.Security.Cryptography.X509Certificates.X509Store]::new(
		[System.Security.Cryptography.X509Certificates.StoreName]::Root,
		[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
	)

	try {
		$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
		$matchingCertificates = @($store.Certificates | Where-Object { $_.Subject -match $IssuerName })
		foreach ($certificate in $matchingCertificates) {
			$store.Remove($certificate)
		}
	}
	finally {
		$store.Close()
	}
}

function New-CompatTemporaryFile {
	<#
	.SYNOPSIS
	Creates a temporary file object compatible with New-TemporaryFile usage
	#>
	$tempPath = [System.IO.Path]::GetTempFileName()
	return [PSCustomObject]@{
		FullName = $tempPath
	}
}


<#
.SYNOPSIS
Imports CA certificate to Windows trusted root store.
.DESCRIPTION
Extracts CA certificate from Kubernetes secret and imports it to
Windows trusted certificate authorities.
#>
function Import-CACertificateToWindowsStore {
    [CmdletBinding()]
    param()

    Write-Log 'Importing CA root certificate to trusted authorities of your computer' -Console
    
    $b64secret = (Invoke-Kubectl -Params '-n', 'cert-manager', 'get', 'secrets', 'ca-issuer-root-secret', '-o', 'jsonpath', '--template', '{.data.ca\.crt}').Output
	$tempFile = New-CompatTemporaryFile
    $certLocationStore = Get-TrustedRootStoreLocation
    
    [Text.Encoding]::Utf8.GetString([Convert]::FromBase64String($b64secret)) | Out-File -Encoding utf8 -FilePath $tempFile.FullName -Force
    
	Import-CertificateToTrustedRootStore -CertificatePath $tempFile.FullName -CertStoreLocation $certLocationStore
    Remove-Item -Path $tempFile.FullName -Force
}

<#
.DESCRIPTION
Orchestrates complete cert-manager installation:
- Downloads cmctl.exe CLI tool
- Installs cert-manager controllers
- Configures CA ClusterIssuer
- Imports CA certificate to Windows trust store

Handles all errors internally and exits on failure.
.PARAMETER Proxy
Optional proxy server to use for downloads.
.PARAMETER EncodeStructuredOutput
Whether to encode error output for CLI consumption.
.PARAMETER MessageType
Message type for structured CLI output.
.EXAMPLE
Enable-CertManager -Proxy 'http://proxy.example.com:8080'
#>
function Enable-CertManager {
    [CmdletBinding()]
    param(
		[string] $InfraNodeSelector = '',
        [Parameter(Mandatory = $false)]
        [string] $Proxy,
        [Parameter(Mandatory = $false)]
        [switch] $EncodeStructuredOutput,
        [Parameter(Mandatory = $false)]
        [string] $MessageType
    )
    try {
   
		$manifestPath = "$PSScriptRoot\ingress\addon.manifest.yaml"
        $k2sRoot = "$PSScriptRoot\.."
        
        Install-CmctlCli -ManifestPath $manifestPath -K2sRoot $k2sRoot -Proxy $Proxy
		$controllersReady = Install-CertManagerControllers -InfraNodeSelector $InfraNodeSelector
		if ($InfraNodeSelector -and $controllersReady -eq $false) { return }
        
        Initialize-CACertificateIssuer
        
        Import-CACertificateToWindowsStore

        Write-Log 'cert-manager installation completed successfully' -Console
    }
    catch {
        $errMsg = "cert-manager installation failed: $($_.Exception.Message)"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            exit 1
        }
        Write-Log $errMsg -Error
        exit 1
    }
}

<#
.SYNOPSIS
Creates a standardized status property object for addon status reporting.
.DESCRIPTION
Provides consistent status property format across all addons with Name, Value, Okay, and Message fields.
.PARAMETER Name
The name of the status property (e.g., 'IsCertManagerAvailable').
.PARAMETER Value
The boolean value indicating the status (typically result from a test function).
.PARAMETER SuccessMessage
The message to display when Value is $true.
.PARAMETER FailureMessage
The message to display when Value is $false.
.EXAMPLE
$certManagerProp = New-AddonStatusProperty `
    -Name 'IsCertManagerAvailable' `
    -Value (Wait-ForCertManagerAvailable) `
    -SuccessMessage 'The cert-manager API is ready' `
    -FailureMessage 'The cert-manager API is not ready. Please use cmctl.exe for diagnostics.'
#>
function New-AddonStatusProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [bool] $Value,
        [Parameter(Mandatory = $true)]
        [string] $SuccessMessage,
        [Parameter(Mandatory = $true)]
        [string] $FailureMessage
    )
    return @{
        Name = $Name
        Value = $Value
        Okay = $Value
        Message = if ($Value) { $SuccessMessage } else { $FailureMessage }
    }
}

<#
.SYNOPSIS
Clears the kubectl API discovery cache from disk.
.DESCRIPTION
Deletes the kubectl discovery cache directory (~/.kube/cache/discovery/) so that
subsequent kubectl commands re-fetch the API server's discovery document.
This is required after installing new CRDs because kubectl's cached discovery
has a long TTL and will not pick up newly registered API groups/versions
automatically. Without this, commands like 'kubectl apply' and 'kubectl get'
fail with 'no matches for kind' errors for CRD-based resources.
.EXAMPLE
Clear-KubectlDiscoveryCache
#>
function Clear-KubectlDiscoveryCache {
    [CmdletBinding()]
    param()

    $kubeCacheDir = Join-Path (Join-Path $env:USERPROFILE '.kube') 'cache'
    if (Test-Path $kubeCacheDir) {
        Write-Log '[kubectl] Clearing kubectl cache to pick up newly registered CRDs' -Console
        Remove-Item -Recurse -Force $kubeCacheDir -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
Gets the path to Gateway API CRDs manifest file.
.DESCRIPTION
Returns the absolute path to the Gateway API v1.4.1 CRDs YAML manifest in the common addon folder.
#>
function Get-GatewayApiCrdsConfig {
    return "$PSScriptRoot\common\manifests\crds\gateway-crds\gateway-api-v1.4.1.yaml"
}

<#
.SYNOPSIS
Installs Gateway API CRDs in the cluster.
.DESCRIPTION
Applies Gateway API v1.4.1 Custom Resource Definitions (GatewayClass, Gateway, HTTPRoute, etc.)
used by ingress controllers like nginx-gw and traefik.
.EXAMPLE
Install-GatewayApiCrds
#>
function Install-GatewayApiCrds {
    [CmdletBinding()]
    param()

    Write-Log 'Installing Gateway API CRDs' -Console
    $gatewayApiCrds = Get-GatewayApiCrdsConfig
    # Use --server-side to avoid oversized last-applied annotations on large CRDs
    (Invoke-Kubectl -Params 'apply', '--server-side', '-f', $gatewayApiCrds).Output | Write-Log

    # Wait for Gateway CRD to be fully established before clearing cache
    Write-Log '[GatewayAPI] Waiting for Gateway API CRDs to be fully established' -Console
    $gwCrdWait = Invoke-Kubectl -Params 'wait', '--for=condition=Established', 'crd/gateways.gateway.networking.k8s.io', '--timeout=120s'
    if ($gwCrdWait.Success -ne $true) {
        Write-Log "[GatewayAPI] CRD wait output: $($gwCrdWait.Output)" -Console
        Write-Log '[GatewayAPI] WARNING: Gateway API CRDs may not be fully established' -Console
    }

    # Clear stale kubectl discovery cache and verify Gateway type is visible
    Clear-KubectlDiscoveryCache
    Write-Log '[GatewayAPI] Waiting for kubectl discovery cache to include Gateway API CRDs' -Console
    $gwDiscoveryReady = $false
    for ($d = 1; $d -le 15; $d++) {
        $probe = Invoke-Kubectl -Params 'get', 'gateways.gateway.networking.k8s.io', '--no-headers', '--ignore-not-found', '-A'
        if ($probe.Success -eq $true) {
            Write-Log '[GatewayAPI] kubectl discovery cache is up-to-date' -Console
            $gwDiscoveryReady = $true
            break
        }
        Write-Log "[GatewayAPI] Discovery probe attempt $d/15 failed, retrying in 2s..." -Console
        Start-Sleep -Seconds 2
    }
    if (-not $gwDiscoveryReady) {
        Write-Log '[GatewayAPI] WARNING: kubectl discovery cache did not refresh within 30s' -Console
    }
}

<#
.SYNOPSIS
Uninstalls Gateway API CRDs from the cluster.
.DESCRIPTION
Removes Gateway API v1.4.1 Custom Resource Definitions from the cluster.
Warning: This will fail if any Gateway, HTTPRoute, or other Gateway API resources still exist.
.EXAMPLE
Uninstall-GatewayApiCrds
#>
function Uninstall-GatewayApiCrds {
    [CmdletBinding()]
    param()

    Write-Log 'Uninstalling Gateway API CRDs' -Console
    $gatewayApiCrds = Get-GatewayApiCrdsConfig
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $gatewayApiCrds).Output | Write-Log
}

<#
.SYNOPSIS
Gets cert-manager status properties for addon status reporting.
.DESCRIPTION
Returns two status properties:
1. IsCertManagerAvailable - checks if cert-manager API is ready
2. IsCaRootCertificateAvailable - checks if CA root certificate secret exists
.EXAMPLE
$certManagerProps = Get-CertManagerStatusProperties
return $isIngressRunningProp, $certManagerProps
#>
function Get-CertManagerStatusProperties {
    [CmdletBinding()]
    param()

    try {
        # Check if cert-manager is installed by probing the namespace
        $certManagerNs = (Invoke-Kubectl -Params 'get', 'namespace', 'cert-manager', '--ignore-not-found').Output
        if (-not (Test-Path $cmctlExe) -or [string]::IsNullOrWhiteSpace($certManagerNs)) {
            $certManagerProp = @{
                Name    = 'IsCertManagerAvailable'
                Value   = $false
                Okay    = $false
                Message = 'The cert-manager is not installed (omitted during addon enablement).'
            }
            $caRootCertificateProp = @{
                Name    = 'IsCaRootCertificateAvailable'
                Value   = $false
                Okay    = $false
                Message = 'The CA root certificate is not available (cert-manager was omitted).'
            }
            return $certManagerProp, $caRootCertificateProp
        }

        $certManagerAvailable = Wait-ForCertManagerAvailable
        $certManagerProp = @{
            Name    = 'IsCertManagerAvailable'
            Value   = $certManagerAvailable
            Okay    = $certManagerAvailable
            Message = if ($certManagerAvailable) { 'The cert-manager API is ready' } else { 'The cert-manager API is not ready. Please use cmctl.exe for further diagnostics.' }
        }

        $caRootCertificateAvailable = Wait-ForCARootCertificate
        $caRootCertificateProp = @{
            Name    = 'IsCaRootCertificateAvailable'
            Value   = $caRootCertificateAvailable
            Okay    = $caRootCertificateAvailable
            Message = if ($caRootCertificateAvailable) { 'The CA root certificate is available' } else { "The CA root certificate is not available ('ca-issuer-root-secret' not created)." }
        }

        return $certManagerProp, $caRootCertificateProp
    }
    catch {
        Write-Log "[CertManager] Error checking cert-manager status: $($_.Exception.Message)" -Console
        $certManagerProp = @{
            Name    = 'IsCertManagerAvailable'
            Value   = $false
            Okay    = $false
            Message = 'The cert-manager is not installed (omitted during addon enablement).'
        }
        $caRootCertificateProp = @{
            Name    = 'IsCaRootCertificateAvailable'
            Value   = $false
            Okay    = $false
            Message = 'The CA root certificate is not available (cert-manager was omitted).'
        }
        return $certManagerProp, $caRootCertificateProp
    }
}

<#
.SYNOPSIS
Disables and uninstalls cert-manager from the cluster.
.DESCRIPTION
Removes cert-manager components:
- Deletes CA ClusterIssuer
- Uninstalls cert-manager controllers
- Removes cmctl.exe CLI tool
- Removes CA certificate from Windows trusted root store
.EXAMPLE
Uninstall-CertManager
#>
function Uninstall-CertManager {
    [CmdletBinding()]
    param()

    Write-Log 'Uninstalling cert-manager' -Console
    
    $certManagerConfig = Get-CertManagerConfig
    $caIssuerConfig = Get-CAIssuerConfig

    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $caIssuerConfig).Output | Write-Log
    (Invoke-Kubectl -Params 'delete', '--ignore-not-found', '--timeout=30s', '-f', $certManagerConfig).Output | Write-Log

    Write-Log 'Removing CA issuer certificate from trusted root' -Console
    $caIssuerName = Get-CAIssuerName
    $trustedRootStoreLocation = Get-TrustedRootStoreLocation
	Remove-CertificateFromTrustedRootStore -IssuerName $caIssuerName -TrustedRootStoreLocation $trustedRootStoreLocation
}

function Wait-ForK8sSecret {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [int]$TimeoutSeconds = 60,
        [int]$CheckIntervalSeconds = 4
    )

    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TimeoutSeconds)

    $kubeToolsPath = Get-KubeToolsPath
    while ((Get-Date) -lt $endTime) {
        try {
            $secret = &"$kubeToolsPath\kubectl.exe" get secret $SecretName -n $Namespace --ignore-not-found
            if ($secret) {
                Write-Log "Secret '$SecretName' is available." -Console
                return $true
            }
        }
        catch {
            Write-Log "Error checking for secret: $_" -Console
        }

        Start-Sleep -Seconds $CheckIntervalSeconds
    }

    Write-Log "Timed out waiting for secret '$SecretName' in namespace '$Namespace'." -Console
    return $false
}
<#
.SYNOPSIS
Asserts TLS certificate exists in ingress namespace.
.DESCRIPTION
Checks if k2s-cluster-local-tls secret exists in the ingress namespace.
If not found, re-applies the Certificate manifest to trigger cert-manager creation.
.PARAMETER IngressType
Type of ingress controller (nginx, traefik, or nginx-gw).
.PARAMETER CertificateManifestPath
Optional path to the Certificate manifest. If not provided, derived from ingress type.
.EXAMPLE
Assert-IngressTlsCertificate -IngressType 'nginx'
#>
function Assert-IngressTlsCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('nginx', 'traefik', 'nginx-gw')]
        [string] $IngressType,

        [Parameter(Mandatory = $false)]
        [string] $CertificateManifestPath
    )

    $namespace = switch ($IngressType) {
        'nginx' { 'ingress-nginx' }
        'traefik' { 'ingress-traefik' }
        'nginx-gw' { 'nginx-gw' }
    }

    Write-Log "Verifying TLS certificate exists in $namespace namespace" -Console
    $certExists = Wait-ForK8sSecret -SecretName 'k2s-cluster-local-tls' -Namespace $namespace -TimeoutSeconds 30

    if (-not $certExists) {
        Write-Log "Certificate not found, applying Certificate manifest to trigger creation" -Console
        (Invoke-Kubectl -Params 'apply', '-f', $CertificateManifestPath).Output | Write-Log
        $certExists = Wait-ForK8sSecret -SecretName 'k2s-cluster-local-tls' -Namespace $namespace -TimeoutSeconds 60

        if (-not $certExists) {
            Write-Log "Warning: TLS certificate still not available after applying manifest" -Console
        }
    }
    else {
        Write-Log "TLS certificate already exists in $namespace namespace" -Console
    }

    return $certExists
}

<#
.SYNOPSIS
	Stores an additional property on an enabled addon entry in setup.json
.DESCRIPTION
	Finds the matching addon entry in the "EnabledAddons" array of setup.json (by Name and, if provided,
	Implementation) and sets/updates a single property on it. Used to persist addon runtime data such as
	the cephadm cluster public key so it can be retrieved later (e.g. by the addon Update script when a new
	OSD host is added to the cluster).
.PARAMETER Addon
	The addon object containing a 'Name' property and optionally an 'Implementation' property.
.PARAMETER PropertyName
	Name of the property to store on the addon entry.
.PARAMETER PropertyValue
	Value of the property to store.
.EXAMPLE
	Set-AddonSetupJsonProperty -Addon ([pscustomobject]@{Name='storage';Implementation='ceph'}) -PropertyName 'CephPublicKey' -PropertyValue $key
#>
function Set-AddonSetupJsonProperty {
	param (
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.'),
		[Parameter(Mandatory = $true)]
		[string]$PropertyName = $(throw 'Please specify the property name.'),
		[Parameter(Mandatory = $false)]
		[string]$PropertyValue = ''
	)
	if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
		throw "Addon does not contain a property with name 'Name'"
	}

	$filePath = Get-SetupConfigFilePath
	$parsedSetupJson = Get-Content -Raw $filePath | ConvertFrom-Json

	$enabledAddonMemberExists = Get-Member -InputObject $parsedSetupJson -Name $ConfigKey_EnabledAddons -MemberType Properties
	if (!$enabledAddonMemberExists) {
		Write-Log "No enabled addons found in setup.json; cannot store property '$PropertyName' for addon '$($Addon.Name)'."
		return
	}

	$matchingEntry = $parsedSetupJson.EnabledAddons | Where-Object {
		($_.Name -eq $Addon.Name) -and ($null -eq $Addon.Implementation -or $_.Implementation -eq $Addon.Implementation)
	} | Select-Object -First 1

	if ($null -eq $matchingEntry) {
		Write-Log "Addon '$($Addon.Name)' not found in setup.json; cannot store property '$PropertyName'."
		return
	}

	$matchingEntry | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $PropertyValue -Force
	$parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $filePath -Confirm:$false
}

<#
.SYNOPSIS
	Reads an additional property from an enabled addon entry in setup.json
.DESCRIPTION
	Returns the value of a property previously stored on an addon entry in the "EnabledAddons" array of
	setup.json (e.g. the cephadm cluster public key). Returns an empty string when the addon or the property
	is not present.
.PARAMETER Addon
	The addon object containing a 'Name' property and optionally an 'Implementation' property.
.PARAMETER PropertyName
	Name of the property to read from the addon entry.
.EXAMPLE
	Get-AddonSetupJsonProperty -Addon ([pscustomobject]@{Name='storage';Implementation='ceph'}) -PropertyName 'CephPublicKey'
#>
function Get-AddonSetupJsonProperty {
	param (
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Addon = $(throw 'Please specify the addon.'),
		[Parameter(Mandatory = $true)]
		[string]$PropertyName = $(throw 'Please specify the property name.')
	)
	if ($null -eq ($Addon | Get-Member -MemberType Properties -Name 'Name')) {
		throw "Addon does not contain a property with name 'Name'"
	}

	$addons = Get-AddonsConfig
	if ($null -eq $addons) {
		return ''
	}

	$matchingEntry = $addons | Where-Object {
		($_.Name -eq $Addon.Name) -and ($null -eq $Addon.Implementation -or $_.Implementation -eq $Addon.Implementation)
	} | Select-Object -First 1

	if ($null -eq $matchingEntry) {
		return ''
	}

	$propertyExists = $matchingEntry | Get-Member -MemberType Properties -Name $PropertyName
	if ($null -eq $propertyExists) {
		return ''
	}

	return "$($matchingEntry.$PropertyName)"
}

Export-ModuleMember -Function Assert-AddonStoragePlacement, Assert-SharedInfrastructurePlacement, Set-SharedInfrastructurePlacement, Invoke-AddonOwnedApply, Set-AddonPlacementIntent, Enable-AddonFromConfig, Get-EnabledAddons, Add-AddonToSetupJson, Remove-AddonFromSetupJson, Set-AddonSetupJsonProperty, Get-AddonSetupJsonProperty,
Get-AddonPlacementOwnerOptions, New-AddonPlacementInput, Assert-AddonPlacementHost, New-AddonPlacementManifest, Test-AddonPlacementIntent, Get-AddonEffectiveInfrastructureSelector, Get-AddonInfrastructurePlacementStatus, Invoke-AddonEnableTransaction, Get-AddonPlacementSelectorConflictMessage, Get-AddonBackupInfrastructureSelector, Test-AddonInfrastructureSelectorOnCluster,
Install-DebianPackages, Get-DebianPackageAvailableOffline, Test-IsAddonEnabled, Invoke-AddonsHooks, Copy-ScriptsToHooksDir,
Remove-ScriptsFromHooksDir, Get-AddonConfig, Backup-Addons, Restore-Addons, Get-AddonStatus, Find-AddonManifests,
Get-ErrCodeAddonAlreadyDisabled, Get-ErrCodeAddonAlreadyEnabled, Get-ErrCodeAddonEnableFailed, Get-ErrCodeAddonNotFound, Get-ErrCodeInvalidParameter,
Add-HostEntries, Add-CoreDNSHostEntry, Remove-CoreDNSHostEntry, Get-AddonsConfig, Update-Addons, Update-IngressForAddon, Test-NginxIngressControllerAvailability, Test-TraefikIngressControllerAvailability,
Test-KeyCloakServiceAvailability, Enable-IngressAddon, Remove-IngressForTraefik, Remove-IngressForNginx, Get-AddonProperties, Get-IngressNginxConfigDirectory,
Update-IngressForTraefik, Update-IngressForNginx, Get-IngressNginxSecureConfig, Get-IngressTraefikConfig, Enable-StorageAddon, Get-AddonNameFromFolderPath, Resolve-AddonImportPath,
Test-LinkerdServiceAvailability, Test-TrustManagerServiceAvailability, Get-IngressTraefikSecureConfig, Write-BrowserWarningForUser,
Get-ImagesFromYamlFiles, Get-ImagesFromYaml, Remove-VersionlessImages, Get-IngressNginxGatewayConfig, Remove-IngressForNginxGateway, Update-IngressForNginxGateway, Test-NginxGatewayAvailability, Get-IngressNginxGatewaySecureConfig,
Get-CertManagerConfig, Get-CAIssuerConfig, Install-CmctlCli, Install-CertManagerControllers, Initialize-CACertificateIssuer, Import-CACertificateToWindowsStore, Enable-CertManager, Uninstall-CertManager, New-AddonStatusProperty, Get-CertManagerStatusProperties, Wait-ForCertManagerAvailable,
Get-GatewayApiCrdsConfig, Install-GatewayApiCrds, Uninstall-GatewayApiCrds, Assert-IngressTlsCertificate, Wait-ForK8sSecret, New-BackendCACertConfigMap,
Clear-KubectlDiscoveryCache
