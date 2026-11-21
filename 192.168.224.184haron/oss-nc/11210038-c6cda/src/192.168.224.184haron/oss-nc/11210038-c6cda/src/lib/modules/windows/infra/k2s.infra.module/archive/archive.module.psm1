# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Stream-based ZIP archive helpers.  Unlike Compress-Archive / Expand-Archive
# these use System.IO.Compression with file streams (not MemoryStream) and
# therefore have **no 2 GB size limit**.

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Format-Size {
    param(
        [uint64] $Bytes
    )
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    $kb = [double]$Bytes / 1KB
    if ($kb -lt 1024) { return ("{0:N2} KB" -f $kb) }
    $mb = $kb / 1024
    if ($mb -lt 1024) { return ("{0:N2} MB" -f $mb) }
    $gb = $mb / 1024
    if ($gb -lt 1024) { return ("{0:N2} GB" -f $gb) }
    $tb = $gb / 1024
    return ("{0:N2} TB" -f $tb)
}

function Expand-ZipWithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$Destination,
        [string]$Label = 'zip',
        [switch]$Show
    )
    Write-Log "[Expand] Starting extraction of '$ZipPath' to '$Destination' (Label=$Label)" -Console
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "Zip not found: $ZipPath" }
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $entries = @()
    [IO.Compression.ZipFile]::OpenRead($ZipPath).Entries | ForEach-Object { $entries += $_ }
    $total = $entries.Count
    Write-Log "[Expand] Zip has $total extractable entries" -Console
    $lastPct = -1
    $idx = 0
    foreach ($e in $entries) {
        $idx++
        if ([string]::IsNullOrEmpty($e.Name)) { continue }
        $targetPath = Join-Path $Destination $e.FullName
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
        $eStream = $e.Open(); $outStream = [IO.File]::Create($targetPath)
        try {
            $buffer = New-Object byte[] 131072
            while (($read = $eStream.Read($buffer,0,$buffer.Length)) -gt 0) { $outStream.Write($buffer,0,$read) }
        } finally { $eStream.Dispose(); $outStream.Dispose() }
        if ($Show -and $total -gt 0) {
            $pct = [int]($idx*100/$total)
            if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
                Write-Progress -Activity "Extracting $Label" -Status "$idx / $total" -PercentComplete $pct
                $lastPct = $pct
            }
        }
    }
    if ($Show) { Write-Progress -Activity "Extracting $Label" -Completed }
    $sw.Stop(); Write-Log ("Expanded {0} entries from {1} in {2:N2}s" -f $total, (Split-Path -Leaf $ZipPath), $sw.Elapsed.TotalSeconds) -Console
}

function New-ZipWithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [string]$Label = 'archive',
        [switch]$Show
    )
    # Resolve to full (long) path to avoid Windows 8.3 short name mismatches
    # (e.g. ADMINI~1 vs Administrator) when computing relative paths from Get-ChildItem .FullName
    $SourceDir = (Get-Item -LiteralPath $SourceDir).FullName
    Write-Log "[Zip] Creating archive '$ZipPath' from source '$SourceDir'" -Console
    if (-not (Test-Path -LiteralPath $SourceDir)) { throw "Source dir not found: $SourceDir" }
    $files = Get-ChildItem -Path $SourceDir -Recurse -File
    $total = $files.Count
    Write-Log "[Zip] Found $total files to add" -Console
    $fileStream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $zipArchive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        $lastPct = -1
        for ($i = 0; $i -lt $total; $i++) {
            $f = $files[$i]
            $rel = $f.FullName.Substring($SourceDir.Length)
            $rel = $rel -replace '^[\\/]+' , ''
            $rel = $rel -replace '\\','/'
            $entry = $zipArchive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $inStream = [System.IO.File]::OpenRead($f.FullName)
                try {
                    $buffer = New-Object byte[] 131072
                    while (($read = $inStream.Read($buffer,0,$buffer.Length)) -gt 0) { $entryStream.Write($buffer,0,$read) }
                } finally { $inStream.Dispose() }
            } finally { $entryStream.Dispose() }
            if ($Show -and $total -gt 0) {
                $pct = [int](($i+1)*100/$total)
                if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
                    Write-Progress -Activity "Zipping $Label" -Status "$(($i+1)) / $total" -PercentComplete $pct
                    $lastPct = $pct
                }
            }
        }
        if ($Show) { Write-Progress -Activity "Zipping $Label" -Completed }
    }
    finally {
        if ($zipArchive) { $zipArchive.Dispose() }
        $fileStream.Dispose()
        $sw.Stop()
        if (Test-Path -LiteralPath $ZipPath) {
            $sz = (Get-Item -LiteralPath $ZipPath).Length
            $hr = Format-Size $sz
            Write-Log ("Zip completed in {0:N2}s (size={1} / {2:N0} bytes)" -f $sw.Elapsed.TotalSeconds, $hr, $sz) -Console
        } else {
            Write-Log '[Warning] Zip creation failed (file not present after process)' -Console
        }
    }
}

Export-ModuleMember -Function Format-Size, Expand-ZipWithProgress, New-ZipWithProgress
