#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSFS_ROOT="${SYSFS_ROOT:-/sys}"

CONFIG_FILE=""
INTERACTIVE=false
LIST_ONLY=false
SAVE_CONFIG=""
SAVED_CONFIG_PATH=""

# Runtime configuration. These are populated by a config file or the wizard.
MODE=""
PF_PCI=""
PF_DEV=""
DRIVER=""
TOTAL_VFS=""
MAX_VFS=""
MAC_MODE=""
VF_PREFIX=""
SET_MAX_RING=""
BRING_REPRESENTORS_UP=""
FLOW_STEERING_MODE=""
INLINE_MODE=""
ENCAP_MODE=""
OVS_HW_OFFLOAD=""
ORIG_MAC=""

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME                         Run the interactive wizard
  $SCRIPT_NAME --interactive          Run the interactive wizard
  $SCRIPT_NAME --interactive --save FILE
                                       Run the wizard and save a successful setup
  $SCRIPT_NAME --list                 List SR-IOV capable physical functions
  $SCRIPT_NAME CONFIG_FILE            Apply a saved configuration non-interactively
  $SCRIPT_NAME --help

Modes:
  sriov       Ordinary SR-IOV (legacy mode when the NIC exposes an e-switch)
  switchdev   SR-IOV switchdev mode with VF representor ports
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    echo "Warning: $*" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

normalize_bool() {
    case "${1,,}" in
        1|yes|y|true|on)  printf '%s\n' true ;;
        0|no|n|false|off) printf '%s\n' false ;;
        *) return 1 ;;
    esac
}

