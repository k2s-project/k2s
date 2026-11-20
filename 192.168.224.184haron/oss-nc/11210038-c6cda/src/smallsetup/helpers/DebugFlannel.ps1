# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

# run flannel (is done in a background process)
$env:NODE_NAME = ($(hostname)).ToLower()
$ipaddress = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp | Select -ExpandProperty IPAddress
if (!($ipaddress)) {
    $ipaddress = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet*" | Select -ExpandProperty IPAddress
}

&"$global:KubernetesPath\bin\exe\flanneld.exe" --v=10 --iface=$ipaddress --ip-masq=1 --kube-subnet-mgr=1 -kubeconfig-file `"$global:KubernetesPath\config`"
