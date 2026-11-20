# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

&$PSScriptRoot\..\common\GlobalVariables.ps1

# containerd
$global:WindowsNode_ContainerdDirectory = "containerd"
$global:WindowsNode_CrictlDirectory = "crictl"
$global:WindowsNode_NerdctlDirectory = "nerdctl"

# dns proxy
$global:WindowsNode_DnsProxyDirectory = "dnsproxy"

# yaml
$global:WindowsNode_YamlDirectory = "yaml"

# flannel
$global:WindowsNode_FlannelDirectory = "flannel"
$global:WindowsNode_CniPluginsDirectory = "cni_plugins"
$global:WindowsNode_CniFlannelDirectory = "cni_flannel"

$global:WindowsNode_FlanneldExe = "flanneld.exe"
$global:WindowsNode_Flannel64exe = "flannel-amd64.exe"

$global:CniPath = "$global:KubernetesPath\bin\cni"

# kubetools
$global:WindowsNode_KubetoolsDirectory = "kubetools"

$global:WindowsNode_KubeletExe = "kubelet.exe"
$global:WindowsNode_KubeadmExe = "kubeadm.exe"
$global:WindowsNode_KubeproxyExe = "kube-proxy.exe"
$global:WindowsNode_KubectlExe = "kubectl.exe"

# windows exporter
$global:WindowsNode_WindowsExporterDirectory = "windowsexporter"
$global:WindowsNode_WindowsExporterExe = "windows_exporter.exe"

# nssm
$global:WindowsNode_NssmDirectory = "nssm"

# docker
$global:WindowsNode_DockerDirectory = "docker"

# Windows images
$global:WindowsNode_ImagesDirectory = "images"

# Putty tools
$global:WindowsNode_PuttytoolsDirectory = "puttytools"
$global:WindowsNode_Plink = "plink.exe"
$global:WindowsNode_Pscp = "pscp.exe"
