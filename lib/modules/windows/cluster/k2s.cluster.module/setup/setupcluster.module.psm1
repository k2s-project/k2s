# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0


$configModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
$hooksModule = "$PSScriptRoot\..\..\..\infra\k2s.infra.module\hooks\hooks.module.psm1"
$vmModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\linuxnode\vm\vm.module.psm1"
$vmNodeModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\vmnode\vmnode.module.psm1"
$kubeToolsModule = "$PSScriptRoot\..\..\..\node\k2s.node.module\windowsnode\downloader\artifacts\kube-tools\kube-tools.module.psm1"
$imageModule = "$PSScriptRoot\..\image\image.module.psm1"
$k8sApiModule = "$PSScriptRoot\..\k8s-api\k8s-api.module.psm1"

Import-Module $configModule, $logModule, $pathModule, $vmModule, $hooksModule, $kubeToolsModule, $imageModule, $vmNodeModule, $k8sApiModule

$kubePath = Get-KubePath
$kubeConfigDir = Get-ConfiguredKubeConfigDir

$kubeletConfigDir = Get-KubeletConfigDir
$joinConfigurationFilePath = "$kubePath\cfg\kubeadm\joinnode.yaml"
$kubernetesImagesJson = Get-KubernetesImagesFilePath
$kubeToolsPath = Get-KubeToolsPath

<#
.SYNOPSIS
    Quotes arguments for a native command line (MSVC/Go argv rules).
