# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

function Test-NodePackageGuestIpAvailability {
	param(
		[Parameter(Mandatory = $true)]
		[string] $IpAddress,
		[Parameter(Mandatory = $true)]
		[string] $SwitchName,
		[Parameter(Mandatory = $true)]
		[string[]] $ReservedIpAddresses,
		[Parameter(Mandatory = $false)]
		[string] $LogPrefix = '[NodePkg]'
	)

	$normalizedIp = $IpAddress.Trim()
	$normalizedReserved = @($ReservedIpAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })

	if ($normalizedReserved -contains $normalizedIp) {
		Write-Log ("{0} Candidate guest IP '{1}' is reserved by K2s networking. Skipping." -f $LogPrefix, $normalizedIp)
		return $false
	}

	$matchingAdapters = @(Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue | Where-Object {
		$adapterIps = @($_.IPAddresses)
		$adapterIps -contains $normalizedIp
	})
	if ($matchingAdapters.Count -gt 0) {
		$vmNames = ($matchingAdapters | Select-Object -ExpandProperty VMName -Unique) -join ', '
		Write-Log ("{0} Candidate guest IP '{1}' is already assigned to Hyper-V VM(s): {2}. Skipping." -f $LogPrefix, $normalizedIp, $vmNames)
		return $false
	}

	$neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
		$_.IPAddress -eq $normalizedIp -and $_.State -ne 'Unreachable'
	})
	if ($neighbors.Count -gt 0) {
		$activeNeighbors = @($neighbors | Where-Object { $_.State -in @('Reachable', 'Permanent') })
		if ($activeNeighbors.Count -gt 0) {
			$ifIndexes = ($activeNeighbors | Select-Object -ExpandProperty ifIndex -Unique) -join ', '
			Write-Log ("{0} Candidate guest IP '{1}' has active neighbor entries (ifIndex={2}). Skipping." -f $LogPrefix, $normalizedIp, $ifIndexes)
			return $false
		}

		$neighborStates = ($neighbors | Select-Object -ExpandProperty State -Unique) -join ', '
		Write-Log ("{0} Candidate guest IP '{1}' has non-active neighbor cache state(s): {2}. Continuing with active checks." -f $LogPrefix, $normalizedIp, $neighborStates)
	}

	if (Test-Connection -ComputerName $normalizedIp -Count 1 -Quiet -ErrorAction SilentlyContinue) {
		Write-Log ("{0} Candidate guest IP '{1}' responds to ping. Skipping." -f $LogPrefix, $normalizedIp)
		return $false
	}

	return $true
}

function Get-NodePackagePreferredHostOctets {
	param(
		[Parameter(Mandatory = $true)]
		[string] $DistributionKey
	)

	$normalizedKey = $DistributionKey.Trim().ToLower()
	if ($normalizedKey -eq 'debian13') {
		return @(102, 101)
	}

	return @(101, 102)
}

function Get-AvailableNodePackageGuestIp {
	param(
		[Parameter(Mandatory = $true)]
		[string] $ControlPlaneCIDR,
		[Parameter(Mandatory = $true)]
		[string] $SwitchName,
		[Parameter(Mandatory = $true)]
		[string[]] $ReservedIpAddresses,
		[Parameter(Mandatory = $false)]
		[int[]] $PreferredHostOctets = @(101, 102),
		[Parameter(Mandatory = $false)]
		[string] $LogPrefix = '[NodePkg]'
	)

	$cidrParts = $ControlPlaneCIDR -split '/'
	if ($cidrParts.Count -ne 2) {
		throw ("{0} Invalid CIDR format '{1}'." -f $LogPrefix, $ControlPlaneCIDR)
	}

	$prefixLen = [int]$cidrParts[1]
	if ($prefixLen -ne 24) {
		throw ("{0} KubeSwitch-based node package provisioning currently expects a /24 control-plane CIDR. Found '{1}'." -f $LogPrefix, $ControlPlaneCIDR)
	}

	$networkBase = ($cidrParts[0] -replace '\.0$', '')
	$candidates = New-Object System.Collections.Generic.List[string]
	$hardBlockedHostOctets = @(1, 2)

	foreach ($octet in $PreferredHostOctets) {
		if ($octet -ge 1 -and $octet -le 254 -and $hardBlockedHostOctets -notcontains $octet) {
			$candidates.Add("$networkBase.$octet")
		}
	}

	for ($octet = 3; $octet -le 254; $octet++) {
		$candidateIp = "$networkBase.$octet"
		if (-not $candidates.Contains($candidateIp)) {
			$candidates.Add($candidateIp)
		}
	}

	foreach ($candidateIp in $candidates) {
		if (Test-NodePackageGuestIpAvailability -IpAddress $candidateIp -SwitchName $SwitchName -ReservedIpAddresses $ReservedIpAddresses -LogPrefix $LogPrefix) {
			return $candidateIp
		}
	}

	throw ("{0} Could not find a free guest IP in '{1}'." -f $LogPrefix, $ControlPlaneCIDR)
}

