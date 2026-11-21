# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

$configModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\config\config.module.psm1"
$vmModule = "$PSScriptRoot\..\..\..\..\node\k2s.node.module\linuxnode\vm\vm.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\infra\k2s.infra.module\path\path.module.psm1"
Import-Module $configModule, $vmModule, $pathModule

$setupJsonFile = Get-SetupConfigFilePath
$kubePath = Get-KubePath
$binDir = "$kubePath\bin"
$nerdctlExe = "$binDir\nerdctl.exe"
$dockerDir = "$binDir\docker"
$dockerExe = "$dockerDir\docker.exe"

function Add-RegistryToSetupJson([string]$Name) {
    $parsedSetupJson = Get-Content -Raw $setupJsonFile | ConvertFrom-Json

    $registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if (!$registryMemberExists) {
        $parsedSetupJson = $parsedSetupJson | Add-Member -NotePropertyMembers @{Registries = @() } -PassThru
    }

    $registryAlreadyExists = $parsedSetupJson.Registries | Where-Object { $_ -eq $Name }
    if (!$registryAlreadyExists) {
        $parsedSetupJson.Registries += $Name
        $tempPath = "$setupJsonFile.tmp"
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $tempPath -Confirm:$false
        Move-Item -Path $tempPath -Destination $setupJsonFile -Force
    }
}

function Remove-RegistryFromSetupJson([string]$Name, [bool]$IsRegex) {
    $parsedSetupJson = Get-Content -Raw $setupJsonFile | ConvertFrom-Json

    $registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if ($registryMemberExists) {
        $registries = $parsedSetupJson.Registries
        if ($IsRegex) {
            $newRegistry = @($registries | Where-Object { $_ -notmatch $Name })
        }
        else {
            $newRegistry = @($registries | Where-Object { $_ -ne $Name })
        }

        if ($newRegistry) {
            $parsedSetupJson.Registries = $newRegistry
        }
        else {
            $parsedSetupJson.PSObject.Properties.Remove('Registries')
        }
        $tempPath = "$setupJsonFile.tmp"
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $tempPath -Confirm:$false
        Move-Item -Path $tempPath -Destination $setupJsonFile -Force
    }
}

function Get-RegistriesFromSetupJson() {
    $parsedSetupJson = Get-Content -Raw $setupJsonFile | ConvertFrom-Json
    $registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if ($registryMemberExists) {
        return $parsedSetupJson.Registries
    }
    return $null
}

function Add-RegistryAuthToContainerdConfigToml {
    param(
        [Parameter()]
        [String]
        $registryName,
        [Parameter()]
        [String]
        $authJson
    )
    $containerdConfig = "$kubePath\cfg\containerd\config.toml"
    Write-Log "Changing $containerdConfig"

    $content = Get-Content $containerdConfig | Out-String
    if ($content.Contains("[plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".auth]")) {
        return
    }

    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    $auth = $authk2s.psobject.properties['auth'].value

    $authPlaceHolder = Get-Content $containerdConfig | Select-String '#add_new_registry_auth' | Select-Object -ExpandProperty Line
    if ( $authPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($authPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$registryName"".auth]`r`n          auth = ""$auth""`r`n`r`n        #add_new_registry_auth") } | Set-Content $containerdConfig
    }
}

function Remove-RegistryAuthToContainerdConfigToml {
    param(
        [Parameter()]
        [String]
        $registryName,
        [Parameter()]
        [String]
        $authJson
    )
    $containerdConfig = "$kubePath\cfg\containerd\config.toml"
    Write-Log "Changing $containerdConfig"

    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$registryName"].value
    
    # Only proceed if auth entry exists for this registry
    if ($null -ne $authk2s) {
        $auth = $authk2s.psobject.properties['auth'].value
        (Get-Content $containerdConfig | Select-String "$registryName"".auth]" -notmatch) | Set-Content $containerdConfig
        (Get-Content $containerdConfig | Select-String "auth = ""$auth""" -notmatch) | Set-Content $containerdConfig
    }
    else {
        Write-Log "[Registry] No auth entry found for '$registryName' in auth.json, skipping containerd config update"
    }
}


function Connect-Docker {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = '',
        [Parameter(Mandatory = $false)]
        [string]$password = '',
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq '' -and $password -eq '') {
            $success = $(&$dockerExe login $registry 2>$null | % { $_ -match 'Login Succeeded' })
        }
        else {
            $success = $(&$dockerExe login -u $username -p $password $registry 2>$null | % { $_ -match 'Login Succeeded' })
        }

        if ($success) {
            Write-Log 'docker login succeeded'
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        throw "Login to registry $registry not possible! Please check credentials!"
    }
}

function Connect-Nerdctl {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = '',
        [Parameter(Mandatory = $false)]
        [string]$password = '',
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq '' -and $password -eq '') {
            $success = $(&$nerdctlExe -n="k8s.io" --insecure-registry login $registry 2>$null | % { $_ -match 'Login Succeeded' })
        }
        else {
            $success = $(&$nerdctlExe -n="k8s.io" --insecure-registry login -u $username -p $password $registry 2>$null | % { $_ -match 'Login Succeeded' })
        }

        if ($success) {
            Write-Log 'nerdctl login succeeded'
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        throw "Login to registry $registry not possible! Please check credentials!"
    }
}

