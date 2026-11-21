# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# File hashing utilities

function Get-FileMap {
    param($root, [string]$label, [switch]$ShowLogs)
    $map = @{}
    $files = Get-ChildItem -Path $root -Recurse -File
    $total = $files.Count
    Write-Log "[Hash] Starting hashing of $total files in '$label' (root='$root')" -Console
    if ($total -eq 0) { return $map }
    $lastPct = -1
    for ($i = 0; $i -lt $total; $i++) {
        $f = $files[$i]
        $rel = $f.FullName.Substring($root.Length) -replace '^[\\/]+' , '' -replace '\\','/'
        try { $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant() } catch { Write-Log "[Warning] Hash failed for '$($f.FullName)': $($_.Exception.Message)"; $hash = '' }
        $map[$rel] = [pscustomobject]@{ Hash = $hash; Size = $f.Length }
        if ($ShowLogs) {
            $pct = [int](($i+1) * 100 / $total)
            if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) { Write-Progress -Activity "Hashing $label" -Status "$(($i+1)) / $total files" -PercentComplete $pct; $lastPct = $pct }
        }
    }
    if ($ShowLogs) { Write-Progress -Activity "Hashing $label" -Completed }
    Write-Log "[Hash] Completed hashing of $total files in '$label'" -Console
    return $map
}
