# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# ARG BASE
# FROM ${BASE}

ARG WINDOWS_VERSION
FROM mcr.microsoft.com/windows/nanoserver:${WINDOWS_VERSION}

ADD pause.exe /pause.exe
ADD wincat.exe /Windows/System32/wincat.exe
ENV PATH="C:\Windows\system32;C:\Windows;"
ENTRYPOINT ["/pause.exe"]
