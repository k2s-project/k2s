# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\update.module.psm1" -PassThru -Force).Name
	Mock -ModuleName $moduleName Write-Log {}
}

Describe 'Get-K2sManagedServiceName' -Tag 'unit', 'ci', 'update' {
	It 'returns the K2s-managed Windows services' {
		$services = Get-K2sManagedServiceName
		$services | Should -Contain 'containerd'
		$services | Should -Contain 'kubelet'
		$services | Should -Contain 'kubeproxy'
		$services | Should -Contain 'flanneld'
		$services | Should -Contain 'dnsproxy'
		$services | Should -Contain 'httpproxy'
		$services | Should -Contain 'windows_exporter'
		$services | Should -Contain 'docker'
	}

	It 'contains no duplicate entries' {
		$services = Get-K2sManagedServiceName
		($services | Sort-Object -Unique).Count | Should -Be $services.Count
	}
}

Describe 'Test-DeltaUpgradeVersionIsValid' -Tag 'unit', 'ci', 'update' {
	It 'allows delta updates within the same major version' {
		InModuleScope $moduleName {
			Test-DeltaUpgradeVersionIsValid -VersionInstalled '1.8.1' -VersionToBeUsed '1.9.0' | Should -BeTrue
		}
	}

	It 'rejects delta updates across major versions' {
		InModuleScope $moduleName {
			Test-DeltaUpgradeVersionIsValid -VersionInstalled '1.8.1' -VersionToBeUsed '2.0.0' | Should -BeFalse
		}
	}
}

Describe 'Get-UpdateVmModulePath' -Tag 'unit', 'ci', 'update' {
	It 'uses the active installation module while running from a delta package' {
		InModuleScope $moduleName -Parameters @{ installFolder = $TestDrive } {
			$script:runningFromDelta = $true
			Mock Get-ClusterInstalledFolder { $installFolder }

			$result = Get-UpdateVmModulePath

			$result | Should -Be (Join-Path $installFolder 'lib\modules\windows\node\k2s.node.module\linuxnode\vm\vm.module.psm1')
		}
	}

	It 'uses the module adjacent to the update module outside a delta package' {
		InModuleScope $moduleName {
			$script:runningFromDelta = $false

			$result = Get-UpdateVmModulePath

			$result | Should -Be "$PSScriptRoot\..\..\..\node\k2s.node.module\linuxnode\vm\vm.module.psm1"
		}
	}
}

