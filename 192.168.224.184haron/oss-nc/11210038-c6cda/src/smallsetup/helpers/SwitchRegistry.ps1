# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$registryFunctionsModule = "$PSScriptRoot\RegistryFunctions.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$infraModule = "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"

Import-Module $registryFunctionsModule, $clusterModule, $imageFunctionsModule, $infraModule -DisableNameChecking

function Write-DockerServiceDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage
    )

    Write-Log "[DockerDiag][$Stage] Collecting docker service diagnostics..." -Console
    $dockerService = Get-Service -Name 'docker' -ErrorAction SilentlyContinue
    if ($null -eq $dockerService) {
        Write-Log "[DockerDiag][$Stage] Service 'docker' not found." -Console
    }
    else {
        Write-Log "[DockerDiag][$Stage] Service Status=$($dockerService.Status), StartType=$($dockerService.StartType), DisplayName=$($dockerService.DisplayName)" -Console
    }

    $dockerWmi = Get-CimInstance -ClassName Win32_Service -Filter "Name='docker'" -ErrorAction SilentlyContinue
    if ($dockerWmi) {
        Write-Log "[DockerDiag][$Stage] Win32_Service State=$($dockerWmi.State), Status=$($dockerWmi.Status), StartMode=$($dockerWmi.StartMode), ProcessId=$($dockerWmi.ProcessId), ExitCode=$($dockerWmi.ExitCode)" -Console
    }

    $dockerdProc = Get-Process -Name 'dockerd' -ErrorAction SilentlyContinue
    if ($dockerdProc) {
        $dockerdSummary = ($dockerdProc | ForEach-Object { "PID=$($_.Id) CPU=$($_.CPU) WS=$($_.WorkingSet64)" }) -join '; '
        Write-Log "[DockerDiag][$Stage] dockerd processes: $dockerdSummary" -Console
    }
    else {
        Write-Log "[DockerDiag][$Stage] No dockerd process detected." -Console
    }

    $nssmExe = Join-Path $global:NssmInstallDirectory 'nssm'
    if (Test-Path $nssmExe) {
        $nssmStatusOutput = (& $nssmExe status docker 2>&1 | ForEach-Object { $_.ToString() }) -join '; '
        if ([string]::IsNullOrWhiteSpace($nssmStatusOutput)) {
            $nssmStatusOutput = '<empty>'
        }
        Write-Log "[DockerDiag][$Stage] nssm status docker => $nssmStatusOutput" -Console
    }
}

function Invoke-NssmCommandWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutInSeconds = 90,
        [Parameter(Mandatory = $false)]
        [switch]$ContinueOnTimeout = $false
    )

    $nssmExe = Join-Path $global:NssmInstallDirectory 'nssm'
    if (-not (Test-Path $nssmExe)) {
        throw "nssm executable not found at '$nssmExe'."
    }

    $stdoutFile = Join-Path $env:TEMP ("nssm-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
    $stderrFile = Join-Path $env:TEMP ("nssm-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
    Write-Log "Invoking nssm with timeout ${TimeoutInSeconds}s: $($ArgumentList -join ' ')"
    $process = Start-Process -FilePath $nssmExe -ArgumentList $ArgumentList -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
    Write-Log "nssm process started. pid=$($process.Id), command=$($ArgumentList -join ' ')"

    $intervalMs = 5000
    $elapsedMs = 0
    while (-not $process.HasExited -and $elapsedMs -lt ($TimeoutInSeconds * 1000)) {
        [void]$process.WaitForExit($intervalMs)
        $elapsedMs += $intervalMs
        if (-not $process.HasExited) {
            Write-Log "nssm command still running after $([int]($elapsedMs / 1000))s: $($ArgumentList -join ' ')" -Console
            Write-DockerServiceDiagnostics -Stage "nssm-inflight-$([int]($elapsedMs / 1000))s"
        }
    }

    if (-not $process.HasExited) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-Log "Failed to stop timed-out nssm process id '$($process.Id)': $($_.Exception.Message)"
        }

        if (Test-Path $stdoutFile) {
            Get-Content -Path $stdoutFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "[nssm stdout] $_" }
        }
        if (Test-Path $stderrFile) {
            Get-Content -Path $stderrFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "[nssm stderr] $_" }
        }

        $timeoutMessage = "nssm command timed out after ${TimeoutInSeconds}s: $($ArgumentList -join ' ')"
        if ($ContinueOnTimeout) {
            Write-Log "$timeoutMessage. Continuing without blocking image workflow."
            Remove-Item -Path $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
            return $false
        }

        Remove-Item -Path $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        throw $timeoutMessage
    }

    if (Test-Path $stdoutFile) {
        Get-Content -Path $stdoutFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "[nssm stdout] $_" }
    }
    if (Test-Path $stderrFile) {
        Get-Content -Path $stderrFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "[nssm stderr] $_" }
    }
    Remove-Item -Path $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue

    Write-Log "nssm process finished. pid=$($process.Id), exitCode=$($process.ExitCode), command=$($ArgumentList -join ' ')"
    if ($process.ExitCode -ne 0) {
        throw "nssm command failed with exit code $($process.ExitCode): $($ArgumentList -join ' ')"
    }

    return $true
}

