# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Import the leaf vm.module in THIS module's scope so Invoke-CmdOnControlPlaneViaSSHKey resolves (not the admin-gated node aggregator).
$vmModule = "$PSScriptRoot/../../../../lib/modules/windows/node/k2s.node.module/linuxnode/vm/vm.module.psm1"
Import-Module $vmModule

# Default fstab SMB dialect (vers=) used when smbDialect is 'auto' or unset.
$script:DefaultSmbFstabDialect = '3.0'

# A configured StorageClass mount option, e.g. 'dir_mode=0700' or 'vers=3.1.1'. Whitespace, commas and
# YAML-special characters are rejected so that every option renders as exactly one plain YAML list entry.
$script:MountOptionPattern = '^[A-Za-z0-9][A-Za-z0-9_.=/+-]*\z'

function Get-FstabVersionOption {
    param (
        [string]$SmbDialect = 'auto',
        # Dialect pinned when smbDialect is 'auto'/unset. Caller-specific to preserve historical
        # defaults: Windows SMB host fstab used 'vers=3.0', Linux Samba host fstab used 'vers=3'.
        [string]$DefaultDialect = $script:DefaultSmbFstabDialect
    )
    if ($SmbDialect -eq 'auto' -or [string]::IsNullOrEmpty($SmbDialect)) {
        return "vers=$DefaultDialect"
    }
    return "vers=$SmbDialect"
}

function Get-StorageClassMountOptions {
    param ([pscustomobject]$Config = $(throw 'Config not specified'))
    if ($null -ne $Config.MountOptions) {
        # Configured options replace the generated ones entirely, including the POSIX and dialect specific options.
        return @($Config.MountOptions)
    }
    if ($Config.EnablePosixExtensions) {
        # handletimeout: rejected by mount.cifs and conflicts with driver-injected nobrl (issue #2478).
        $opts = [System.Collections.ArrayList]@('dir_mode=0777','file_mode=0777','uid=1001','gid=1001','mfsymlinks','cache=strict')
        if (-not $Config.UseServerInode) { $opts.Add('noserverino') | Out-Null }
    } else {
        $opts = [System.Collections.ArrayList]@('dir_mode=0777','file_mode=0777','uid=1001','gid=1001','noperm','mfsymlinks','cache=strict','noserverino')
    }
    # CSI driver negotiates version automatically; only pin vers= for a non-default dialect.
    if ($Config.SmbDialect -and $Config.SmbDialect -ne 'auto') {
        $opts.Add("vers=$($Config.SmbDialect)") | Out-Null
    }
    return $opts
}

function Get-StorageClassMountOptionsError {
    <#
    .SYNOPSIS
    Validates the optional mountOptions configured for an SMB storage entry.
    .DESCRIPTION
    Returns $null when the entry does not configure mountOptions or when all configured options are valid.
    Otherwise, returns an error message identifying the affected StorageClass and the offending value.
    #>
    param ([pscustomobject]$Config = $(throw 'Config not specified'))
    $mountOptions = $Config.MountOptions
    if ($null -eq $mountOptions) {
        return $null
    }

    $errorPrefix = "Invalid 'mountOptions' for StorageClass '$($Config.StorageClassName)'"
    if ($mountOptions -isnot [array] -or $mountOptions.Count -eq 0) {
        return "$errorPrefix`: expected a non-empty array of mount options, e.g. [`"dir_mode=0700`", `"file_mode=0600`"]."
    }
    foreach ($option in $mountOptions) {
        if ($option -isnot [string] -or $option -notmatch $script:MountOptionPattern) {
            return "$errorPrefix`: '$option' is not a valid mount option. Each array entry must be a single option string such as 'dir_mode=0700', containing only letters, digits and the characters '_ . = / + -' (no whitespace or commas)."
        }
    }
    return $null
}

function Get-SambaSharePosixConfig {
    param ([pscustomobject]$Config = $(throw 'Config not specified'))
    $lines = @()
    if ($Config.EnablePosixExtensions) {
        $lines += 'vfs objects = streams_xattr'
        $lines += 'store dos attributes = no'
    }
    return $lines
}

function Test-SambaPosixNegotiation {
    <#
    .SYNOPSIS
    Validates at runtime that the Samba host advertises the POSIX (streams_xattr) settings
    required for SMB 3.1.1 POSIX extensions on a configured share.
    .DESCRIPTION
    Runs testparm against the live smb.conf on the Linux control-plane host and verifies the
    given share section declares the streams_xattr vfs object and disables DOS attribute storage.
    Returns $true when both settings are present, otherwise $false. Intended as a warn-not-fail
    post-configuration check; callers log a warning on $false rather than aborting setup.
    #>
    param (
        [Parameter(Mandatory = $true)] [string]$ShareName,
        [int]$Timeout = 2,
        [int]$Retries = 1,
        [int]$RetryDelaySeconds = 3
    )
    $cmd = "sudo testparm -s --section-name '$ShareName' 2>/dev/null"
    # Bounded poll: smbd may have just restarted, so POSIX settings can take seconds to become serviceable.
    $attempt = 0
    while ($true) {
        $result = Invoke-CmdOnControlPlaneViaSSHKey -Timeout $Timeout -CmdToExecute $cmd
        $output = ($result.Output | Out-String)
        if ([string]::IsNullOrWhiteSpace($output)) {
            # Fall back to dumping the whole config if the section query returned nothing.
            $result = Invoke-CmdOnControlPlaneViaSSHKey -Timeout $Timeout -CmdToExecute "sudo testparm -s 2>/dev/null"
            $output = ($result.Output | Out-String)
        }
        $hasStreams = $output -match 'streams_xattr'
        $hasNoDosAttr = $output -match 'store dos attributes\s*=\s*[Nn]o'
        if ($hasStreams -and $hasNoDosAttr) {
            return $true
        }
        $attempt++
        if ($attempt -ge $Retries) {
            return $false
        }
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}
Export-ModuleMember -Function Get-FstabVersionOption, Get-StorageClassMountOptions, Get-StorageClassMountOptionsError, Get-SambaSharePosixConfig, Test-SambaPosixNegotiation -Variable DefaultSmbFstabDialect
