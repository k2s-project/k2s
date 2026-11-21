# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

Param (
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Username')]
    [string] $Username,
    [parameter(Mandatory = $false, HelpMessage = 'Password')]
    [string] $Password,
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

if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    Import-Module $infraModule -DisableNameChecking
}

function Set-Containerd-Config() {
    param(
        [Parameter()]
        [String]
        $RegistryName,
        [Parameter()]
        [String]
        $authJson
    )
    $containerdConfig = "$global:KubernetesPath\cfg\containerd\config.toml"
    Write-Log "Changing $containerdConfig"

    $content = Get-Content $containerdConfig | Out-String
    if ($content.Contains("[plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$RegistryName"".auth]")) {
        return
    }

    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$RegistryName"].value
    $auth = $authk2s.psobject.properties['auth'].value

    $authPlaceHolder = Get-Content $containerdConfig | Select-String '#add_new_registry_auth' | Select-Object -ExpandProperty Line
    if ( $authPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($authPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$RegistryName"".auth]`r`n          auth = ""$auth""`r`n`r`n        #add_new_registry_auth") } | Set-Content $containerdConfig
    }

    $tlsPlaceHolder = Get-Content $containerdConfig | Select-String '#add_new_insecure_verify_skip' | Select-Object -ExpandProperty Line
    if ( $tlsPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($tlsPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$RegistryName"".tls]`r`n          insecure_skip_verify = true`r`n`r`n        #add_new_insecure_verify_skip") } | Set-Content $containerdConfig
    }
}

function Restart-Services() {
    param(
        [Parameter()]
        [String]
        $setupType
    )
    Write-Output 'Restarting services'
    if ($setupType -ne $global:SetupType_BuildOnlyEnv) {
        &$global:NssmInstallDirectory\nssm stop kubeproxy
        &$global:NssmInstallDirectory\nssm stop kubelet
    }

    &$global:NssmInstallDirectory\nssm restart containerd

    if ($setupType -ne $global:SetupType_BuildOnlyEnv) {
        &$global:NssmInstallDirectory\nssm start kubelet
        &$global:NssmInstallDirectory\nssm start kubeproxy
    }
}

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$registries = $(Get-RegistriesFromSetupJson)
if ($registries) {
    $registryAlreadyExists = $registries | Where-Object { $_ -eq $RegistryName }
    if ($registryAlreadyExists) {        
        $errMsg = "Registry '$RegistryName' is already configured."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'registry-already-configured' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
}

Write-Log "Adding registry '$RegistryName'" -Console

if ($Username -and $Password) {
    $username = $Username
    $password = $password
}
else {
    Write-Log 'Please enter credentials for registry access:' -Console
    $username = Read-Host 'Enter username'
    $passwordSecured = Read-Host 'Enter password' -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential ($username, $passwordSecured)
    $password = $cred.GetNetworkCredential().Password
}

if ($PSVersionTable.PSVersion.Major -gt 5) {
    ExecCmdMaster "grep location=\""$RegistryName\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=""$RegistryName""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf"
}
else {
    ExecCmdMaster "grep location=\\\""$RegistryName\\\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=\""$RegistryName\""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf"
}

ExecCmdMaster 'sudo systemctl daemon-reload'
ExecCmdMaster 'sudo systemctl restart crio'

Start-Sleep 2

Login-Buildah -username $username -password $password -registry $RegistryName

if (!$?) {
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        ExecCmdMaster "grep location=\""$RegistryName\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\""$RegistryName\""\ninsecure=true//g' /etc/containers/registries.conf"
    }
    else {
        ExecCmdMaster "grep location=\\\""$RegistryName\\\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\\\""$RegistryName\\\""\ninsecure=true//g' /etc/containers/registries.conf"
    }

    $errMsg = 'Login to private registry not possible, please check credentials.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'registry-login-impossible' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$setupInfo = Get-SetupInfo

$authJson = ExecCmdMaster 'sudo cat /root/.config/containers/auth.json' -NoLog | Out-String

# Add dockerd parameters and restart docker daemon to push nondistributable artifacts and use insecure registry
if ($setupInfo.Name -eq $global:SetupType_k2s -or $setupInfo.Name -eq $global:SetupType_BuildOnlyEnv) {
    $storageLocalDrive = Get-StorageLocalDrive
    &"$global:NssmInstallDirectory\nssm" set docker AppParameters --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --log-level debug --allow-nondistributable-artifacts "$RegistryName" --insecure-registry "$RegistryName" | Out-Null
    if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
        &"$global:NssmInstallDirectory\nssm" restart docker
    }
    else {
        &"$global:NssmInstallDirectory\nssm" start docker
    }

    Login-Docker -username $username -password $password -registry $RegistryName

    # set authentication for containerd
    Set-Containerd-Config -RegistryName $RegistryName -authJson $authJson

    Restart-Services -setupType $setupInfo.Name
}

Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value $RegistryName
Add-RegistryToSetupJson -Name $RegistryName
Write-Log "Registry '$RegistryName' added successfully.'" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