Describe 'Confirm-UpdateInstallationHome' -Tag 'unit', 'ci', 'update' {
	It 'reads the persisted folder and preserves other setup fields' {
		InModuleScope $moduleName -Parameters @{ setupPath = (Join-Path $TestDrive 'setup.json') } {
			@{ InstallFolder = 'C:\k2s-delta'; Version = '2.1.0'; ClusterName = 'k2s' } |
				ConvertTo-Json | Set-Content -LiteralPath $setupPath
			$before = Get-Content -LiteralPath $setupPath -Raw

			{ Confirm-UpdateInstallationHome -SetupConfigPath $setupPath -ExpectedInstallPath 'c:\k2s-delta\' } | Should -Not -Throw
			Get-Content -LiteralPath $setupPath -Raw | Should -Be $before
		}
	}

	It 'rejects a stale authoritative file even if the config accessor reports the new folder' {
		InModuleScope $moduleName -Parameters @{ setupPath = (Join-Path $TestDrive 'setup.json') } {
			@{ InstallFolder = 'C:\k2s' } | ConvertTo-Json | Set-Content -LiteralPath $setupPath
			Mock Get-ConfigInstallFolder { 'C:\k2s-delta' }

			{ Confirm-UpdateInstallationHome -SetupConfigPath $setupPath -ExpectedInstallPath 'C:\k2s-delta' } |
				Should -Throw '*expected*C:\k2s-delta*found*C:\k2s*'
		}
	}

	It 'rejects missing or invalid setup files' {
		InModuleScope $moduleName -Parameters @{ setupPath = (Join-Path $TestDrive 'invalid-setup.json') } {
			{ Confirm-UpdateInstallationHome -SetupConfigPath $setupPath -ExpectedInstallPath 'C:\k2s-delta' } | Should -Throw
			Set-Content -LiteralPath $setupPath -Value 'invalid json'
			{ Confirm-UpdateInstallationHome -SetupConfigPath $setupPath -ExpectedInstallPath 'C:\k2s-delta' } | Should -Throw
			Set-Content -LiteralPath $setupPath -Value '{}'
			{ Confirm-UpdateInstallationHome -SetupConfigPath $setupPath -ExpectedInstallPath 'C:\k2s-delta' } | Should -Throw
		}
	}
}

Describe 'Set-UpdateSetupConfigValue' -Tag 'unit', 'ci', 'update' {
	It 'updates the authoritative setup file and preserves unrelated fields' {
		InModuleScope $moduleName -Parameters @{ setupPath = (Join-Path $TestDrive 'setup.json') } {
			@{
				InstallFolder     = 'C:\k2s-delta'
				KubernetesVersion = 'v1.36.4'
				Version           = '2.0.0'
			} | ConvertTo-Json | Set-Content -LiteralPath $setupPath

			Set-UpdateSetupConfigValue -SetupConfigPath $setupPath -Key 'KubernetesVersion' -Value 'v1.37.2'

			$setup = Get-Content -LiteralPath $setupPath -Raw | ConvertFrom-Json
			$setup.KubernetesVersion | Should -Be 'v1.37.2'
			$setup.InstallFolder | Should -Be 'C:\k2s-delta'
			$setup.Version | Should -Be '2.0.0'
		}
	}

	It 'fails when the requested value was not persisted' {
		InModuleScope $moduleName -Parameters @{ setupPath = (Join-Path $TestDrive 'setup.json') } {
			@{ KubernetesVersion = 'v1.36.4' } | ConvertTo-Json | Set-Content -LiteralPath $setupPath
			Mock Set-ConfigValue {}

			{ Set-UpdateSetupConfigValue -SetupConfigPath $setupPath -Key 'KubernetesVersion' -Value 'v1.37.2' } |
				Should -Throw "*expected 'v1.37.2'*found 'v1.36.4'*"
		}
	}
}

Describe 'Confirm-DeltaKubernetesVersion' -Tag 'unit', 'ci', 'update' {
	It '<name>' -TestCases @(
		@{ name = 'uses destination kubectl despite the old imported client'; client = 'v1.37.2'; server = 'v1.37.2'; code = 0; invalidJson = $false; errorPattern = $null }
		@{ name = 'rejects a server rollback'; client = 'v1.37.2'; server = 'v1.36.4'; code = 0; invalidJson = $false; errorPattern = '*server*v1.36.4*' }
		@{ name = 'rejects a stale destination client'; client = 'v1.36.4'; server = 'v1.37.2'; code = 0; invalidJson = $false; errorPattern = '*client*v1.36.4*' }
		@{ name = 'rejects a failed kubectl query'; client = 'v1.37.2'; server = 'v1.37.2'; code = 1; invalidJson = $false; errorPattern = '*query failed*exit code 1*' }
		@{ name = 'rejects malformed version JSON'; client = ''; server = ''; code = 0; invalidJson = $true; errorPattern = '*' }
		@{ name = 'accepts valid JSON with a stderr warning'; client = 'v1.37.2'; server = 'v1.37.2'; code = 0; invalidJson = $false; errorPattern = $null; stderrMessage = 'transport warning' }
		@{ name = 'includes stderr in a failed query error'; client = ''; server = ''; code = 1; invalidJson = $false; errorPattern = '*connection refused*'; stderrMessage = 'connection refused' }
	) {
		param($client, $server, $code, $invalidJson, $errorPattern, $stderrMessage)
		InModuleScope $moduleName -Parameters @{
			installPath = (Join-Path $TestDrive 'new installation')
			client = $client; server = $server; code = $code; invalidJson = $invalidJson; errorPattern = $errorPattern; stderrMessage = $stderrMessage
		} {
			$kubectlPath = Join-Path $installPath 'bin\kube\kubectl.exe'
			$configPath = Join-Path $installPath 'config'
			Mock Test-Path { $true }
			function Get-K8sVersionInfo { throw 'Must not query the old installation client' }
			$script:versionQueryArguments = $null
			Set-Item -Path "Function:$kubectlPath" -Value {
				$script:versionQueryArguments = $args
				if ($stderrMessage) { Write-Error $stderrMessage -ErrorAction Continue }
				$global:LASTEXITCODE = $code
				if ($invalidJson) { return 'not json' }
				@{ clientVersion = @{ gitVersion = $client }; serverVersion = @{ gitVersion = $server } } | ConvertTo-Json
			}
			try {
				if ($errorPattern) {
					{ Confirm-DeltaKubernetesVersion -ExpectedVersion 'v1.37.2' -InstallPath $installPath } |
						Should -Throw $errorPattern
				} else {
					Confirm-DeltaKubernetesVersion -ExpectedVersion 'v1.37.2' -InstallPath $installPath
				}
				($script:versionQueryArguments -join '|') |
					Should -Be "--kubeconfig|$configPath|--request-timeout=30s|version|-o|json"
			} finally {
				Remove-Item -LiteralPath "Function:$kubectlPath"
			}
		}
	}

	It 'rejects missing destination artifacts rather than falling back to PATH' {
		InModuleScope $moduleName -Parameters @{ installPath = $TestDrive } {
			Mock Test-Path { $false }
			{ Confirm-DeltaKubernetesVersion -ExpectedVersion 'v1.37.2' -InstallPath $installPath } |
				Should -Throw '*verification requires*'
		}
	}
}

Describe 'PerformClusterUpdate stopped-cluster preflight' -Tag 'unit', 'ci', 'update' {
	It 'rejects <label> before reading the manifest or changing the installation' -TestCases @(
		@{ label = 'a stopped cluster'; setupName = 'k2s' }
		@{ label = 'an absent setup'; setupName = $null }
	) {
		param($setupName)
		InModuleScope $moduleName -Parameters @{ setupName = $setupName; root = $TestDrive } {
			function Get-SetupInfo {}
			function Get-RunningState {}
			Mock Test-Path { $true }
			Mock Get-SetupConfigFilePath { Join-Path $root 'setup.json' }
			Mock Get-SetupInfo { @{ Name = $setupName } }
			Mock Get-RunningState { @{ IsRunning = $false } }
			Mock Get-Content { throw 'Must not read the manifest' }
			Mock Set-K2sInstallationHome { throw 'Must not relocate' }
			Mock Set-UpdateSetupConfigValue { throw 'Must not update metadata' }

			PerformClusterUpdate | Should -BeFalse

			Should -Invoke Get-Content -Times 0 -Exactly
			Should -Invoke Set-K2sInstallationHome -Times 0 -Exactly
			Should -Invoke Set-UpdateSetupConfigValue -Times 0 -Exactly
			Should -Invoke Write-Log -Times 1 -ParameterFilter { $Messages -like '*requires a running cluster*' }
		}
	}
}

Describe 'Get-DeltaTargetKubernetesVersion' -Tag 'unit', 'ci', 'update' {
	It 'uses the target Kubernetes version declared by the manifest' {
		InModuleScope $moduleName {
			$manifest = [pscustomobject]@{
				TargetKubernetesVersion = 'v1.37.2'
				DebianDeltaRelativePath = $null
			}

			Get-DeltaTargetKubernetesVersion -Manifest $manifest -DeltaRoot $TestDrive |
				Should -Be 'v1.37.2'
		}
	}

	It 'uses the expected version marker for an older manifest' {
		InModuleScope $moduleName -Parameters @{ deltaRoot = $TestDrive } {
			$debianDelta = Join-Path $deltaRoot 'debian-delta'
			New-Item -ItemType Directory -Path $debianDelta -Force | Out-Null
			Set-Content -LiteralPath (Join-Path $debianDelta 'expected-k8s-version') -Value '1.37.2'
			$manifest = [pscustomobject]@{
				DebianDeltaRelativePath = 'debian-delta'
			}

			Get-DeltaTargetKubernetesVersion -Manifest $manifest -DeltaRoot $deltaRoot |
				Should -Be 'v1.37.2'
		}
	}
}

Describe 'Copy-UnchangedInstallationFiles' -Tag 'unit', 'ci', 'update' {
	BeforeEach {
		$old = Join-Path $TestDrive 'old'
		$new = Join-Path $TestDrive 'new'
		New-Item -ItemType Directory -Path $old -Force | Out-Null
		New-Item -ItemType Directory -Path $new -Force | Out-Null

		# Previous installation (seed source)
		Set-Content -Path (Join-Path $old 'a.txt') -Value 'old-a' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $old 'sub') -Force | Out-Null
		Set-Content -Path (Join-Path $old 'sub\b.txt') -Value 'old-b' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $old 'wholedir') -Force | Out-Null
		Set-Content -Path (Join-Path $old 'wholedir\old1.txt') -Value 'old-1' -NoNewline
		Set-Content -Path (Join-Path $old 'wholedir\old2.txt') -Value 'old-2' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $old 'otherdir') -Force | Out-Null
		Set-Content -Path (Join-Path $old 'otherdir\c.txt') -Value 'old-c' -NoNewline

		# New installation (delta package directory) - already contains changed + wholesale files
		Set-Content -Path (Join-Path $new 'a.txt') -Value 'new-a' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $new 'wholedir') -Force | Out-Null
		Set-Content -Path (Join-Path $new 'wholedir\new1.txt') -Value 'new-1' -NoNewline
	}

	It 'seeds files that are missing in the new folder' {
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Should -BeTrue
		(Test-Path (Join-Path $new 'sub\b.txt')) | Should -BeTrue
		Get-Content (Join-Path $new 'sub\b.txt') -Raw | Should -Be 'old-b'
	}

	It 'does not overwrite files that already exist (changed delta files)' {
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Out-Null
		Get-Content (Join-Path $new 'a.txt') -Raw | Should -Be 'new-a'
	}

	It 'seeds missing files in a wholesale directory without overwriting delta-provided files' {
		# The new folder's wholesale dir already has the delta's new1.txt (a changed file) but is
		# missing old1.txt/old2.txt (unchanged binaries). Those must be seeded so e.g. an unchanged
		# containerd.exe is not lost, while the delta's newer file is preserved.
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Out-Null
		(Test-Path (Join-Path $new 'wholedir\old1.txt')) | Should -BeTrue
		(Test-Path (Join-Path $new 'wholedir\old2.txt')) | Should -BeTrue
		(Test-Path (Join-Path $new 'wholedir\new1.txt')) | Should -BeTrue
		Get-Content (Join-Path $new 'wholedir\new1.txt') -Raw | Should -Be 'new-1'
	}

	It 'seeds an empty wholesale directory from the previous installation (offline-package case)' {
		# Reproduces the real failure: bin\containerd is staged EMPTY in the delta (binaries live in
		# WindowsNodeArtifacts.zip), so its unchanged binaries must be seeded or containerd cannot start.
		New-Item -ItemType Directory -Path (Join-Path $new 'wholedir-empty') -Force | Out-Null
		New-Item -ItemType Directory -Path (Join-Path $old 'wholedir-empty') -Force | Out-Null
		Set-Content -Path (Join-Path $old 'wholedir-empty\containerd.exe') -Value 'binary' -NoNewline
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir-empty') | Out-Null
		(Test-Path (Join-Path $new 'wholedir-empty\containerd.exe')) | Should -BeTrue
	}

	It 'seeds wholesale directories that did not change (absent in the new folder)' {
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Out-Null
		(Test-Path (Join-Path $new 'otherdir\c.txt')) | Should -BeTrue
		Get-Content (Join-Path $new 'otherdir\c.txt') -Raw | Should -Be 'old-c'
	}
}