#>
function ConvertTo-KubectlArgumentString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]] $Arguments
    )

    $quoted = foreach ($argument in $Arguments) {
        if ($argument.Length -gt 0 -and $argument -notmatch '[\s"]') {
            $argument
            continue
        }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($char in $argument.ToCharArray()) {
            if ($char -eq '\') {
                $backslashes++
                continue
            }
            if ($char -eq '"') {
                [void]$builder.Append('\', 2 * $backslashes + 1)
            }
            elseif ($backslashes -gt 0) {
                [void]$builder.Append('\', $backslashes)
            }
            $backslashes = 0
            [void]$builder.Append($char)
        }
        [void]$builder.Append('\', 2 * $backslashes)
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return ($quoted -join ' ')
}

<#
.SYNOPSIS
    Runs kubectl with an explicit KUBECONFIG and returns exit code, raw stdout bytes and stderr.
.DESCRIPTION
    Stdout is read from the process stream as raw bytes, so it is neither re-decoded with the
    console code page nor re-encoded by PowerShell redirection (which writes UTF-16LE in
    Windows PowerShell 5.1). KUBECONFIG is set only for the child process; an empty value
    removes it so that '--kubeconfig' is the single source of truth.
#>
function Invoke-KubeconfigKubectl {
    param(
        [Parameter(Mandatory = $true)]
        [string] $KubectlPath,
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,
        [Parameter(Mandatory = $false)]
        [string] $KubeConfig = ''
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $KubectlPath
    $startInfo.Arguments = ConvertTo-KubectlArgumentString -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if ([string]::IsNullOrEmpty($KubeConfig)) {
        $startInfo.EnvironmentVariables.Remove('KUBECONFIG')
    }
    else {
        $startInfo.EnvironmentVariables['KUBECONFIG'] = $KubeConfig
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        # Drain stderr asynchronously to avoid a pipe deadlock while copying stdout.
        $stdErrTask = $process.StandardError.ReadToEndAsync()
        $stdOut = New-Object System.IO.MemoryStream
        $process.StandardOutput.BaseStream.CopyTo($stdOut)
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdOut.ToArray()
            StdErr   = [string]$stdErrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-KubeconfigKubectlChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $KubectlPath,
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,
        [Parameter(Mandatory = $false)]
        [string] $KubeConfig = ''
    )

    $result = Invoke-KubeconfigKubectl -KubectlPath $KubectlPath -Arguments $Arguments -KubeConfig $KubeConfig
    if ($null -eq $result -or $result.ExitCode -ne 0) {
        $exitCode = if ($null -eq $result) { 'n/a' } else { $result.ExitCode }
        $stdErr = if ($null -eq $result) { '' } else { "$($result.StdErr)".Trim() }
        throw "[KubeConfig] 'kubectl $($Arguments -join ' ')' failed with exit code $($exitCode): $stdErr"
    }
    return $result
}

<#
.SYNOPSIS
    Throws unless the bytes are non-empty, BOM-less, NUL-free, valid UTF-8.
#>
function Assert-KubeconfigBytes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]] $Bytes,
        [Parameter(Mandatory = $true)]
        [string] $Description
    )

    if ($Bytes.Length -eq 0) {
        throw "[KubeConfig] $Description is empty"
    }
    if (($Bytes.Length -ge 2) -and (($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) -or ($Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF))) {
        throw "[KubeConfig] $Description has a UTF-16 byte order mark"
    }
    if (($Bytes.Length -ge 3) -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        throw "[KubeConfig] $Description has a UTF-8 byte order mark"
    }
    if ([array]::IndexOf($Bytes, [byte]0) -ge 0) {
        throw "[KubeConfig] $Description contains NUL bytes"
    }
    try {
        $null = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes)
    }
    catch {
        throw "[KubeConfig] $Description is not valid UTF-8: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Parses a kubeconfig file with kubectl and returns it as an object (JSON representation).
#>
function Get-KubeconfigObject {
    param(
        [Parameter(Mandatory = $true)]
        [string] $KubectlPath,
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $result = Invoke-KubeconfigKubectlChecked -KubectlPath $KubectlPath -Arguments @('config', 'view', '--raw', '-o', 'json', '--kubeconfig', $Path)
    $json = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($result.StdOut)
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "[KubeConfig] kubectl returned no content when parsing '$Path'"
    }
    return ($json | ConvertFrom-Json)
}

function Get-KubeconfigNamedEntries {
    param(
        [Parameter(Mandatory = $false)]
        $Config,
        [Parameter(Mandatory = $true)]
        [ValidateSet('clusters', 'users', 'contexts')]
        [string] $Section
    )

    $entries = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
    if ($null -eq $Config) {
        return , $entries
    }
    foreach ($entry in @($Config.$Section | Where-Object { $null -ne $_ })) {
        if ($entries.ContainsKey($entry.name)) {
            throw "[KubeConfig] duplicate $Section entry '$($entry.name)'"
        }
        $entries[$entry.name] = ($entry | ConvertTo-Json -Compress -Depth 64)
    }
    return , $entries
}

<#
.SYNOPSIS
    Verifies that a merged kubeconfig contains exactly the preserved foreign entries plus the K2s entries.
.DESCRIPTION
    Foreign entries (all entries of the original user kubeconfig except the K2s cluster/user/context)
    must be unchanged. Entries of the K2s source config must be present unchanged. No other entries
    may exist and the K2s context must be the current context.
#>
function Assert-MergedKubeconfig {
    param(
        [Parameter(Mandatory = $true)]
        $Merged,
        [Parameter(Mandatory = $false)]
        $Original,
        [Parameter(Mandatory = $true)]
        $K2sSource,
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,
        [Parameter(Mandatory = $true)]
        [string] $UserName,
        [Parameter(Mandatory = $true)]
        [string] $ContextName
    )

    $k2sNames = @{ clusters = $ClusterName; users = $UserName; contexts = $ContextName }
    foreach ($section in @('clusters', 'users', 'contexts')) {
        $mergedEntries = Get-KubeconfigNamedEntries -Config $Merged -Section $section
        $originalEntries = Get-KubeconfigNamedEntries -Config $Original -Section $section
        $sourceEntries = Get-KubeconfigNamedEntries -Config $K2sSource -Section $section

        $expected = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
        foreach ($name in $originalEntries.Keys) {
            if ($name -cne $k2sNames[$section]) {
                $expected[$name] = $originalEntries[$name]
            }
        }
        foreach ($name in $sourceEntries.Keys) {
            if (!$expected.ContainsKey($name)) {
                $expected[$name] = $sourceEntries[$name]
            }
        }
        if (!$expected.ContainsKey($k2sNames[$section])) {
            throw "[KubeConfig] K2s $section entry '$($k2sNames[$section])' is missing in the K2s kubeconfig"
        }

        foreach ($name in $expected.Keys) {
            if (!$mergedEntries.ContainsKey($name)) {
                throw "[KubeConfig] merged kubeconfig is missing $section entry '$name'"
            }
            if ($mergedEntries[$name] -cne $expected[$name]) {
                throw "[KubeConfig] merged kubeconfig changed $section entry '$name'"
            }
        }
        foreach ($name in $mergedEntries.Keys) {
            if (!$expected.ContainsKey($name)) {
                throw "[KubeConfig] merged kubeconfig contains unexpected $section entry '$name'"
            }
        }
    }

    $k2sContext = @($Merged.contexts | Where-Object { $null -ne $_ -and $_.name -ceq $ContextName })[0]
    if ($k2sContext.context.cluster -cne $ClusterName -or $k2sContext.context.user -cne $UserName) {
        throw "[KubeConfig] K2s context '$ContextName' does not reference cluster '$ClusterName' and user '$UserName'"
    }
    if ($Merged.'current-context' -cne $ContextName) {
        throw "[KubeConfig] merged kubeconfig current-context is '$($Merged.'current-context')' instead of '$ContextName'"
    }
}

<#
.SYNOPSIS
    Throws unless the K2s cluster and user carry complete, embedded base64-encoded PEM credentials.
.DESCRIPTION
    The K2s kubeconfig is kubeadm's admin.conf, which always embeds certificate-authority-data,
    client-certificate-data and client-key-data; all three are mandatory. kubectl accepts a kubeconfig
    truncated inside the last base64 value, so a partially copied '<install>\config' would otherwise
    pass validation and be committed with corrupt credentials. Each value must decode to one or more
    PEM blocks with matching BEGIN/END labels and a base64 body, and nothing outside the blocks:
    certificates must be CERTIFICATE blocks, the key exactly one RSA/EC/PKCS#8 PRIVATE KEY block.
#>
function Assert-K2sCredentialData {
    param(
        [Parameter(Mandatory = $true)]
        $K2sSource,
        [Parameter(Mandatory = $true)]
        [string] $ClusterName,
        [Parameter(Mandatory = $true)]
        [string] $UserName
    )

    $clusters = @($K2sSource.clusters | Where-Object { $null -ne $_ -and $_.name -ceq $ClusterName })
    $users = @($K2sSource.users | Where-Object { $null -ne $_ -and $_.name -ceq $UserName })
    foreach ($entry in @(@{ Kind = 'cluster'; Name = $ClusterName; Count = $clusters.Count }, @{ Kind = 'user'; Name = $UserName; Count = $users.Count })) {
        if ($entry.Count -eq 0) {
            throw "[KubeConfig] K2s kubeconfig has no $($entry.Kind) '$($entry.Name)'"
        }
        if ($entry.Count -gt 1) {
            throw "[KubeConfig] K2s kubeconfig has duplicate $($entry.Kind) '$($entry.Name)'"
        }
    }
    $fields = @(
        @{ Owner = "cluster '$ClusterName'"; Data = $clusters[0].cluster; Name = 'certificate-authority-data'; Labels = @('CERTIFICATE'); SingleBlock = $false },
        @{ Owner = "user '$UserName'"; Data = $users[0].user; Name = 'client-certificate-data'; Labels = @('CERTIFICATE'); SingleBlock = $false },
        @{ Owner = "user '$UserName'"; Data = $users[0].user; Name = 'client-key-data'; Labels = @('RSA PRIVATE KEY', 'EC PRIVATE KEY', 'PRIVATE KEY'); SingleBlock = $true }
    )
    # Whole value = one or more BEGIN/END blocks with the same label (\k<label> is the label of the current block).
    $pemPattern = '\A\s*(?:-----BEGIN (?<label>[A-Z0-9]+(?: [A-Z0-9]+)*)-----\r?\n(?<body>[A-Za-z0-9+/=\r\n]+?)-----END \k<label>-----\s*)+\z'
    foreach ($field in $fields) {
        $value = $null
        if ($null -ne $field.Data -and $null -ne $field.Data.PSObject.Properties[$field.Name]) {
            $value = $field.Data.($field.Name)
        }
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            throw "[KubeConfig] K2s kubeconfig $($field.Owner) has no $($field.Name); the file may be incomplete"
        }
        try {
            $decoded = [System.Text.Encoding]::ASCII.GetString([System.Convert]::FromBase64String([string]$value))
        }
        catch {
            throw "[KubeConfig] K2s kubeconfig $($field.Owner) has invalid $($field.Name) (not base64); the file may be truncated"
        }
        $match = [regex]::Match($decoded, $pemPattern)
        if (!$match.Success) {
            throw "[KubeConfig] K2s kubeconfig $($field.Owner) has incomplete PEM data in $($field.Name) (missing, unterminated or mismatched BEGIN/END blocks); the file may be truncated"
        }
        $labels = @($match.Groups['label'].Captures | ForEach-Object { $_.Value })
        if (($field.SingleBlock -and $labels.Count -ne 1) -or @($labels | Where-Object { $field.Labels -cnotcontains $_ }).Count -gt 0) {
            throw "[KubeConfig] K2s kubeconfig $($field.Owner) has unexpected PEM blocks in $($field.Name) ($($labels -join ', ')); expected $(if ($field.SingleBlock) { 'one of' } else { 'only' }) $($field.Labels -join ' / ')"
        }
        foreach ($body in $match.Groups['body'].Captures) {
            try {
                $null = [System.Convert]::FromBase64String(($body.Value -replace '\s', ''))
            }
            catch {
                throw "[KubeConfig] K2s kubeconfig $($field.Owner) has a corrupt PEM body in $($field.Name)"
            }
        }
    }
}

