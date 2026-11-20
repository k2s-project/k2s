REM SPDX-FileCopyrightText: © 2024 The K2s Authors
REM
REM SPDX-License-Identifier: Apache-2.0

@SET installationDirectory=%~dp0..
@SET installationDrive=%~d0

del %installationDrive%\k.zip
powershell -Command "Compress-Archive -Path '%installationDirectory%' -DestinationPath %installationDrive%\k.zip"