if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    Import-Module $infraModule -DisableNameChecking
}

if (-not (Get-Module -Name $infraModule -ListAvailable)) { Initialize-Logging -ShowLogs:$ShowLogs }

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo

$registries = $(Get-RegistriesFromSetupJson)
if ($null -eq $registries) {
    $errMsg = 'No registries configured.'    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'no-registry-configured' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($registries.Contains($RegistryName) -ne $true) {
    $errMsg = "Registry $RegistryName not configured, please add it first."    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'registry-not-configured' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

Write-Log "Trying to login into $RegistryName" -Console
$buildahLoginStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Write-Log 'Starting buildah registry login...' -Console
Login-Buildah -registry $RegistryName
Write-Log "buildah registry login completed in $([int]$buildahLoginStopwatch.Elapsed.TotalSeconds)s." -Console

# Add dockerd parameters and restart docker daemon to push nondistributable artifacts and use insecure registry
if ($setupInfo.Name -eq $global:SetupType_k2s -or $setupInfo.Name -eq $global:SetupType_BuildOnlyEnv) {
    $storageLocalDrive = Get-StorageLocalDrive
    Write-DockerServiceDiagnostics -Stage 'before-docker-config'
    Write-Log "Configuring docker daemon for registry '$RegistryName'" -Console
    [void](Invoke-NssmCommandWithTimeout -ArgumentList @('set', 'docker', 'AppParameters', '--exec-opt', 'isolation=process', '--data-root', "$storageLocalDrive\docker", '--log-level', 'debug', '--allow-nondistributable-artifacts', "$RegistryName", '--insecure-registry', "$RegistryName") -TimeoutInSeconds 60)

    $dockerService = Get-Service -Name 'docker' -ErrorAction SilentlyContinue
    $dockerServiceStatus = if ($null -eq $dockerService) { 'NotFound' } else { $dockerService.Status.ToString() }
    Write-Log "Docker service status before nssm action: $dockerServiceStatus" -Console

    $nssmActionSucceeded = $false
    if ($dockerServiceStatus -eq 'Running') {
        $nssmActionSucceeded = Invoke-NssmCommandWithTimeout -ArgumentList @('restart', 'docker') -TimeoutInSeconds 90 -ContinueOnTimeout
    }
    else {
        $nssmActionSucceeded = Invoke-NssmCommandWithTimeout -ArgumentList @('start', 'docker') -TimeoutInSeconds 90 -ContinueOnTimeout
    }

    if ($nssmActionSucceeded) {
        Write-DockerServiceDiagnostics -Stage 'after-nssm-action'
        $dockerLoginStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Log 'Starting docker registry login...' -Console
        Login-Docker -registry $RegistryName
        Write-Log "docker registry login completed in $([int]$dockerLoginStopwatch.Elapsed.TotalSeconds)s." -Console
    }
    else {
        Write-DockerServiceDiagnostics -Stage 'after-nssm-timeout'
        Write-Log "Skipping docker login because docker service action timed out. Buildah login remains active for Linux image push workflows." -Console
    }
}

Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value $RegistryName

Write-Log "Login to '$RegistryName' was successful." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
