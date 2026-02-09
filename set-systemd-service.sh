#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate service file from template with correct path and install it
sed "s|%INSTALL_DIR%|$SCRIPT_DIR|g" "$SCRIPT_DIR/sriov-nic.service" | sudo tee /etc/systemd/system/sriov-nic.service > /dev/null

# Reload systemd daemon to recognize the new service
systemctl daemon-reload

echo "SR-IOV systemd service has been installed and systemd daemon reloaded."