Describe 'Remove-DeltaPackageArtifact' -Tag 'unit', 'ci', 'update' {
	It 'removes delta-only artifacts and keeps installation files' {
		$install = Join-Path $TestDrive 'install'
		New-Item -ItemType Directory -Path $install -Force | Out-Null
		Set-Content -Path (Join-Path $install 'delta-manifest.json') -Value '{}' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $install 'image-delta') -Force | Out-Null
		Set-Content -Path (Join-Path $install 'image-delta\img.tar') -Value 'x' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $install 'debian-delta') -Force | Out-Null
		Set-Content -Path (Join-Path $install 'k2s.exe') -Value 'binary' -NoNewline

		Remove-DeltaPackageArtifact -InstallPath $install

		(Test-Path (Join-Path $install 'delta-manifest.json')) | Should -BeFalse
		(Test-Path (Join-Path $install 'image-delta')) | Should -BeFalse
		(Test-Path (Join-Path $install 'debian-delta')) | Should -BeFalse
		(Test-Path (Join-Path $install 'k2s.exe')) | Should -BeTrue
	}

	It 'does not fail when no delta artifacts are present' {
		$install = Join-Path $TestDrive 'install2'
		New-Item -ItemType Directory -Path $install -Force | Out-Null
		Set-Content -Path (Join-Path $install 'k2s.exe') -Value 'binary' -NoNewline
		{ Remove-DeltaPackageArtifact -InstallPath $install } | Should -Not -Throw
		(Test-Path (Join-Path $install 'k2s.exe')) | Should -BeTrue
	}
}

