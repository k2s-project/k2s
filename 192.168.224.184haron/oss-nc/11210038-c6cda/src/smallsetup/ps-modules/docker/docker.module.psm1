# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

&$PSScriptRoot\..\..\common\GlobalVariables.ps1

function Set-DockerToExperimental {
    $env:DOCKER_CLI_EXPERIMENTAL = 'enabled'

    &"$global:NssmInstallDirectory\nssm" restart docker

    if ($LASTEXITCODE -ne 0) {
        throw 'error while restarting Docker'
    }
}

function Start-DockerLogin {
    param (
        [parameter(Mandatory = $true, HelpMessage = "Registry to push to, e.g. 'k2s-registry.local'")]
        [string] $Registry,
        [parameter(Mandatory = $true, HelpMessage = 'User for registry login')]
        [string] $RegUser,
        [parameter(Mandatory = $true, HelpMessage = 'Password for registry login')]
        [string] $RegPw        
    )

    if ($Registry -eq '') {
        Write-Output 'Registry is empty, skipping Docker login'
    }

    docker login -u $RegUser -p $RegPw $Registry

    if ($LASTEXITCODE -ne 0) {
        throw 'error while Docker login'
    }
}

function Start-BuildDockerImage {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Dockerfile = $(throw 'Dockerfile not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $WorkDir = $(throw 'WorkDir not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $ToolVersion = $(throw 'ToolVersion not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $WindowsBaseVersion = $(throw 'WindowsBaseVersion not specified')
    )
    docker image build -f "$Dockerfile" -t $Tag --build-arg WINDOWS_VERSION=$WindowsBaseVersion "$WorkDir"
    Write-Output "  -> CMD: docker image build -f "$Dockerfile" -t $Tag --build-arg WINDOWS_VERSION=$WindowsBaseVersion '$WorkDir'"
     
    if ($LASTEXITCODE -ne 0) {
        throw 'error while building image'
    }
}

function Push-DockerImage {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified')
    )
    docker push $Tag
    Write-Output "  -> CMD: docker push $Tag"

    if ($LASTEXITCODE -ne 0) {
        throw 'error while pushing image'
    }
}

function New-DockerManifest {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $AmendTag = $(throw 'AmendTag not specified'),
        [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
        [switch] $AllowInsecureRegistries     
    )
    if ($AllowInsecureRegistries -eq $true) {
        docker manifest create --insecure $Tag --amend $AmendTag  
        Write-Output "  -> CMD: docker manifest create --insecure $Tag --amend $AmendTag"  
    }
    else {
        docker manifest create $Tag --amend $AmendTag
        Write-Output "  -> CMD: docker manifest create $Tag --amend $AmendTag" 
    }            

    if ($LASTEXITCODE -ne 0) {
        throw 'error while creating manifest'
    }
}

function New-DockerManifestAnnotation {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $AmendTag = $(throw 'AmendTag not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $OS = $(throw 'OS not specified'),
        [Parameter(Mandatory = $false)]
        [string]
        $Arch = $(throw 'Arch not specified'),
        [string]
        $OSVersion = $(throw 'OSVersion not specified')    
    )
    docker manifest annotate --os $OS --arch $Arch --os-version $OSVersion $Tag $AmendTag
    Write-Output "  -> CMD: docker manifest annotate --os $OS --arch $Arch --os-version $OSVersion $Tag $AmendTag"

    if ($LASTEXITCODE -ne 0) {
        throw 'error while annotating manifest'
    }
}

function Push-DockerManifest {
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $Tag = $(throw 'Tag not specified'),
        [parameter(Mandatory = $false, HelpMessage = 'If set to true, insecure registries like local registries are allowed.')]
        [switch] $AllowInsecureRegistries   
    )
    if ($AllowInsecureRegistries -eq $true) {
        docker manifest push --insecure $Tag
        Write-Output "  -> CMD: docker manifest push --insecure $Tag"
    }
    else {
        docker manifest push $Tag
        Write-Output "  -> CMD: docker manifest push --insecure $Tag"
    }          

    if ($LASTEXITCODE -ne 0) {
        throw 'error pushing manifest'
    }
}

function Copy-ExecutablesFromImage {
    param(
        [Parameter(Mandatory=$true)][string]$ToolImage,      # Source image with executables
        [Parameter(Mandatory=$true)][string[]]$Executables,  # List of executables inside source image
        [Parameter(Mandatory=$true)][string]$OutputDir       # Local host directory to copy executables to
    )

    # check if image is not empty
    if ($ToolImage -eq "") {
        Write-Output "Image '$ToolImage' is empty, nothing to copy"
        return
    }
    
    # Create the output directory if it doesn't exist
    if (-not (Test-Path -Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir | Out-Null
    }

    # Generate a random container name to avoid collision
    $containerName = "extract_temp_" + [guid]::NewGuid().ToString()

    try {
        # Create a container from the image (but don't start it)
        docker create --name $containerName $ToolImage | Out-Null

        foreach ($exe in $Executables) {
            $fileName = Split-Path $exe -Leaf
            $destPath = Join-Path $OutputDir $fileName
            docker cp "$($containerName):$exe" "$destPath"
            Write-Output "  -> CMD: docker cp '$($containerName):$exe' '$destPath'"
        }
    }
    finally {
        # Clean up the temporary container
        docker rm $containerName | Out-Null
    }
}

function Get-ToolVersionImages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$DockerfilePath,
        
        [Parameter(Mandatory = $false)]
        [string]$ToolVersionValue
    )
    
    $toolVersionImages = @()
    
    try {
        if (-not (Test-Path $DockerfilePath)) {
            Write-Error "Dockerfile not found at path: $DockerfilePath"
            return @()
        }
        
        $dockerfileContent = Get-Content -Path $DockerfilePath -Raw
        $lines = $dockerfileContent -split "`r?`n"
        
        foreach ($line in $lines) {
            $trimmedLine = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) {
                continue
            }
            
            if ($trimmedLine -match '^FROM\s+(.+)$') {
                $fromStatement = $matches[1].Trim()
                
                if ($fromStatement -match '\$\{TOOL_VERSION\}') {
                    $imagePart = ($fromStatement -split '\s+AS\s+')[0].Trim()
                    
                    if ($PSBoundParameters.ContainsKey('ToolVersionValue')) {
                        $finalImage = $imagePart -replace '\$\{TOOL_VERSION\}', $ToolVersionValue
                        $toolVersionImages += $finalImage
                    } else {
                        $toolVersionImages += $imagePart
                    }
                }
            }
        }
        
        return $toolVersionImages
    }
    catch {
        Write-Error "Error parsing Dockerfile at '$DockerfilePath': $($_.Exception.Message)"
        return @()
    }
}

