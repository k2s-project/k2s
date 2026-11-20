@echo off
REM SPDX-FileCopyrightText: © 2024 The K2s Authors
REM SPDX-License-Identifier: Apache-2.0
@echo on
@rem wrapper for powershell script with same name
@SET installationDirectory=%~dp0..
@"%installationDirectory%\k2s" start %*
