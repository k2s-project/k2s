# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Build a new image on the control plane VM or on Windows host

.DESCRIPTION
Builds a Linux container image or a Windows container image in the K2s setup.

.PARAMETER InputFolder
Directory with the Dockerfile

.PARAMETER Dockerfile
Name of the Dockerfile

.PARAMETER ImageName
Name of the created image

.PARAMETER ImageTag
Tag in registry

.PARAMETER Push
Push image to repository

.PARAMETER NoCache
Don't use cache in Docker build

.PARAMETER Optimize
Optimize for size

.PARAMETER NoCGO
Use bindings for C

.PARAMETER Distroless
Use distroless base image

.PARAMETER KeepColor
Keep the colored output from Docker build

.PARAMETER Keep
Keep temporary directory on VM

.PARAMETER PreCompile
Precompile outside of container

.PARAMETER Windows
Build a windows container image

.PARAMETER GitConfigWithSecrets
Use a gitconfig with --secret during docker build

.PARAMETER NpmRcWithSecrets
Use a npmrc with --secret during docker build

.PARAMETER BuildArgs
Build Arguments for building container image

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Build a linux image 'k2s.registry.local/testserver:v1' and push to registry 'k2s.registry.local'
PS> .\Build-Image.ps1 -ImageName k2s.registry.local/testserver -ImageTag v1 -Push

.EXAMPLE
# Build a linux image 'k2s.registry.local/testserver:v1' with several options e.g. pre-compile outside of container and optimize size
PS> .\Build-Image.ps1 -ImageName k2s.registry.local/testserver -Tag v1 -PreCompile -Optimize -Distroless -NoCGO
#>

Param(
    [Alias('d')]
    [parameter(Mandatory = $false, HelpMessage = 'Directory with the Dockerfile')]
    [string] $InputFolder = '.',

    [Alias('f')]
    [parameter(Mandatory = $false, HelpMessage = 'Name of the Dockerfile')]
    [string] $Dockerfile = '',

    [parameter(Mandatory = $false, HelpMessage = 'Name of the created image')]
    [string] $ImageName = '',

    [Alias('t', 'Tag')]
    [parameter(Mandatory = $false, HelpMessage = 'Tag in registry')]
    [string] $ImageTag = 'local',

    [Alias('p')]
    [parameter(Mandatory = $false, HelpMessage = 'Push image to repository')]
    [switch] $Push = $false,

    [parameter(Mandatory = $false, HelpMessage = "Don't use cache in Docker build")]
    [switch] $NoCache = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Optimize for size')]
    [switch] $Optimize = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Use bindings for C')]
    [switch] $NoCGO = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Use distroless base image')]
    [switch] $Distroless = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Keep the colored output from Docker build')]
    [switch] $KeepColor = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Keep temporary directory on VM')]
    [switch] $Keep = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Precompile outside of container')]
    [switch] $PreCompile = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Build a windows container image')]
    [switch] $Windows = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Use a gitconfig with --secret during docker build')]
    [string] $GitConfigWithSecrets = '',

    [parameter(Mandatory = $false, HelpMessage = 'Use a npmrc with --secret during docker build')]
    [string] $NpmRcWithSecrets = '',

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'Build Arguments for building container image')]
    [string[]] $BuildArgs = @(),

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$nodeModule = "$PSScriptRoot\..\..\..\..\modules\windows\node\k2s.node.module\k2s.node.module.psm1"
$infraModule = "$PSScriptRoot\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $nodeModule, $infraModule, $clusterModule
Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

$scriptStartLocation = Get-Location
Write-Log "Script start location: $scriptStartLocation"

$InputFolder = [System.IO.Path]::GetFullPath($InputFolder)

$kubeBinPath = Get-KubeBinPath
$nerdctlExe = "$kubeBinPath\nerdctl.exe"

$dockerfileAbsoluteFp, $PreCompile = Get-DockerfileAbsolutePathAndPreCompileFlag -InputFolder $InputFolder -Dockerfile $Dockerfile -PreCompile:$PreCompile

if (($ImageTag -eq 'local') -and $Push) { throw 'Unable to push without valid tag, use -ImageTag' }

Write-Log "Using Dockerfile: $dockerfileAbsoluteFp" -Console

