# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

function Invoke-CommandWithPowershell([string]$Command) {
    $powershellExe = 'powershell.exe'
    $arguments = "-noprofile -Command `"$Command`""
    Write-Host "Calling $powershellExe $arguments"
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powershellExe
        $startInfo.RedirectStandardError = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.UseShellExecute = $false
        $startInfo.Arguments = $arguments
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        # Register Object Events for stdin\stdout reading
        $OutEvent = Register-ObjectEvent -Action {
            Write-Host $Event.SourceEventArgs.Data
        } -InputObject $process -EventName OutputDataReceived
        $ErrEvent = Register-ObjectEvent -Action {
            Write-Host $Event.SourceEventArgs.Data
        } -InputObject $process -EventName ErrorDataReceived
        $process.Start() | Out-Null
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        $process.WaitForExit()
        # Unregister events
        $OutEvent.Name, $ErrEvent.Name |
        ForEach-Object { Unregister-Event -SourceIdentifier $_ }
        $exitCode = $process.ExitCode
        return $exitCode
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-GoCommand {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy,
        [Parameter(Mandatory = $false)]
        [string]
        $Cmd
    )
    $currentHttpProxy = $env:http_proxy
    $currentHttpsProxy = $env:https_proxy

    try {
        $env:http_proxy = $Proxy
        $env:https_proxy = $Proxy
        $exitCode = Invoke-CommandWithPowershell -Command $Cmd
        if ($exitCode -ne 0) {
            $errorMessage = "Command $Cmd resulted in a non-zero exit code. Exit Code: $exitCode"
            throw $errorMessage
        }
    }
    finally {
        $env:http_proxy = $currentHttpProxy
        $env:https_proxy = $currentHttpsProxy
    }
}

# Internal helper: Safely execute 'go mod download' inside a working directory that may contain spaces.
function Invoke-GoModDownloadInDir {
    param (
        [Parameter(Mandatory = $true)]
        [string] $WorkingDir,
        [Parameter(Mandatory = $false)]
        [string] $Proxy
    )

    if (-not (Test-Path -LiteralPath $WorkingDir)) {
        throw "Working directory '$WorkingDir' does not exist."
    }

    # Detect if installed go supports '-C' flag (Go 1.20+). We'll attempt 'go help build' and inspect output once.
    $supportsChangeDir = $false
    try {
        $help = & go.exe help build 2>$null
        if ($help -match "-C") {
            $supportsChangeDir = $true
        }
    } catch {
        Write-Host "Warning: unable to detect go version capabilities. Falling back to Push-Location approach." -ForegroundColor Yellow
    }

    $prevHttp = $env:http_proxy
    $prevHttps = $env:https_proxy
    try {
        if ($Proxy) { $env:http_proxy = $Proxy; $env:https_proxy = $Proxy }

        if ($supportsChangeDir) {
            Write-Host "Using 'go -C' for module download in '$WorkingDir'" -ForegroundColor DarkCyan
            $exit = & go.exe -C "$WorkingDir" mod download 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host $exit
                throw "go mod download failed (exit $LASTEXITCODE) using -C in '$WorkingDir'"
            }
            return
        }

        # Fallback: change directory in-process with Push/Pop-Location
        Write-Host "Using Push-Location fallback for module download in '$WorkingDir'" -ForegroundColor DarkCyan
        Push-Location -LiteralPath $WorkingDir
        try {
            $exit = & go.exe mod download 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host $exit
                throw "go mod download failed (exit $LASTEXITCODE) in '$WorkingDir'"
            }
        } finally {
            Pop-Location
        }
    }
    finally {
        $env:http_proxy = $prevHttp
        $env:https_proxy = $prevHttps
    }
}

function New-GinkgoTestCmd {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string[]]
        $ExcludeTags,
        [Parameter(Mandatory = $false)]
        [string]
        $OutDir = $(throw 'OutDir not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $V = $false,
        [Parameter(Mandatory = $false)]
        [int]
        $Procs = 0,
        [Parameter(Mandatory = $false)]
        [string]
        $Timeout = '90m'
    )
    $ginkgoCmd = 'ginkgo'
    if ($V -eq $true) {
        $ginkgoCmd += ' -v'
    }

    # Normalize ExcludeTags if they arrive as a single comma-separated string (happens
    # when invocation style/quoting differs e.g. due to spaces in install path).
    if ($ExcludeTags -and $ExcludeTags.Count -eq 1) {
        $single = $ExcludeTags[0]
        if ($single -match ',') {
            $split = $single -split '\s*,\s*' | Where-Object { $_ -and ($_.Trim().Length -gt 0) }
            if ($split.Count -gt 0) { $ExcludeTags = $split }
        }
    }

    $ginkgoCmd += ' --require-suite' # complains about specs without test suite
    $ginkgoCmd += " --timeout=$Timeout"
    $ginkgoCmd += " --junit-report=GoTest-$((Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').ToString()).xml"
    $ginkgoCmd += " --output-dir=$OutDir"
    $ginkgoCmd += ' --vet=off' # disable go vet during test compilation to avoid sporadic Windows I/O errors (vet should run as a separate lint step)

    if ($Procs -gt 0) {
        $ginkgoCmd += " --procs=$Procs"
    }

    if ($null -eq $Tags -and $null -eq $ExcludeTags) {
        return $ginkgoCmd
    }

    # see https://onsi.github.io/ginkgo/#filtering-specs
    $ginkgoCmd += ' --label-filter="'
    $isFirstLabel = $true

    for ($i = 0; $i -lt $tags.Length; $i++) {
        if ($i -eq 0) {
            $isFirstLabel = $false

            $ginkgoCmd += '( '
        }
        else {
            $ginkgoCmd += ' || '
        }

        $ginkgoCmd += $tags[$i]

        if ($i -eq $tags.Length - 1) {
            $ginkgoCmd += ' )'
        }
    }

    foreach ($tag in $ExcludeTags) {
        if ($isFirstLabel -eq $true) {
            $isFirstLabel = $false
        }
        else {
            $ginkgoCmd += ' && '
        }

        $ginkgoCmd += "!$tag"
    }

    # Append path placeholder quoted to survive spaces in paths like 'C:\Program Files\...'
    $ginkgoCmd += '" "{path}"'

    return $ginkgoCmd
}

function Install-GinkgoIfNecessary {
    param (
        [Parameter(Mandatory = $false)]
        [string] $Proxy,

        [Parameter(Mandatory = $false)]
        [string] $GinkgoVersion = $(throw 'GinkgoVersion not specified')
    )

    # Ensure Go bin is on PATH for this session
    $goBinPath = if ($env:GOPATH) {
        Join-Path $env:GOPATH 'bin'
    } else {
        Join-Path $env:USERPROFILE 'go\bin'
    }

    if ($env:PATH -notmatch [regex]::Escape($goBinPath)) {
        $env:PATH = "$goBinPath;$env:PATH"
    }

    $ginkgoCmd = Get-Command -ErrorAction Ignore -Type Application ginkgo

    if (!$ginkgoCmd) {
        Write-Output 'Ginkgo not found, installing it..'
        Invoke-GoCommand -Proxy $Proxy -Cmd "go.exe install 'github.com/onsi/ginkgo/v2/ginkgo@v$GinkgoVersion'"

        # Re-check after install
        if ($env:PATH -notmatch [regex]::Escape($goBinPath)) {
            $env:PATH = "$goBinPath;$env:PATH"
        }
    }

    $foundVersion = (ginkgo.exe version).Split(' ')[2].Trim()
    Write-Output "Found Ginkgo version $foundVersion"

    if ($foundVersion -ne $GinkgoVersion) {
        Write-Output "Updating Ginkgo to version $GinkgoVersion.."
        Invoke-GoCommand -Proxy $Proxy -Cmd "go.exe install 'github.com/onsi/ginkgo/v2/ginkgo@v$GinkgoVersion'"
    }
}


function Install-PesterIfNecessary {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy,
        [Parameter(Mandatory = $false)]
        [string]
        $PesterVersion = $(throw 'PesterVersion not specified')
    )
    
    $pesterModule = $null
    try {
        $pesterModule = Get-InstalledModule -Name Pester -ErrorAction SilentlyContinue
    } catch {
        # PowerShellGet 1.0.0.1 has a bug with null dates in module metadata
        Write-Warning "Get-InstalledModule failed (likely PowerShellGet bug): $_"
        Write-Warning "Consider updating PowerShellGet: Install-Module -Name PowerShellGet -Force -AllowClobber"
    }

    if (!$pesterModule) {
        Write-Output 'Pester not found, installing it..'

        $pkgProviderVersion = '2.8.5.201 '

        if ($Proxy -ne '') {
            Install-PackageProvider -Name NuGet -MinimumVersion $pkgProviderVersion -Force -Proxy $Proxy
            Register-PSRepository -Default -Proxy $Proxy -ErrorAction SilentlyContinue
            Install-Module -Name Pester -Proxy $Proxy -Force -SkipPublisherCheck -MinimumVersion $PesterVersion
        }
        else {
            Install-PackageProvider -Name NuGet -MinimumVersion $pkgProviderVersion -Force
            Register-PSRepository -Default -ErrorAction SilentlyContinue
            Install-Module -Name Pester -Force -SkipPublisherCheck -MinimumVersion $PesterVersion
        }
        return
    }

    $foundVersion = "$($pesterModule.Version.Major).$($pesterModule.Version.Minor).$($pesterModule.Version.Build)"

    Write-Output "Found Pester version $foundVersion"

    if ($foundVersion -ne $PesterVersion) {
        Write-Output "Updating Pester to version $PesterVersion.."

        Update-Module -Name Pester -RequiredVersion $PesterVersion -Force -Proxy "$Proxy"
    }
}

function Start-GinkgoTests {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string[]]
        $ExcludeTags,
        [Parameter(Mandatory = $false)]
        [string]
        $WorkingDir = (throw 'working directory not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Proxy,
        [Parameter(Mandatory = $false)]
        [string]
        $OutDir = $(throw 'OutDir not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $V = $false,
        [Parameter(Mandatory = $false)]
        [switch]
        $VV = $false,
        [Parameter(Mandatory = $false)]
        [int]
        $Procs = 0,
        [Parameter(Mandatory = $false)]
        [string]
        $Timeout = '90m'
    )
    Write-Output "  Executing Go-based tests in '$WorkingDir' with verbose='$V' and super-verbose='$VV' for tags '$Tags' and excluding tags '$ExcludeTags'.."

    if ($Proxy -ne '') {
        Write-Output "  Using Proxy to download go modules: '$Proxy'.."
        Invoke-GoModDownloadInDir -WorkingDir $WorkingDir -Proxy $Proxy
    } else {
        # Even without proxy we still must ensure modules are downloaded with safe path handling
        Invoke-GoModDownloadInDir -WorkingDir $WorkingDir
    }

    $effectiveProcs = $Procs
    if ($effectiveProcs -le 0) {
        $containsSecurity = $false
        $containsInvasive = $false

        if ($Tags) {
            $containsSecurity = [bool]($Tags | Where-Object { $_ -eq 'security' })
            $containsInvasive = [bool]($Tags | Where-Object { $_ -eq 'invasive' })
        }

        if ($containsSecurity -or $containsInvasive) {
            $effectiveProcs = 1
            Write-Output '  Forcing ginkgo single-process mode (--procs=1) for security/invasive tagged runs.'
        }
    }

    $ginkgoCmd = $(New-GinkgoTestCmd -Tags $Tags -ExcludeTags $ExcludeTags -OutDir $OutDir -V:$V -Procs $effectiveProcs -Timeout $Timeout)
    $testFolders = (Get-ChildItem -Path $WorkingDir -File -Recurse -Filter '*_test.go').DirectoryName | Get-Unique

    if ($VV -eq $true) {
        Write-Output '  Found tests in folders:'
        $testFolders | ForEach-Object { Write-Output "       $_" }
    }

    foreach ($folder in $testFolders) {
        # TODO: refactor
        $labelsResult = (ginkgo labels $folder 2>$null) | Out-String

        if ($labelsResult -match 'Found no test suites') {
            Write-Output "No test suites found in '$folder'"
            continue
        }

        $foundLabels = [System.Collections.ArrayList]@()
        $packageName = $labelsResult.Split(':')[0]

        if ($labelsResult -match 'No labels found') {
            if ($VV -eq $true) {
                Write-Output "  No labels found for package '$packageName'"
            }
        }
        else {
            $splitResult = $labelsResult.Trim().Replace(' ', '').Split(':')[1]
            if ($splitResult) {
                $result = $splitResult | ConvertFrom-Json
                foreach ($label in @($result)) {
                    [void] $foundLabels.Add($label)
                }
            }
        }

        if ($VV -eq $true) {
            Write-Output "  Found labels for package '$packageName': $foundLabels"
        }

        $isMatch = (($null -eq $ExcludeTags) -or ($null -eq ($ExcludeTags | Where-Object { $foundLabels -contains $_ }))) -and (($null -eq $Tags) -or ($null -ne ($Tags | Where-Object { $foundLabels -contains $_ })))
        if ($isMatch -ne $true) {
            if ($VV -eq $true) {
                Write-Output "  No match for package '$packageName'"
            }
            continue
        }

        if ($VV -eq $true) {
            Write-Output "  Match for package '$packageName'"
        }

        $cmd = $ginkgoCmd -replace '{path}', $folder

        Write-Output "  Executing Gingko Command: '$cmd'.."
        Invoke-Expression $cmd
        if ($LASTEXITCODE -ne 0) {
            break
        }
    }
}

function Start-PesterTests {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]
        $Tags,
        [Parameter(Mandatory = $false)]
        [string[]]
        $ExcludeTags,
        [Parameter(Mandatory = $false)]
        [string]
        $WorkingDir = (throw 'working directory not specified'),
        [Parameter(Mandatory = $false)]
        [ValidateSet('None', 'Run', 'Container', 'Block')]
        [string]
        $SkipRemainingOnFailure = 'None',
        [Parameter(Mandatory = $false)]
        [string]
        $OutDir = $(throw 'OutDir not specified'),
        [Parameter(Mandatory = $false)]
        [switch]
        $V = $false
    )
    Write-Output "Executing Powershell tests in '$WorkingDir' with verbose='$V' for tags '$Tags' and excluding tags '$ExcludeTags'.."

    $pesterConf = New-PesterConfiguration
    $pesterConf.Run.Path = $WorkingDir
    $pesterConf.Run.SkipRemainingOnFailure = $SkipRemainingOnFailure
    $pesterConf.Filter.Tag = $Tags
    $pesterConf.Filter.ExcludeTag = $ExcludeTags
    $pesterConf.TestResult.Enabled = $true
    $pesterConf.TestResult.OutputPath = $OutDir + '\PowershellTest-' + (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss').ToString() + '.xml'

    if ($V -eq $true) {
        $pesterConf.Output.Verbosity = 'Detailed'
    }

    Invoke-Pester -Configuration $pesterConf
}

Export-ModuleMember -Function Install-PesterIfNecessary, Install-GinkgoIfNecessary, Start-PesterTests, Start-GinkgoTests
