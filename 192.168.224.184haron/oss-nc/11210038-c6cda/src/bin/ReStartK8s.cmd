@echo off
REM SPDX-FileCopyrightText: © 2024 The K2s Authors
REM SPDX-License-Identifier: Apache-2.0
@echo on
@echo off

call Stopk8s.cmd

if "%K8S_RESTART_DELAY%" == "" set K8S_RESTART_DELAY=10
if not "%K8S_RESTART_DELAY%" == "0" timeout %K8S_RESTART_DELAY%

call Startk8s.cmd