# Handle CGO flags
$CGOFlags = 'CC=musl-gcc CGO_ENABLED=1'
$env:CGO_ENABLED = '1'
if ( $NoCGO ) {
    $CGOFlags = 'CGO_ENABLED=0'
    $env:CGO_ENABLED = '0'
}

# Handle parameters from dockerfile
$ImageNameFromDockerfile = ''
$ccExecutableName = ''
$GoBuild = 'build'
# by default, we build the main module package:
$goPackageToBuild = '.'
Get-Content $dockerfileAbsoluteFp | ForEach-Object {
    if ($_ -match '^# *ExeName: +(\S+)') {
        $ccExecutableName = $matches[1]
    }
    if ($_ -match '^# *GoPackage: +(\S+)') {
        $goPackageToBuild = $matches[1]
    }
    if ($_ -match '^# *ImageName: +(\S+)') {
        $ImageNameFromDockerfile = $matches[1]
    }
    if ($_ -match '^# *GoBuild: +(\S+)') {
        $GoBuild = $matches[1]
    }
    if ($_ -match '^# *ImageType: +Windows') {
        $Windows = $true
    }
}
if ($ImageName -eq '') {
    if ($ImageNameFromDockerfile -eq '') { throw "Missing ImageName in $InputFolder\$Dockerfile, and no -ImageName parameter given" }
    $ImageName = $ImageNameFromDockerfile
    Write-Log "Using ImageName from Dockerfile: $ImageName"
}

if ($ccExecutableName -eq '' -and $PreCompile ) {
    throw "Missing ExeName in $InputFolder\$Dockerfile"
}

Set-Location $InputFolder
$BuildDirFromDockerfile = '..'
Set-Location $BuildDirFromDockerfile
Write-Log "Using BuildDirFromDockerfile: $BuildDirFromDockerfile"
Copy-Item $dockerfileAbsoluteFp Dockerfile.ForBuild.tmp

if ($Distroless -and $NoCGO ) {
    $file = 'Dockerfile.ForBuild.tmp'
    $line = Get-Content $file | select-string 'FROM' | Select-Object -ExpandProperty Line
    (Get-Content ($file)) | Foreach-Object { $_ -replace "$line", ('FROM gcr.io/distroless/static-debian11') } | Set-Content ($file)
}

$GitConfigWithSecretsArg = ''
$NpmSecretsArg = ''

if ($GitConfigWithSecrets -ne '') {
    # Copy git config
    Write-Log "Copy $GitConfigWithSecrets to gitconfig"
    attrib -r Dockerfile.ForBuild.tmp
    Copy-Item $GitConfigWithSecrets gitconfig
    attrib -r gitconfig
    $GitConfigWithSecretsArg = '--secret id=gitconfig,src=gitconfig'
}

if ($NpmRcWithSecrets -ne '') {
    # Copy npmrc config
    Write-Log "Copy $NpmRcWithSecrets to .npmrc"
    Copy-Item $NpmRcWithSecrets .npmrc
    attrib -r .npmrc
    $NpmSecretsArg = '--secret id=npmrc,src=.npmrc'
}

# Linux Precompile & Full: copy source files to VM
if (!$Windows) {
    Write-Log "Copying needed source files into control plane VM from $InputFolder" -Console
    $target = '~/tmp/docker-build/' + $(Split-Path -Leaf $InputFolder)
    (Invoke-CmdOnControlPlaneViaSSHKey "test -d ~/tmp/docker-build && find ~/tmp/docker-build -exec chmod a+w {} \; ; rm -rf ~/tmp/docker-build; mkdir -p ~/tmp/docker-build; mkdir -p $target;mkdir -p ~/tmp/docker-build/common").Output | Write-Log
    $source = $InputFolder
    Write-Log "Copying $source to $target"
    Get-ChildItem -Path $source -Exclude 'node_modules', 'dist', '.angular' | % { $n = $_.Name ; Write-Log "Copying $source\$n to $target"; Copy-ToControlPlaneViaSSHKey "$source/$n" $target }

    # copy gitconfig
    $source = $InputFolder + '\..\gitconfig'
    $target = '~/tmp/docker-build/'
    Write-Log "Copying $source to $target"
    Copy-ToControlPlaneViaSSHKey $source $target -IgnoreErrors

    # copy .npmrc
    $source = $InputFolder + '\..\.npmrc'
    $target = '~/tmp/docker-build/'
    Write-Log "Copying $source to $target"
    Copy-ToControlPlaneViaSSHKey $source $target -IgnoreErrors

    # copy Dockerfile.ForBuild.tmp
    $source = $InputFolder + '\..\Dockerfile.ForBuild.tmp'
    $target = '~/tmp/docker-build/'
    Write-Log "Copying $source to $target"
    Copy-ToControlPlaneViaSSHKey $source $target

    # copy common if available
    $source = $InputFolder + '\..\common'
    if ( Test-Path -Path $source ) {
        $target = '~/tmp/docker-build/common'
        Write-Log "Copying $source to $target"
        Copy-ToControlPlaneViaSSHKey "$source\*" $target
    }
}

