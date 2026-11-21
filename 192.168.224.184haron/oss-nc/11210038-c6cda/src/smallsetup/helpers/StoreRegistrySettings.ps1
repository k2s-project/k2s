# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
Store Registry Settings

.DESCRIPTION
In order to save the registry settings, we shall collect username and token and save them in a file for later retrieval.
This is a pure indirection as there is no encryption mechanism implemented. 

NOTE: Setup required!

.EXAMPLE
powershell <installation folder>\helpers\StoreRegistrySettings.ps1

#>

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

# Prompt for username and token
$registry = Read-Host -Prompt "Enter Registry"
$username = Read-Host -Prompt "Enter Registry Username"
$token = Read-Host -Prompt "Enter Registry Token" -AsSecureString

# Convert token to plain text
$tokenText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($token))

# Login to registry one time generate 
nerdctl login -u $username -p $tokenText $registry

# Read auth json file
$json = Get-Content "$env:userprofile\.docker\config.json" | Out-String | ConvertFrom-Json
$auth = $json."auths"."$registry".auth

$auth | Set-Content -Path "$global:KubernetesPath\bin\registry.dat" -Encoding UTF8

Write-Output "'$global:KubernetesPath\bin\registry.dat' is saved successfully!"
