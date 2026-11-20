# SPDX-FileCopyrightText: © 2025 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

# Backward-compatibility shim: Expand-ZipWithProgress, New-ZipWithProgress and
# Format-Size now live in k2s.infra.module/archive/archive.module.psm1.
# This file is still dot-sourced by delta-package helpers so we re-import the
# module to make the functions available in the caller's scope.

Import-Module "$PSScriptRoot\..\..\..\..\..\modules\windows\infra\k2s.infra.module\k2s.infra.module.psm1" -Force
