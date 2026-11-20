@echo off
REM SPDX-FileCopyrightText: © 2024 The K2s Authors
REM SPDX-License-Identifier: Apache-2.0
@echo on
@rem wrapper for Build-Image.ps1 script
@rem Only for backward compatibility, will be removed later. Use BuildImage.cmd instead
@SET installationDirectory=%~dp0..
@%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command "try { & '%installationDirectory%\lib\scripts\windows\host\image\Build-Image.ps1' %*; $err = -not $? } catch { Write-Host $_; $err = $true; $LastExitCode = 1 }; if ($err) { $ppid = (gwmi Win32_Process -Filter processid=$pid).ParentProcessId; $cl = (gwmi Win32_Process -Filter processid=$ppid).CommandLine; if ($cl -like '*cmd.exe /c*') { $gppid = (gwmi Win32_Process -Filter processid=$ppid).ParentProcessId; $pn = (gps -id $gppid).ProcessName; if ($pn -eq 'explorer') { pause } } }; exit $LastExitCode"