function Write-KubeconfigStagingFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [byte[]] $Bytes
    )

    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Invoke-KubeconfigFileReplace {
    param(
        [Parameter(Mandatory = $true)]
        [string] $StagingPath,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $BackupPath
    )

    [System.IO.File]::Replace($StagingPath, $Path, $BackupPath)
}

function Test-KubeconfigFileUnchanged {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [byte[]] $OriginalBytes
    )

    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    }
    catch {
        return $false
    }
    try {
        $buffer = New-Object System.IO.MemoryStream
        $stream.CopyTo($buffer)
        $currentBytes = $buffer.ToArray()
    }
    finally {
        $stream.Dispose()
    }
    return ($currentBytes.Length -eq $OriginalBytes.Length) -and ([System.Convert]::ToBase64String($currentBytes) -ceq [System.Convert]::ToBase64String($OriginalBytes))
}

<#
.SYNOPSIS
    Replaces the user kubeconfig with the validated staging file.
.DESCRIPTION
    Staging and target are in the same directory, so the operation is a rename on the same volume.
    An existing target is swapped with File.Replace (ReplaceFile), which keeps the target's ACL and
    attributes and moves the previous content to BackupPath. The target is opened with
    FileShare.Read|Delete and compared with the original bytes; the handle is held until the swap,
    so in-place writers are blocked between check and swap. Writers that replace the file by rename
    are not blocked (remaining race window). If ReplaceFile fails after it already moved the target
    to BackupPath (ERROR_UNABLE_TO_MOVE_REPLACEMENT_2), the original is moved back. Transient IO errors
    that leave the target untouched (e.g. ERROR_UNABLE_TO_REMOVE_REPLACED while a scanner briefly holds
    the file) are retried up to ReplaceAttempts times after re-checking that the target is unchanged.
    A target that does not exist is created with File.Move, which fails instead of overwriting if
    another process created it in the meantime.
