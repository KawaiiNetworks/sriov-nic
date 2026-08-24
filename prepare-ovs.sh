#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob

need_hw_offload=false
configs=("$SCRIPT_DIR"/sriov-nic.conf*)

for config_file in "${configs[@]}"; do
    [[ -f "$config_file" ]] || continue

    # Config files are trusted shell fragments, just like set-sriov.sh configs.
    unset MODE OVS_HW_OFFLOAD
    # shellcheck source=/dev/null
    source "$config_file"

    # Old repository configs had no MODE/OVS_HW_OFFLOAD and always enabled OVS.
    if [[ -z "${MODE+x}" ]]; then
        OVS_HW_OFFLOAD="${OVS_HW_OFFLOAD:-true}"
    else
        OVS_HW_OFFLOAD="${OVS_HW_OFFLOAD:-false}"
    fi

    case "${OVS_HW_OFFLOAD,,}" in
        1|yes|y|true|on)
            need_hw_offload=true
            break
            ;;
    esac
done

if [[ "$need_hw_offload" != true ]]; then
    echo "No saved configuration requests Open vSwitch hardware offload; skipped."
    exit 0
fi

command -v ovs-vsctl >/dev/null 2>&1 || {
    echo "Error: OVS_HW_OFFLOAD=true, but ovs-vsctl is not installed." >&2
    exit 1
}
command -v systemctl >/dev/null 2>&1 || {
    echo "Error: OVS_HW_OFFLOAD=true, but systemctl is unavailable." >&2
    exit 1
}

if ! systemctl is-active --quiet openvswitch-switch.service; then
    echo "Starting Open vSwitch..."
    systemctl start openvswitch-switch.service
fi

echo "Enabling Open vSwitch hardware offload..."
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
systemctl restart openvswitch-switch.service