function Start-NodePackageVmProvisioning {
	param (
		[Parameter(Mandatory = $true)]
		[string] $DistributionKey,
		[Parameter(Mandatory = $true)]
		[string] $VmName,
		[Parameter(Mandatory = $false)]
		[string] $Hostname = '',
		[Parameter(Mandatory = $false)]
		[string] $GuestIp = '',
		[Parameter(Mandatory = $false)]
		[string] $Proxy = '',
		[Parameter(Mandatory = $false)]
		[switch] $ShowLogs
	)

	# Hardcoded defaults
	$sshUser = 'admin'
	$sshPwd = 'admin'
	$netIntf = 'eth0'

	$kubePath = Get-KubePath
	$kubeBinPath = Get-KubeBinPath

	$switchName = Get-ControlPlaneNodeDefaultSwitchName
	$controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
	$hostIp = Get-ConfiguredKubeSwitchIP
	$masterIp = Get-ConfiguredIPControlPlane
	$reservedIps = @($hostIp, $masterIp)
	if ([string]::IsNullOrWhiteSpace($GuestIp)) {
		$preferredHostOctets = Get-NodePackagePreferredHostOctets -DistributionKey $DistributionKey
		$guestIp = Get-AvailableNodePackageGuestIp -ControlPlaneCIDR $controlPlaneCIDR -SwitchName $switchName -ReservedIpAddresses $reservedIps -PreferredHostOctets $preferredHostOctets -LogPrefix '[NodePkg]'
	}
	else {
		$guestIp = $GuestIp.Trim()
		if (-not (Test-NodePackageGuestIpAvailability -IpAddress $guestIp -SwitchName $switchName -ReservedIpAddresses $reservedIps -LogPrefix '[NodePkg]')) {
			throw "[NodePkg] Requested guest IP '$guestIp' is not available."
		}
	}
	$prefixLen = [int](($controlPlaneCIDR -split '/')[1])

	$kubeSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
	if ($null -eq $kubeSwitch) {
		Write-Log "[NodePkg] KubeSwitch '$switchName' not found. Creating it for node package VM provisioning." -Console
		New-KubeSwitch
	}
	else {
		Write-Log "[NodePkg] Reusing existing KubeSwitch '$switchName' for node package VM provisioning." -Console
	}
	Write-Log "[NodePkg] Using KubeSwitch subnet '$controlPlaneCIDR' with guest IP '$guestIp' and gateway '$hostIp'." -Console

	$hostDns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
		ForEach-Object { @($_.ServerAddresses) } |
		Where-Object { $_ -and $_ -ne '0.0.0.0' -and $_ -notlike '127.*' } |
		Select-Object -First 1
	if ([string]::IsNullOrWhiteSpace($hostDns)) {
		$hostDns = '8.8.8.8'
		Write-Log "[NodePkg] No host DNS detected. Falling back to '$hostDns'." -Console
	}
	else {
		Write-Log "[NodePkg] Using host DNS '$hostDns' for VM provisioning." -Console
	}

	$tempPath = [System.IO.Path]::GetTempPath()
	$workingRoot = Join-Path $tempPath "k2s-node-pkg-$([guid]::NewGuid().ToString().Substring(0, 8))"
	$downloadsDir = Join-Path $workingRoot 'downloads'
	$provisioningDir = Join-Path $workingRoot 'provisioning'
	New-Item -Path $downloadsDir -ItemType Directory -Force | Out-Null
	New-Item -Path $provisioningDir -ItemType Directory -Force | Out-Null

	$vhdxName = "$VmName.vhdx"
	$isoName = "$VmName.iso"
	$effectiveHostname = if ([string]::IsNullOrWhiteSpace($Hostname)) { "k2s-nodepkg-$DistributionKey" } else { $Hostname }

	$vmParams = @{
		VmName               = $VmName
		VhdxName             = $vhdxName
		VMMemoryStartupBytes = 2GB
		VMProcessorCount     = 2
		VMDiskSize           = 20GB
	}
	$netParams = @{
		Proxy              = $Proxy
		SwitchName         = $switchName
		HostIpAddress      = $hostIp
		HostIpPrefixLength = $prefixLen
		DnsIpAddresses     = $hostDns
		ReuseExistingSwitch = $true
	}
	$isoParams = @{
		IsoFileCreatorToolPath = Join-Path $kubeBinPath 'cloudinitisobuilder.exe'
		IsoFileName            = $isoName
		SourcePath             = Join-Path $kubePath 'lib\modules\windows\node\k2s.node.module\linuxnode\baseimage\cloud-init-templates'
		Hostname               = "k2s-nodepkg-$DistributionKey"
		NetworkInterfaceName   = $netIntf
		IPAddressVM            = $guestIp
		IPAddressGateway       = $hostIp
		UserName               = $sshUser
		UserPwd                = $sshPwd
	}
	Write-Log "[NodePkg] Using guest hostname '$effectiveHostname' for VM '$VmName'." -Console
	$dirParams = @{
		DownloadsDirectory    = $downloadsDir
		ProvisioningDirectory = $provisioningDir
	}

	# Phase 1
	Write-Log "[NodePkg] === Phase 1: Creating Hyper-V VM for '$DistributionKey' ===" -Console
	New-LinuxCloudBasedVirtualMachine `
		-VirtualMachineParams $vmParams `
		-NetworkParams $netParams `
		-IsoFileParams $isoParams `
		-WorkingDirectoriesParams $dirParams `
		-TargetDistribution $DistributionKey

	# Phase 2
	Write-Log "[NodePkg] === Phase 2: Starting VM '$VmName' ===" -Console
	Start-VirtualMachineAndWaitForHeartbeat -Name $VmName

	# Phase 3
	Write-Log "[NodePkg] === Phase 3: Waiting for SSH ($sshUser@$guestIp) ===" -Console
	Wait-ForSshPossible `
		-User "$sshUser@$guestIp" `
		-UserPwd $sshPwd `
		-SshTestCommand 'which ls' `
		-ExpectedSshTestCommandResult '/usr/bin/ls'

	return [PSCustomObject]@{
		VmName                 = $VmName
		SwitchName             = $switchName
		NatName                = ''
		GuestIp                = $guestIp
		SshUser                = $sshUser
		SshPwd                 = $sshPwd
		UsesSharedKubeSwitch   = $true
		InProvisioningVhdxPath = (Join-Path $provisioningDir $vhdxName)
	}
}