$GO_VERSION = '1.27.3'
if ($null -ne $env:GOVERSION -and $env:GOVERSION -ne '') {
    Write-Log "Using local GOVERSION $Env:GOVERSION environment variable from the host machine"
    # $env:GOVERSION will be go1.24.2, remove the go part.
    $GO_VERSION = $env:GOVERSION -split 'go' | Select-Object -Last 1
}

# Linux Precompile: build inside VM images
if (!$Windows -and $PreCompile) {
    #Set-PSDebug -Trace 1
    Write-Log 'Pre-Compilation: Build inside control plane VM'

    if ($GitConfigWithSecrets -ne '') {
        Write-Log 'Pre-Compilation: creating ~/.gitconfig in VM'
        Copy-ToControlPlaneViaSSHKey 'gitconfig' '.gitconfig' | Out-Null
    }

    # check if we need to install go and gcc into VM
    $GoInstalled = (Invoke-CmdOnControlPlaneViaSSHKey "which /usr/local/go-$GO_VERSION/bin/go").Output
    $MuslInstalled = (Invoke-CmdOnControlPlaneViaSSHKey 'which musl-gcc').Output
    if ($GoInstalled -match '/bin/go' -and $MuslInstalled -match '/bin/musl-gcc') {
        Write-Log 'Pre-Compilation: go and gcc compiler already available in VM'
    }
    else {
        Write-Log 'Pre-Compilation: Downloading needed binaries (go, gcc)...'
        $dpkgRepairCmd = 'sudo dpkg --configure -a'
        (Invoke-CmdOnControlPlaneViaSSHKey "echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections").Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo apt-get update;DEBIAN_FRONTEND=noninteractive sudo apt-get install -q --yes gcc git musl musl-tools;' -Retries 3 -Timeout 2 -RepairCmd $dpkgRepairCmd).Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey 'DEBIAN_FRONTEND=noninteractive sudo apt-get install -q --yes upx-ucl' -Retries 3 -Timeout 2 -RepairCmd $dpkgRepairCmd).Output | Write-Log
        # (Invoke-CmdOnControlPlaneViaSSHKey "sudo apt-get update >/dev/null ; sudo apt-get install -q --yes golang-$GO_VERSION gcc git musl musl-tools; sudo apt-get install -q --yes upx-ucl").Output | Write-Log
        if ($LASTEXITCODE -ne 0) {
            throw "'apt install' returned code $LASTEXITCODE. Aborting. In case of timeouts do a retry."
        }

        # Install Go
        $goInstallScript = '/tmp/install_go.sh'
        $kubePath = Get-KubePath
        Copy-ToControlPlaneViaSSHKey "$kubePath\lib\modules\windows\node\k2s.node.module\linuxnode\distros\scripts\install_go.sh" $goInstallScript

        # After copy we need to remove carriage line endings from the shell script.
        # TODO: Function to copy shell script to Linux host and remove CR in the shell script file before execution
        (Invoke-CmdOnControlPlaneViaSSHKey "sed -i -e 's/\r$//' $goInstallScript" -NoLog).Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey "chmod +x $goInstallScript" -NoLog).Output | Write-Log
        (Invoke-CmdOnControlPlaneViaSSHKey "$goInstallScript $GO_Ver 2>&1").Output | Write-Log
    }

    $dirForBuild = '~/tmp/docker-build'
    if ($BuildDirFromDockerfile -ne '') {
        if ($BuildDirFromDockerfile -eq '..') {
            $dirForBuild = $dirForBuild + '/' + $(Split-Path -Leaf $InputFolder)
            Write-Log "Pre-Compilation: Building in VM in $dirForBuild ..."
        }
        else {
            throw "currently only '..' is allowed as value for DockerBuildDir"
        }
    }

    $setTransparentProxy = 'export HTTPS_PROXY=http://' + $(Get-ConfiguredKubeSwitchIP) + ':8181;'

    $setGoEnvironment = 'GOPRIVATE=dev.azure.com'
    if ($Env:GOPRIVATE -ne '') {
        Write-Log 'Using your local GOPRIVATE environment variable on the build host'
        $setGoEnvironment = "GOPRIVATE=$Env:GOPRIVATE"
    }
    if ($Env:GOPROXY -ne '') {
        Write-Log 'Using your local GOPROXY environment variable on the build host'
        $setGoEnvironment = "$setGoEnvironment GOPROXY=$Env:GOPROXY"
    }
    if ($Env:GOSUMDB -ne '') {
        Write-Log 'Using your local GOSUMDB environment variable on the build host'
        $setGoEnvironment = "$setGoEnvironment GOSUMDB=$Env:GOSUMDB"
    }

    if ($GoBuild -eq 'test') {
        Write-Log "Pre-Compilation: Building test-executable with GO: $ccExecutableName ..."
        (Invoke-CmdOnControlPlaneViaSSHKey "cd $dirForBuild ; $setTransparentProxy $setGoEnvironment $CGOFlags /usr/local/go-$GO_VERSION/bin/go test -c -v -o $ccExecutableName 2>&1").Output | Write-Log
    }
    else {
        Write-Log "Getting dependencies for GO: $ccExecutableName ..."
        (Invoke-CmdOnControlPlaneViaSSHKey "cd $dirForBuild ; $setTransparentProxy $setGoEnvironment /usr/local/go-$GO_VERSION/bin/go get -v $goPackageToBuild 2>&1").Output | Write-Log

        if ( $Optimize ) {
            Write-Log "Pre-Compilation: Building optimized executable with GO: $ccExecutableName ..."
            (Invoke-CmdOnControlPlaneViaSSHKey "cd $dirForBuild ; $setTransparentProxy $setGoEnvironment $CGOFlags /usr/local/go-$GO_VERSION/bin/go build -v -ldflags='-s -w' -o $ccExecutableName $goPackageToBuild 2>&1; upx $ccExecutableName ; ls -l").Output | Write-Log
        }
        else {
            Write-Log "Pre-Compilation: Building executable with GO: $ccExecutableName ..."
            (Invoke-CmdOnControlPlaneViaSSHKey "cd $dirForBuild ; $setTransparentProxy $setGoEnvironment $CGOFlags /usr/local/go-$GO_VERSION/bin/go build -v -o $ccExecutableName $goPackageToBuild 2>&1").Output | Write-Log
        }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "go returned code $LASTEXITCODE. Aborting."
    }
}



