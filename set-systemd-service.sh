#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Overridable destinations so the installer can be tested or repackaged.
UNIT_PATH="${SRIOV_UNIT_PATH:-/etc/systemd/system/sriov-nic.service}"
SYSTEMCTL="${SRIOV_SYSTEMCTL:-systemctl}"
ENABLE_SERVICE=false

case "${1:-}" in
    "") ;;
    --enable) ENABLE_SERVICE=true ;;
    *) echo "Usage: $0 [--enable]" >&2; exit 2 ;;
esac

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

if [[ "$ENABLE_SERVICE" == true ]]; then
    "$SYSTEMCTL" enable sriov-nic.service
    echo "Installed and enabled sriov-nic.service."
    echo "Reboot to apply the boot ordering; do not start it directly while the PF is attached to a running OVS bridge."
else
    echo "Installed $UNIT_PATH (not enabled)."
    echo "To enable it for the next boot:"
    echo "  $SYSTEMCTL enable sriov-nic.service"
    echo "  reboot"
fi
