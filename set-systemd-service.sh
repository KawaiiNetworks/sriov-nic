#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable destinations so the installer can be tested or repackaged.
UNIT_PATH="${SRIOV_UNIT_PATH:-/etc/systemd/system/sriov-nic.service}"
SYSTEMCTL="${SRIOV_SYSTEMCTL:-systemctl}"

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

mkdir -p "$(dirname "$UNIT_PATH")"
sed "s|%INSTALL_DIR%|$SCRIPT_DIR|g" "$SCRIPT_DIR/sriov-nic.service" >"$UNIT_PATH"
chmod 0644 "$UNIT_PATH"
"$SYSTEMCTL" daemon-reload

echo "Installed $UNIT_PATH"
echo "Enable it, then reboot so NIC setup runs before ovs-vswitchd:"
echo "  $SYSTEMCTL enable sriov-nic.service"
echo "  reboot"
echo "Do not start it directly while the PF is attached to a running OVS bridge."