#>
function Publish-KubeconfigFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $StagingPath,
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $BackupPath,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [byte[]] $OriginalBytes,
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int] $ReplaceAttempts = 5
    )

    if ($null -eq $OriginalBytes) {
        if (Test-Path -LiteralPath $Path) {
            throw "[KubeConfig] '$Path' was created by another process during the update; it was left unchanged"
        }
        [System.IO.File]::Move($StagingPath, $Path)
        return
    }

    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete))
    }
    catch {
        throw "[KubeConfig] '$Path' is in use by another process; it was left unchanged: $($_.Exception.Message)"
    }
    $replaceError = $null
    try {
        $buffer = New-Object System.IO.MemoryStream
        $stream.CopyTo($buffer)
        $currentBytes = $buffer.ToArray()
        if (($currentBytes.Length -ne $OriginalBytes.Length) -or ([System.Convert]::ToBase64String($currentBytes) -cne [System.Convert]::ToBase64String($OriginalBytes))) {
            throw "[KubeConfig] '$Path' was modified by another process during the update; it was left unchanged"
        }
        $attempt = 0
        while ($true) {
            $attempt++
            try {
                Invoke-KubeconfigFileReplace -StagingPath $StagingPath -Path $Path -BackupPath $BackupPath
                $replaceError = $null
                break
            }
            catch {
                $replaceError = $_
            }
            $cause = $replaceError.Exception
            if ($cause -is [System.Management.Automation.MethodInvocationException] -and $null -ne $cause.InnerException) {
                $cause = $cause.InnerException
            }
            # Only transient IO errors (e.g. ERROR_UNABLE_TO_REMOVE_REPLACED while a scanner briefly holds the
            # target) are retried, and only while nothing has been moved yet.
            if ($attempt -ge $ReplaceAttempts -or $cause -isnot [System.IO.IOException] -or
                ![System.IO.File]::Exists($Path) -or ![System.IO.File]::Exists($StagingPath)) {
                break
            }
            if (!(Test-KubeconfigFileUnchanged -Path $Path -OriginalBytes $OriginalBytes)) {
                throw "[KubeConfig] '$Path' was modified by another process during the update; it was left unchanged"
            }
            Write-Log "[KubeConfig] replacing '$Path' failed (attempt $attempt of $ReplaceAttempts), retrying: $($cause.Message)"
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
    finally {
        $stream.Dispose()
    }
    if ($null -eq $replaceError) {
        return
    }

    $reason = $replaceError.Exception.Message
    if ([System.IO.File]::Exists($Path)) {
        throw "[KubeConfig] replacing '$Path' failed; it was left unchanged: $reason"
    }
    if (![System.IO.File]::Exists($BackupPath)) {
        throw "[KubeConfig] replacing '$Path' failed and neither '$Path' nor '$BackupPath' exists: $reason"
    }
    # Only move the backup back if ReplaceFile actually moved the original there; otherwise (e.g. the target
    # was deleted by another process) BackupPath still holds an older backup and must not be presented as the original.
    if (!(Test-KubeconfigFileUnchanged -Path $BackupPath -OriginalBytes $OriginalBytes)) {
        throw "[KubeConfig] replacing '$Path' failed, '$Path' no longer exists and '$BackupPath' does not hold its original content; nothing was restored: $reason"
    }
    try {
        [System.IO.File]::Move($BackupPath, $Path)
    }
    catch {
        throw "[KubeConfig] replacing '$Path' failed ($reason) and the original could not be moved back; it is preserved in '$BackupPath': $($_.Exception.Message)"
    }
    throw "[KubeConfig] replacing '$Path' failed; the original was restored: $reason"
}

<#
.SYNOPSIS
    Adds or updates the K2s cluster, user and context in the user kubeconfig and makes the K2s context current.
.DESCRIPTION
    The user kubeconfig is never modified in place. The K2s entries are removed from a private copy,
    merged with the K2s kubeconfig ('<install>\config'), the K2s context is selected, and the result
    is validated (UTF-8 without BOM, no NUL bytes, parseable, foreign entries unchanged, K2s entries
    present). Only then is the user kubeconfig replaced; the previous content is kept in 'config_backup'.
    On any failure the user kubeconfig is left byte-for-byte unchanged and temporary files are removed.
#>
function Add-K8sContext {
    Write-Log '[KubeConfig] Updating K2s context in user kubeconfig'
    if (!(Test-Path $kubeConfigDir)) {
        mkdir $kubeConfigDir -Force | Out-Null
    }

    $kubectl = "$kubeToolsPath\kubectl.exe"
    $clusterName = Get-InstalledClusterName
    $userName = 'kubernetes-admin'
    $contextName = "$userName@$clusterName"
    $sourcePath = "$kubePath\config"
    $userConfigPath = "$kubeConfigDir\config"
    $backupPath = "$kubeConfigDir\config_backup"
    $workId = [guid]::NewGuid().ToString('N')
    $strippedPath = "$kubeConfigDir\config.k2s-$workId.work"
    $stagingPath = "$kubeConfigDir\config.k2s-$workId.new"

    try {
        if (!(Test-Path -LiteralPath $sourcePath) -or ((Get-Item -LiteralPath $sourcePath).Length -eq 0)) {
            throw "[KubeConfig] K2s kubeconfig '$sourcePath' is missing or empty"
        }
        $k2sSource = Get-KubeconfigObject -KubectlPath $kubectl -Path $sourcePath
        Assert-K2sCredentialData -K2sSource $k2sSource -ClusterName $clusterName -UserName $userName

        $originalBytes = $null
        $originalConfig = $null
        $mergeInputs = $sourcePath
        if (Test-Path -LiteralPath $userConfigPath) {
            $originalBytes = [System.IO.File]::ReadAllBytes($userConfigPath)
            $originalConfig = Get-KubeconfigObject -KubectlPath $kubectl -Path $userConfigPath
            foreach ($context in @($originalConfig.contexts | Where-Object { $null -ne $_ -and $_.name -cne $contextName })) {
                if ($context.context.cluster -ceq $clusterName -or $context.context.user -ceq $userName) {
                    Write-Log "[KubeConfig] Warning: context '$($context.name)' references cluster '$($context.context.cluster)' / user '$($context.context.user)'; entries named '$clusterName' / '$userName' are replaced with the K2s entries" -Console
                }
            }

            # Remove existing K2s entries from a private copy in the same directory (relative paths keep resolving).
            [System.IO.File]::WriteAllBytes($strippedPath, $originalBytes)
            $deletions = @(
                @{ Section = 'contexts'; Command = 'delete-context'; Name = $contextName },
                @{ Section = 'clusters'; Command = 'delete-cluster'; Name = $clusterName },
                @{ Section = 'users'; Command = 'delete-user'; Name = $userName }
            )
            foreach ($deletion in $deletions) {
                $existing = @($originalConfig.($deletion.Section) | Where-Object { $null -ne $_ -and $_.name -ceq $deletion.Name })
                if ($existing.Count -gt 0) {
                    $null = Invoke-KubeconfigKubectlChecked -KubectlPath $kubectl -Arguments @('config', $deletion.Command, $deletion.Name, '--kubeconfig', $strippedPath)
                }
            }
            $mergeInputs = "$strippedPath;$sourcePath"
        }

        Write-Log '[KubeConfig] Merging K2s cluster, user and context into user kubeconfig'
        $merged = Invoke-KubeconfigKubectlChecked -KubectlPath $kubectl -Arguments @('config', 'view', '--raw') -KubeConfig $mergeInputs
        Assert-KubeconfigBytes -Bytes $merged.StdOut -Description 'merged kubeconfig'
        Write-KubeconfigStagingFile -Path $stagingPath -Bytes $merged.StdOut
        $null = Invoke-KubeconfigKubectlChecked -KubectlPath $kubectl -Arguments @('config', 'use-context', $contextName, '--kubeconfig', $stagingPath)

        $stagedBytes = [System.IO.File]::ReadAllBytes($stagingPath)
        Assert-KubeconfigBytes -Bytes $stagedBytes -Description 'staged kubeconfig'
        $stagedConfig = Get-KubeconfigObject -KubectlPath $kubectl -Path $stagingPath
        Assert-MergedKubeconfig -Merged $stagedConfig -Original $originalConfig -K2sSource $k2sSource -ClusterName $clusterName -UserName $userName -ContextName $contextName

        Publish-KubeconfigFile -StagingPath $stagingPath -Path $userConfigPath -BackupPath $backupPath -OriginalBytes $originalBytes
        Write-Log "[KubeConfig] Switched to context '$contextName' in '$userConfigPath'"
    }
    finally {
        foreach ($tempFile in @($strippedPath, "$strippedPath.lock", $stagingPath, "$stagingPath.lock")) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        $env:KUBECONFIG = ''
    }

    # Informational only (secrets redacted); the update is already committed.
    Write-Log 'Config from user directory:'
    try {
        $view = Invoke-KubeconfigKubectl -KubectlPath $kubectl -Arguments @('config', 'view', '--kubeconfig', $userConfigPath)
        Write-Log ((New-Object System.Text.UTF8Encoding($false)).GetString($view.StdOut))
    }
    catch {
        Write-Log "[KubeConfig] Unable to display kubeconfig: $($_.Exception.Message)"
    }
}

<#
    NOTE: Import module is necessary as this function runs as independent process
    Wait until both the master and the worker node are ready, then kill the kubeadm process which waits
    for the TLS bootstrap.
    This shortens the waiting time, as we have no real TLS bootstrap:
     - The config file got copied from the master, so the kubelet
       starts and joins without doing a full TLS bootstrap
     - As a consequence, the kubeadm join waits forever and does not detect
       the finished joining
#>
function Wait-ForNodesReady {
    param(
        [Parameter()]
        [String]
        $controlPlaneHostName,
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]
        $KubeadmProcessId
    )
    # force import path module since this is executed in a script block
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep 2
        #Write-Output "Checking for node $env:COMPUTERNAME..."
        # using is used because this function is executed in script block in Join-WindowsNode.
        $nodes = $(&"$using:kubeToolsPath\kubectl.exe" get nodes)
        #Write-Output "$i WaitForJoin: $nodes"

        $nodefound = $nodes | Select-String -Pattern "$env:COMPUTERNAME\s*Ready"
        if ( $nodefound ) {
            Write-Output "Node found: $nodefound"
            $masterReady = $nodes | Select-String -Pattern "$controlPlaneHostName\s*Ready"
            if ($masterReady) {
                Write-Output "Master also ready, stopping 'kubeadm join'"
                if ($KubeadmProcessId -gt 0) {
                    Stop-Process -Id $KubeadmProcessId -Force -ErrorAction SilentlyContinue
                }
                break
            }
            else {
                Write-Output 'Master not ready yet, keep waiting...'
            }
        }
    }
}

