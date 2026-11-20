# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Debian package parsing & per-package acquisition helpers (guest VM context)

function Get-DebianPackageMapFromStatusFile {
    param(
        [string] $StatusFilePath
    )
    $map = @{}
    if (-not (Test-Path -LiteralPath $StatusFilePath)) { return $map }
    $currentName = $null
    $currentVersion = $null
    Get-Content -LiteralPath $StatusFilePath | ForEach-Object {
        $line = $_
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($currentName) { $map[$currentName] = $currentVersion }
            $currentName = $null
            $currentVersion = $null
            return
        }
        if ($line -like 'Package:*') { $currentName = ($line.Substring(8)).Trim() }
        elseif ($line -like 'Version:*') { $currentVersion = ($line.Substring(8)).Trim() }
    }
    if ($currentName) { $map[$currentName] = $currentVersion }
    return $map
}

# --- Helper: detect nameservers usable by the NAT'd transient guest
function Get-HostDnsServer {
    # The transient VM reaches the internet through the host NAT (default route 172.19.1.1), but the
    # base image ships an immutable /etc/resolv.conf pointing at a DNS server that is not reachable on
    # the throwaway delta network. Prefer the host's own resolvers first (these are reachable through
    # the NAT and work in corporate/air-gapped networks where public DNS is blocked at the perimeter),
    # then append public resolvers as a fallback for home/dev hosts whose LAN DNS is not forwardable.
    # In corporate environments the intended mechanism is -Proxy (apt routes through the proxy), so the
    # public fallback only ever matters for direct-NAT (no-proxy) hosts.
    $hostServers = @()
    try {
        $hostServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.ServerAddresses } |
            Where-Object { $_.InterfaceAlias -notlike '*k2s*' -and $_.InterfaceAlias -notlike '*Loopback*' } |
            ForEach-Object { $_.ServerAddresses } |
            Where-Object { $_ -and ($_ -notlike '172.19.1.*') }
    } catch { }
    $servers = @($hostServers) + @('8.8.8.8','8.8.4.4')
    return @($servers | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 4)
}

