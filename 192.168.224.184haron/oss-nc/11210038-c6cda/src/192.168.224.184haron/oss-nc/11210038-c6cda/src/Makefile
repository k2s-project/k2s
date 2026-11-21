# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#
# Convenience wrapper for the native Linux build (see build.sh).

.PHONY: build clean help

# Default target: build all Linux executables.
build:
	bash ./build.sh

# Remove the binaries produced by build.sh.
clean:
	rm -f ./k2s.linux ./bin/cloudinitisobuilder ./bin/httpproxy ./bin/yaml2json

help:
	@echo "Targets:"
	@echo "  build   Build the Linux K2s executables natively (runs ./build.sh)."
	@echo "  clean   Remove the binaries produced by build."
