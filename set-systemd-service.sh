#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH=/etc/systemd/system/sriov-nic.service

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: run this installer as root." >&2
    exit 1
fi

for script in set-sriov.sh set-sriov-all.sh prepare-ovs.sh; do
    [[ -x "$SCRIPT_DIR/$script" ]] || {
        echo "Error: $SCRIPT_DIR/$script is missing or not executable." >&2
        exit 1
    }
done

sed "s|%INSTALL_DIR%|$SCRIPT_DIR|g" "$SCRIPT_DIR/sriov-nic.service" >"$SERVICE_PATH"
chmod 0644 "$SERVICE_PATH"
systemctl daemon-reload

echo "Installed $SERVICE_PATH"
echo "Enable it after testing your configuration manually:"
echo "  systemctl enable --now sriov-nic.service"