function Get-ToolVersionImageDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$DockerfilePath
    )
    
    try {
        if (-not (Test-Path $DockerfilePath)) {
            Write-Error "Dockerfile not found at path: $DockerfilePath"
            return @()
        }
        
        $dockerfileContent = Get-Content -Path $DockerfilePath -Raw
        $lines = $dockerfileContent -split "`r?`n"
        $results = @()
        
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i].Trim()
            
            if ($line -match '^FROM\s+(.+)$') {
                $fromStatement = $matches[1].Trim()
                
                if ($fromStatement -match '\$\{TOOL_VERSION\}') {
                    $parts = $fromStatement -split '\s+AS\s+', 2
                    $imageName = $parts[0].Trim()
                    $alias = if ($parts.Count -eq 2) { $parts[1].Trim() } else { $null }
                    
                    $result = [PSCustomObject]@{
                        LineNumber = $i + 1
                        FullStatement = "FROM $fromStatement"
                        ImageName = $imageName
                        Alias = $alias
                        UsesToolVersion = $true
                    }
                    
                    $results += $result
                }
            }
        }
        
        return $results
    }
    catch {
        Write-Error "Error parsing Dockerfile at '$DockerfilePath': $($_.Exception.Message)"
        return @()
    }
}

function Get-DockerfileExecutables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerfilePath
    )
    
    $executables = @()
    
    try {
        if (-not (Test-Path $DockerfilePath)) {
            Write-Error "Dockerfile not found at path: $DockerfilePath"
            return @()
        }
        
        $dockerfileContent = Get-Content -Path $DockerfilePath -Raw
        $lines = $dockerfileContent -split "`r?`n"
        
        foreach ($line in $lines) {
            $trimmedLine = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) {
                continue
            }
            
            if ($trimmedLine -match '^COPY\s+(.*)$') {
                $copyStatement = $matches[1].Trim()
                Write-Verbose "Processing COPY statement: $copyStatement"
                
                $allFiles = @()
                
                if ($copyStatement -match '\[([^\]]+)\]') {
                    $bracketContent = $matches[1]
                    $files = $bracketContent -split ',' | ForEach-Object { 
                        $_.Trim().Trim('"').Trim("'") 
                    }
                    $allFiles += $files
                } else {
                    $parts = $copyStatement -split '\s+'
                    foreach ($part in $parts) {
                        $cleanPart = $part.Trim().Trim('"').Trim("'")
                        if (-not [string]::IsNullOrWhiteSpace($cleanPart) -and 
                            -not $cleanPart.StartsWith('--from=') -and
                            $cleanPart -ne 'COPY') {
                            $allFiles += $cleanPart
                        }
                    }
                }
                
                foreach ($file in $allFiles) {
                    if ($file.EndsWith('.exe')) {
                        $execName = [System.IO.Path]::GetFileName($file)
                        Write-Verbose "Found executable: $execName"
                        if ($executables -notcontains $execName) {
                            $executables += $execName
                        }
                    }
                }
            }
        }
        
        return $executables | Sort-Object -Unique
    }
    catch {
        Write-Error "Error parsing Dockerfile at '$DockerfilePath': $($_.Exception.Message)"
        return @()
    }
}

function Write-SignatureExecutable {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ExecutablePath,
        [parameter(Mandatory = $false, HelpMessage = 'Path to certificate')]
        [string] $CertPath = '',
        [parameter(Mandatory = $false, HelpMessage = 'Password for certificate')]
        [string] $CertPw = ''
    )

    # signtool is assumed to be in path
    $signtool = "signtool.exe"

    # Build the signtool command
    $arguments = @(
        "sign",
        "/f", "`"$CertPath`"",
        "/p", "`"$CertPw`"",
        "/fd", "SHA256",
        "/v", "`"$ExecutablePath`""
    )

    # Run signtool.exe
    Write-Output "Signing $ExecutablePath with certificate $CertificatePath and using arguments: $arguments"
    $process = Start-Process -FilePath $signtool -ArgumentList $arguments -Wait -PassThru

    # Check exit code
    if ($process.ExitCode -ne 0) {
        Write-Error "Error signing $ExecutablePath with certificate $CertificatePath with error code: $($process.ExitCode)"
    }
    
    # Return exit code
    return "Exit code: " + $process.ExitCode
}

Export-ModuleMember -Function Set-DockerToExperimental, Start-DockerLogin, Start-BuildDockerImage, Push-DockerImage, New-DockerManifest, New-DockerManifestAnnotation, Push-DockerManifest, Copy-ExecutablesFromImage, Get-ToolVersionImages, Get-ToolVersionImageDetails, Get-DockerfileExecutables, Write-SignatureExecutable
