# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

$WindowsImageVersions = [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = '1809';
    TagSuffix   = 'win10-1809';
    OSVersion   = '10.0.17763.2300'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = '20H2';
    TagSuffix   = 'win10-20H2';
    OSVersion   = '10.0.19042.2251' # Win 10 / Win Server
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = '20H2';
    TagSuffix   = 'win10-21H2';
    OSVersion   = '10.0.19044.2251'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = '20H2';
    TagSuffix   = 'win10-22H2';
    OSVersion   = '10.0.19045.2251'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = 'ltsc2022';
    TagSuffix   = 'srv22-21H2';
    OSVersion   = '10.0.20348.2113'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = 'ltsc2022';
    TagSuffix   = 'win11-21H2';
    OSVersion   = '10.0.22000.121'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = 'ltsc2022';
    TagSuffix   = 'win11-22H2';
    OSVersion   = '10.0.22621.2283'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = 'ltsc2022';
    TagSuffix   = 'win11-23H2';
    OSVersion   = '10.0.22631.2861'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = 'ltsc2022';
    TagSuffix   = 'win11-24H2';
    OSVersion   = '10.0.26100.2314'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = 'ltsc2022';
    TagSuffix   = 'win11-25H2';
    OSVersion   = '10.0.26200.5074'
}, [pscustomobject]@{
    OS          = 'windows';
    Arch        = 'amd64';
    BaseVersion = 'ltsc2022';
    TagSuffix   = 'win11-26H2';
    OSVersion   = '10.0.26300.7760'
}

function Get-WindowsImageVersions {
    return $WindowsImageVersions
}

Export-ModuleMember -Function Get-WindowsImageVersions