function Wait-KubeadmJoinProcess {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Process,
        [Parameter(Mandatory = $true)]
        [string] $StandardOutputPath,
        [Parameter(Mandatory = $true)]
        [string] $StandardErrorPath,
        [int] $TimeoutSeconds = 600
    )

    $null = $Process.Handle
    if ($Process.WaitForExit($TimeoutSeconds * 1000)) {
        return $Process.ExitCode
    }

    Write-Log "[KubeadmJoin] kubeadm join timed out after $TimeoutSeconds seconds. Terminating process $($Process.Id)." -Console
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    $Process.WaitForExit()

    if (Test-Path -LiteralPath $StandardOutputPath) {
        Get-Content -LiteralPath $StandardOutputPath -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Log "[KubeadmJoin][stdout] $_" }
    }
    if (Test-Path -LiteralPath $StandardErrorPath) {
        Get-Content -LiteralPath $StandardErrorPath -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Log "[KubeadmJoin][stderr] $_" }
    }

    $kubectlPath = "$kubeToolsPath\kubectl.exe"
    if (Test-Path -LiteralPath $kubectlPath) {
        &$kubectlPath get nodes -o wide 2>&1 | Write-Log
    }
    Get-Service -Name 'containerd', 'kubelet', 'kubeproxy' -ErrorAction SilentlyContinue |
        Format-Table Name, Status, StartType -AutoSize |
        Out-String |
        Write-Log
    throw "kubeadm join timed out after $TimeoutSeconds seconds"
}

<#
.SYNOPSIS
Pre-creates a Windows node object with the correct PodCIDR before kubeadm join.

.DESCRIPTION
Kubernetes controller-manager auto-allocates a PodCIDR when a node joins the cluster.
However, K2s expects a specific PodCIDR (podNetworkWorkerCIDR) that Flannel is configured to use.
Since Kubernetes does not allow changing podCIDR after it's set, we pre-create the node object
with the correct podCIDR BEFORE kubeadm join runs. When kubeadm join completes, it updates
the node's status and other fields but preserves the pre-set podCIDR.

.PARAMETER NodeName
The name of the Windows node to pre-create.

.PARAMETER PodSubnetworkNumber
The pod subnetwork number (e.g., '1' for 172.20.1.0/24).
#>
function Initialize-WindowsNodePodCIDR {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    # Get expected PodCIDR from config.json
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRWorkerTemplate = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value
    $expectedPodCIDR = $clusterCIDRWorkerTemplate.Replace('X', $PodSubnetworkNumber)

    Write-Log "Pre-creating Windows node '$NodeName' with PodCIDR '$expectedPodCIDR'"

    # Check if node already exists
    $existingNode = &"$kubeToolsPath\kubectl.exe" get nodes $NodeName --ignore-not-found -o name 2>&1
    if ($LASTEXITCODE -eq 0 -and $existingNode) {
        Write-Log "Node '$NodeName' already exists, skipping pre-creation"
        return
    }

    # Create the node object with the correct PodCIDR
    # When kubeadm join runs, it will update this node rather than creating a new one
    $nodeManifest = @{
        apiVersion = "v1"
        kind = "Node"
        metadata = @{
            name = $NodeName
        }
        spec = @{
            podCIDR = $expectedPodCIDR
            podCIDRs = @($expectedPodCIDR)
        }
    }
    $nodeJson = $nodeManifest | ConvertTo-Json -Depth 10
    
    $nodeFile = [System.IO.Path]::GetTempFileName()
    try {
        # Write JSON without BOM (Out-File -Encoding utf8 adds BOM in Windows PowerShell)
        [System.IO.File]::WriteAllText($nodeFile, $nodeJson, [System.Text.UTF8Encoding]::new($false))
        
        $createOutput = &"$kubeToolsPath\kubectl.exe" create -f $nodeFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "[WARN] Failed to pre-create node '$NodeName': $createOutput" -Console
            Write-Log "Continuing with join - controller-manager will allocate PodCIDR"
            return
        }
        Write-Log "Successfully pre-created node '$NodeName' with PodCIDR '$expectedPodCIDR'"
    }
    finally {
        Remove-Item -Path $nodeFile -Force -ErrorAction SilentlyContinue
    }
}

