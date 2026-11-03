# SPDX-FileCopyrightText: © 2026 The K2s Authors
#
# SPDX-License-Identifier: Apache-2.0
#!/bin/bash

PROXY="$1"

# The proxy is written into a double-quoted apt configuration value. Reject values which could end that value
# or start a new line, since they would otherwise add arbitrary (e.g. DPkg::Post-Invoke) options to the apt config.
case "$PROXY" in
    *'"'* | *[[:cntrl:]]*)
        echo "Invalid proxy: double quotes and control characters are not allowed" >&2
        exit 1
        ;;
esac

echo "Setting proxy '$PROXY' for apt"

# Create proxy config file
sudo touch /etc/apt/apt.conf.d/proxy.conf

# Add proxy configuration
printf 'Acquire::http::Proxy "%s";\n' "$PROXY" | sudo tee -a /etc/apt/apt.conf.d/proxy.conf > /dev/null

echo "Proxy configuration completed successfully"