Describe 'Set-K2sInstallationHome' -Tag 'unit', 'ci', 'update' {
	It 'returns false when the services module is missing at the destination' {
		# Empty destination: lib\...\services.module.psm1 is absent, so the function aborts early
		# before touching any service, machine environment variable, or setup.json. This intentionally
		# returns before importing any module so the test never loads a stub named 'services.module'.
		$to = Join-Path $TestDrive 'to-no-services'
		New-Item -ItemType Directory -Path $to -Force | Out-Null
		$result = Set-K2sInstallationHome -FromPath (Join-Path $TestDrive 'from') -ToPath $to
		$result | Should -BeFalse
	}
}

Describe 'Select-PrunableRemovedFile' -Tag 'unit', 'ci', 'update' {
	It 'keeps genuine removals outside bin and wholesale directories' {
		$removed = @('lib/manifests/clusterip-webhook/certgen-create-job.yaml', 'cfg/old-thing.yaml')
		$result = Select-PrunableRemovedFile -RemovedFiles $removed -WholesaleDirs @('bin/cni', 'bin/containerd')
		$result | Should -Contain 'lib/manifests/clusterip-webhook/certgen-create-job.yaml'
		$result | Should -Contain 'cfg/old-thing.yaml'
		$result.Count | Should -Be 2
	}

	It 'never prunes essential binaries or other files under bin/' {
		# Reproduces the real-world false positives that broke the re-home (nssm.exe deleted).
		$removed = @('bin/nssm.exe', 'bin/helm.exe', 'bin/jq.exe', 'bin/crictl.yaml', 'bin/containerd/ctr.exe')
		$result = Select-PrunableRemovedFile -RemovedFiles $removed -WholesaleDirs @('bin/containerd')
		$result.Count | Should -Be 0
	}

	It 'excludes files under an explicit wholesale directory even outside bin' {
		$removed = @('addons/registry/old.yaml', 'data/stale.txt')
		$result = Select-PrunableRemovedFile -RemovedFiles $removed -WholesaleDirs @('addons/registry')
		$result | Should -Not -Contain 'addons/registry/old.yaml'
		$result | Should -Contain 'data/stale.txt'
	}

	It 'handles backslash separators and empty entries' {
		$removed = @('bin\nssm.exe', '', 'lib\foo\bar.yaml')
		$result = Select-PrunableRemovedFile -RemovedFiles $removed -WholesaleDirs @()
		$result | Should -Not -Contain 'bin\nssm.exe'
		$result | Should -Contain 'lib\foo\bar.yaml'
		$result.Count | Should -Be 1
	}
}