<#
Join the windows node with linux control plane node
#>
function Join-WindowsNode {
    Param(
        [string]$CommandForJoining = $(throw 'Argument missing: CommandForJoining'),
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    # join node if necessary
    $nodefound = &"$kubeToolsPath\kubectl.exe" get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
    if ( !($nodefound) ) {

        # copy kubeadmin to c:
        $tempKubeadmDirectory = $(Get-SystemDriveLetter) + ':\k'
        $bPathAvailable = Test-Path -Path $tempKubeadmDirectory
        if ( !$bPathAvailable ) { mkdir -Force $tempKubeadmDirectory | Out-Null }
        Copy-Item -Path "$kubeToolsPath\kubeadm.exe" -Destination $tempKubeadmDirectory -Force

        Write-Log 'Add kubeadm to firewall rules'
        $tempRuleName = 'Allow temp Kubeadm'
        New-NetFirewallRule -DisplayName $tempRuleName -Group 'k2s' -Direction Inbound -Action Allow -Program "$tempKubeadmDirectory\kubeadm.exe" -Enabled True | Out-Null
        #Below rule is not necessary but adding in case we perform subsequent operations.
        New-NetFirewallRule -DisplayName 'Allow Kubeadm' -Group 'k2s' -Direction Inbound -Action Allow -Program "$kubeToolsPath\kubeadm.exe" -Enabled True | Out-Null

        Write-Log "Host $env:COMPUTERNAME not yet available as worker node."

        & "$tempKubeadmDirectory\kubeadm.exe" reset -f 2>&1 | Write-Log
        Get-ChildItem -Path $kubeletConfigDir -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }
        Remove-Item -Path "$kubeletConfigDir\etc" -Force -Recurse -ErrorAction SilentlyContinue
        New-Item -Path "$kubeletConfigDir\etc" -ItemType SymbolicLink -Value "$(Get-SystemDriveLetter):\etc" | Out-Null
        # get join command
        # Remove-Job -Name JoinK8sJob -Force -ErrorAction SilentlyContinue
        Write-Log 'Build join command ..'

        $cmdjoin = $CommandForJoining | Select-String -Pattern 'kubeadm join' -CaseSensitive -SimpleMatch
        $cmdjoin.Line = $cmdjoin.Line.replace("`n", '').replace("`r", '')

        $searchPattern = 'kubeadm join (?<api>[^\s]*) --token (?<token>[^\s]*) --discovery-token-ca-cert-hash (?<hash>[^\s]*)'
        $patternSearchResult = $cmdjoin.Line | Select-String -Pattern $searchPattern

        if (($null -eq $patternSearchResult.Matches) -or ($patternSearchResult.Matches.Count -ne 1) -or ($patternSearchResult.Matches.Groups.Count -ne (3 + 1))) {
            $errorMessage = "Could not find the api server endpoint and/or the token and/or the hash from the return value of the command '$tokenCreationCommand'`n" +
            "  - Command return value: '$($cmdjoin.Line)'`n" +
            "  - Search pattern: '$searchPattern'`n"
            throw $errorMessage
        }

        $apiServerEndpoint = $patternSearchResult.Matches.Groups[1].Value
        $token = $patternSearchResult.Matches.Groups[2].Value
        $hash = $patternSearchResult.Matches.Groups[3].Value
        $caCertFilePath = "$(Get-SystemDriveLetter):\etc\kubernetes\pki\ca.crt"
        $windowsNodeIpAddress = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber

        Write-Log 'Create config file for join command'
        $joinConfigurationTemplateFilePath = "$kubePath\cfg\kubeadm\joinnode.template.yaml"

        $content = (Get-Content -path $joinConfigurationTemplateFilePath -Raw)
        $content.Replace('__CA_CERT__', $caCertFilePath).Replace('__API__', $apiServerEndpoint).Replace('__TOKEN__', $token).Replace('__SHA__', $hash).Replace('__CRI_SOCKET__', 'npipe:////./pipe/containerd-containerd').Replace('__NODE_IP__', $windowsNodeIpAddress) | Set-Content -Path "$joinConfigurationFilePath"

        $joinArguments = "join $apiServerEndpoint" + ' --node-name ' + $env:COMPUTERNAME + ' --ignore-preflight-errors IsPrivilegedUser,SystemVerification' + " --config `"$joinConfigurationFilePath`""
        $joinCommand = ".\kubeadm.exe $joinArguments"

        Write-Log $joinCommand

        # Pre-create the node with correct PodCIDR before kubeadm join
        # This ensures controller-manager doesn't auto-allocate a different CIDR
        Initialize-WindowsNodePodCIDR -NodeName $env:COMPUTERNAME.ToLower() -PodSubnetworkNumber $PodSubnetworkNumber

        $controlPlaneHostName = Get-ConfigControlPlaneNodeHostname
        $joinStdoutPath = [System.IO.Path]::GetTempFileName()
        $joinStderrPath = [System.IO.Path]::GetTempFileName()
        $job = $null
        $joinProcess = $null
        try {
            $joinProcess = Start-Process -FilePath "$tempKubeadmDirectory\kubeadm.exe" `
                -ArgumentList $joinArguments `
                -WorkingDirectory $tempKubeadmDirectory `
                -NoNewWindow `
                -PassThru `
                -RedirectStandardOutput $joinStdoutPath `
                -RedirectStandardError $joinStderrPath
            Write-Log "[KubeadmJoin] Started process $($joinProcess.Id) with a 600 second timeout"
            $job = Start-Job -ScriptBlock ${Function:Wait-ForNodesReady} -ArgumentList $controlPlaneHostName, $joinProcess.Id
            $joinExitCode = Wait-KubeadmJoinProcess -Process $joinProcess `
                -StandardOutputPath $joinStdoutPath `
                -StandardErrorPath $joinStderrPath `
                -TimeoutSeconds 600
            Get-Content -LiteralPath $joinStdoutPath -ErrorAction SilentlyContinue | Write-Log
            Get-Content -LiteralPath $joinStderrPath -ErrorAction SilentlyContinue | Write-Log
            Write-Log "[KubeadmJoin] Process exited with code $joinExitCode"
        }
        finally {
            if ($null -ne $joinProcess -and -not $joinProcess.HasExited) {
                Write-Log "[KubeadmJoin] Terminating process $($joinProcess.Id) during cleanup"
                Stop-Process -Id $joinProcess.Id -Force -ErrorAction SilentlyContinue
                $joinProcess.WaitForExit()
            }
            if ($null -ne $job) {
                Receive-Job $job -ErrorAction SilentlyContinue | Write-Log
                Stop-Job $job -ErrorAction SilentlyContinue
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $joinStdoutPath, $joinStderrPath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path "$tempKubeadmDirectory\kubeadm.exe" -Force -ErrorAction SilentlyContinue
            if ( !$bPathAvailable ) { Remove-Item -Path $tempKubeadmDirectory -Force -ErrorAction SilentlyContinue }
            $rule = Get-NetFirewallRule -DisplayName $tempRuleName -ErrorAction SilentlyContinue
            if ($rule) { Remove-NetFirewallRule -DisplayName $tempRuleName -ErrorAction SilentlyContinue }
        }

        # check success in joining
        $nodefound = &"$kubeToolsPath\kubectl.exe" get nodes | Select-String -Pattern $env:COMPUTERNAME -SimpleMatch
        if ( !($nodefound) ) {
            &"$kubeToolsPath\kubectl.exe" get nodes
            throw 'Joining the windows node failed'
        }

        Write-Log "Joining node $env:COMPUTERNAME to cluster is done."
    }
    else {
        Write-Log "Host $env:COMPUTERNAME already available as node !"
    }

    # check success in creating kubelet config file
    $kubeletConfig = "$kubeletConfigDir\config.yaml"
    Write-Log "kubelet config under: $kubeletConfig"
    if (! (Test-Path $kubeletConfig)) {
        throw "Expected file not created: $kubeletConfig"
    }
    if (! (Get-Content $kubeletConfig | Select-String -Pattern 'KubeletConfiguration' -SimpleMatch)) {
        throw "Wrong content in $kubeletConfig, aborting"
    }
    $kubeletEnv = "$kubeletConfigDir\kubeadm-flags.env"
    if (! (Test-Path $kubeletEnv)) {
        throw "Expected file not created: $kubeletEnv"
    }

    # mark nodes as worker
    Write-Log 'Labeling windows node as worker node'
    &"$kubeToolsPath\kubectl.exe" label nodes $env:computername.ToLower() kubernetes.io/role=worker --overwrite | Out-Null

    # Verify PodCIDR is correct (should have been set by pre-creation before join)
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRWorkerTemplate = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value
    $expectedPodCIDR = $clusterCIDRWorkerTemplate.Replace('X', $PodSubnetworkNumber)
    $actualPodCIDR = &"$kubeToolsPath\kubectl.exe" get nodes $env:computername.ToLower() -o jsonpath="{.spec.podCIDR}" 2>&1
    if ($actualPodCIDR -eq $expectedPodCIDR) {
        Write-Log "Node PodCIDR correctly set to '$expectedPodCIDR'"
    }
    else {
        Write-Log "[ERROR] Node PodCIDR mismatch. Expected: $expectedPodCIDR, Got: $actualPodCIDR" -Console
        throw "Windows node PodCIDR mismatch. Expected '$expectedPodCIDR' but got '$actualPodCIDR'. Flannel networking will not work correctly."
    }
}

