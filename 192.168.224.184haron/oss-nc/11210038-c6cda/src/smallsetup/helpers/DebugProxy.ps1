# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

#Requires -RunAsAdministrator

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

$env:NODE_NAME = ($(hostname)).ToLower()
$env:KUBE_NETWORK = 'cbr0'

# Note: kube-proxy supports --log-dir / --log-file, but these have no effect when --logtostderr=true is set (all logs go to stderr/stdout).
# Logs are captured via NSSM AppStdout/AppStderr redirection in the production install path.
&"$global:KubernetesPath\bin\exe\kube-proxy.exe" --v=6 --proxy-mode=kernelspace --hostname-override=$(hostname) --kubeconfig=`"$global:KubernetesPath\config`" --enable-dsr=false --logtostderr=true