Describe 'Get-GuestConfigApplyAllowlist' -Tag 'unit', 'ci', 'update' {
	It 'allows only /usr/local/bin host tools by default' {
		$allow = Get-GuestConfigApplyAllowlist
		$allow | Should -Contain '/usr/local/bin/'
		$allow.Count | Should -Be 1
	}
}

Describe 'Test-GuestConfigApplyAllowed' -Tag 'unit', 'ci', 'update' {
	It 'permits the Linux helm and yq host tools' {
		Test-GuestConfigApplyAllowed 'usr/local/bin/helm' | Should -BeTrue
		Test-GuestConfigApplyAllowed 'usr/local/bin/yq' | Should -BeTrue
	}

	It 'permits the Linux kubectl-krew host tool' {
		Test-GuestConfigApplyAllowed 'usr/local/bin/kubectl-krew' | Should -BeTrue
		Test-GuestConfigApplyAllowed '/usr/local/bin/kubectl-krew' | Should -BeTrue
	}

	It 'permits absolute and backslash forms of allowlisted paths' {
		Test-GuestConfigApplyAllowed '/usr/local/bin/helm' | Should -BeTrue
		Test-GuestConfigApplyAllowed 'usr\local\bin\yq' | Should -BeTrue
	}

	It 'rejects cluster-identity files even though creation already excludes them' {
		Test-GuestConfigApplyAllowed 'etc/kubernetes/admin.conf' | Should -BeFalse
		Test-GuestConfigApplyAllowed 'etc/kubernetes/pki/ca.crt' | Should -BeFalse
		Test-GuestConfigApplyAllowed 'var/lib/kubelet/config.yaml' | Should -BeFalse
	}

	It 'rejects other system binaries outside the allowlist' {
		Test-GuestConfigApplyAllowed 'usr/bin/helm' | Should -BeFalse
		Test-GuestConfigApplyAllowed 'lib/systemd/system/kubelet.service' | Should -BeFalse
	}

	It 'rejects empty or null input' {
		Test-GuestConfigApplyAllowed '' | Should -BeFalse
		Test-GuestConfigApplyAllowed $null | Should -BeFalse
	}
}