# --- Helper: initialize remote acquisition directory & capture diagnostics
function Initialize-DebAcquisitionEnvironment {
    param(
        [string] $RemoteDir,
        [string] $SshClient,
        [bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        [string] $SshPassword,
        # Optional HTTP proxy for guest apt downloads (e.g. a corporate proxy). When empty (default),
        # the guest reaches the repos directly through the host NAT using the injected nameservers.
        [string] $Proxy = ''
    )
    function _BaseArgsLocal() {
        if ($UsingPlink) {
            $sshArgs = @('-batch','-noagent','-P','22')
            if ($PlinkHostKey) { $sshArgs += @('-hostkey', $PlinkHostKey) }
            if ($SshKey) { $sshArgs += @('-i', $SshKey) } elseif ($SshPassword) { $sshArgs += @('-pw', $SshPassword) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        } else {
            $sshArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            if ($SshKey) { $sshArgs += @('-i', $SshKey) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        }
    }
    # Override the guest's immutable resolv.conf with reachable nameservers before any apt call, so the
    # NAT'd guest can resolve the package repositories.
    #
    # The script is base64-encoded and run via `echo <b64> | base64 -d | bash`. This is deliberate:
    # passing a `bash -c '...'` string through PowerShell -> plink -> remote login shell mangles quotes
    # (PowerShell strips embedded double quotes) and chokes on shell metacharacters like '('. base64
    # output is only [A-Za-z0-9+/=], so the script survives every layer untouched.
    $dnsServers = Get-HostDnsServer
    $dnsFmt = (($dnsServers | ForEach-Object { "nameserver $_\n" }) -join '')
    $dnsLabel = $dnsServers -join ', '
    # When a proxy is supplied (corporate environments), route apt through it; otherwise remove any
    # stale proxy config so apt connects directly via the host NAT.
    if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
        # Escape single quotes so a proxy value containing one cannot break out of the bash
        # single-quoted argument below (bash idiom: ' -> '\'').
        $proxyEsc = $Proxy.Replace("'", "'\''")
        # Pass the proxy URL as a printf ARGUMENT (%s), never inside the format string, so '%'
        # characters in the URL (e.g. URL-encoded '%40') are treated as literal data and not as
        # printf conversion specifiers. The format string is constant (only the intended %s specifiers).
        $proxyLine = "printf 'Acquire::http::Proxy `"%s`";\nAcquire::https::Proxy `"%s`";\n' '$proxyEsc' '$proxyEsc' | sudo tee /etc/apt/apt.conf.d/proxy.conf > /dev/null && echo SET_PROXY_OK || echo SET_PROXY_FAIL"
        $proxyLabel = $Proxy
    } else {
        $proxyLine = 'sudo rm -f /etc/apt/apt.conf.d/proxy.conf 2>/dev/null || true'
        $proxyLabel = 'none (direct via NAT)'
    }
    # Diagnostics are ordered so the connectivity verdicts (HOSTGW/ROUTE/DNS/HTTPS) appear first.
    # ROUTE pings a raw IP (no DNS) to isolate routing from name resolution.
    $scriptLines = @(
        'set -uo pipefail',
        "rm -rf $RemoteDir; mkdir -p $RemoteDir || { echo MKDIR_FAIL; exit 1; }",
        "cd $RemoteDir || { echo CD_FAIL; exit 1; }",
        'echo __K2S_DIAG_BEGIN__',
        "echo '--- SET DNS: $dnsLabel ---'",
        'sudo chattr -i /etc/resolv.conf 2>/dev/null || true',
        # Make a failed resolv.conf write visible (SET_DNS_FAIL) instead of silently continuing; with
        # -e dropped this is the explicit guard the reviewer asked for, and it surfaces the real cause
        # of a subsequent apt-get update DNS failure.
        "printf '$dnsFmt' | sudo tee /etc/resolv.conf > /dev/null && echo SET_DNS_OK || echo SET_DNS_FAIL",
        "echo '--- APT PROXY: $proxyLabel ---'",
        $proxyLine,
        "echo '--- RESOLV.CONF (effective) ---'",
        'cat /etc/resolv.conf 2>/dev/null || true',
        'ping -c1 -W3 172.19.1.1 >/dev/null 2>&1 && echo HOSTGW_OK || echo HOSTGW_FAIL',
        'ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 && echo ROUTE_OK || echo ROUTE_FAIL',
        'getent hosts deb.debian.org >/dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL',
        'if command -v curl >/dev/null 2>&1; then curl -fsI --connect-timeout 8 https://deb.debian.org/ >/dev/null 2>&1 && echo HTTPS_DEB_OK || echo HTTPS_DEB_FAIL; else echo CURL_NOT_INSTALLED; fi',
        "echo '--- IP ROUTE ---'",
        'ip route show 2>/dev/null || true',
        "echo '--- APT SOURCES ---'",
        'grep -v ^# /etc/apt/sources.list 2>/dev/null || true',
        'ls -1 /etc/apt/sources.list.d 2>/dev/null || true',
        # Emit the END marker BEFORE apt-get update so the connectivity verdicts and the marker itself are
        # always within the captured window even if apt-get update produces many lines on a fresh image.
        'echo __K2S_DIAG_END__',
        "echo '--- APT-GET UPDATE ---'",
        'apt-get update 2>&1 || true'
    )
    $scriptBody = $scriptLines -join "`n"
    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptBody))
    $initCmd = "echo $b64 | base64 -d | bash"
    $initOut = & $SshClient @((_BaseArgsLocal) + $initCmd) 2>&1
    return ,$initOut
}

