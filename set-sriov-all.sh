#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob

configs=("$SCRIPT_DIR"/sriov-nic.conf*)
sf_configs=("$SCRIPT_DIR"/sf-nic.conf*)

declare -A sf_pfs=()
normalize_pci() {
    local pci="${1,,}"
    [[ "$pci" =~ ^[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] && pci="0000:$pci"
    printf '%s\n' "$pci"
}

# Reject PF/SF configurations that can never coexist before changing any
# device. Configuration files are trusted shell fragments throughout this
# project; inspect them in subshells to avoid leaking variables across files.
for config_file in "${sf_configs[@]}"; do
    [[ -f "$config_file" ]] || continue
    sf_pci=$(
        unset PF_PCI
        # shellcheck source=/dev/null
        source "$config_file" >/dev/null 2>&1 || exit 1
        [[ -n "${PF_PCI:-}" ]] || exit 1
        normalize_pci "$PF_PCI"
    ) || {
        echo "Error: Could not read PF_PCI from SF configuration $config_file." >&2
        exit 1
    }
    [[ "$sf_pci" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || {
        echo "Error: SF configuration $config_file has invalid PF_PCI '$sf_pci'." >&2
        exit 1
    }
    sf_pfs[$sf_pci]="$config_file"
done

for config_file in "${configs[@]}"; do
    [[ -f "$config_file" ]] || continue
    identity=$(
        unset MODE PF_PCI
        # shellcheck source=/dev/null
        source "$config_file" >/dev/null 2>&1 || exit 1
        [[ -n "${PF_PCI:-}" ]] || exit 1
        printf '%s|%s\n' "${MODE:-switchdev}" "$(normalize_pci "$PF_PCI")"
    ) || {
        echo "Error: Could not inspect PF configuration $config_file." >&2
        exit 1
    }
    mode="${identity%%|*}"
    pf_pci="${identity#*|}"
    [[ "$pf_pci" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || {
        echo "Error: PF configuration $config_file has invalid PF_PCI '$pf_pci'." >&2
        exit 1
    }
    case "${mode,,}" in
        sriov|legacy|ordinary)
            if [[ -n "${sf_pfs[$pf_pci]+x}" ]]; then
                echo "Error: $config_file requests legacy SR-IOV for $pf_pci," >&2
                echo "       but ${sf_pfs[$pf_pci]} requires switchdev for an mlx5 SF." >&2
                echo "       Resolve the saved configuration conflict before boot-time apply." >&2
                exit 1
            fi
            ;;
    esac
done

if (( ${#configs[@]} == 0 && ${#sf_configs[@]} == 0 )); then
    echo "No sriov-nic.conf* or sf-nic.conf* files found in $SCRIPT_DIR; nothing to do."
    exit 0
fi

# PF mode and any SR-IOV VFs must exist before mlx5 SFs are restored.
for config_file in "${configs[@]}"; do
    [[ -f "$config_file" ]] || continue
    echo "============================================================"
    echo "Applying PF/VF configuration: $config_file"
    # Saved SF configs were prevalidated above and will be restored in the
    # second phase. Runtime SF ports still block disruptive VF recreation.
    SRIOV_COORDINATED_SF_RESTORE=true "$SCRIPT_DIR/set-sriov.sh" "$config_file"
done

if (( ${#sf_configs[@]} > 0 )); then
    [[ -x "$SCRIPT_DIR/manage-sf.sh" ]] || {
        echo "Error: sf-nic.conf* files exist, but $SCRIPT_DIR/manage-sf.sh is unavailable." >&2
        exit 1
    }
    echo "============================================================"
    echo "Restoring managed mlx5 SF/vDPA devices..."
    "$SCRIPT_DIR/manage-sf.sh" --apply-all "$SCRIPT_DIR"
fi