function Disconnect-Nerdctl {
    param (
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    &$nerdctlExe -n="k8s.io" logout $registry
}

function Connect-Buildah {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = '',
        [Parameter(Mandatory = $false)]
        [string]$password = '',
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq '' -and $password -eq '') {
            $success = (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah login --authfile /root/.config/containers/auth.json '$registry' > /dev/null 2>&1").Success
        }
        else {
            $success = (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah login --authfile /root/.config/containers/auth.json -u '$username' -p '$password' '$registry' > /dev/null 2>&1" -NoLog -IgnoreErrors).Success
            Write-Log("cmd: sudo buildah login --authfile /root/.config/containers/auth.json -u 'user' -p '<redacted>' '$registry' > /dev/null 2>&1 (redacted output)")
        }

        if ($success) {
            Write-Log 'buildah login succeeded'
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        throw "Login to registry $registry not possible! Please check credentials!"
    }
}

function Disconnect-Buildah {
    param (
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    (Invoke-CmdOnControlPlaneViaSSHKey "sudo buildah logout --authfile /root/.config/containers/auth.json '$registry'").Output | Write-Log
}

function Get-ConfiguredRegistryFromImageName {
    param (
        [Parameter()]
        [string] $ImageName
    )

    if (!$ImageName.Contains('/')) {
        throw 'Please check ImageName! Cannot get registry name!'
    }

    $registry = $($ImageName -split '/')[0]

    $registries = Get-RegistriesFromSetupJson
    if ($null -eq $registries) {
        return $null
    }
    $registryExists = $registries | Where-Object { $_ -eq $registry }

    if ($registryExists) {
        return $registry
    }
    else {
        return $null
    }
}

function Set-Registry {
    param(
        [Parameter()]
        [String]
        $Name,
        [Parameter()]
        [switch]
        $Https,
        [Parameter()]
        [switch] $SkipVerify,
        [Parameter()]
        [switch] $LocalRegistry,
        [Parameter(Mandatory = $false)]
        [String]
        $Mirror,
        [Parameter(Mandatory = $false)]
        [String]
        $Server
    )

    if ($Https) {
        $protocol = 'https'
    }
    else {
        $protocol = 'http'
        $SkipVerify = $true
    }

    #################
    # Linux (cri-o) #
    #################
    $fileName = $Name -replace ':', ''

    if ($LocalRegistry) {
        $SkipVerify = $true
    }

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p /etc/containers/registries.conf.d').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo -e `'[[registry]]\nlocation=\""$Name\""\ninsecure=$($SkipVerify.ToString().ToLower())`' | sudo tee /etc/containers/registries.conf.d/$fileName.conf").Output | Write-Log

    if ($Mirror -and $Server) {
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo -e `'[[registry.mirror]]\nlocation=\""$Mirror\""\ninsecure=$($SkipVerify.ToString().ToLower())`' | sudo tee -a /etc/containers/registries.conf.d/$fileName.conf").Output | Write-Log
    }

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl daemon-reload').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart crio').Output | Write-Log

    ########################
    # Windows (containerd) #
    ########################
    $folderName = $Name -replace ':', ''

    New-Item -Path "$(Get-SystemDriveLetter):\etc\containerd\certs.d\$folderName" -ItemType Directory -Force | Out-Null

    $content = ''

    if ($LocalRegistry) {
        $content += @"
server = "${protocol}://$Name"
"@
    }

    if ($Mirror -and $Server) {
        $content += @"

server = "${protocol}://$Server"  # default after trying hosts

[host."${protocol}://$Mirror"]
  capabilities = ["pull", "resolve"]
  skip_verify = $($SkipVerify.ToString().ToLower())

[host."${protocol}://$Server"]
  capabilities = ["pull", "resolve"]
"@
    } 
    else {    

        $content += @"

[host."${protocol}://$Name"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = $($SkipVerify.ToString().ToLower())
  plain_http = $($(!$Https).ToString().ToLower())
"@
    }
    
    $content | Set-Content -Path "$(Get-SystemDriveLetter):\etc\containerd\certs.d\$folderName\hosts.toml"
}

function Remove-Registry {
    param(
        [Parameter()]
        [String]
        $Name
    )

    # Linux (cri-o)
    $fileName = $Name -replace ':', ''
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf /etc/containers/registries.conf.d/$fileName.conf").Output | Write-Log

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl daemon-reload').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo systemctl restart crio').Output | Write-Log

    # Windows (containerd)
    $folderName = $Name -replace ':', ''
    Remove-Item -Force "$(Get-SystemDriveLetter):\etc\containerd\certs.d\$folderName" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Add-RegistryToSetupJson,
Remove-RegistryFromSetupJson,
Get-RegistriesFromSetupJson,
Add-RegistryAuthToContainerdConfigToml,
Remove-RegistryAuthToContainerdConfigToml,
Connect-Docker,
Connect-Buildah,
Disconnect-Buildah,
Connect-Nerdctl,
Disconnect-Nerdctl,
Get-ConfiguredRegistryFromImageName,
Set-Registry,
Remove-Registry