if ($NoCache) {
    $NoCacheFlag = '--no-cache'
}
else {
    $NoCacheFlag = ''
}

if ($KeepColor -or $Windows) {
    $RemoveColorSequences = ''
}
else {
    # 'go get' outputs all download commands to stderr, which is then converted by 'docker build'
    # into red text with ANSI escape sequences. This is all hardcoded, and we don't want that.
    # So we remove these ANSI sequences with a sed command. The 'unbuffer' from package 'expect'
    # is needed to avoid buffering of output, we want to see it line by line, not as one big
    # block after the process has finished.
    $RemoveColorSequences = " 2>&1 | unbuffer -p sed 's/\x1b\[[0-9;]*m//g'; eval test $\{PIPESTATUS[0]} -eq 0 || exit 1"
    $UnbufferInstalled = (Invoke-CmdOnControlPlaneViaSSHKey 'which unbuffer').Output
    if ($UnbufferInstalled -match 'unbuffer') {
        Write-Log "Found unbuffer command ('expect' package)"
    }
    else {
        Write-Log "Installing unbuffer command ('expect' package)"
        (Invoke-CmdOnControlPlaneViaSSHKey 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -q --yes expect').Output | Write-Log
        $UnbufferInstalled = (Invoke-CmdOnControlPlaneViaSSHKey 'which unbuffer').Output
        if (! ($UnbufferInstalled -match 'unbuffer')) {
            Write-Log 'Unable to install unbuffer command, keeping ANSI sequences'
            $RemoveColorSequences = ''
        }
    }
}

if ($Env:GOPRIVATE -ne '') {
    Write-Log 'Passing your local GOPRIVATE environment as Build Argument'
    $BuildArgs += "GOPRIVATE=$Env:GOPRIVATE"
}
if ($Env:GOPROXY -ne '') {
    Write-Log 'Passing your local GOPROXY environment as Build Argument'
    $BuildArgs += "GOPROXY=$Env:GOPROXY"
}
if ($Env:GOSUMDB -ne '') {
    Write-Log 'Passing your local GOSUMDB environment as Build Argument'
    $BuildArgs += "GOSUMDB=$Env:GOSUMDB"
}

$buildArgsString = Get-BuildArgs($BuildArgs)
if ($buildArgsString -ne '') {
    Write-Log "Build arguments $buildArgsString"
}

# Windows container
if ($Windows) {
    Install-WinDocker
    New-WindowsImage -InputFolder $InputFolder -Dockerfile 'Dockerfile.ForBuild.tmp' -ImageName $ImageName -ImageTag $ImageTag -NoCacheFlag $NoCacheFlag -BuildArgsString $buildArgsString
}
else {
    Write-Log 'Building container image using Buildah inside control plane VM' -Console
    Write-Log "with gitconfig and npmrc: $GitConfigWithSecretsArg $NpmSecretsArg"
    $buildContextFolder = $(Split-Path -Leaf $InputFolder)
    $buildahBudCommand = "cd ~/tmp/docker-build; sudo buildah bud -f Dockerfile.ForBuild.tmp --force-rm --no-cache $GitConfigWithSecretsArg $NpmSecretsArg -t ${ImageName}:$ImageTag $buildContextFolder $RemoveColorSequences 2>&1"
    if ($buildArgsString -ne '') {
        $buildahBudCommand = "cd ~/tmp/docker-build; sudo buildah bud $buildArgsString -f Dockerfile.ForBuild.tmp --force-rm --no-cache $GitConfigWithSecretsArg $NpmSecretsArg -t ${ImageName}:$ImageTag $buildContextFolder $RemoveColorSequences 2>&1"
        Write-Log $buildahBudCommand
    }
    (Invoke-CmdOnControlPlaneViaSSHKey "$buildahBudCommand").Output | Write-Log
    if ($LASTEXITCODE -ne 0) { throw "error while creating image with 'buildah bud' in linux VM. Error code returned was $LastExitCode" }

    Write-Log ''
    (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah images | grep ${ImageName}").Output | Write-Log
}

# Cleanup on host
if (Test-Path '.\Dockerfile.ForBuild.tmp') {
    Remove-Item '.\Dockerfile.ForBuild.tmp'
}
if (Test-Path '.\gitconfig') {
    Remove-Item '.\gitconfig'
}
if (Test-Path '.\.npmrc') {
    Remove-Item '.\.npmrc'
}

# Push image to registry
if ($Push) {
    $registry = Get-ConfiguredRegistryFromImageName -ImageName $ImageName
    if ($null -eq $registry) {
        $errMsg = 'Unable to push the built container image, Registry is not configured in k2s! You can add it: k2s image registry add <registry_name>'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-image-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    Write-Log "Trying to push image ${ImageName}:$ImageTag to repository" -Console

    $success = $false
    if ($Windows) {
        $(&$nerdctlExe -n="k8s.io" --insecure-registry image push "${ImageName}:$ImageTag" --allow-nondistributable-artifacts --quiet 2>&1) | Out-String
        $success = $?
    }
    else {
        $success = (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah push ${ImageName}:$ImageTag 2>&1").Success
    }

    if (!$success) {
        Write-Log '#######################################################################################'
        Write-Log "### ERROR: image ${ImageName}:$ImageTag NOT uploaded to repository"
        Write-Log '#######################################################################################'
        $errMsg = 'unable to push image to registry'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'build-image-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
    else {
        Write-Log "Image '${ImageName}:$ImageTag' pushed successfully to registry" -Console
    }
}

# Cleanup inside VM
if (!$Keep -and !$Windows) {
    Write-Log 'Cleaning up temporary disk space in control plane VM' -Console
    (Invoke-CmdOnControlPlaneViaSSHKey 'find ~/tmp/docker-build -exec chmod a+w {} \; ; rm -rf ~/tmp/docker-build').Output | Write-Log
}

Write-Log "Total duration: $('{0:hh\:mm\:ss}' -f $mainStopwatch.Elapsed )"

Set-Location $scriptStartLocation

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
