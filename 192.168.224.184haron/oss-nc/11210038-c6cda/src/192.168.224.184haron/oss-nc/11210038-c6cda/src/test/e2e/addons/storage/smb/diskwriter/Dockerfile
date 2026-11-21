# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

ARG WINDOWS_VERSION

FROM mcr.microsoft.com/windows/nanoserver:${WINDOWS_VERSION}

LABEL description='diskwriter Tool'

COPY ["/dist/diskwriter.exe", "/diskwriter.exe"]
