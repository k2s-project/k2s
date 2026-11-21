# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#!/bin/bash

PROXY="$1"

echo "Setting proxy '$PROXY' for apt"

# Create proxy config file
sudo touch /etc/apt/apt.conf.d/proxy.conf

# Add proxy configuration
echo "Acquire::http::Proxy \"$PROXY\";" | sudo tee -a /etc/apt/apt.conf.d/proxy.conf > /dev/null

echo "Proxy configuration completed successfully"
