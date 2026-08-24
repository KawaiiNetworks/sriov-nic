#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob

configs=("$SCRIPT_DIR"/sriov-nic.conf*)
if (( ${#configs[@]} == 0 )); then
    echo "No sriov-nic.conf* files found in $SCRIPT_DIR; nothing to do."
    exit 0
fi

for config_file in "${configs[@]}"; do
    [[ -f "$config_file" ]] || continue
    echo "============================================================"
    echo "Applying configuration: $config_file"
    "$SCRIPT_DIR/set-sriov.sh" "$config_file"
done
