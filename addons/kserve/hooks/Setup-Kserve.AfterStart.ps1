# SPDX-FileCopyrightText: (c) 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

Import-Module "$PSScriptRoot\..\addons.module.psm1",
    "$PSScriptRoot\..\..\lib\modules\windows\cluster\k2s.cluster.module\k2s.cluster.module.psm1",
    "$PSScriptRoot\..\..\lib\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1"
. "$PSScriptRoot\..\kserve\Kserve.Helpers.ps1"

$ErrorActionPreference = 'Stop'
if (Test-IsAddonEnabled -Addon ([pscustomobject]@{ Name = 'kserve' })) {
    $null = Update-KserveWebhookCertificate
}
