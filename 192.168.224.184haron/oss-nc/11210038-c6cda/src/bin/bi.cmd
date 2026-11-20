@echo off
REM SPDX-FileCopyrightText: © 2024 The K2s Authors
REM SPDX-License-Identifier: Apache-2.0
@echo on
@SET installationDirectory=%~dp0..
@"%installationDirectory%\bin\BuildImage" %*