Describe 'Invoke-GuestConfigDeltaApply' -Tag 'unit', 'ci', 'update' {
	It 'returns success with nothing applied when the manifest has no guest-config payload' {
		$manifest = [pscustomobject]@{ GuestConfigRelativePath = $null }
		$result = Invoke-GuestConfigDeltaApply -DeltaRoot $TestDrive -Manifest $manifest
		$result.Success | Should -BeTrue
		$result.Applied.Count | Should -Be 0
	}

	It 'skips all entries and never reaches the VM when only non-allowlisted files are present' {
		$deltaRoot = Join-Path $TestDrive 'delta'
		$guestDir = Join-Path $deltaRoot 'guest-config'
		New-Item -ItemType Directory -Path (Join-Path $guestDir 'etc\kubernetes') -Force | Out-Null
		Set-Content -Path (Join-Path $guestDir 'etc\kubernetes\admin.conf') -Value 'secret' -NoNewline
		$manifest = [pscustomobject]@{
			GuestConfigRelativePath = 'guest-config'
			GuestConfigDiff         = [pscustomobject]@{ CopiedFiles = @('etc/kubernetes/admin.conf') }
		}
		$result = Invoke-GuestConfigDeltaApply -DeltaRoot $deltaRoot -Manifest $manifest
		$result.Applied.Count | Should -Be 0
		$result.Skipped | Should -Contain 'etc/kubernetes/admin.conf'
	}
}
