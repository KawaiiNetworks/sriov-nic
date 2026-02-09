#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy sriov-nic.service to /etc/systemd/system/
cp "$SCRIPT_DIR/sriov-nic.service" /etc/systemd/system/sriov-nic.service

# Reload systemd daemon to recognize the new service
systemctl daemon-reload

echo "SR-IOV systemd service has been installed and systemd daemon reloaded."