normalize_pci() {
    local pci="${1,,}"
    if [[ "$pci" =~ ^[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]; then
        pci="0000:$pci"
    fi
    printf '%s\n' "$pci"
}

get_devlink_ports() {
    local pci="$1"
    local output

    command_exists devlink || return 1

    # Newer iproute2 supports a device selector here. Fall back to listing all
    # ports for older versions whose parser only accepts DEV/PORT_INDEX.
    if output=$(devlink port show "pci/$pci" 2>/dev/null); then
        awk -v prefix="pci/$pci/" 'index($1, prefix) == 1' <<<"$output"
        return 0
    fi
    output=$(devlink port show 2>/dev/null) || return 1
    awk -v prefix="pci/$pci/" 'index($1, prefix) == 1' <<<"$output"
}

get_pf_netdev() {
    local pci="$1"
    local path iface first_iface="" phys_port_name="" port_output=""

    # In switchdev mode, representors may share the PF's PCI parent and appear
    # in the same sysfs net directory. Prefer devlink's physical uplink port.
    if port_output=$(get_devlink_ports "$pci"); then
        while IFS= read -r line; do
            [[ "$line" == *"flavour physical"* ]] || continue
            iface=$(awk '{for (i=1; i<=NF; i++) if ($i == "netdev") {print $(i+1); exit}}' \
                <<<"$line")
            if [[ -n "$iface" && -e "$SYSFS_ROOT/bus/pci/devices/$pci/net/$iface" ]]; then
                printf '%s\n' "$iface"
                return 0
            fi
        done <<<"$port_output"
    fi

    # Fall back to sysfs. Prefer a netdev whose physical port name does not
    # look like a VF/SF representor (pf0vf0, c0pf0vf0, pf0sf0, ...).
    for path in "$SYSFS_ROOT/bus/pci/devices/$pci/net"/*; do
        [[ -e "$path" ]] || continue
        iface=$(basename "$path")
        [[ -n "$first_iface" ]] || first_iface="$iface"
        if [[ -r "$SYSFS_ROOT/class/net/$iface/phys_port_name" ]]; then
            phys_port_name=$(<"$SYSFS_ROOT/class/net/$iface/phys_port_name")
        else
            phys_port_name=""
        fi
        if [[ ! "$phys_port_name" =~ ^(c[0-9]+)?pf[0-9]+(vf|sf)[0-9]+$ ]]; then
            printf '%s\n' "$iface"
            return 0
        fi
    done

    [[ -n "$first_iface" ]] || return 1
    printf '%s\n' "$first_iface"
}

get_driver() {
    local pci="$1"
    local target

    target=$(readlink "$SYSFS_ROOT/bus/pci/devices/$pci/driver" 2>/dev/null || true)
    if [[ -n "$target" ]]; then
        basename "$target"
    else
        printf '%s\n' unknown
    fi
}

get_pci_description() {
    local pci="$1"
    local description=""

    if command_exists lspci; then
        description=$(lspci -D -s "$pci" 2>/dev/null | cut -d' ' -f2- || true)
    fi
    [[ -n "$description" ]] || description="PCI device"
    printf '%s\n' "$description"
}

get_eswitch_info() {
    local pci="$1"

    command_exists devlink || return 1
    devlink dev eswitch show "pci/$pci" 2>/dev/null
}

get_eswitch_mode() {
    local info="$1"
    local mode

    mode=$(awk '{for (i=1; i<=NF; i++) if ($i == "mode") {print $(i+1); exit}}' <<<"$info")
    printf '%s\n' "${mode:-unknown}"
}

switchdev_status() {
    local pci="$1"
    local info mode

    if info=$(get_eswitch_info "$pci"); then
        mode=$(get_eswitch_mode "$info")
        printf 'yes (%s)\n' "$mode"
    else
        printf '%s\n' no
    fi
}

# Arrays used by --list and the interactive wizard.
declare -a DISCOVERED_PCIS=()
declare -a DISCOVERED_IFACES=()
declare -a DISCOVERED_DRIVERS=()
declare -a DISCOVERED_CURRENT=()
declare -a DISCOVERED_MAX=()
declare -a DISCOVERED_SWITCHDEV=()
declare -a DISCOVERED_DESCRIPTIONS=()

discover_pfs() {
    local device pci max current iface driver sw description

    DISCOVERED_PCIS=()
    DISCOVERED_IFACES=()
    DISCOVERED_DRIVERS=()
    DISCOVERED_CURRENT=()
    DISCOVERED_MAX=()
    DISCOVERED_SWITCHDEV=()
    DISCOVERED_DESCRIPTIONS=()

    for device in "$SYSFS_ROOT"/bus/pci/devices/*; do
        [[ -r "$device/sriov_totalvfs" && -r "$device/sriov_numvfs" ]] || continue
        max=$(<"$device/sriov_totalvfs")
        [[ "$max" =~ ^[0-9]+$ ]] || continue
        (( 10#$max > 0 )) || continue

        pci=$(basename "$device")
        current=$(<"$device/sriov_numvfs")
        iface=$(get_pf_netdev "$pci" 2>/dev/null || true)
        # Ignore SR-IOV capable non-network PCI functions (for example GPUs)
        # and NIC PFs whose driver has not created a netdev yet.
        [[ -n "$iface" ]] || continue
        driver=$(get_driver "$pci")
        sw=$(switchdev_status "$pci")
        description=$(get_pci_description "$pci")

        DISCOVERED_PCIS+=("$pci")
        DISCOVERED_IFACES+=("$iface")
        DISCOVERED_DRIVERS+=("$driver")
        DISCOVERED_CURRENT+=("$current")
        DISCOVERED_MAX+=("$max")
        DISCOVERED_SWITCHDEV+=("$sw")
        DISCOVERED_DESCRIPTIONS+=("$description")
    done
}

print_pfs() {
    local i

    discover_pfs
    if (( ${#DISCOVERED_PCIS[@]} == 0 )); then
        echo "No SR-IOV capable physical function was found."
        return 1
    fi

    printf '%-4s %-14s %-14s %-12s %-11s %-18s %s\n' \
        No. Interface PCI Driver VFs Switchdev Description
    for i in "${!DISCOVERED_PCIS[@]}"; do
        printf '%-4s %-14s %-14s %-12s %-11s %-18s %s\n' \
            "$((i + 1))" \
            "${DISCOVERED_IFACES[$i]}" \
            "${DISCOVERED_PCIS[$i]}" \
            "${DISCOVERED_DRIVERS[$i]}" \
            "${DISCOVERED_CURRENT[$i]}/${DISCOVERED_MAX[$i]}" \
            "${DISCOVERED_SWITCHDEV[$i]}" \
            "${DISCOVERED_DESCRIPTIONS[$i]}"
    done
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-no}"
    local answer suffix

    if [[ "$default" == yes ]]; then
        suffix='[Y/n]'
    else
        suffix='[y/N]'
    fi

    while true; do
        read -r -p "$prompt $suffix " answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

default_vf_prefix() {
    local pci="$1"
    if [[ "$pci" =~ ^([[:xdigit:]]{4}):([[:xdigit:]]{2}):([[:xdigit:]]{2})\.([0-7])$ ]]; then
        printf '02:%s:%s:%s:%02x\n' \
            "${BASH_REMATCH[1]:2:2}" \
            "${BASH_REMATCH[2]}" \
            "${BASH_REMATCH[3]}" \
            "$((10#${BASH_REMATCH[4]}))"
    else
        printf '%s\n' '02:00:00:00:00'
    fi
}

interactive_setup() {
    local choice index default_vfs answer default_prefix

    [[ -t 0 && -t 1 ]] || die "Interactive mode requires a terminal."

    echo "SR-IOV NIC configuration wizard"
    echo "================================"
    print_pfs || exit 1
    echo

    while true; do
        read -r -p "Select a physical function [1-${#DISCOVERED_PCIS[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( 10#$choice >= 1 && 10#$choice <= ${#DISCOVERED_PCIS[@]} )); then
            index=$((10#$choice - 1))
            break
        fi
        echo "Invalid selection."
    done

    PF_PCI="${DISCOVERED_PCIS[$index]}"
    PF_DEV="${DISCOVERED_IFACES[$index]}"
    DRIVER="${DISCOVERED_DRIVERS[$index]}"
    MAX_VFS="${DISCOVERED_MAX[$index]}"

    [[ "$PF_DEV" != '<no-netdev>' ]] || \
        die "The selected PCI function has no netdev; make sure its PF driver is loaded."

    echo
    echo "Operating mode:"
    echo "  1) Ordinary SR-IOV (legacy)"
    if [[ "${DISCOVERED_SWITCHDEV[$index]}" == yes* ]]; then
        echo "  2) Switchdev (supported; creates representor ports)"
    else
        echo "  2) Switchdev (not exposed by the current driver/firmware)"
    fi

    while true; do
        read -r -p "Select mode [1]: " answer
        answer="${answer:-1}"
        case "$answer" in
            1)
                MODE=sriov
                break
                ;;
            2)
                if [[ "${DISCOVERED_SWITCHDEV[$index]}" == yes* ]]; then
                    MODE=switchdev
                    break
                fi
                echo "Switchdev is unavailable for this physical function."
                ;;
            *) echo "Invalid selection." ;;
        esac
    done

    if (( 10#${DISCOVERED_CURRENT[$index]} > 0 )); then
        default_vfs=$((10#${DISCOVERED_CURRENT[$index]}))
    elif (( 10#$MAX_VFS < 8 )); then
        default_vfs=$((10#$MAX_VFS))
    else
        default_vfs=8
    fi

    while true; do
        read -r -p "Number of VFs [${default_vfs}, maximum ${MAX_VFS}]: " answer
        answer="${answer:-$default_vfs}"
        if [[ "$answer" =~ ^[0-9]+$ ]] &&
           (( 10#$answer >= 1 && 10#$answer <= 10#$MAX_VFS )); then
            TOTAL_VFS=$((10#$answer))
            break
        fi
        echo "Enter an integer between 1 and $MAX_VFS."
    done

    echo
    echo "MAC configuration:"
    echo "  1) Leave PF and VF MAC addresses to the driver/hypervisor (safest)"
    echo "  2) Keep the PF MAC and assign generated MAC addresses to all VFs"
    echo "  3) Move the permanent PF MAC to VF 0 (original repository behavior)"
    while true; do
        read -r -p "Select MAC policy [1]: " answer
        answer="${answer:-1}"
        case "$answer" in
            1) MAC_MODE=none; break ;;
            2) MAC_MODE=generated; break ;;
            3) MAC_MODE=move-pf-to-vf0; break ;;
            *) echo "Invalid selection." ;;
        esac
    done

    VF_PREFIX=""
    if [[ "$MAC_MODE" != none ]]; then
        default_prefix=$(default_vf_prefix "$PF_PCI")
        read -r -p "Five-byte VF MAC prefix [$default_prefix]: " VF_PREFIX
        VF_PREFIX="${VF_PREFIX:-$default_prefix}"
    fi

    if prompt_yes_no "Set supported RX/TX ring sizes to their maximum?" yes; then
        SET_MAX_RING=true
    else
        SET_MAX_RING=false
    fi

    BRING_REPRESENTORS_UP=false
    FLOW_STEERING_MODE=auto
    INLINE_MODE=auto
    ENCAP_MODE=auto
    OVS_HW_OFFLOAD=false

    if [[ "$MODE" == switchdev ]]; then
        BRING_REPRESENTORS_UP=true
        if [[ "$DRIVER" == mlx5_core ]]; then
            # Preserve the tuning used by the original mlx5-oriented script.
            FLOW_STEERING_MODE=dmfs
            INLINE_MODE=transport
        fi
        if command_exists ovs-vsctl &&
           prompt_yes_no "Enable Open vSwitch hardware offload when saved configs run at boot?" yes; then
            OVS_HW_OFFLOAD=true
        fi
    fi
}

load_config() {
    local file="$1"
    local legacy_config=false

    [[ -f "$file" ]] || die "Configuration file '$file' was not found."

    # Config files are shell fragments and must therefore be trusted.
    unset MODE PF_PCI TOTAL_VFS MAC_MODE VF_PREFIX SET_MAX_RING
    unset BRING_REPRESENTORS_UP FLOW_STEERING_MODE INLINE_MODE ENCAP_MODE
    unset OVS_HW_OFFLOAD
    # shellcheck source=/dev/null
    source "$file"

    if [[ -z "${MODE+x}" ]]; then
        # Backward compatibility with the original three-variable format.
        legacy_config=true
        MODE=switchdev
    fi

    : "${PF_PCI:?Variable PF_PCI is not set in $file.}"
    : "${TOTAL_VFS:?Variable TOTAL_VFS is not set in $file.}"

    if [[ "$legacy_config" == true ]]; then
        MAC_MODE="${MAC_MODE:-move-pf-to-vf0}"
        FLOW_STEERING_MODE="${FLOW_STEERING_MODE:-dmfs}"
        INLINE_MODE="${INLINE_MODE:-transport}"
        OVS_HW_OFFLOAD="${OVS_HW_OFFLOAD:-true}"
    else
        MAC_MODE="${MAC_MODE:-none}"
        FLOW_STEERING_MODE="${FLOW_STEERING_MODE:-auto}"
        INLINE_MODE="${INLINE_MODE:-auto}"
        OVS_HW_OFFLOAD="${OVS_HW_OFFLOAD:-false}"
    fi

    VF_PREFIX="${VF_PREFIX:-}"
    SET_MAX_RING="${SET_MAX_RING:-true}"
    if [[ -z "${BRING_REPRESENTORS_UP+x}" ]]; then
        if [[ "${MODE,,}" == switchdev ]]; then
            BRING_REPRESENTORS_UP=true
        else
            BRING_REPRESENTORS_UP=false
        fi
    fi
    ENCAP_MODE="${ENCAP_MODE:-auto}"
}

validate_settings() {
    local first_octet eswitch_info

    case "${MODE,,}" in
        sriov|legacy|ordinary) MODE=sriov ;;
        switchdev) MODE=switchdev ;;
        *) die "MODE must be 'sriov' or 'switchdev', not '$MODE'." ;;
    esac

    case "${MAC_MODE,,}" in
        none|off) MAC_MODE=none ;;
        generated|generate) MAC_MODE=generated ;;
        move-pf-to-vf0|legacy) MAC_MODE=move-pf-to-vf0 ;;
        *) die "MAC_MODE must be none, generated, or move-pf-to-vf0." ;;
    esac

    SET_MAX_RING=$(normalize_bool "$SET_MAX_RING") || \
        die "SET_MAX_RING must be true or false."
    BRING_REPRESENTORS_UP=$(normalize_bool "$BRING_REPRESENTORS_UP") || \
        die "BRING_REPRESENTORS_UP must be true or false."
    OVS_HW_OFFLOAD=$(normalize_bool "$OVS_HW_OFFLOAD") || \
        die "OVS_HW_OFFLOAD must be true or false."

    PF_PCI=$(normalize_pci "$PF_PCI")
    [[ "$PF_PCI" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] || \
        die "Invalid PCI address '$PF_PCI'. Use a value such as 0000:03:00.0."

    local pci_dir="$SYSFS_ROOT/bus/pci/devices/$PF_PCI"
    [[ -d "$pci_dir" ]] || die "PCI device $PF_PCI does not exist."
    [[ -r "$pci_dir/sriov_totalvfs" && -w "$pci_dir/sriov_numvfs" ]] || \
        die "PCI device $PF_PCI does not expose writable SR-IOV controls."

    MAX_VFS=$(<"$pci_dir/sriov_totalvfs")
    if [[ ! "$MAX_VFS" =~ ^[0-9]+$ ]] || (( 10#$MAX_VFS == 0 )); then
        die "PCI device $PF_PCI reports no SR-IOV capability."
    fi
    [[ "$TOTAL_VFS" =~ ^[0-9]+$ ]] || die "TOTAL_VFS must be a positive integer."
    TOTAL_VFS=$((10#$TOTAL_VFS))
    MAX_VFS=$((10#$MAX_VFS))
    (( TOTAL_VFS >= 1 && TOTAL_VFS <= MAX_VFS )) || \
        die "TOTAL_VFS must be between 1 and $MAX_VFS for $PF_PCI."

    PF_DEV=$(get_pf_netdev "$PF_PCI" || true)
    [[ -n "$PF_DEV" ]] || \
        die "No network interface was found for $PF_PCI; make sure the PF driver is loaded."
    DRIVER=$(get_driver "$PF_PCI")

    command_exists ip || die "The 'ip' command is required (install iproute2)."

    if [[ "$MODE" == switchdev ]]; then
        command_exists devlink || die "Switchdev requires the 'devlink' command."
        if ! eswitch_info=$(get_eswitch_info "$PF_PCI"); then
            die "$PF_PCI ($PF_DEV, driver $DRIVER) does not expose devlink e-switch mode. Use MODE=sriov instead."
        fi
        [[ "$eswitch_info" == *"mode "* ]] || \
            die "Could not determine the e-switch mode of $PF_PCI."
    fi

    if [[ "$MAC_MODE" != none ]]; then
        [[ "$VF_PREFIX" =~ ^[[:xdigit:]]{2}(:[[:xdigit:]]{2}){4}$ ]] || \
            die "VF_PREFIX must contain exactly five MAC octets, e.g. 02:00:00:03:00."
        (( TOTAL_VFS <= 256 )) || \
            die "Generated one-byte MAC suffixes support at most 256 VFs."
        VF_PREFIX="${VF_PREFIX,,}"
        first_octet="${VF_PREFIX%%:*}"
        (( (16#$first_octet & 1) == 0 )) || \
            die "VF_PREFIX starts with a multicast MAC octet ($first_octet)."
        if (( (16#$first_octet & 2) == 0 )); then
            warn "VF_PREFIX is not locally administered; a prefix beginning with 02 is recommended."
        fi
    fi

    if [[ "$MAC_MODE" == move-pf-to-vf0 || "$SET_MAX_RING" == true ]]; then
        command_exists ethtool || die "The 'ethtool' command is required."
    fi

    FLOW_STEERING_MODE="${FLOW_STEERING_MODE,,}"
    INLINE_MODE="${INLINE_MODE,,}"
    ENCAP_MODE="${ENCAP_MODE,,}"

    case "$INLINE_MODE" in
        auto|none|link|network|transport) ;;
        *) die "INLINE_MODE must be auto, none, link, network, or transport." ;;
    esac
    case "$ENCAP_MODE" in
        auto|none|basic) ;;
        *) die "ENCAP_MODE must be auto, none, or basic." ;;
    esac
}

set_max_ring() {
    local iface="$1"
    local max_rx max_tx
    local -a args=()

    [[ "$SET_MAX_RING" == true ]] || return 0
    [[ -e "$SYSFS_ROOT/class/net/$iface" ]] || return 0

    max_rx=$(ethtool -g "$iface" 2>/dev/null |
        awk '/Pre-set maximums:/{f=1} f && /^RX:/{print $2; exit}' || true)
    max_tx=$(ethtool -g "$iface" 2>/dev/null |
        awk '/Pre-set maximums:/{f=1} f && /^TX:/{print $2; exit}' || true)

    if [[ -z "$max_rx" && -z "$max_tx" ]]; then
        echo "    Ring: $iface (not supported, skipped)"
        return 0
    fi

    [[ -n "$max_rx" ]] && args+=(rx "$max_rx")
    [[ -n "$max_tx" ]] && args+=(tx "$max_tx")
    if ethtool -G "$iface" "${args[@]}" 2>/dev/null; then
        echo "    Ring: $iface rx=${max_rx:-n/a} tx=${max_tx:-n/a} -> max"
    else
        echo "    Ring: $iface (setting failed, skipped)"
    fi
}

set_optional_devlink_param() {
    local name="$1"
    local value="$2"

    [[ "$value" != auto && -n "$value" ]] || return 0
    if devlink dev param show "pci/$PF_PCI" name "$name" >/dev/null 2>&1; then
        echo "Setting devlink parameter $name=$value..."
        devlink dev param set "pci/$PF_PCI" name "$name" value "$value" cmode runtime
    else
        warn "devlink parameter '$name' is unavailable on driver $DRIVER; skipped."
    fi
}

set_optional_eswitch_attr() {
    local attr="$1"
    local value="$2"
    local info

    [[ "$value" != auto && -n "$value" ]] || return 0
    info=$(get_eswitch_info "$PF_PCI")
    if grep -q -- "$attr" <<<"$info"; then
        echo "Setting e-switch $attr=$value..."
        devlink dev eswitch set "pci/$PF_PCI" "$attr" "$value"
    else
        warn "e-switch attribute '$attr' is unavailable on driver $DRIVER; skipped."
    fi
}

settle_devices() {
    if command_exists udevadm; then
        if ! udevadm settle; then
            warn "udevadm settle failed; falling back to a one-second wait."
            sleep 1
        fi
    else
        sleep 1
    fi
}

configure_mac_addresses() {
    local i suffix mac pf_dummy_mac was_up=false

    case "$MAC_MODE" in
        none)
            echo "Leaving PF/VF MAC addresses unchanged."
            return 0
            ;;
        generated)
            echo "Assigning generated MAC addresses to VFs..."
            for ((i = 0; i < TOTAL_VFS; i++)); do
                printf -v suffix '%02x' "$i"
                mac="$VF_PREFIX:$suffix"
                ip link set dev "$PF_DEV" vf "$i" mac "$mac"
            done
            ;;
        move-pf-to-vf0)
            [[ "$ORIG_MAC" =~ ^[[:xdigit:]]{2}(:[[:xdigit:]]{2}){5}$ ]] || \
                die "Could not read a valid permanent MAC from $PF_DEV."
            pf_dummy_mac="$VF_PREFIX:00"
            echo "Moving permanent PF MAC $ORIG_MAC to VF 0..."

            if ip -o link show dev "$PF_DEV" | grep -qE '(<|,)UP(,|>)'; then
                was_up=true
            fi
            ip link set dev "$PF_DEV" down
            if ! ip link set dev "$PF_DEV" address "$pf_dummy_mac"; then
                [[ "$was_up" == true ]] && ip link set dev "$PF_DEV" up || true
                die "Failed to set the PF dummy MAC."
            fi
            [[ "$was_up" == true ]] && ip link set dev "$PF_DEV" up

            ip link set dev "$PF_DEV" vf 0 mac "$ORIG_MAC"
            for ((i = 1; i < TOTAL_VFS; i++)); do
                printf -v suffix '%02x' "$i"
                mac="$VF_PREFIX:$suffix"
                ip link set dev "$PF_DEV" vf "$i" mac "$mac"
            done
            ;;
    esac
}

configure_vf_rings() {
    local i vf_path vf_dev

    [[ "$SET_MAX_RING" == true ]] || return 0
    echo "Setting maximum ring sizes for host-visible VF netdevs..."
    for ((i = 0; i < TOTAL_VFS; i++)); do
        vf_path="$SYSFS_ROOT/bus/pci/devices/$PF_PCI/virtfn$i/net"
        vf_dev=""
        if [[ -d "$vf_path" ]]; then
            vf_dev=$(find "$vf_path" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null |
                head -n 1 || true)
        fi
        if [[ -n "$vf_dev" ]]; then
            set_max_ring "$vf_dev"
        fi
    done
    return 0
}

configure_representors() {
    local iface port_output
    local representor_count=0
    local -a netdevs=()

    [[ "$MODE" == switchdev && "$BRING_REPRESENTORS_UP" == true ]] || return 0

    echo "Bringing up the switchdev uplink and representor ports..."
    echo "    Setting UP: $PF_DEV (uplink)"
    ip link set dev "$PF_DEV" up

    if ! port_output=$(get_devlink_ports "$PF_PCI"); then
        warn "Could not list devlink ports for $PF_PCI."
        return 0
    fi
    mapfile -t netdevs < <(
        awk '{for (i=1; i<=NF; i++) if ($i == "netdev") print $(i+1)}' \
            <<<"$port_output" | sort -u
    )

    for iface in "${netdevs[@]}"; do
        [[ -n "$iface" && "$iface" != "$PF_DEV" ]] || continue
        [[ -e "$SYSFS_ROOT/class/net/$iface" ]] || continue
        echo "    Setting UP: $iface"
        ip link set dev "$iface" up
        set_max_ring "$iface"
        ((representor_count += 1))
    done

    if (( representor_count == 0 )); then
        warn "No VF representor netdevs were found for $PF_PCI after creating $TOTAL_VFS VFs."
    fi
    return 0
}

print_summary() {
    cat <<EOF

Configuration summary
---------------------
PCI function:       $PF_PCI
Interface:          $PF_DEV
Driver:             $DRIVER
Mode:               $MODE
VFs:                $TOTAL_VFS (maximum $MAX_VFS)
MAC policy:         $MAC_MODE
VF MAC prefix:      ${VF_PREFIX:-n/a}
Max ring sizes:     $SET_MAX_RING
OVS boot offload:   $OVS_HW_OFFLOAD
EOF
}

apply_configuration() {
    local sriov_file current eswitch_info current_mode actual

    sriov_file="$SYSFS_ROOT/bus/pci/devices/$PF_PCI/sriov_numvfs"

    if [[ "$MAC_MODE" == move-pf-to-vf0 ]]; then
        ORIG_MAC=$(ethtool -P "$PF_DEV" 2>/dev/null |
            awk -F': ' '/Permanent address:/{print $2; exit}' || true)
        ORIG_MAC="${ORIG_MAC,,}"
        [[ "$ORIG_MAC" =~ ^[[:xdigit:]]{2}(:[[:xdigit:]]{2}){5}$ ]] || \
            die "Could not read a valid permanent MAC from $PF_DEV; no changes were made."
    fi

    current=$(<"$sriov_file")
    echo ">>> Configuring $PF_PCI ($PF_DEV, driver $DRIVER) in $MODE mode"
    echo "Removing $current existing VF(s)..."
    printf '0\n' >"$sriov_file"
    settle_devices

    if [[ "$MODE" == switchdev ]]; then
        set_optional_devlink_param flow_steering_mode "$FLOW_STEERING_MODE"

        echo "Switching the e-switch to switchdev mode..."
        devlink dev eswitch set "pci/$PF_PCI" mode switchdev
        set_optional_eswitch_attr inline-mode "$INLINE_MODE"
        set_optional_eswitch_attr encap-mode "$ENCAP_MODE"
    else
        if ! command_exists devlink; then
            warn "devlink is unavailable, so the script cannot detect or force legacy e-switch mode."
            echo "Using ordinary SR-IOV sysfs controls directly."
        elif eswitch_info=$(get_eswitch_info "$PF_PCI"); then
            current_mode=$(get_eswitch_mode "$eswitch_info")
            if [[ "$current_mode" != legacy ]]; then
                echo "Switching the e-switch from $current_mode to legacy mode..."
                devlink dev eswitch set "pci/$PF_PCI" mode legacy
            else
                echo "The e-switch is already in legacy mode."
            fi
        else
            echo "The driver has no devlink e-switch mode; using ordinary SR-IOV directly."
        fi
    fi

    echo "Creating $TOTAL_VFS VF(s)..."
    printf '%s\n' "$TOTAL_VFS" >"$sriov_file"
    settle_devices

    actual=$(<"$sriov_file")
    [[ "$actual" == "$TOTAL_VFS" ]] || \
        die "Requested $TOTAL_VFS VFs, but the driver reports $actual."

    configure_vf_rings
    configure_mac_addresses
    set_max_ring "$PF_DEV"
    configure_representors

    echo ">>> Configuration complete: $PF_DEV has $actual VF(s) in $MODE mode."
    if [[ "$MODE" == switchdev ]]; then
        devlink dev eswitch show "pci/$PF_PCI" || true
    fi
}

save_config_file() {
    local path="$1"
    local directory

    [[ -n "$path" ]] || path="$SCRIPT_DIR/sriov-nic.conf.$PF_DEV"
    if [[ "$path" != /* ]]; then
        path="$PWD/$path"
    fi
    directory=$(dirname "$path")
    [[ -d "$directory" ]] || die "Directory '$directory' does not exist."

    if [[ -e "$path" ]] && ! prompt_yes_no "Overwrite $path?" no; then
        echo "Configuration was not saved."
        return 0
    fi

    # Remember the saved location so the wizard can offer boot-service setup.
    SAVED_CONFIG_PATH="$path"

    {
        echo "# Generated by $SCRIPT_NAME on $(date -Is)"
        printf 'MODE=%q\n' "$MODE"
        printf 'PF_PCI=%q\n' "$PF_PCI"
        printf 'TOTAL_VFS=%q\n' "$TOTAL_VFS"
        printf 'MAC_MODE=%q\n' "$MAC_MODE"
        printf 'VF_PREFIX=%q\n' "$VF_PREFIX"
        printf 'SET_MAX_RING=%q\n' "$SET_MAX_RING"
        printf 'BRING_REPRESENTORS_UP=%q\n' "$BRING_REPRESENTORS_UP"
        printf 'FLOW_STEERING_MODE=%q\n' "$FLOW_STEERING_MODE"
        printf 'INLINE_MODE=%q\n' "$INLINE_MODE"
        printf 'ENCAP_MODE=%q\n' "$ENCAP_MODE"
        printf 'OVS_HW_OFFLOAD=%q\n' "$OVS_HW_OFFLOAD"
    } >"$path"
    chmod 0644 "$path"
    echo "Saved configuration to $path"
}

install_boot_service() {
    local installer="$SCRIPT_DIR/set-systemd-service.sh"

    [[ -x "$installer" ]] || {
        warn "$installer is missing or not executable; skipping boot service install."
        return 1
    }

    # set-systemd-service.sh renders %INSTALL_DIR% into the unit and reloads
    # systemd. SRIOV_UNIT_PATH / SRIOV_SYSTEMCTL can override its destinations.
    "$installer"
    if ! command_exists systemctl; then
        warn "systemctl is unavailable; the unit was installed but not enabled."
        return 1
    fi
    systemctl enable sriov-nic.service
    echo "sriov-nic.service installed and enabled; configs will be re-applied on boot."
}

while (( $# > 0 )); do
    case "$1" in
        -i|--interactive)
            INTERACTIVE=true
            ;;
        -l|--list)
            LIST_ONLY=true
            ;;
        --save)
            shift
            (( $# > 0 )) || die "--save requires a file path."
            SAVE_CONFIG="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            (( $# <= 1 )) || die "Only one configuration file can be supplied."
            if (( $# == 1 )); then
                [[ -z "$CONFIG_FILE" ]] || die "Only one configuration file can be supplied."
                CONFIG_FILE="$1"
            fi
            break
            ;;
        -*)
            die "Unknown option '$1'. Use --help for usage."
            ;;
        *)
            [[ -z "$CONFIG_FILE" ]] || die "Only one configuration file can be supplied."
            CONFIG_FILE="$1"
            ;;
    esac
    shift
done

if [[ "$LIST_ONLY" == true ]]; then
    [[ "$INTERACTIVE" == false && -z "$CONFIG_FILE" && -z "$SAVE_CONFIG" ]] || \
        die "--list cannot be combined with interactive mode, --save, or a config file."
    print_pfs
    exit $?
fi

if [[ -z "$CONFIG_FILE" && "$INTERACTIVE" == false ]]; then
    if [[ -t 0 && -t 1 ]]; then
        INTERACTIVE=true
    else
        usage >&2
        exit 2
    fi
fi

[[ "$EUID" -eq 0 ]] || die "Run this script as root."

if [[ "$INTERACTIVE" == true ]]; then
    [[ -z "$CONFIG_FILE" ]] || die "Interactive mode cannot be combined with a config file."
    interactive_setup
else
    [[ -z "$SAVE_CONFIG" ]] || die "--save is only valid in interactive mode."
    load_config "$CONFIG_FILE"
fi

validate_settings
print_summary

if [[ "$INTERACTIVE" == true ]]; then
    cat <<EOF

WARNING: Applying this configuration deletes and recreates all VFs on $PF_DEV.
It can interrupt networking and disconnect this shell. Stop every VM/process
using these VFs and use a local or out-of-band management console.
EOF
    read -r -p "Type APPLY to continue: " answer
    [[ "$answer" == APPLY ]] || die "Cancelled; no changes were made."
fi

apply_configuration

if [[ "$INTERACTIVE" == true ]]; then
    if [[ -n "$SAVE_CONFIG" ]]; then
        save_config_file "$SAVE_CONFIG"
    elif prompt_yes_no "Save this working configuration for set-sriov-all.sh/systemd?" no; then
        save_config_file "$SCRIPT_DIR/sriov-nic.conf.$PF_DEV"
    fi

    if [[ -n "$SAVED_CONFIG_PATH" ]]; then
        if [[ "$SAVED_CONFIG_PATH" == "$SCRIPT_DIR"/sriov-nic.conf* ]]; then
            if prompt_yes_no "Install and enable sriov-nic.service to re-apply this config on boot?" no; then
                install_boot_service
            fi
        else
            echo "Note: the saved config is outside the script directory, so the boot"
            echo "      service will not load it automatically. To use boot-time"
            echo "      re-application, save it into $SCRIPT_DIR as sriov-nic.conf*."
        fi
    fi
fi
