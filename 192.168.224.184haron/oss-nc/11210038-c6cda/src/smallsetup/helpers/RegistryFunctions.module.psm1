# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

function Add-RegistryToSetupJson([string]$Name) {
    $parsedSetupJson = Get-Content -Raw $global:SetupJsonFile | ConvertFrom-Json

    $registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if (!$registryMemberExists) {
        $parsedSetupJson = $parsedSetupJson | Add-Member -NotePropertyMembers @{Registries = @() } -PassThru
    }

    $registryAlreadyExists = $parsedSetupJson.Registries | Where-Object { $_ -eq $Name }
    if (!$registryAlreadyExists) {
        $parsedSetupJson.Registries += $Name
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $global:SetupJsonFile -Confirm:$false
    }
}

function Remove-RegistryFromSetupJson([string]$Name, [bool]$IsRegex) {
    $parsedSetupJson = Get-Content -Raw $global:SetupJsonFile | ConvertFrom-Json

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
        $parsedSetupJson | ConvertTo-Json -Depth 100 | Set-Content -Force $global:SetupJsonFile -Confirm:$false
    }
}

function Get-RegistriesFromSetupJson() {
    $parsedSetupJson = Get-Content -Raw $global:SetupJsonFile | ConvertFrom-Json
    $registryMemberExists = Get-Member -InputObject $parsedSetupJson -Name 'Registries' -MemberType Properties
    if ($registryMemberExists) {
        $registries = $parsedSetupJson.Registries
        return $registries
    }
    return $null
}

function Login-Docker {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = "",
        [Parameter(Mandatory = $false)]
        [string]$password = "",
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq "" -and $password -eq "") {
            $success = $(&$global:DockerExe login $registry 2>$null | % { $_ -match 'Login Succeeded' })
        } else {
            $success = $(&$global:DockerExe login -u $username -p $password $registry 2>$null | % { $_ -match 'Login Succeeded' })
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

function Login-Nerdctl {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = "",
        [Parameter(Mandatory = $false)]
        [string]$password = "",
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq "" -and $password -eq "") {
            $success = $(&$global:NerdctlExe login $registry 2>$null | % { $_ -match 'Login Succeeded' })
        } else {
            $success = $(&$global:NerdctlExe login -u $username -p $password $registry 2>$null | % { $_ -match 'Login Succeeded' })
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

function Login-Buildah {
    param (
        [Parameter(Mandatory = $false)]
        [string]$username = "",
        [Parameter(Mandatory = $false)]
        [string]$password = "",
        [Parameter(Mandatory = $false)]
        [string]$registry
    )

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        if ($username -eq "" -and $password -eq "") {
            ExecCmdMaster "sudo buildah login --authfile /root/.config/containers/auth.json '$registry' > /dev/null 2>&1" -NoLog
        } else {
            ExecCmdMaster "sudo buildah login --authfile /root/.config/containers/auth.json -u '$username' -p '$password' '$registry' > /dev/null 2>&1" -NoLog
        }

        if ($?) {
            Write-Log 'buildah login succeeded'
            $success = $true
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        throw "Login to registry $registry not possible! Please check credentials!"
    }
}

Export-ModuleMember -Function Add-RegistryToSetupJson,
                              Remove-RegistryFromSetupJson,
                              Get-RegistriesFromSetupJson,
                              Login-Docker,
                              Login-Buildah,
                              Login-Nerdctl