function Join-LinuxNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $NodeUserName = $(throw 'Argument missing: NodeUserName'),
        [string] $NodeIpAddress = $(throw 'Argument missing: NodeIpAddress'),
        [scriptblock] $PreStepHook = {}
    )

    # join node if necessary
    $nodefound = &"$kubeToolsPath\kubectl.exe" get nodes | Select-String -Pattern $NodeName -SimpleMatch
    if ( !($nodefound) ) {
        Write-Log "Host $NodeName not yet available as worker node."

        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -f /etc/kubernetes/kubelet.conf' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -rf /etc/kubernetes/pki' -UserName $NodeUserName -IpAddress $NodeIpAddress -IgnoreErrors).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -rf /var/lib/kubelet/pki' -UserName $NodeUserName -IpAddress $NodeIpAddress -IgnoreErrors).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl stop kubelet' -UserName $NodeUserName -IpAddress $NodeIpAddress -IgnoreErrors).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo kubeadm reset --force' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log

        Write-Log "Preparing kubelet prerequisites on node '$NodeIpAddress'"
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo mkdir -p /etc/kubernetes/kubelet.conf.d' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo mkdir -p /var/lib/kubelet' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl reset-failed kubelet' -UserName $NodeUserName -IpAddress $NodeIpAddress -IgnoreErrors).Output | Write-Log

        if ($null -ne $PreStepHook) {
            &$PreStepHook
        }

        $CommandForJoining = New-JoinCommand

        Write-Log 'Build join command ..'

        $cmdjoin = $CommandForJoining | Select-String -Pattern 'kubeadm join' -CaseSensitive -SimpleMatch
        $cmdjoin.Line = $cmdjoin.Line.replace("`n", '').replace("`r", '')

        $searchPattern = 'kubeadm join (?<api>[^\s]*) --token (?<token>[^\s]*) --discovery-token-ca-cert-hash (?<hash>[^\s]*)'
        $patternSearchResult = $cmdjoin.Line | Select-String -Pattern $searchPattern

        if (($null -eq $patternSearchResult.Matches) -or ($patternSearchResult.Matches.Count -ne 1) -or ($patternSearchResult.Matches.Groups.Count -ne (3 + 1))) {
            $errorMessage = "Could not find the api server endpoint and/or the token and/or the hash from the return value of the command 'sudo kubeadm token create --print-join-command'`n" +
            "  - Command return value: '$($cmdjoin.Line)'`n" +
            "  - Search pattern: '$searchPattern'`n"
            throw $errorMessage
        }

        $apiServerEndpoint = $patternSearchResult.Matches.Groups[1].Value
        $token = $patternSearchResult.Matches.Groups[2].Value
        $hash = $patternSearchResult.Matches.Groups[3].Value
        $caCertFilePath = '/etc/kubernetes/pki/ca.crt'

        Write-Log 'Create config file for join command'
        $joinConfigurationTemplateFilePath = "$kubePath\cfg\kubeadm\joinnode-linux.template.yaml"
        $content = (Get-Content -path $joinConfigurationTemplateFilePath -Raw)
        $content.Replace('__CA_CERT__', $caCertFilePath).Replace('__API__', $apiServerEndpoint).Replace('__TOKEN__', $token).Replace('__SHA__', $hash).Replace('__CRI_SOCKET__', 'unix:///run/crio/crio.sock').Replace('__NODE_IP__', $NodeIpAddress) | Set-Content -Path "$joinConfigurationFilePath"

        Write-Log "Copy config file for join command to node '$NodeIpAddress'"
        $source = $joinConfigurationFilePath
        $target = '/tmp/joinnode.yaml'
        Copy-ToRemoteComputerViaSshKey -Source $source -Target $target -UserName $NodeUserName -IpAddress $NodeIpAddress
   
        $joinCommand = "sudo kubeadm join $apiServerEndpoint" + ' --node-name ' + $NodeName + ' --ignore-preflight-errors IsPrivilegedUser,SystemVerification' + " --config `"$target`""
        Write-Log "Created join command: $joinCommand"

        (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl start crio' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
        
        Write-Log "Invoke join command in node '$NodeName'"
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute $joinCommand -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log

        # check success in joining
        Write-Log "Check join status for node '$NodeName'"
        $nodefound = $false
        for ($retry = 0; $retry -lt 30; $retry++) {
            $singleNodeStatus = &"$kubeToolsPath\kubectl.exe" get node $NodeName --ignore-not-found --no-headers 2>&1
            if (($LASTEXITCODE -eq 0) -and -not [string]::IsNullOrWhiteSpace((($singleNodeStatus | Out-String).Trim()))) {
                $nodefound = $true
                break
            }
            Start-Sleep -Seconds 2
        }

        if ( !($nodefound) ) {
            &"$kubeToolsPath\kubectl.exe" get nodes
            throw "Joining the linux node '$NodeName' failed"
        }

        Write-Log "Joining linux node '$NodeName' to cluster is done."
    }
    else {
        Write-Log "Host $NodeName already available as node !"
    }

    # mark node as worker
    Write-Log "Labeling linux node '$NodeName' as worker node"
    &"$kubeToolsPath\kubectl.exe" label nodes $Nodename.ToLower() kubernetes.io/role=worker --overwrite | Out-Null
}

function Remove-LinuxNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $NodeUserName = $(throw 'Argument missing: NodeUserName'),
        [string] $NodeIpAddress = $(throw 'Argument missing: NodeIpAddress'),
        [scriptblock] $PostStepHook = {}
    )

    # Use --force --grace-period=0 --timeout=60s to avoid hanging on NotReady nodes
    (Invoke-Kubectl -Params @('drain', "$NodeName", '--ignore-daemonsets', '--delete-emptydir-data', '--force', '--grace-period=0', '--timeout=60s')).Output | ForEach-Object { "$_" } | Write-Log
    (Invoke-Kubectl -Params @('delete', 'node', "$NodeName", '--ignore-not-found')).Output | ForEach-Object { "$_" } | Write-Log
    
    # delete control plane route only if it exists and is not a connected/kernel route
    $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $controlPlaneRoute = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "ip route show $controlPlaneCIDR | head -1" -UserName $NodeUserName -IpAddress $NodeIpAddress -IgnoreErrors).Output.Trim()
    if (-not [string]::IsNullOrWhiteSpace($controlPlaneRoute)) {
        if ($controlPlaneRoute -match 'proto kernel|scope link') {
            Write-Log "[Route] Keeping connected route: $controlPlaneRoute"
        } else {
            (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route delete $controlPlaneCIDR" -UserName $NodeUserName -IpAddress $NodeIpAddress -IgnoreErrors).Output | Write-Log
        }
    } else {
        Write-Log "[Route] $controlPlaneCIDR not found on node, skipping delete."
    }
    
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo systemctl stop kubelet' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -rf /etc/kubernetes' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo kubeadm reset --force' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log

    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -rf /etc/cni' -UserName $NodeUserName -IpAddress $NodeIpAddress).Output | Write-Log

    &$PostStepHook

}

function Set-KubeletDiskPressure {
    # set new limits for the windows node for disk pressure
    # kubelet is running now (caused by joining the windows host to the cluster), so we stop it. Will be restarted in start-up sequence.
    Stop-Service kubelet
    $kubeletconfig = "$kubeletConfigDir\config.yaml"
    Write-Log "using kubelet file: $kubeletconfig"
    $content = Get-Content "$kubeletconfig"
    $content | ForEach-Object { $_ -replace 'evictionPressureTransitionPeriod:',
        "evictionHard:`r`n  nodefs.available: 8Gi`r`n  imagefs.available: 8Gi`r`nevictionPressureTransitionPeriod:" } |
    Set-Content "$kubeletconfig"
}

function Initialize-KubernetesCluster {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $JoinCommand = $(throw 'Argument missing: JoinCommand')
    )
    Invoke-Hook -HookName 'AfterVmInitialized' -AdditionalHooksDir $AdditionalHooksDir

    # try to join host windows node
    Write-Log 'starting the join process'
    
    Join-WindowsNode -CommandForJoining $JoinCommand -PodSubnetworkNumber $PodSubnetworkNumber

    Set-KubeletDiskPressure

    # show results
    Write-Log "Current state of kubernetes nodes:`n"
    Start-Sleep 2
    &"$kubeToolsPath\kubectl.exe" get nodes -o wide

    Write-Log "Collecting kubernetes images and storing them to $kubernetesImagesJson."
    Write-KubernetesImagesIntoJson
}

function Uninstall-Cluster {
    Remove-Item -Path "$joinConfigurationFilePath" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubernetesImagesJson" -Force -ErrorAction SilentlyContinue
}

function New-JoinCommand {
    $tokenCreationCommand = 'sudo kubeadm token create --print-join-command'
    $joinCommand = (Invoke-CmdOnControlPlaneViaSSHKey -Retries 3 -CmdToExecute "$tokenCreationCommand").Output 2>&1
    return $joinCommand
}

Export-ModuleMember Initialize-KubernetesCluster,
Uninstall-Cluster, Set-KubeletDiskPressure,
Join-WindowsNode, Join-LinuxNode, Add-K8sContext,
New-JoinCommand, Remove-LinuxNode,
Wait-KubeadmJoinProcess
