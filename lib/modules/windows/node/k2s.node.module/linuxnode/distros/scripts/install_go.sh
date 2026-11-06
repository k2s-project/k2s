#!/bin/bash

# SPDX-FileCopyrightText: © 2024 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0

# Set default Go version
DEFAULT_GO_VERSION="1.27.3"

# Check if an argument is provided and is a valid integer
if [ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    GO_VERSION="$1"
else
    echo "Invalid or no version provided. Using default version: $DEFAULT_GO_VERSION"
    GO_VERSION="$DEFAULT_GO_VERSION"
fi

# Proxy
PROXY="http://172.19.1.1:8181"

# Set the installation directory
INSTALL_DIR="/usr/local/go-$GO_VERSION"

# Download and extract the Go binary
sudo curl -LO https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz --silent --proxy $PROXY
sudo mkdir -p $INSTALL_DIR
sudo tar -C $INSTALL_DIR -xzf go$GO_VERSION.linux-amd64.tar.gz
sudo mv $INSTALL_DIR/go/* $INSTALL_DIR
sudo rm -d $INSTALL_DIR/go


# Check if GOPATH line already exists in .profile
if ! grep -q "export GOPATH=\$HOME/go" .profile; then
    # Add Go binary to the system PATH
    echo "export GOPATH=\$HOME/go" >> .profile
fi

# Apply the changes to the current session
source .profile

# Clean up downloaded files
rm go$GO_VERSION.linux-amd64.tar.gz

# Display Go version
$INSTALL_DIR/bin/go version