# --- Helper: run a single package download attempt, returning logs & failure flag
function Invoke-DebSinglePackageDownload {
    param(
        [string] $Spec,
        [string] $RemoteDir,
        [string] $SshClient,
        [bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        [string] $SshPassword
    )
    function _BaseArgsLocal() {
        if ($UsingPlink) {
            $sshArgs = @('-batch','-noagent','-P','22')
            if ($PlinkHostKey) { $sshArgs += @('-hostkey', $PlinkHostKey) }
            if ($SshKey) { $sshArgs += @('-i', $SshKey) } elseif ($SshPassword) { $sshArgs += @('-pw', $SshPassword) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        } else {
            $sshArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            if ($SshKey) { $sshArgs += @('-i', $SshKey) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        }
    }
    $escaped = $Spec.Replace("'", "'\\''")
    $cmdScript = @(
        'set -euo pipefail',
        "mkdir -p $RemoteDir",
        "cd $RemoteDir",
        "echo [dl] $escaped",
        "if apt-get help 2>&1 | grep -qi download; then apt-get download '$escaped' 2>&1 || echo WARN: failed $escaped; elif command -v apt >/dev/null 2>&1; then apt download '$escaped' 2>&1 || echo WARN: failed $escaped; else echo WARN: no download command; fi",
        'echo [ls-after]',
        'pwd || true',
        'ls -al 2>/dev/null | head -n 20 || true',
        'for f in *.deb; do if [ -f "$f" ]; then echo $f; fi; done || true'
    ) -join '; '
    $cmd = "bash -c '" + $cmdScript + "'"
    $out = & $SshClient @((_BaseArgsLocal) + $cmd) 2>&1
    $failed = $out | Where-Object { $_ -match 'WARN: failed' }
    return [pscustomobject]@{ Output=$out; Failed=([bool]$failed) }
}

# --- Helper: parse listing output and merge new deb filenames into result
function Add-DebFilesFromListing {
    param(
        [string[]] $ListOutput,
        [object] $Result
    )
    if (-not $ListOutput) { return }
    $rawDebLines = $ListOutput | Where-Object { ($_ -like '*.deb') -and ($_ -notmatch '\s') }
    $ignoredMeta = $ListOutput | Where-Object { ($_ -like '*.deb') -and ($_ -match '\s') }
    if ($ignoredMeta -and $ignoredMeta.Count -gt 0) {
        Write-Log ("[DebPkg][DL][Debug] Ignoring metadata lines mistaken as deb entries: {0}" -f (($ignoredMeta | Select-Object -First 3) -join ' | ')) -Console
    }
    if (-not $rawDebLines) { return }
    $previous = @($Result.DebFiles)
    $newOnes = $rawDebLines | Where-Object { $previous -notcontains $_ }
    if ($rawDebLines) { $Result.DebFiles = @($previous + $rawDebLines) | Sort-Object -Unique }
    return ,$newOnes
}

# --- Helper: satisfy meta packages (linux-image-cloud-amd64) using concrete kernel images
function Resolve-DebMetaPackages {
    param(
        [object] $Result
    )
    if ($Result.Failures.Count -le 0 -or $Result.DebFiles.Count -le 0) { return }
    $remaining = @()
    foreach ($spec in $Result.Failures) {
        if ($spec -match '^(?<name>linux-image-cloud-amd64)=(?<ver>[^=]+)$') {
            $metaVer = $matches['ver']
            $matching = $Result.DebFiles | Where-Object { $_ -like "linux-image-*cloud-amd64_${metaVer}_*.deb" }
            if ($matching) {
                Write-Log ("[DebPkg][DL] Meta spec {0} satisfied by kernel image(s): {1}" -f $spec, ($matching -join ', ')) -Console
                $Result.SatisfiedMeta += [pscustomobject]@{ Spec=$spec; Via=$matching }
                continue
            }
        }
        $remaining += $spec
    }
    $Result.Failures = $remaining
}

# --- Helper: fallback copy from apt cache for failed packages
function Invoke-DebCacheFallback {
    param(
        [string] $RemoteDir,
        [string] $SshClient,
        [bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        [string] $SshPassword,
        [object] $Result
    )
    function _BaseArgsLocal() {
        if ($UsingPlink) {
            $sshArgs = @('-batch','-noagent','-P','22')
            if ($PlinkHostKey) { $sshArgs += @('-hostkey', $PlinkHostKey) }
            if ($SshKey) { $sshArgs += @('-i', $SshKey) } elseif ($SshPassword) { $sshArgs += @('-pw', $SshPassword) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        } else {
            $sshArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            if ($SshKey) { $sshArgs += @('-i', $SshKey) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        }
    }

    # Phase 1: Bulk fallback if no debs at all
    if ($Result.DebFiles.Count -eq 0) {
        Write-Log '[DebPkg][DL] No deb files after per-package attempts; invoking bulk cache fallback' -Console
        $fallbackCmd = "bash -c 'cd $RemoteDir; cp -a /var/cache/apt/archives/*.deb . 2>/dev/null || true; ls -1 *.deb 2>/dev/null || true'"
        $fallbackOut = & $SshClient @((_BaseArgsLocal) + $fallbackCmd) 2>&1
        $fbDebs = @($fallbackOut | Where-Object { $_ -like '*.deb' })
        if ($fbDebs.Count -gt 0) { $Result.DebFiles = ($fbDebs | Sort-Object -Unique); $Result.UsedFallback = $true }
        $Result.Diagnostics += @($fallbackOut | Select-Object -First 40)
    }

    # Phase 2: Try to find specific failed packages in apt cache
    if ($Result.Failures.Count -gt 0) {
        Write-Log "[DebPkg][DL] Attempting cache fallback for $($Result.Failures.Count) failed specs..." -Console
        $resolvedFromCache = @()

        foreach ($failedSpec in $Result.Failures) {
            # Parse package name and version from spec (format: pkgname=version)
            if ($failedSpec -match '^(?<pkg>[^=]+)=(?<ver>.+)$') {
                $pkgName = $matches['pkg']
                $pkgVer = $matches['ver']

                # Escape special characters for shell glob pattern
                $pkgVerEscaped = $pkgVer -replace '\+', '\\+' -replace ':', '%3a'

                # Try to find matching .deb in apt cache (format: pkgname_version_arch.deb)
                $findCmd = "bash -c 'ls -1 /var/cache/apt/archives/${pkgName}_${pkgVerEscaped}_*.deb 2>/dev/null || true'"
                $findOut = & $SshClient @((_BaseArgsLocal) + $findCmd) 2>&1
                $foundDebs = @($findOut | Where-Object { $_ -like '*.deb' -and $_ -notmatch 'No such file' })

                if ($foundDebs.Count -gt 0) {
                    Write-Log "[DebPkg][DL] Found cached .deb for $failedSpec" -Console

                    # Copy to staging directory
                    foreach ($debPath in $foundDebs) {
                        $copyCmd = "bash -c 'cp -a `"$debPath`" $RemoteDir/ 2>&1 && basename `"$debPath`"'"
                        $copyOut = & $SshClient @((_BaseArgsLocal) + $copyCmd) 2>&1
                        $debName = $copyOut | Where-Object { $_ -like '*.deb' } | Select-Object -First 1

                        if ($debName -and ($Result.DebFiles -notcontains $debName)) {
                            $Result.DebFiles += $debName
                            Write-Log "[DebPkg][DL] Copied from cache: $debName" -Console
                        }
                    }
                    $resolvedFromCache += $failedSpec
                    $Result.UsedFallback = $true

                    # Add resolution record
                    $Result.Resolutions += [PSCustomObject]@{
                        Spec     = $failedSpec
                        Provided = $pkgVer
                        Files    = @($foundDebs | ForEach-Object { Split-Path -Leaf $_ })
                        Method   = 'cache-fallback'
                    }
                } else {
                    # Try broader search with just package name prefix
                    $broadFindCmd = "bash -c 'ls -1 /var/cache/apt/archives/${pkgName}_*.deb 2>/dev/null | head -n 5 || true'"
                    $broadOut = & $SshClient @((_BaseArgsLocal) + $broadFindCmd) 2>&1
                    $broadDebs = @($broadOut | Where-Object { $_ -like '*.deb' })

                    if ($broadDebs.Count -gt 0) {
                        # Check if any of these match the version closely
                        foreach ($debPath in $broadDebs) {
                            $debName = Split-Path -Leaf $debPath
                            # Extract version from deb filename: pkgname_version_arch.deb
                            if ($debName -match "^${pkgName}_(?<debver>[^_]+)_[^_]+\.deb$") {
                                $debVer = $matches['debver']
                                # Decode URL-encoded chars for comparison
                                $debVerDecoded = $debVer -replace '%3a', ':'
                                $baseVer = ($pkgVer -split '\+')[0]

                                # If version matches or is close (same base version), use it
                                if ($debVerDecoded -eq $pkgVer -or $debVerDecoded.StartsWith($baseVer)) {
                                    Write-Log "[DebPkg][DL] Using close match: $debName (wanted $pkgVer, found $debVerDecoded)" -Console
                                    $copyCmd = "bash -c 'cp -a `"$debPath`" $RemoteDir/ 2>&1'"
                                    $null = & $SshClient @((_BaseArgsLocal) + $copyCmd) 2>&1

                                    if ($Result.DebFiles -notcontains $debName) {
                                        $Result.DebFiles += $debName
                                    }
                                    $resolvedFromCache += $failedSpec
                                    $Result.UsedFallback = $true

                                    # Add resolution record
                                    $Result.Resolutions += [PSCustomObject]@{
                                        Spec     = $failedSpec
                                        Provided = $debVerDecoded
                                        Files    = @($debName)
                                        Method   = 'cache-fallback-close'
                                    }
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }

        # Remove resolved specs from failures
        if ($resolvedFromCache.Count -gt 0) {
            Write-Log "[DebPkg][DL] Resolved $($resolvedFromCache.Count) specs from apt cache" -Console
            $Result.Failures = @($Result.Failures | Where-Object { $resolvedFromCache -notcontains $_ })
        }
    }
}

# --- Helper: revision substitution (probing higher ~deb12u revisions and plain fallback)
function Resolve-DebRevisionBumps {
    param(
        [object] $Result,
        [string] $RemoteDir,
        [string] $SshClient,
        [bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        [string] $SshPassword
    )
    function _BaseArgsLocal() {
        if ($UsingPlink) {
            $sshArgs = @('-batch','-noagent','-P','22')
            if ($PlinkHostKey) { $sshArgs += @('-hostkey', $PlinkHostKey) }
            if ($SshKey) { $sshArgs += @('-i', $SshKey) } elseif ($SshPassword) { $sshArgs += @('-pw', $SshPassword) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        } else {
            $sshArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            if ($SshKey) { $sshArgs += @('-i', $SshKey) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        }
    }
    if ($Result.Failures.Count -le 0) { return }
    $still = @()
    foreach ($spec in $Result.Failures) {
        if ($spec -notmatch '^(?<name>[^=]+)=(?<ver>.+)$') { $still += $spec; continue }
        $pkgName = $matches['name']; $reqVer = $matches['ver']
        if ($reqVer -notmatch '^(?<base>.+~deb12u)(?<rev>\d+)$') { $still += $spec; continue }
        $basePrefix = $matches['base']; $reqRev = [int]$matches['rev']
        $maxProbe = 8
        $foundVersion = $null
        for ($inc=1; $inc -le $maxProbe; $inc++) {
            $tryRev = $reqRev + $inc
            $tryVer = "$basePrefix$tryRev"
            Write-Log ("[DebPkg][DL][Debug] Probing revision {0} for {1}" -f $tryVer, $pkgName) -Console
            $probeCmd = ('bash -c ''cd {0}; apt-get download {1}={2} 2>&1 || echo PROBE_FAIL: {1}={2}; ls -1 *{1}_{2}_*.deb 2>/dev/null || true''' -f $RemoteDir, $pkgName, $tryVer)
            $probeOut = & $SshClient @((_BaseArgsLocal) + $probeCmd) 2>&1
            $Result.Logs += $probeOut
            if ($probeOut -notmatch "PROBE_FAIL: $pkgName=$tryVer") {
                $debFiles = $probeOut | Where-Object { $_ -like '*.deb' }
                if ($debFiles) { foreach ($df in $debFiles) { if ($Result.DebFiles -notcontains $df) { $Result.DebFiles += $df } }; $foundVersion = $tryVer; break }
            }
        }
        if (-not $foundVersion) {
            Write-Log ("[DebPkg][DL][Info] Probes failed for {0}; attempting plain download fallback" -f $pkgName) -Console
            $plainCmd = ('bash -c ''cd {0}; apt-get download {1} 2>&1 || echo PLAIN_FAIL: {1}; ls -1 *{1}_*.deb 2>/dev/null || true''' -f $RemoteDir, $pkgName)
            $plainOut = & $SshClient @((_BaseArgsLocal) + $plainCmd) 2>&1
            $Result.Logs += $plainOut
            if ($plainOut -notmatch "PLAIN_FAIL: $pkgName") {
                $plainFiles = $plainOut | Where-Object { $_ -like '*.deb' }
                if ($plainFiles) {
                    $firstPlain = $plainFiles | Select-Object -First 1
                    if ($firstPlain -match "^${pkgName}_(?<ver>[^_]+)_.+\.deb$") {
                        $parsed = $matches['ver']
                        if ($parsed -match '^(?<cbase>.+~deb12u)(?<crev>\d+)$') {
                            $cBase = $matches['cbase']; $cRev = [int]$matches['crev']
                            if ($cBase -eq $basePrefix -and $cRev -gt $reqRev) {
                                foreach ($pf in $plainFiles) { if ($Result.DebFiles -notcontains $pf) { $Result.DebFiles += $pf } }
                                $foundVersion = $parsed
                            }
                        }
                    }
                }
            }
        }
        if (-not $foundVersion) { $still += $spec; continue }
        Write-Log ("[DebPkg][DL] Substituting {0} -> {1}" -f $spec, $foundVersion) -Console
        $Result.Resolutions += [pscustomobject]@{ Spec=$spec; Action='Deb12Revision'; Requested=$reqRev; Provided=$foundVersion; Files=($Result.DebFiles | Where-Object { $_ -like "$pkgName*${foundVersion}_*.deb" }) }
    }
    $Result.Failures = $still
}

function Invoke-GuestDebAcquisition {
    param(
        [Parameter(Mandatory)][string] $RemoteDir,
        [Parameter(Mandatory)][string[]] $PackageSpecs,
        [Parameter(Mandatory)][string] $SshClient,
        [Parameter(Mandatory)][bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        # NOTE: Legacy plain-text password to match existing calling pattern; avoid proliferating further. Prefer key auth.
        # PSScriptAnalyzer Suppression: Using string for backward compatibility with existing callers.
        [string] $SshPassword,
        # Optional HTTP proxy for guest apt downloads (corporate environments). Empty = direct via NAT.
        [string] $Proxy = ''
    )
    $result = [pscustomobject]@{ DebFiles=@(); Failures=@(); Logs=@(); RemoteDir=$RemoteDir; UsedFallback=$false; Diagnostics=@(); SatisfiedMeta=@(); Resolutions=@() }
    if (-not $PackageSpecs -or $PackageSpecs.Count -eq 0) { return $result }

    function _BaseArgs([string]$extra='') {
        if ($UsingPlink) {
            $sshArgs = @('-batch','-noagent','-P','22')
            if ($PlinkHostKey) { $sshArgs += @('-hostkey', $PlinkHostKey) }
            if ($SshKey) { $sshArgs += @('-i', $SshKey) } elseif ($SshPassword) { $sshArgs += @('-pw', $SshPassword) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        } else {
            $sshArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            if ($SshKey) { $sshArgs += @('-i', $SshKey) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        }
    }

    $initOut = Initialize-DebAcquisitionEnvironment -RemoteDir $RemoteDir -SshClient $SshClient -UsingPlink:$UsingPlink -PlinkHostKey $PlinkHostKey -SshUser $SshUser -GuestIp $GuestIp -SshKey $SshKey -SshPassword $SshPassword -Proxy $Proxy
    if ($initOut) { $result.Diagnostics += ($initOut | Select-Object -First 200) }
    # Log the full diagnostic block (connectivity verdicts + apt-get update output) so download failures
    # are explainable without a second run. The cap is generous so apt-get update errors are not hidden;
    # the END marker is emitted before apt-get update so it is always captured regardless.
    Write-Log ("[DebPkg][DL] Init diagnostics:`n{0}" -f (($initOut | Select-Object -First 200) -join "`n")) -Console

    $idx = 0; $total = $PackageSpecs.Count
    foreach ($spec in $PackageSpecs) {
        $idx++
        if ([string]::IsNullOrWhiteSpace($spec)) { continue }
        $pkgSpec = $spec.Trim()
        Write-Log ("[DebPkg][DL] ({0}/{1}) --> Downloading {2} to {3}" -f $idx, $total, $pkgSpec, $RemoteDir) -Console
        $single = Invoke-DebSinglePackageDownload -Spec $pkgSpec -RemoteDir $RemoteDir -SshClient $SshClient -UsingPlink:$UsingPlink -PlinkHostKey $PlinkHostKey -SshUser $SshUser -GuestIp $GuestIp -SshKey $SshKey -SshPassword $SshPassword
        $out = $single.Output; $result.Logs += $out
        Write-Log ("[DebPkg][DL] ({0}/{1})    {2} downloaded to {3}, output head: {4}" -f $idx, $total, $pkgSpec, $RemoteDir, (($out | Select-Object -First 6) -join ' | ')) -Console
        if ($single.Failed) {
            Write-Log ("[DebPkg][DL] ({0}/{1})    Failed to download {2}" -f $idx, $total, $pkgSpec) -Console
            $result.Failures += $pkgSpec
        } else {
            Write-Log ("[DebPkg][DL] ({0}/{1})    Listing .deb files in {2}" -f $idx, $total, $RemoteDir) -Console
            # Re-run listing to ensure we get clean file names only
            $listCmd = ('bash -c ''cd {0}; pwd; ls -al 2>/dev/null | head -n 20; for f in *.deb; do if [ -f "$f" ]; then echo $f; fi; done || true''' -f $RemoteDir)
            $listOut = & $SshClient @((_BaseArgs) + $listCmd) 2>&1
            $newOnes = Add-DebFilesFromListing -ListOutput $listOut -Result $result
            $display = if ($newOnes -and $newOnes.Count -gt 0) { $newOnes -join ', ' } else { '(none new)' }
            Write-Log ("[DebPkg][DL] ({0}/{1})    new .deb file(s): {2}" -f $idx, $total, $display) -Console
        }
        Write-Log ("[DebPkg][DL] ({0}/{1}) <-- Completed attempt for {2}; total .deb files now: {3}" -f $idx, $total, $pkgSpec, ($result.DebFiles.Count)) -Console
    }
    Write-Log ("[DebPkg][DL] Completed per-package download attempts; total .deb files now: {0}" -f ($result.DebFiles.Count)) -Console

    Resolve-DebMetaPackages -Result $result
    Invoke-DebCacheFallback -RemoteDir $RemoteDir -SshClient $SshClient -UsingPlink:$UsingPlink -PlinkHostKey $PlinkHostKey -SshUser $SshUser -GuestIp $GuestIp -SshKey $SshKey -SshPassword $SshPassword -Result $result

    # Re-run meta satisfaction after fallback
    Resolve-DebMetaPackages -Result $result

    Resolve-DebRevisionBumps -Result $result -RemoteDir $RemoteDir -SshClient $SshClient -UsingPlink:$UsingPlink -PlinkHostKey $PlinkHostKey -SshUser $SshUser -GuestIp $GuestIp -SshKey $SshKey -SshPassword $SshPassword

    # Summary log
    if ($result.Resolutions.Count -gt 0) {
        $bad = $result.Resolutions | Where-Object { -not $_.Spec -or -not $_.Provided }
        if ($bad) {
            Write-Log ("[DebPkg][DL][Debug] Detected resolution entries missing Spec/Provided: {0}" -f (($bad | ConvertTo-Json -Depth 4))) -Console
        }
        # Try to repair missing Provided by parsing Files if possible
        foreach ($r in $result.Resolutions) {
            if ((-not $r.Provided) -and $r.Files -and $r.Files.Count -gt 0) {
                $first = $r.Files | Select-Object -First 1
                if ($first -match '^[^_]+_(?<ver>[^_]+)_.+\.deb$') { $r | Add-Member -NotePropertyName Provided -NotePropertyValue $matches['ver'] -Force }
            }
        }
        $formatted = @()
        foreach ($r in $result.Resolutions) {
            $specTxt = if ($r.Spec) { $r.Spec } else { '(unknown-spec)' }
            $provTxt = if ($r.Provided) { $r.Provided } else { '(unknown-version)' }
            $formatted += ("{0}->{1}" -f $specTxt, $provTxt)
        }
        $subs = $formatted -join ', '
        Write-Log ("[DebPkg][DL] Substitutions applied: {0}" -f $subs) -Console
    }
    if ($result.Failures.Count -gt 0) {
        Write-Log ("[DebPkg][DL] Unresolved specs after substitution: {0}" -f ($result.Failures -join ', ')) -Console
    }
    # (Removed interactive Read-Host used for debugging to allow non-interactive execution)

    return $result
}
