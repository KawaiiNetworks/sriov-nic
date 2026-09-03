#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SYSFS_ROOT="${SYSFS_ROOT:-/sys}"
CONFIG_DIR="${SF_CONFIG_DIR:-$SCRIPT_DIR}"
DEV_ROOT="${SF_DEV_ROOT:-/dev}"
STABLE_DEV_DIR="${SF_STABLE_DEV_DIR:-$DEV_ROOT/sriov-nic}"
PVE_CONFIG_DIR="${PVE_QEMU_CONFIG_DIR:-/etc/pve/qemu-server}"

PF_PCI=""
PF_DEV=""
PFNUM=""
SF_CONTROLLER=0
SF_NUM=""
SF_MAC=""
SF_MAC_MODE="explicit"
SF_PREFIX=""
VDPA_NAME=""
VDPA_MAX_VQP=4
VDPA_MTU=1500
REP_NAME=""
PVE_VMID=""
CONFIG_FILE=""

ENSURE_VDPA_NODE=""
ENSURE_REP_NAME=""

declare -A FW_QUERY_CACHE=()
FW_QUERY_OUTPUT=""
declare -a TX_NEW_SFS=()
declare -a TX_NEW_VDPAS=()
declare -a TX_NEW_CONFIGS=()
declare -a TX_SWITCHED_PFS=()
TX_ACTIVE=false

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME                              Interactive SF/vDPA manager
  $SCRIPT_NAME --interactive                Interactive SF/vDPA manager
  $SCRIPT_NAME --list [PF_PCI]              List current and managed SFs
  $SCRIPT_NAME --apply CONFIG               Restore one sf-nic.conf file
  $SCRIPT_NAME --apply-all [DIRECTORY]       Restore all sf-nic.conf* files
  $SCRIPT_NAME --attach CONFIG VMID          Attach a managed vDPA SF to a stopped PVE VM
  $SCRIPT_NAME --detach CONFIG               Detach a managed vDPA SF from its stopped PVE VM
  $SCRIPT_NAME --delete CONFIG               Delete a managed SF and its config
  $SCRIPT_NAME --help

This tool manages mlx5 subfunctions backed by hardware vDPA. It never changes
persistent NIC firmware settings and it never connects representors to OVS or
a Linux bridge.
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

normalize_pci() {
    local pci="${1,,}"
    if [[ "$pci" =~ ^[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]; then
        pci="0000:$pci"
    fi
    printf '%s\n' "$pci"
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
            n|no) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

settle_devices() {
    if command_exists udevadm; then
        if ! udevadm settle; then
            warn "udevadm settle failed; waiting one second instead."
            sleep 1
        fi
    else
        sleep 1
    fi
}

get_driver() {
    local target
    target=$(readlink "$SYSFS_ROOT/bus/pci/devices/$1/driver" 2>/dev/null || true)
    [[ -n "$target" ]] && basename "$target" || printf '%s\n' unknown
}

get_devlink_handles() {
    local pci="$1" output
    {
        printf 'pci/%s\n' "$pci"
        if output=$(devlink dev show "pci/$pci" 2>/dev/null); then
            awk '{
                for (i = 1; i <= NF; i++) {
                    h = $i
                    sub(/:$/, "", h)
                    if (h ~ /^(pci|auxiliary|platform)\/[^[:space:]]+$/)
                        print h
                }
            }' <<<"$output"
        fi
    } | awk 'NF && !seen[$0]++'
}

get_devlink_ports() {
    local pci="$1" output handles handle
    output=$(devlink port show 2>/dev/null) || return 1
    handles=$(get_devlink_handles "$pci") || return 1
    while IFS= read -r handle; do
        [[ -n "$handle" ]] || continue
        awk -v prefix="$handle/" 'index($1, prefix) == 1' <<<"$output"
    done <<<"$handles" | awk 'NF && !seen[$0]++'
}

get_pf_netdev() {
    local pci="$1" line iface path first="" port_name

    while IFS= read -r line; do
        [[ "$line" == *"flavour physical"* ]] || continue
        iface=$(awk '{for (i=1; i<=NF; i++) if ($i=="netdev") {print $(i+1); exit}}' <<<"$line")
        if [[ -n "$iface" && -e "$SYSFS_ROOT/class/net/$iface" ]]; then
            printf '%s\n' "$iface"
            return 0
        fi
    done < <(get_devlink_ports "$pci" 2>/dev/null || true)

    for path in "$SYSFS_ROOT/bus/pci/devices/$pci/net"/*; do
        [[ -e "$path" ]] || continue
        iface=$(basename "$path")
        [[ -n "$first" ]] || first="$iface"
        port_name=$(cat "$SYSFS_ROOT/class/net/$iface/phys_port_name" 2>/dev/null || true)
        if [[ ! "$port_name" =~ ^(c[0-9]+)?pf[0-9]+(vf|sf)[0-9]+$ ]]; then
            printf '%s\n' "$iface"
            return 0
        fi
    done
    [[ -n "$first" ]] && printf '%s\n' "$first"
}

get_eswitch_info() {
    devlink dev eswitch show "pci/$1" 2>/dev/null
}

get_eswitch_mode() {
    awk '{for (i=1; i<=NF; i++) if ($i=="mode") {print $(i+1); exit}}' <<<"$1"
}

get_sf_port() {
    local pci="$1" pfnum="$2" sfnum="$3" controller="${4:-0}"
    devlink port show 2>/dev/null | awk \
        -v prefix="pci/$pci/" -v wanted_pf="$pfnum" -v wanted_sf="$sfnum" \
        -v wanted_controller="$controller" '
        index($1, prefix) == 1 && $0 ~ /flavour pcisf/ {
            controller="0"; pf=""; sf=""
            for (i=1; i<=NF; i++) {
                if ($i=="controller") controller=$(i+1)
                if ($i=="pfnum") pf=$(i+1)
                if ($i=="sfnum") sf=$(i+1)
            }
            if (controller==wanted_controller && pf==wanted_pf && sf==wanted_sf) {
                port=$1; sub(/:$/, "", port); print port; exit
            }
        }'
}

get_sf_field() {
    local port="$1" field="$2"
    devlink port show "$port" 2>/dev/null | awk -v wanted="$field" '
        {for (i=1; i<=NF; i++) if ($i==wanted) {print $(i+1); exit}}'
}

get_sf_nested_devlink() {
    devlink port show "$1" 2>/dev/null | awk '
        $1=="nested_devlink:" {getline; gsub(/:$/, "", $1); print $1; exit}'
}

wait_for_sf_nested_devlink() {
    local port="$1" attempt nested
    for ((attempt=1; attempt<=40; attempt++)); do
        nested=$(get_sf_nested_devlink "$port" || true)
        if [[ "$nested" == auxiliary/mlx5_core.sf.* ]]; then
            printf '%s\n' "$nested"
            return 0
        fi
        sleep 0.25
    done
    return 1
}

wait_for_sf_detached() {
    local port="$1" attempt opstate nested
    for ((attempt=1; attempt<=40; attempt++)); do
        opstate=$(get_sf_field "$port" opstate || true)
        nested=$(get_sf_nested_devlink "$port" || true)
        if [[ "$opstate" == detached || -z "$nested" ]]; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

get_sf_vdpa_name() {
    local sfdev="$1"
    vdpa dev show 2>/dev/null | awk -v wanted="$sfdev" '
        {
            name=$1; sub(/:$/, "", name)
            for (i=1; i<=NF; i++)
                if ($i=="mgmtdev" && $(i+1)==wanted) {print name; exit}
        }'
}

get_vdpa_mgmtdev() {
    vdpa dev show "$1" 2>/dev/null | awk '
        {for (i=1; i<=NF; i++) if ($i=="mgmtdev") {print $(i+1); exit}}'
}

get_vdpa_config_field() {
    vdpa dev config show "$1" 2>/dev/null | awk -v wanted="$2" '
        {for (i=1; i<=NF; i++) if ($i==wanted) {print $(i+1); exit}}'
}

get_param_driverinit() {
    devlink dev param show "$1" name "$2" 2>/dev/null | awk '
        $1=="cmode" && $2=="driverinit" && $3=="value" {print $4; exit}'
}

restore_driverinit_params() {
    local dev="$1" names_name="$2" values_name="$3" i
    local -n names_ref="$names_name"
    local -n values_ref="$values_name"

    for ((i=${#names_ref[@]}-1; i>=0; i--)); do
        devlink dev param set "$dev" name "${names_ref[$i]}" \
            value "${values_ref[$i]}" cmode driverinit >/dev/null 2>&1 ||
            warn "Could not restore ${names_ref[$i]}=${values_ref[$i]} on $dev."
    done
}

pci_token() {
    printf '%s\n' "${1//[:.]/-}"
}

compact_pci_token() {
    printf '%s\n' "${1//[:.]/}"
}

default_vdpa_name() {
    printf 'snc-%s-s%s\n' "$(compact_pci_token "$1")" "$2"
}

default_rep_name() {
    local base name compact
    base=$(sed -E 's/np[0-9]+$//' <<<"$1")
    name="${base}sf${3}r"
    if (( ${#name} <= 15 )); then
        printf '%s\n' "$name"
        return
    fi
    compact=$(compact_pci_token "$2")
    name="r${compact}s${3}"
    if (( ${#name} <= 15 )); then
        printf '%s\n' "$name"
        return
    fi
    # Keep the rightmost BDF digits and the complete SF number.
    printf 'sfr%s%s\n' "${compact: -$((11-${#3}))}" "$3"
}

stable_vhost_link() {
    printf '%s/%s-sf%s\n' "$STABLE_DEV_DIR" "$(pci_token "$1")" "$2"
}

remove_stable_vhost_link() {
    local link="$1"
    if [[ -L "$link" ]]; then
        rm -f -- "$link"
    elif [[ -e "$link" ]]; then
        warn "Refusing to remove $link because it is not a symbolic link."
        return 1
    fi
}

valid_mac() {
    [[ "${1,,}" =~ ^[[:xdigit:]]{2}(:[[:xdigit:]]{2}){5}$ ]] || return 1
    [[ "${1,,}" != 00:00:00:00:00:00 ]] || return 1
    local first="${1%%:*}"
    (( (16#$first & 1) == 0 ))
}

usable_vm_mac() {
    valid_mac "$1"
}

get_pf_base_mac() {
    local iface="$1" mac=""
    if command_exists ethtool; then
        mac=$(ethtool -P "$iface" 2>/dev/null |
            awk -F': ' '/Permanent address:/{print tolower($2); exit}' || true)
    fi
    if ! valid_mac "$mac"; then
        mac=$(tr '[:upper:]' '[:lower:]' \
            <"$SYSFS_ROOT/class/net/$iface/address" 2>/dev/null || true)
    fi
    valid_mac "$mac" || return 1
    printf '%s\n' "$mac"
}

derive_sf_oui_mac() {
    local iface="$1" sfnum="$2" mac o1 o2 o3 o4 o5 _o6 i4 suffix
    (( sfnum >= 0 && sfnum <= 255 )) || return 1
    mac=$(get_pf_base_mac "$iface") || return 1
    IFS=: read -r o1 o2 o3 o4 o5 _o6 <<<"$mac"
    printf -v i4 '%02x' "$((16#$o4 ^ 0xff))"
    printf -v suffix '%02x' "$sfnum"
    # VF option 2 inverts PF octets 4 and 5. SF option 2 inverts only
    # octet 4 and keeps octet 5, creating a separate deterministic space.
    printf '%s:%s:%s:%s:%s:%s\n' "$o1" "$o2" "$o3" "$i4" "$o5" "$suffix"
}

derive_prefix_mac() {
    local prefix="${1,,}" sfnum="$2" suffix
    [[ "$prefix" =~ ^[[:xdigit:]]{2}(:[[:xdigit:]]{2}){4}$ ]] || return 1
    (( sfnum >= 0 && sfnum <= 255 )) || return 1
    printf -v suffix '%02x' "$sfnum"
    valid_mac "$prefix:$suffix" || return 1
    printf '%s:%s\n' "$prefix" "$suffix"
}

config_path_for() {
    printf '%s/sf-nic.conf.%s.sf%s\n' "$CONFIG_DIR" "$(pci_token "$1")" "$2"
}

reset_config_vars() {
    PF_PCI=""; PF_DEV=""; PFNUM=""; SF_CONTROLLER=0; SF_NUM=""
    SF_MAC=""; SF_MAC_MODE=explicit; SF_PREFIX=""; VDPA_NAME=""
    VDPA_MAX_VQP=4; VDPA_MTU=1500; REP_NAME=""; PVE_VMID=""
    CONFIG_FILE=""
}

load_sf_config() {
    local file="$1"
    [[ -f "$file" ]] || die "SF configuration '$file' was not found."
    reset_config_vars
    unset PF_PCI SF_CONTROLLER SF_NUM SF_MAC SF_MAC_MODE SF_PREFIX
    unset VDPA_NAME VDPA_MAX_VQP VDPA_MTU REP_NAME PVE_VMID
    # Config files are trusted shell fragments, like sriov-nic.conf files.
    # shellcheck source=/dev/null
    source "$file"
    : "${PF_PCI:?PF_PCI is not set in $file}"
    : "${SF_NUM:?SF_NUM is not set in $file}"
    SF_CONTROLLER="${SF_CONTROLLER:-0}"
    SF_MAC="${SF_MAC:-}"
    SF_MAC_MODE="${SF_MAC_MODE:-explicit}"
    SF_PREFIX="${SF_PREFIX:-}"
    VDPA_MAX_VQP="${VDPA_MAX_VQP:-4}"
    VDPA_MTU="${VDPA_MTU:-1500}"
    PVE_VMID="${PVE_VMID:-}"
    CONFIG_FILE="$file"
}

save_sf_config() {
    local file="${1:-$(config_path_for "$PF_PCI" "$SF_NUM")}" directory tmp
    directory=$(dirname "$file")
    mkdir -p "$directory" || return 1
    tmp=$(mktemp "$directory/.sf-nic.conf.XXXXXX") || return 1
    if ! {
        echo "# Generated by $SCRIPT_NAME on $(date -Is)"
        printf 'PF_PCI=%q\n' "$PF_PCI"
        printf 'SF_CONTROLLER=%q\n' "$SF_CONTROLLER"
        printf 'SF_NUM=%q\n' "$SF_NUM"
        printf 'SF_MAC_MODE=%q\n' "$SF_MAC_MODE"
        printf 'SF_PREFIX=%q\n' "$SF_PREFIX"
        printf 'SF_MAC=%q\n' "$SF_MAC"
        printf 'VDPA_NAME=%q\n' "$VDPA_NAME"
        printf 'VDPA_MAX_VQP=%q\n' "$VDPA_MAX_VQP"
        printf 'VDPA_MTU=%q\n' "$VDPA_MTU"
        printf 'REP_NAME=%q\n' "$REP_NAME"
        printf 'PVE_VMID=%q\n' "$PVE_VMID"
    } >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! chmod 0644 "$tmp" || ! mv -f -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 1
    fi
    CONFIG_FILE="$file"
    echo "Saved SF configuration to $file"
}

offer_boot_service() {
    local config_real installer="$SCRIPT_DIR/set-systemd-service.sh"
    config_real=$(readlink -f "$CONFIG_DIR" 2>/dev/null || true)
    [[ "$config_real" == "$SCRIPT_DIR" ]] || return 0
    [[ -x "$installer" ]] || { warn "$installer is unavailable; boot restoration was not installed."; return 0; }
    if prompt_yes_no "Install/update and enable sriov-nic.service for these SFs?" no; then
        if ! "$installer" --enable; then
            warn "SF configuration succeeded, but sriov-nic.service could not be installed/enabled."
        fi
    fi
}

find_managed_config() {
    local wanted_pci="$1" wanted_sf="$2" file cpci csf
    shopt -s nullglob
    for file in "$CONFIG_DIR"/sf-nic.conf*; do
        [[ -f "$file" ]] || continue
        cpci=""; csf=""
        cpci=$(
            set +u
            unset PF_PCI SF_NUM
            # shellcheck source=/dev/null
            source "$file" >/dev/null 2>&1 || exit 1
            [[ -n "${PF_PCI:-}" && -n "${SF_NUM:-}" ]] || exit 1
            printf '%s\n' "$(normalize_pci "$PF_PCI")"
        ) || continue
        csf=$(
            set +u
            unset SF_NUM
            # shellcheck source=/dev/null
            source "$file" >/dev/null 2>&1 || exit 1
            printf '%s\n' "${SF_NUM:-}"
        ) || continue
        if [[ "$cpci" == "$wanted_pci" && "$csf" == "$wanted_sf" ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    return 1
}

validate_config_values() {
    PF_PCI=$(normalize_pci "$PF_PCI")
    [[ "$PF_PCI" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]] ||
        die "Invalid PF PCI address '$PF_PCI'."
    [[ -d "$SYSFS_ROOT/bus/pci/devices/$PF_PCI" ]] ||
        die "PCI device $PF_PCI does not exist."
    [[ "$(get_driver "$PF_PCI")" == mlx5_core ]] ||
        die "$PF_PCI is not bound to mlx5_core; upstream mlx5 SF management is unavailable."

    PF_DEV=$(get_pf_netdev "$PF_PCI" || true)
    [[ -n "$PF_DEV" ]] || die "No physical netdev was found for $PF_PCI."
    PFNUM=$((16#${PF_PCI##*.}))

    [[ "$SF_CONTROLLER" =~ ^[0-9]+$ ]] || die "SF_CONTROLLER must be a non-negative integer."
    [[ "$SF_NUM" =~ ^[0-9]+$ ]] || die "SF_NUM must be a non-negative integer."
    SF_CONTROLLER=$((10#$SF_CONTROLLER))
    SF_NUM=$((10#$SF_NUM))
    (( SF_CONTROLLER == 0 )) ||
        die "Only local controller 0 is supported by this SF manager."
    (( SF_NUM <= 65535 )) || die "SF_NUM is too large."

    SF_MAC_MODE="${SF_MAC_MODE,,}"
    case "$SF_MAC_MODE" in
        none|off)
            SF_MAC_MODE=none
            SF_MAC=""
            ;;
        pf-oui-invert-one|oui-invert-one|pf-oui-sf)
            SF_MAC_MODE="pf-oui-invert-one"
            SF_MAC=$(derive_sf_oui_mac "$PF_DEV" "$SF_NUM") ||
                die "Could not derive the option-2 SF MAC; this mode supports SF numbers 0-255."
            ;;
        generated|generate)
            SF_MAC_MODE=generated
            SF_PREFIX="${SF_PREFIX,,}"
            SF_MAC=$(derive_prefix_mac "$SF_PREFIX" "$SF_NUM") ||
                die "SF_PREFIX must contain five MAC octets and generated mode supports SF numbers 0-255."
            ;;
        explicit|adopted)
            [[ -n "$SF_MAC" ]] || die "SF_MAC is required for SF_MAC_MODE=$SF_MAC_MODE."
            SF_MAC="${SF_MAC,,}"
            valid_mac "$SF_MAC" || die "Invalid or multicast SF MAC '$SF_MAC'."
            ;;
        *)
            die "SF_MAC_MODE must be none, pf-oui-invert-one, generated, explicit, or adopted."
            ;;
    esac
    [[ "$VDPA_MAX_VQP" =~ ^[0-9]+$ ]] || die "VDPA_MAX_VQP must be an integer."
    VDPA_MAX_VQP=$((10#$VDPA_MAX_VQP))
    (( VDPA_MAX_VQP >= 1 && VDPA_MAX_VQP <= 32 )) ||
        die "VDPA_MAX_VQP must be between 1 and 32."
    [[ "$VDPA_MTU" =~ ^[0-9]+$ ]] || die "VDPA_MTU must be an integer."
    VDPA_MTU=$((10#$VDPA_MTU))
    (( VDPA_MTU >= 68 && VDPA_MTU <= 65535 )) ||
        die "VDPA_MTU must be between 68 and 65535."
    [[ -z "$PVE_VMID" || "$PVE_VMID" =~ ^[1-9][0-9]*$ ]] ||
        die "PVE_VMID must be empty or a positive integer."

    [[ -n "$VDPA_NAME" ]] || VDPA_NAME=$(default_vdpa_name "$PF_PCI" "$SF_NUM")
    [[ "$VDPA_NAME" =~ ^[[:alnum:]_.-]+$ ]] || die "Invalid vDPA name '$VDPA_NAME'."
    [[ -n "$REP_NAME" ]] || REP_NAME=$(default_rep_name "$PF_DEV" "$PF_PCI" "$SF_NUM")
    [[ "$REP_NAME" =~ ^[[:alnum:]_.-]{1,15}$ ]] ||
        die "Invalid representor name '$REP_NAME' (Linux limit is 15 characters)."
}

require_sf_tools() {
    local m kernel_config
    kernel_config="$SYSFS_ROOT/../boot/config-$(uname -r)"
    command_exists devlink || die "The 'devlink' command is required."
    command_exists vdpa || die "The 'vdpa' command is required."
    command_exists ip || die "The 'ip' command is required."
    command_exists modprobe || die "The 'modprobe' command is required."
    command_exists modinfo || die "The 'modinfo' command is required."
    command_exists timeout || die "The 'timeout' command is required."

    # /boot is outside a mocked SYSFS_ROOT in tests; prefer the real path when
    # available. Absence of a readable config is not fatal because distro
    # kernels may omit it and runtime devlink remains authoritative.
    [[ -r "$kernel_config" ]] || kernel_config="/boot/config-$(uname -r)"
    if [[ -r "$kernel_config" ]] &&
       ! grep -qE '^CONFIG_MLX5_SF=(y|m)$' "$kernel_config"; then
        die "The running kernel was built without CONFIG_MLX5_SF."
    fi
    for m in mlx5_vdpa vhost_vdpa; do
        modinfo "$m" >/dev/null 2>&1 || die "Kernel module '$m' is unavailable."
    done
    if ! compgen -G "$SYSFS_ROOT/kernel/iommu_groups/*" >/dev/null; then
        die "No IOMMU groups were found. Enable the platform IOMMU before using hardware vDPA."
    fi
    if [[ ! -e "$SYSFS_ROOT/bus/pci/devices/$PF_PCI/iommu_group" ]]; then
        die "$PF_PCI has no IOMMU group even though other groups exist; hardware vDPA is not safe to configure on this PF."
    fi
}

firmware_query() {
    local pci="$1" tool output found=false
    FW_QUERY_OUTPUT=""
    if [[ -n "${FW_QUERY_CACHE[$pci]+x}" ]]; then
        FW_QUERY_OUTPUT="${FW_QUERY_CACHE[$pci]}"
        return 0
    fi
    for tool in mlxconfig mstconfig; do
        command_exists "$tool" || continue
        found=true
        if output=$(timeout "${SF_FW_QUERY_TIMEOUT:-10}" "$tool" -d "$pci" query 2>/dev/null); then
            FW_QUERY_CACHE[$pci]="$output"
            FW_QUERY_OUTPUT="$output"
            return 0
        fi
    done
    [[ "$found" == true ]] || return 2
    return 1
}

firmware_field() {
    awk -v key="$2" '$1==key {print $2; exit}' <<<"$1"
}

count_runtime_sfs() {
    local pci="$1"
    devlink port show 2>/dev/null | awk -v prefix="pci/$pci/" '
        index($1, prefix) == 1 && $0 ~ /flavour pcisf/ {count++}
        END {print count + 0}'
}

check_firmware_sf_capacity() {
    local output per_pf total bar_size bar2 rc current_count port
    if firmware_query "$PF_PCI"; then
        output="$FW_QUERY_OUTPUT"
    else
        rc=$?
        case "$rc" in
            2) warn "mlxconfig/mstconfig is unavailable; firmware SF allocation cannot be inspected. Runtime devlink capability will be authoritative." ;;
            *) warn "Could not query persistent firmware settings for $PF_PCI; runtime devlink capability will be authoritative." ;;
        esac
        return 0
    fi
    per_pf=$(firmware_field "$output" PER_PF_NUM_SF || true)
    total=$(firmware_field "$output" PF_TOTAL_SF || true)
    bar_size=$(firmware_field "$output" PF_SF_BAR_SIZE || true)
    bar2=$(firmware_field "$output" PF_BAR2_ENABLE || true)

    echo "    Firmware SF allocation: PER_PF_NUM_SF=${per_pf:-unknown}, PF_TOTAL_SF=${total:-unknown}, PF_SF_BAR_SIZE=${bar_size:-unknown}, PF_BAR2_ENABLE=${bar2:-unknown}"
    if [[ -z "$per_pf" && -z "$total" && -z "$bar_size" ]]; then
        warn "The firmware query exposes no SF allocation fields. This device may predate mlx5 SF support; runtime devlink creation will be authoritative."
    fi
    if [[ -n "$per_pf" && ! "$per_pf" =~ ^(True|true|1)(\(1\))?$ ]]; then
        die "Firmware PER_PF_NUM_SF is not enabled. sriov-nic only detects firmware settings; it does not modify them."
    fi
    if [[ "$total" =~ ^[0-9]+$ ]]; then
        total=$((10#$total))
        (( total > 0 )) ||
            die "Firmware PF_TOTAL_SF is zero. Configure SF resources externally and cold power-cycle the host."
        port=$(get_sf_port "$PF_PCI" "$PFNUM" "$SF_NUM" || true)
        if [[ -z "$port" ]]; then
            current_count=$(count_runtime_sfs "$PF_PCI")
            (( current_count < total )) ||
                die "$PF_PCI already has $current_count SF(s), exhausting firmware PF_TOTAL_SF=$total."
        fi
    fi
    if [[ "$bar_size" =~ ^[0-9]+$ ]] && (( 10#$bar_size == 0 )); then
        die "Firmware PF_SF_BAR_SIZE is zero. Configure SF resources externally and cold power-cycle the host."
    fi
    if [[ -n "$bar2" && ! "$bar2" =~ ^(False|false|0)(\(0\))?$ ]]; then
        warn "PF_BAR2_ENABLE is $bar2. This may be valid for some firmware profiles; devlink creation will determine runtime support."
    fi
}

preflight_switchdev() {
    local info mode current_vfs=0
    info=$(get_eswitch_info "$PF_PCI") || die "$PF_PCI does not expose a devlink e-switch."
    mode=$(get_eswitch_mode "$info")
    [[ "$mode" == switchdev ]] && return 0
    if [[ -r "$SYSFS_ROOT/bus/pci/devices/$PF_PCI/sriov_numvfs" ]]; then
        current_vfs=$(<"$SYSFS_ROOT/bus/pci/devices/$PF_PCI/sriov_numvfs")
    fi
    if (( 10#$current_vfs > 0 )); then
        die "$PF_PCI is in $mode mode with $current_vfs active VFs. Stop users, remove VFs, and switch to switchdev first."
    fi
    echo "    E-switch plan: $mode -> switchdev (SFs require switchdev)"
}

ensure_switchdev() {
    local info mode
    info=$(get_eswitch_info "$PF_PCI") || die "$PF_PCI does not expose a devlink e-switch."
    mode=$(get_eswitch_mode "$info")
    [[ "$mode" == switchdev ]] && return 0
    preflight_switchdev
    echo "Switching $PF_PCI e-switch from $mode to switchdev..."
    devlink dev eswitch set "pci/$PF_PCI" mode switchdev
    if [[ "$TX_ACTIVE" == true ]]; then
        TX_SWITCHED_PFS+=("$PF_PCI|$mode")
    fi
}

preflight_batch_capacity() {
    local requested="$1" output total current
    if ! firmware_query "$PF_PCI"; then
        return 0
    fi
    output="$FW_QUERY_OUTPUT"
    total=$(firmware_field "$output" PF_TOTAL_SF || true)
    [[ "$total" =~ ^[0-9]+$ ]] || return 0
    total=$((10#$total))
    current=$(count_runtime_sfs "$PF_PCI")
    (( current + requested <= total )) ||
        die "Batch requests $requested new SF(s), but $PF_PCI has $current/$total firmware-allocated SF slots in use."
}

ensure_vnet_personality() {
    local sfdev="$1" changed=false reloaded=false current_vdpa name wanted current
    local -a changed_names=() old_values=()

    modprobe mlx5_vdpa
    modprobe vhost_vdpa

    # Never change staged driverinit values or reload a live vDPA device.
    current_vdpa=$(get_sf_vdpa_name "$sfdev" || true)
    if [[ -n "$current_vdpa" ]]; then
        for spec in enable_eth:false enable_rdma:false enable_roce:false enable_vnet:true; do
            name="${spec%%:*}"; wanted="${spec##*:}"
            if devlink dev param show "$sfdev" name "$name" >/dev/null 2>&1; then
                current=$(get_param_driverinit "$sfdev" "$name" || true)
                [[ "$current" == "$wanted" ]] ||
                    die "$sfdev owns live vDPA $current_vdpa but $name=${current:-unknown}, expected $wanted; refusing to stage a disruptive change."
            elif [[ "$name" == enable_vnet ]]; then
                die "$sfdev owns vDPA $current_vdpa but no longer exposes enable_vnet."
            fi
        done
        return 0
    fi

    for spec in enable_eth:false enable_rdma:false enable_roce:false enable_vnet:true; do
        name="${spec%%:*}"; wanted="${spec##*:}"
        if ! devlink dev param show "$sfdev" name "$name" >/dev/null 2>&1; then
            if [[ "$name" == enable_vnet ]]; then
                restore_driverinit_params "$sfdev" changed_names old_values
                die "$sfdev does not expose enable_vnet; this mlx5 firmware/driver cannot provide SF-backed vDPA."
            fi
            continue
        fi
        current=$(get_param_driverinit "$sfdev" "$name" || true)
        if [[ -z "$current" ]]; then
            restore_driverinit_params "$sfdev" changed_names old_values
            die "Could not read driverinit value for $name on $sfdev."
        fi
        [[ "$current" == "$wanted" ]] && continue
        echo "    $name: $current -> $wanted"
        if ! devlink dev param set "$sfdev" name "$name" value "$wanted" cmode driverinit; then
            restore_driverinit_params "$sfdev" changed_names old_values
            die "Could not set $name=$wanted on $sfdev; earlier staged values were restored."
        fi
        changed_names+=("$name")
        old_values+=("$current")
        changed=true
    done

    if [[ "$changed" == true ]]; then
        echo "Reloading $sfdev to activate its vDPA personality..."
        if ! devlink dev reload "$sfdev" action driver_reinit; then
            restore_driverinit_params "$sfdev" changed_names old_values
            die "Could not reload $sfdev; its staged personality values were restored."
        fi
        settle_devices
        reloaded=true
    fi

    if ! vdpa mgmtdev show "$sfdev" >/dev/null 2>&1; then
        [[ -z "$current_vdpa" ]] || return 0
        if [[ "$reloaded" != true ]]; then
            echo "Reloading $sfdev once to register the mlx5 vDPA management device..."
            devlink dev reload "$sfdev" action driver_reinit
            settle_devices
        fi
    fi
    if ! vdpa mgmtdev show "$sfdev" >/dev/null 2>&1; then
        if (( ${#changed_names[@]} > 0 )); then
            restore_driverinit_params "$sfdev" changed_names old_values
            if [[ "$reloaded" == true ]]; then
                devlink dev reload "$sfdev" action driver_reinit >/dev/null 2>&1 ||
                    warn "Could not reload $sfdev after restoring its original personality."
            fi
        fi
        die "$sfdev did not register as a vDPA management device."
    fi
}

preflight_representor_name() {
    local port="$1" current master=""
    current=$(get_sf_field "$port" netdev || true)
    [[ -n "$current" ]] || die "No representor netdev was found for $port."
    [[ "$current" == "$REP_NAME" ]] && return 0
    [[ ! -e "$SYSFS_ROOT/class/net/$REP_NAME" ]] ||
        die "Cannot rename SF $SF_NUM representor $current to $REP_NAME: the target name already exists."
    if [[ -L "$SYSFS_ROOT/class/net/$current/master" ]]; then
        master=$(basename "$(readlink -f "$SYSFS_ROOT/class/net/$current/master")")
        die "Cannot rename SF $SF_NUM representor $current while it belongs to ${master:-a bridge/OVS master}. Detach it first."
    fi
}

rename_representor() {
    local port="$1" current target="$REP_NAME" was_up=false master=""
    current=$(get_sf_field "$port" netdev || true)
    [[ -n "$current" ]] || die "No representor netdev was found for $port."
    if [[ "$current" == "$target" ]]; then
        ip link set dev "$target" alias "sriov-nic PF $PF_PCI SF $SF_NUM representor" 2>/dev/null || true
        ENSURE_REP_NAME="$target"
        return 0
    fi
    if [[ -e "$SYSFS_ROOT/class/net/$target" ]]; then
        die "Cannot rename SF $SF_NUM representor $current to $target: the target name already exists."
    fi
    if [[ -L "$SYSFS_ROOT/class/net/$current/master" ]]; then
        master=$(basename "$(readlink -f "$SYSFS_ROOT/class/net/$current/master")")
        die "Cannot rename SF $SF_NUM representor $current while it belongs to ${master:-a bridge/OVS master}. Detach it first."
    fi
    if ip -o link show dev "$current" | grep -qE '(<|,)UP(,|>)'; then
        was_up=true
    fi
    echo "Renaming SF $SF_NUM representor: $current -> $target"
    ip link set dev "$current" down
    if ! ip link set dev "$current" name "$target"; then
        if [[ "$was_up" == true ]]; then
            ip link set dev "$current" up || true
        fi
        die "Could not give SF $SF_NUM representor its stable name $target."
    fi
    ip link set dev "$target" alias "sriov-nic PF $PF_PCI SF $SF_NUM representor" 2>/dev/null || true
    if [[ "$was_up" == true ]]; then
        ip link set dev "$target" up || true
    fi
    ENSURE_REP_NAME="$target"
}

find_vhost_node() {
    local vdpa_name="$1" vdpa_path path node
    vdpa_path=$(readlink -f "$SYSFS_ROOT/bus/vdpa/devices/$vdpa_name" 2>/dev/null || true)
    [[ -n "$vdpa_path" && -d "$vdpa_path" ]] || return 1
    for path in "$vdpa_path"/vhost-vdpa-* "$vdpa_path"/*/vhost-vdpa-*; do
        [[ -e "$path" ]] || continue
        node=$(basename "$path")
        [[ -e "$DEV_ROOT/$node" ]] || continue
        printf '%s\n' "$DEV_ROOT/$node"
        return 0
    done
    return 1
}

create_stable_vhost_link() {
    local vdpa_name="$1" node link attempt
    for ((attempt=1; attempt<=40; attempt++)); do
        node=$(find_vhost_node "$vdpa_name" || true)
        [[ -n "$node" ]] && break
        sleep 0.25
    done
    [[ -n "${node:-}" ]] || die "No /dev/vhost-vdpa device appeared for $vdpa_name."
    mkdir -p "$STABLE_DEV_DIR"
    link=$(stable_vhost_link "$PF_PCI" "$SF_NUM")
    if [[ -e "$link" && ! -L "$link" ]]; then
        die "Stable vhost path $link exists but is not a symbolic link."
    fi
    ln -sfnT "$node" "$link"
    printf '%s\n' "$link"
}

ensure_vdpa_device() {
    local sfdev="$1" existing_by_name="" existing_for_sf="" mgmt config_mac config_vqp config_mtu
    local mgmt_info max_vqs required_vqs
    local -a args

    existing_for_sf=$(get_sf_vdpa_name "$sfdev" || true)
    if vdpa dev show "$VDPA_NAME" >/dev/null 2>&1; then
        existing_by_name="$VDPA_NAME"
        mgmt=$(get_vdpa_mgmtdev "$VDPA_NAME" || true)
        [[ "$mgmt" == "$sfdev" ]] ||
            die "vDPA name $VDPA_NAME already belongs to ${mgmt:-another management device}."
    fi
    if [[ -n "$existing_for_sf" && "$existing_for_sf" != "$VDPA_NAME" ]]; then
        die "$sfdev already owns vDPA device $existing_for_sf, but the config requests $VDPA_NAME. Adopt the existing device or delete it first."
    fi

    if [[ -z "$existing_by_name" ]]; then
        mgmt_info=$(vdpa mgmtdev show "$sfdev" 2>/dev/null || true)
        max_vqs=$(awk '{for (i=1; i<=NF; i++) if ($i=="max_supported_vqs") {print $(i+1); exit}}' <<<"$mgmt_info")
        required_vqs=$((2 * VDPA_MAX_VQP + 1))
        if [[ "$max_vqs" =~ ^[0-9]+$ ]] && (( required_vqs > 10#$max_vqs )); then
            die "$sfdev supports $max_vqs virtqueues, but VDPA_MAX_VQP=$VDPA_MAX_VQP requires $required_vqs."
        fi
        args=(dev add name "$VDPA_NAME" mgmtdev "$sfdev")
        [[ -n "$SF_MAC" ]] && args+=(mac "$SF_MAC")
        args+=(mtu "$VDPA_MTU" max_vqp "$VDPA_MAX_VQP")
        echo "Creating hardware vDPA device $VDPA_NAME (VQP=$VDPA_MAX_VQP, MTU=$VDPA_MTU)..."
        vdpa "${args[@]}"
        if [[ "$TX_ACTIVE" == true ]]; then
            TX_NEW_VDPAS+=("$PF_PCI|$SF_NUM|$VDPA_NAME")
        fi
    fi

    config_mac=$(get_vdpa_config_field "$VDPA_NAME" mac || true)
    config_vqp=$(get_vdpa_config_field "$VDPA_NAME" max_vq_pairs || true)
    config_mtu=$(get_vdpa_config_field "$VDPA_NAME" mtu || true)
    if [[ -n "$SF_MAC" && "${config_mac,,}" != "$SF_MAC" ]]; then
        die "$VDPA_NAME has MAC ${config_mac:-unknown}, expected $SF_MAC."
    fi
    [[ "$config_vqp" == "$VDPA_MAX_VQP" ]] ||
        die "$VDPA_NAME has max_vq_pairs=${config_vqp:-unknown}, expected $VDPA_MAX_VQP."
    [[ "$config_mtu" == "$VDPA_MTU" ]] ||
        die "$VDPA_NAME has MTU=${config_mtu:-unknown}, expected $VDPA_MTU."

    ENSURE_VDPA_NODE=$(create_stable_vhost_link "$VDPA_NAME")
}

ensure_sf_runtime() {
    local port state current_mac sfdev
    ENSURE_VDPA_NODE=""
    ENSURE_REP_NAME=""

    require_sf_tools
    check_firmware_sf_capacity
    ensure_switchdev

    port=$(get_sf_port "$PF_PCI" "$PFNUM" "$SF_NUM" || true)
    if [[ -z "$port" ]]; then
        local -a add_args=(port add "pci/$PF_PCI" flavour pcisf)
        if (( SF_CONTROLLER != 0 )); then
            add_args+=(controller "$SF_CONTROLLER")
        fi
        add_args+=(pfnum "$PFNUM" sfnum "$SF_NUM")
        echo "Creating SF $SF_NUM on $PF_PCI (pfnum $PFNUM)..."
        devlink "${add_args[@]}"
        if [[ "$TX_ACTIVE" == true ]]; then
            TX_NEW_SFS+=("$PF_PCI|$SF_NUM")
        fi
        port=$(get_sf_port "$PF_PCI" "$PFNUM" "$SF_NUM" || true)
        [[ -n "$port" ]] || die "devlink accepted SF $SF_NUM, but its port could not be found."
    else
        echo "Reusing existing SF $SF_NUM at $port."
    fi
    # Check naming conflicts before changing an existing SF's MAC/person/personality.
    preflight_representor_name "$port"
    current_mac=$(get_sf_field "$port" hw_addr || true)
    current_mac="${current_mac,,}"
    if [[ -n "$SF_MAC" && "$current_mac" != "$SF_MAC" ]]; then
        state=$(get_sf_field "$port" state || true)
        if [[ "$state" == active ]]; then
            die "Existing active SF $SF_NUM has MAC ${current_mac:-unknown}, expected $SF_MAC. Delete/recreate it or adopt its current MAC."
        fi
        echo "Setting SF $SF_NUM function MAC to $SF_MAC..."
        devlink port function set "$port" hw_addr "$SF_MAC"
    fi

    state=$(get_sf_field "$port" state || true)
    if [[ "$state" != active ]]; then
        echo "Activating SF $SF_NUM..."
        devlink port function set "$port" state active
    fi
    sfdev=$(wait_for_sf_nested_devlink "$port" || true)
    [[ -n "$sfdev" ]] || die "SF $SF_NUM did not attach an auxiliary mlx5_core.sf device."
    ensure_vnet_personality "$sfdev"
    ensure_vdpa_device "$sfdev"
    rename_representor "$port"

    state=$(get_sf_field "$port" opstate || true)
    [[ "$state" == attached ]] || die "SF $SF_NUM opstate is ${state:-unknown}, expected attached."
    echo ">>> SF $SF_NUM ready: representor=$ENSURE_REP_NAME, vDPA=$VDPA_NAME, vhost=$ENSURE_VDPA_NODE"
}

node_is_open() {
    local node="$1" fd target
    if command_exists fuser; then
        fuser "$node" >/dev/null 2>&1
        return
    fi
    for fd in /proc/[0-9]*/fd/*; do
        [[ -e "$fd" ]] || continue
        target=$(readlink -f "$fd" 2>/dev/null || true)
        [[ "$target" == "$node" ]] && return 0
    done
    return 1
}

assert_runtime_sf_not_busy() {
    local pci="$1" sfnum="$2" pfnum port sfdev vdpa_name node referenced_vm
    pfnum=$((16#${pci##*.}))
    port=$(get_sf_port "$pci" "$pfnum" "$sfnum" || true)
    [[ -n "$port" ]] || return 0
    sfdev=$(get_sf_nested_devlink "$port" || true)
    vdpa_name=""
    [[ -n "$sfdev" ]] && vdpa_name=$(get_sf_vdpa_name "$sfdev" || true)
    [[ -n "$vdpa_name" ]] || return 0
    node=$(find_vhost_node "$vdpa_name" || true)
    if [[ -n "$node" ]]; then
        referenced_vm=$(find_other_vm_for_link "" "$node" || true)
        [[ -z "$referenced_vm" ]] ||
            die "$node is still referenced by Proxmox VM $referenced_vm."
        if node_is_open "$node"; then
            die "$node is open by a process; stop its VM before deleting SF $sfnum."
        fi
    fi
}

cleanup_one_runtime_sf() {
    local pci="$1" sfnum="$2" pfnum port sfdev vdpa_name link
    pfnum=$((16#${pci##*.}))
    port=$(get_sf_port "$pci" "$pfnum" "$sfnum" || true)
    [[ -n "$port" ]] || return 0
    sfdev=$(get_sf_nested_devlink "$port" || true)
    vdpa_name=""
    [[ -n "$sfdev" ]] && vdpa_name=$(get_sf_vdpa_name "$sfdev" || true)
    if [[ -n "$vdpa_name" ]]; then
        timeout 10 vdpa dev del "$vdpa_name" || return 1
    fi
    link=$(stable_vhost_link "$pci" "$sfnum")
    # Preserve a conflicting ordinary file, but never let it prevent cleanup
    # of an SF that this failed transaction just created.
    remove_stable_vhost_link "$link" || true
    devlink port function set "$port" state inactive 2>/dev/null || true
    wait_for_sf_detached "$port" || warn "SF $sfnum did not report detached during rollback; attempting deletion anyway."
    devlink port del "$port"
}

rollback_transaction() {
    local i entry pci sf name link
    [[ "$TX_ACTIVE" == true ]] || return 0
    warn "Rolling back resources created by this operation..."
    for ((i=${#TX_NEW_VDPAS[@]}-1; i>=0; i--)); do
        entry="${TX_NEW_VDPAS[$i]}"
        pci="${entry%%|*}"
        entry="${entry#*|}"
        sf="${entry%%|*}"
        name="${entry#*|}"
        if vdpa dev show "$name" >/dev/null 2>&1; then
            timeout 10 vdpa dev del "$name" || warn "Could not roll back vDPA device $name."
        fi
        link=$(stable_vhost_link "$pci" "$sf")
        remove_stable_vhost_link "$link" || true
    done
    for ((i=${#TX_NEW_SFS[@]}-1; i>=0; i--)); do
        entry="${TX_NEW_SFS[$i]}"
        pci="${entry%|*}"; sf="${entry##*|}"
        cleanup_one_runtime_sf "$pci" "$sf" || warn "Could not fully roll back $pci SF $sf."
    done
    for entry in "${TX_NEW_CONFIGS[@]}"; do
        rm -f -- "$entry"
    done
    for ((i=${#TX_SWITCHED_PFS[@]}-1; i>=0; i--)); do
        entry="${TX_SWITCHED_PFS[$i]}"
        pci="${entry%|*}"
        name="${entry##*|}"
        if [[ "$(count_runtime_sfs "$pci")" == 0 ]]; then
            devlink dev eswitch set "pci/$pci" mode "$name" ||
                warn "Could not restore $pci e-switch mode to $name."
        fi
    done
}

on_exit() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 )) && [[ "$TX_ACTIVE" == true ]]; then
        rollback_transaction
    fi
    exit "$rc"
}

apply_sf_config() {
    local file="$1" own_port
    load_sf_config "$file"
    validate_config_values
    if [[ -n "$SF_MAC" ]]; then
        own_port=$(get_sf_port "$PF_PCI" "$PFNUM" "$SF_NUM" || true)
        mac_conflicts "$SF_MAC" "$own_port" &&
            die "SF MAC $SF_MAC from $file is already used outside its own SF."
    fi
    echo ">>> Applying SF configuration: $file"
    TX_ACTIVE=true
    TX_NEW_SFS=()
    TX_NEW_VDPAS=()
    TX_NEW_CONFIGS=()
    TX_SWITCHED_PFS=()
    ensure_sf_runtime
    TX_ACTIVE=false
}

apply_all_sf_configs() {
    local dir="${1:-$CONFIG_DIR}" file key own_port pci output total current requested
    local -a files
    local -A seen_sf=() seen_vdpa=() seen_mac=() checked_pf=() requested_new=()
    [[ -d "$dir" ]] || die "SF configuration directory '$dir' does not exist."
    dir=$(cd "$dir" && pwd -P)
    CONFIG_DIR="$dir"
    shopt -s nullglob
    files=("$dir"/sf-nic.conf*)
    if (( ${#files[@]} == 0 )); then
        echo "No sf-nic.conf* files found in $dir; no SFs to restore."
        return 0
    fi

    # Validate the whole set before creating the first device. This catches
    # duplicate identities and deterministic MAC collisions transaction-free.
    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        load_sf_config "$file"
        validate_config_values
        key="$PF_PCI|$SF_CONTROLLER|$SF_NUM"
        [[ -z "${seen_sf[$key]+x}" ]] ||
            die "Duplicate managed SF identity $key in $file and ${seen_sf[$key]}."
        seen_sf[$key]="$file"
        own_port=$(get_sf_port "$PF_PCI" "$PFNUM" "$SF_NUM" || true)
        if [[ -z "$own_port" ]]; then
            requested_new[$PF_PCI]=$(( ${requested_new[$PF_PCI]:-0} + 1 ))
        fi
        if [[ -z "${checked_pf[$PF_PCI]+x}" ]]; then
            require_sf_tools
            preflight_switchdev
            check_firmware_sf_capacity
            checked_pf[$PF_PCI]=1
        fi
        [[ -z "${seen_vdpa[$VDPA_NAME]+x}" ]] ||
            die "Duplicate VDPA_NAME=$VDPA_NAME in $file and ${seen_vdpa[$VDPA_NAME]}."
        seen_vdpa[$VDPA_NAME]="$file"
        if [[ -n "$SF_MAC" ]]; then
            [[ -z "${seen_mac[$SF_MAC]+x}" ]] ||
                die "Duplicate SF MAC $SF_MAC in $file and ${seen_mac[$SF_MAC]}."
            seen_mac[$SF_MAC]="$file"
            mac_conflicts "$SF_MAC" "$own_port" &&
                die "SF MAC $SF_MAC from $file is already used outside its own SF."
        fi
    done

    for pci in "${!requested_new[@]}"; do
        requested="${requested_new[$pci]}"
        if firmware_query "$pci"; then
            output="$FW_QUERY_OUTPUT"
            total=$(firmware_field "$output" PF_TOTAL_SF || true)
            if [[ "$total" =~ ^[0-9]+$ ]]; then
                total=$((10#$total))
                current=$(count_runtime_sfs "$pci")
                (( current + requested <= total )) ||
                    die "Saved configs request $requested new SF(s) on $pci, but $current/$total firmware-allocated slots are already in use."
            fi
        fi
    done

    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        echo "============================================================"
        apply_sf_config "$file"
    done
}

pve_args_fragment() {
    local id vectors link device_args
    id="snc$(compact_pci_token "$PF_PCI")s$SF_NUM"
    link=$(stable_vhost_link "$PF_PCI" "$SF_NUM")
    device_args="virtio-net-pci,id=${id}dev,netdev=${id},mac=${SF_MAC}"
    if (( VDPA_MAX_VQP > 1 )); then
        vectors=$((2 * VDPA_MAX_VQP + 2))
        device_args+=",mq=on,vectors=${vectors}"
    fi
    # This mirrors QEMU/libvirt's vhost-vdpa network construction. The host
    # IOMMU is required by mlx5 vDPA, but a guest vIOMMU/iommu_platform device
    # property is not required merely to use this backend.
    printf '%s\n' "-netdev vhost-vdpa,id=${id},vhostdev=${link},queues=${VDPA_MAX_VQP} -device ${device_args}"
}

get_vm_args() {
    qm config "$1" 2>/dev/null | awk 'index($0,"args: ")==1 {print substr($0,7); exit}'
}

require_stopped_vm() {
    local vmid="$1" status
    command_exists qm || die "The Proxmox 'qm' command is unavailable."
    qm config "$vmid" >/dev/null 2>&1 || die "Proxmox VM $vmid does not exist."
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    [[ "$status" == stopped ]] || die "VM $vmid must be stopped (current state: ${status:-unknown})."
}

check_qemu_vdpa() {
    local qemu
    qemu=$(command -v kvm || command -v qemu-system-x86_64 || true)
    [[ -n "$qemu" ]] || die "QEMU/KVM was not found."
    "$qemu" -netdev help 2>&1 | grep -qw vhost-vdpa ||
        die "$qemu was built without the vhost-vdpa network backend."
}

check_unit_memlock() {
    local unit="$1" required_bytes="$2" memory_mib="$3"
    local load_state limit

    command_exists systemctl || return 2
    load_state=$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)
    [[ "$load_state" == loaded ]] || return 2
    limit=$(systemctl show "$unit" -p LimitMEMLOCK --value 2>/dev/null || true)
    case "$limit" in
        infinity|infinite|unlimited) return 0 ;;
    esac
    if [[ "$limit" =~ ^[0-9]+$ ]]; then
        if (( limit < required_bytes )); then
            printf 'Error: %s has LimitMEMLOCK=%s bytes, but VM memory is %s MiB.\n' \
                "$unit" "$limit" "$memory_mib" >&2
            printf '       mlx5 vDPA must pin/map guest RAM; this limit will cause vhost-vdpa DMA mapping failure.\n' >&2
            printf '       Configure a systemd drop-in with LimitMEMLOCK=infinity and restart %s before attaching.\n' \
                "$unit" >&2
            return 1
        fi
        return 0
    fi
    warn "Could not interpret $unit LimitMEMLOCK='${limit:-missing}'; vDPA RAM pinning was not verified."
    return 0
}

check_pve_memlock() {
    local vmid="$1" config memory_spec memory_mib required_bytes onboot rc

    config=$(qm config "$vmid" 2>/dev/null) || return 1
    memory_spec=$(awk '$1=="memory:" {print $2; exit}' <<<"$config")
    memory_mib="${memory_spec%%,*}"
    [[ "$memory_mib" =~ ^[0-9]+$ ]] || {
        warn "Could not determine VM $vmid memory; PVE memlock capacity was not verified."
        return 0
    }
    required_bytes=$((10#$memory_mib * 1024 * 1024))

    if check_unit_memlock pvedaemon.service "$required_bytes" "$memory_mib"; then
        :
    else
        rc=$?
        (( rc == 2 )) || return 1
    fi

    onboot=$(awk '$1=="onboot:" {print $2; exit}' <<<"$config")
    if [[ "$onboot" == 1 ]]; then
        if check_unit_memlock pve-guests.service "$required_bytes" "$memory_mib"; then
            :
        else
            rc=$?
            (( rc == 2 )) || return 1
        fi
    fi
    return 0
}

check_pf_health() {
    local output unhealthy
    output=$(devlink health show "pci/$PF_PCI" 2>/dev/null) || return 0
    unhealthy=$(awk '
        $1=="reporter" {reporter=$2; next}
        reporter=="fw" && $1=="state" && $2!="healthy" {print $2; exit}
    ' <<<"$output")
    [[ -z "$unhealthy" ]] ||
        die "$PF_PCI firmware health reporter is '$unhealthy'. Do not start another vDPA VM until the NIC has been recovered or cold power-cycled."
}

find_other_vm_for_link() {
    local wanted_vmid="$1" link="$2" file vmid
    [[ -d "$PVE_CONFIG_DIR" ]] || return 1
    for file in "$PVE_CONFIG_DIR"/*.conf; do
        [[ -r "$file" ]] || continue
        vmid=$(basename "$file" .conf)
        [[ "$vmid" == "$wanted_vmid" ]] && continue
        grep -Fq -- "$link" "$file" && { printf '%s\n' "$vmid"; return 0; }
    done
    return 1
}

attach_to_vm() {
    local vmid="$1" current fragment new verify id link node other_vm
    if [[ -z "$SF_MAC" ]] || ! usable_vm_mac "$SF_MAC"; then
        die "SF $SF_NUM needs a non-zero unicast MAC before it can be attached to a VM."
    fi
    if [[ -n "$PVE_VMID" && "$PVE_VMID" != "$vmid" ]]; then
        die "SF $SF_NUM is already assigned to VM $PVE_VMID. Detach it first."
    fi
    require_stopped_vm "$vmid"
    check_qemu_vdpa
    check_pve_memlock "$vmid" ||
        die "Insufficient PVE memlock would make this vDPA attachment unsafe."
    check_pf_health
    link=$(stable_vhost_link "$PF_PCI" "$SF_NUM")
    other_vm=$(find_other_vm_for_link "$vmid" "$link" || true)
    [[ -z "$other_vm" ]] ||
        die "$link is already referenced by Proxmox VM $other_vm."
    ensure_sf_runtime
    # Recheck stable and current kernel-assigned paths after reconciliation to
    # catch both managed and manually-authored PVE configurations.
    other_vm=$(find_other_vm_for_link "$vmid" "$link" || true)
    [[ -z "$other_vm" ]] ||
        die "$link is already referenced by Proxmox VM $other_vm."
    node=$(readlink -f "$link" 2>/dev/null || true)
    if [[ -n "$node" ]]; then
        other_vm=$(find_other_vm_for_link "$vmid" "$node" || true)
        [[ -z "$other_vm" ]] ||
            die "$node (the current node for $link) is already referenced by Proxmox VM $other_vm."
    fi

    current=$(get_vm_args "$vmid" || true)
    fragment=$(pve_args_fragment)
    id="snc$(compact_pci_token "$PF_PCI")s$SF_NUM"
    if [[ "$current" == *"$fragment"* ]]; then
        echo "VM $vmid already contains the exact SF $SF_NUM vDPA arguments."
    else
        [[ "$current" != *"id=${id}"* && "$current" != *"id=${id}dev"* ]] ||
            die "VM $vmid args already contain QEMU id $id, but not the expected managed fragment."
        new="${current:+$current }$fragment"
        echo "Attaching $VDPA_NAME to stopped VM $vmid..."
        qm set "$vmid" --args "$new"
        verify=$(get_vm_args "$vmid" || true)
        if [[ "$verify" != *"$fragment"* ]] || ! qm showcmd "$vmid" --pretty >/dev/null 2>&1; then
            warn "PVE could not generate a valid QEMU command with the new vDPA arguments; restoring the previous args."
            if [[ -n "$current" ]]; then
                qm set "$vmid" --args "$current" || true
            else
                qm set "$vmid" --delete args || true
            fi
            die "The VM assignment was rolled back after QEMU command validation failed."
        fi
    fi
    PVE_VMID="$vmid"
    if ! save_sf_config "$CONFIG_FILE"; then
        warn "Could not save the VM assignment; restoring the previous VM args."
        if [[ -n "$current" ]]; then
            qm set "$vmid" --args "$current" || true
        else
            qm set "$vmid" --delete args || true
        fi
        die "The VM assignment was rolled back because its SF config could not be saved."
    fi
    echo ">>> SF $SF_NUM is assigned to VM $vmid. Its representor is not connected by sriov-nic."
}

detach_from_vm() {
    local vmid="${PVE_VMID:-}" current fragment new verify
    [[ -n "$vmid" ]] || die "This SF configuration has no PVE_VMID assignment."
    require_stopped_vm "$vmid"
    current=$(get_vm_args "$vmid" || true)
    fragment=$(pve_args_fragment)
    [[ "$current" == *"$fragment"* ]] ||
        die "VM $vmid no longer contains the exact arguments managed for SF $SF_NUM; refusing to rewrite unrelated args."
    new="${current/"$fragment"/}"
    # Trim only leading/trailing whitespace. Do not normalize internal spaces,
    # which might be significant inside user-supplied quoted QEMU arguments.
    new="${new#"${new%%[![:space:]]*}"}"
    new="${new%"${new##*[![:space:]]}"}"
    if [[ -n "$new" ]]; then
        qm set "$vmid" --args "$new"
    else
        qm set "$vmid" --delete args
    fi
    verify=$(get_vm_args "$vmid" || true)
    if [[ "$verify" == *"$fragment"* ]] || ! qm showcmd "$vmid" --pretty >/dev/null 2>&1; then
        warn "PVE did not produce a clean, valid QEMU command after detach; restoring the previous args."
        qm set "$vmid" --args "$current" || true
        die "The detach was rolled back after QEMU command validation failed."
    fi
    PVE_VMID=""
    if ! save_sf_config "$CONFIG_FILE"; then
        warn "Could not save the detached state; restoring the VM's previous args."
        qm set "$vmid" --args "$current" || true
        die "The detach was rolled back because its SF config could not be saved."
    fi
    echo ">>> SF $SF_NUM detached from VM $vmid; the SF/vDPA device remains available."
}

delete_loaded_sf() {
    local port sfdev vdpa_name link node="" referenced_vm=""
    if [[ -n "$PVE_VMID" ]]; then
        die "SF $SF_NUM is assigned to VM $PVE_VMID. Detach it before deletion."
    fi
    link=$(stable_vhost_link "$PF_PCI" "$SF_NUM")
    if [[ -e "$link" && ! -L "$link" ]]; then
        die "Refusing to delete SF $SF_NUM while stable path $link is an ordinary file. Move that file first."
    fi
    referenced_vm=$(find_other_vm_for_link "" "$link" || true)
    [[ -z "$referenced_vm" ]] ||
        die "$link is still referenced by Proxmox VM $referenced_vm. Remove that assignment before deleting SF $SF_NUM."
    port=$(get_sf_port "$PF_PCI" "$PFNUM" "$SF_NUM" || true)
    if [[ -z "$port" ]]; then
        echo "SF $SF_NUM is already absent."
    else
        sfdev=$(get_sf_nested_devlink "$port" || true)
        vdpa_name=""
        [[ -n "$sfdev" ]] && vdpa_name=$(get_sf_vdpa_name "$sfdev" || true)
        if [[ -n "$vdpa_name" ]]; then
            node=$(find_vhost_node "$vdpa_name" || true)
            if [[ -n "$node" ]]; then
                referenced_vm=$(find_other_vm_for_link "" "$node" || true)
                [[ -z "$referenced_vm" ]] ||
                    die "$node is still referenced by Proxmox VM $referenced_vm."
                if node_is_open "$node"; then
                    die "$node is open by a process; stop its VM before deleting SF $SF_NUM."
                fi
            fi
            echo "Deleting vDPA device $vdpa_name..."
            timeout 10 vdpa dev del "$vdpa_name"
        fi
        echo "Deactivating and deleting SF $SF_NUM..."
        devlink port function set "$port" state inactive
        wait_for_sf_detached "$port" ||
            die "SF $SF_NUM did not detach within 10 seconds; its port was not deleted."
        devlink port del "$port"
    fi
    remove_stable_vhost_link "$link" ||
        die "SF $SF_NUM was deleted, but its conflicting stable path was preserved."
    [[ -n "$CONFIG_FILE" ]] && rm -f -- "$CONFIG_FILE"
    echo ">>> SF $SF_NUM deleted. Existing VFs, e-switch mode, and NIC firmware settings were not changed."
}

list_sfs() {
    local filter="${1:-}" line port pci pf sf rep state opstate mac nested vdpa_name managed vm
    local found=false file cpci csf
    [[ -z "$filter" ]] || filter=$(normalize_pci "$filter")
    printf '%-14s %-5s %-9s %-9s %-18s %-18s %-18s %-8s %s\n' \
        PF SF State OpState MAC Representor vDPA Managed VM
    while IFS= read -r line; do
        [[ "$line" == *"flavour pcisf"* ]] || continue
        port=$(awk '{p=$1; sub(/:$/, "", p); print p}' <<<"$line")
        pci="${port#pci/}"; pci="${pci%/*}"
        [[ -z "$filter" || "$pci" == "$filter" ]] || continue
        pf=$(awk '{for(i=1;i<=NF;i++) if($i=="pfnum"){print $(i+1);exit}}' <<<"$line")
        sf=$(awk '{for(i=1;i<=NF;i++) if($i=="sfnum"){print $(i+1);exit}}' <<<"$line")
        rep=$(awk '{for(i=1;i<=NF;i++) if($i=="netdev"){print $(i+1);exit}}' <<<"$line")
        state=$(get_sf_field "$port" state || true)
        opstate=$(get_sf_field "$port" opstate || true)
        mac=$(get_sf_field "$port" hw_addr || true)
        nested=$(get_sf_nested_devlink "$port" || true)
        vdpa_name=""; [[ -n "$nested" ]] && vdpa_name=$(get_sf_vdpa_name "$nested" || true)
        managed=no; vm=-
        if file=$(find_managed_config "$pci" "$sf" 2>/dev/null); then
            managed=yes
            vm=$(
                set +u; unset PVE_VMID
                # shellcheck source=/dev/null
                source "$file" >/dev/null 2>&1 || true
                printf '%s\n' "${PVE_VMID:--}"
            )
            [[ -n "$vm" ]] || vm=-
        fi
        printf '%-14s %-5s %-9s %-9s %-18s %-18s %-18s %-8s %s\n' \
            "$pci" "$sf" "${state:--}" "${opstate:--}" "${mac:--}" "${rep:--}" "${vdpa_name:--}" "$managed" "$vm"
        found=true
    done < <(devlink port show 2>/dev/null || true)

    # Also show managed SF configs that are currently absent.
    shopt -s nullglob
    for file in "$CONFIG_DIR"/sf-nic.conf*; do
        [[ -f "$file" ]] || continue
        cpci=""; csf=""
        cpci=$(
            set +u; unset PF_PCI
            # shellcheck source=/dev/null
            source "$file" >/dev/null 2>&1 || exit 1
            printf '%s\n' "$(normalize_pci "${PF_PCI:-}")"
        ) || continue
        csf=$(
            set +u; unset SF_NUM
            # shellcheck source=/dev/null
            source "$file" >/dev/null 2>&1 || exit 1
            printf '%s\n' "${SF_NUM:-}"
        ) || continue
        if [[ ! "$cpci" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7]$ ]]; then
            warn "Ignoring malformed SF config $file (invalid PF_PCI)."
            continue
        fi
        if [[ ! "$csf" =~ ^[0-9]+$ ]]; then
            warn "Ignoring malformed SF config $file (invalid SF_NUM)."
            continue
        fi
        [[ -z "$filter" || "$cpci" == "$filter" ]] || continue
        pf=$((16#${cpci##*.}))
        [[ -z "$(get_sf_port "$cpci" "$pf" "$csf" || true)" ]] || continue
        vm=$(
            set +u; unset PVE_VMID
            # shellcheck source=/dev/null
            source "$file" >/dev/null 2>&1 || true
            printf '%s\n' "${PVE_VMID:--}"
        )
        [[ -n "$vm" ]] || vm=-
        printf '%-14s %-5s %-9s %-9s %-18s %-18s %-18s %-8s %s\n' \
            "$cpci" "$csf" absent - - - - yes "$vm"
        found=true
    done
    [[ "$found" == true ]] || echo "No SFs found."
}

parse_sf_set() {
    local input="${1//[[:space:]]/}" output_name="$2" part start end i
    local -A seen=()
    local -a parts=() result=()
    # shellcheck disable=SC2034 # This nameref is an output parameter.
    local -n output_ref="$output_name"
    [[ -n "$input" ]] || return 1
    IFS=, read -ra parts <<<"$input"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=$((10#${BASH_REMATCH[1]})); end=$((10#${BASH_REMATCH[2]}))
            (( start <= end && end <= 65535 )) || return 1
            for ((i=start; i<=end; i++)); do
                [[ -n "${seen[$i]+x}" ]] || { result+=("$i"); seen[$i]=1; }
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            i=$((10#$part)); (( i <= 65535 )) || return 1
            [[ -n "${seen[$i]+x}" ]] || { result+=("$i"); seen[$i]=1; }
        else
            return 1
        fi
    done
    # shellcheck disable=SC2034 # Assignment through nameref returns the parsed set.
    output_ref=("${result[@]}")
}

choose_pf() {
    local device pci driver iface description choice index
    local -a pcis=() ifaces=() descriptions=()
    for device in "$SYSFS_ROOT"/bus/pci/devices/*; do
        [[ -e "$device" ]] || continue
        pci=$(basename "$device")
        driver=$(get_driver "$pci")
        [[ "$driver" == mlx5_core ]] || continue
        get_eswitch_info "$pci" >/dev/null 2>&1 || continue
        iface=$(get_pf_netdev "$pci" || true)
        [[ -n "$iface" ]] || continue
        description=$(lspci -D -s "$pci" 2>/dev/null | cut -d' ' -f2- || true)
        pcis+=("$pci"); ifaces+=("$iface"); descriptions+=("${description:-mlx5 device}")
    done
    (( ${#pcis[@]} > 0 )) || die "No mlx5_core PF with a devlink e-switch was found."
    printf '%-4s %-14s %-14s %s\n' No. Interface PCI Description
    for index in "${!pcis[@]}"; do
        printf '%-4s %-14s %-14s %s\n' "$((index+1))" "${ifaces[$index]}" "${pcis[$index]}" "${descriptions[$index]}"
    done
    while true; do
        read -r -p "Select a physical function [1-${#pcis[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#pcis[@]} )); then
            PF_PCI="${pcis[$((10#$choice-1))]}"
            PF_DEV="${ifaces[$((10#$choice-1))]}"
            PFNUM=$((16#${PF_PCI##*.}))
            return
        fi
        echo "Invalid selection."
    done
}

mac_conflicts() {
    local mac="${1,,}" own_sf="${2:-}" own_sfdev="" own_vdpa="" own_rep="" own_aux=""
    local line port pmac vdpa_name vmac file cmac cpci csf path current iface device_path
    [[ -n "$mac" ]] || return 1
    if [[ -n "$own_sf" ]]; then
        own_sfdev=$(get_sf_nested_devlink "$own_sf" || true)
        own_rep=$(get_sf_field "$own_sf" netdev || true)
        own_aux="${own_sfdev#auxiliary/}"
        [[ -n "$own_sfdev" ]] && own_vdpa=$(get_sf_vdpa_name "$own_sfdev" || true)
    fi
    for path in "$SYSFS_ROOT"/class/net/*/address; do
        [[ -r "$path" ]] || continue
        iface=$(basename "$(dirname "$path")")
        [[ -n "$own_rep" && "$iface" == "$own_rep" ]] && continue
        if [[ -n "$own_aux" ]]; then
            device_path=$(readlink -f "$SYSFS_ROOT/class/net/$iface/device" 2>/dev/null || true)
            [[ "$device_path" == *"/$own_aux" || "$device_path" == *"/$own_aux/"* ]] && continue
        fi
        current=$(tr '[:upper:]' '[:lower:]' <"$path" 2>/dev/null || true)
        [[ "$current" == "$mac" ]] && return 0
    done
    if ip -d link show 2>/dev/null |
       grep -qiE "^[[:space:]]+vf[[:space:]]+[0-9]+[[:space:]]+link/ether[[:space:]]+$mac([[:space:]]|$)"; then
        return 0
    fi
    while IFS= read -r line; do
        [[ "$line" == *"flavour pcisf"* ]] || continue
        port=$(awk '{p=$1; sub(/:$/, "", p); print p}' <<<"$line")
        [[ -n "$own_sf" && "$port" == "$own_sf" ]] && continue
        pmac=$(get_sf_field "$port" hw_addr || true)
        [[ "${pmac,,}" == "$mac" ]] && return 0
    done < <(devlink port show 2>/dev/null || true)
    while IFS= read -r line; do
        vdpa_name="${line%%:*}"
        [[ -n "$vdpa_name" && "$vdpa_name" != "$own_vdpa" ]] || continue
        vmac=$(get_vdpa_config_field "$vdpa_name" mac || true)
        [[ "${vmac,,}" == "$mac" ]] && return 0
    done < <(vdpa dev show 2>/dev/null || true)
    for file in "$CONFIG_DIR"/sf-nic.conf*; do
        [[ -f "$file" ]] || continue
        cmac=""; cpci=""; csf=""
        eval "$({
            set +u; unset SF_MAC PF_PCI SF_NUM
            # shellcheck source=/dev/null
            source "$file" >/dev/null 2>&1 || exit 1
            printf 'cmac=%q\ncpci=%q\ncsf=%q\n' "${SF_MAC:-}" "${PF_PCI:-}" "${SF_NUM:-}"
        })" || continue
        if [[ "${cmac,,}" == "$mac" && ! ( "$(normalize_pci "$cpci")" == "$PF_PCI" && "$csf" == "$SF_NUM" ) ]]; then
            return 0
        fi
    done
    return 1
}

prompt_mac_policy_for_set() {
    local answer default_prefix mac sf
    local -n sf_numbers_ref=$1
    local -n macs_ref=$2
    echo
    echo "SF MAC policy:"
    echo "  1) Leave the function/vDPA MAC unconfigured (cannot be attached to a VM yet)"
    echo "  2) Keep PF octets 1-3, invert octet 4 only, keep octet 5, use SF number as octet 6"
    echo "  3) Use a chosen five-byte prefix and the SF number as octet 6"
    echo "  4) Enter an explicit MAC for each SF"
    while true; do
        read -r -p "Select MAC policy [2]: " answer
        answer="${answer:-2}"
        case "$answer" in
            1) SF_MAC_MODE=none; break ;;
            2) SF_MAC_MODE="pf-oui-invert-one"; break ;;
            3) SF_MAC_MODE=generated; break ;;
            4) SF_MAC_MODE=explicit; break ;;
            *) echo "Invalid selection." ;;
        esac
    done
    SF_PREFIX=""
    if [[ "$SF_MAC_MODE" == generated ]]; then
        default_prefix="02:${PF_PCI:2:2}:${PF_PCI:5:2}:${PF_PCI:8:2}:$(printf '%02x' "$PFNUM")"
        read -r -p "Five-byte SF MAC prefix [$default_prefix]: " SF_PREFIX
        SF_PREFIX="${SF_PREFIX:-$default_prefix}"
    fi
    macs_ref=()
    for sf in "${sf_numbers_ref[@]}"; do
        case "$SF_MAC_MODE" in
            none) mac="" ;;
            pf-oui-invert-one)
                mac=$(derive_sf_oui_mac "$PF_DEV" "$sf") || die "Automatic option 2 supports SF numbers 0-255."
                ;;
            generated)
                mac=$(derive_prefix_mac "$SF_PREFIX" "$sf") || die "Invalid prefix or SF number; generated MACs support SF numbers 0-255."
                ;;
            explicit)
                while true; do
                    read -r -p "MAC for SF $sf: " mac
                    mac="${mac,,}"
                    valid_mac "$mac" && break
                    echo "Enter a valid unicast MAC address."
                done
                ;;
        esac
        macs_ref+=("$mac")
    done
}

interactive_create() {
    local input answer i sf path
    local -a sfs=() macs=()
    local -A planned_macs=()

    read -r -p "SF numbers/ranges (for example 0 or 0-7 or 0,2,4-7): " input
    parse_sf_set "$input" sfs || die "Invalid SF number/range expression."
    (( ${#sfs[@]} > 0 )) || die "No SF numbers selected."

    for sf in "${sfs[@]}"; do
        [[ -z "$(get_sf_port "$PF_PCI" "$PFNUM" "$sf" || true)" ]] ||
            die "SF $sf already exists. Use Adopt existing SFs instead."
    done

    require_sf_tools
    preflight_switchdev
    check_firmware_sf_capacity
    preflight_batch_capacity "${#sfs[@]}"

    prompt_mac_policy_for_set sfs macs
    read -r -p "vDPA queue pairs [4]: " answer
    VDPA_MAX_VQP="${answer:-4}"
    read -r -p "vDPA MTU [1500]: " answer
    VDPA_MTU="${answer:-1500}"

    echo
    echo "Creation plan (firmware settings will not be changed):"
    for i in "${!sfs[@]}"; do
        sf="${sfs[$i]}"; SF_NUM="$sf"; SF_MAC="${macs[$i]}"
        VDPA_NAME=$(default_vdpa_name "$PF_PCI" "$sf")
        REP_NAME=$(default_rep_name "$PF_DEV" "$PF_PCI" "$sf")
        validate_config_values
        path=$(config_path_for "$PF_PCI" "$SF_NUM")
        [[ ! -e "$path" ]] ||
            die "Managed config $path already exists. Apply or delete it instead of creating a duplicate SF."
        [[ ! -e "$SYSFS_ROOT/class/net/$REP_NAME" ]] ||
            die "Stable representor name $REP_NAME already exists."
        if vdpa dev show "$VDPA_NAME" >/dev/null 2>&1; then
            die "vDPA device name $VDPA_NAME already exists."
        fi
        if [[ -n "$SF_MAC" ]]; then
            [[ -z "${planned_macs[$SF_MAC]+x}" ]] || die "Generated duplicate MAC $SF_MAC in this batch."
            planned_macs[$SF_MAC]=1
            mac_conflicts "$SF_MAC" && die "MAC $SF_MAC is already used by another SF/vDPA/config."
        fi
        printf '  SF %-5s MAC %-18s VQP %-2s MTU %-5s representor %-15s\n' \
            "$sf" "${SF_MAC:--}" "$VDPA_MAX_VQP" "$VDPA_MTU" "$REP_NAME"
    done
    echo "Existing VFs will not be removed or recreated. Network bridge/OVS wiring will not be changed."
    read -r -p "Type CREATE to continue: " answer
    [[ "$answer" == CREATE ]] || die "Cancelled; no changes were made."

    TX_ACTIVE=true; TX_NEW_SFS=(); TX_NEW_VDPAS=(); TX_NEW_CONFIGS=(); TX_SWITCHED_PFS=()
    for i in "${!sfs[@]}"; do
        SF_NUM="${sfs[$i]}"; SF_MAC="${macs[$i]}"
        VDPA_NAME=$(default_vdpa_name "$PF_PCI" "$SF_NUM")
        REP_NAME=$(default_rep_name "$PF_DEV" "$PF_PCI" "$SF_NUM")
        PVE_VMID=""; CONFIG_FILE=""
        validate_config_values
        ensure_sf_runtime
    done

    if prompt_yes_no "Save these SFs for boot-time restoration?" yes; then
        for i in "${!sfs[@]}"; do
            SF_NUM="${sfs[$i]}"; SF_MAC="${macs[$i]}"
            VDPA_NAME=$(default_vdpa_name "$PF_PCI" "$SF_NUM")
            REP_NAME=$(default_rep_name "$PF_DEV" "$PF_PCI" "$SF_NUM")
            PVE_VMID=""
            path=$(config_path_for "$PF_PCI" "$SF_NUM")
            [[ ! -e "$path" ]] || die "Refusing to overwrite existing config $path."
            save_sf_config "$path"
            TX_NEW_CONFIGS+=("$path")
        done
    fi
    TX_ACTIVE=false
    echo ">>> Created ${#sfs[@]} SF-backed vDPA device(s)."
    if (( ${#TX_NEW_CONFIGS[@]} > 0 )); then
        offer_boot_service
    fi
}

interactive_adopt() {
    local input answer sf port nested vdpa_name mac vqp mtu path
    local -a sfs=()
    read -r -p "Existing SF numbers/ranges to adopt: " input
    parse_sf_set "$input" sfs || die "Invalid SF number/range expression."
    (( ${#sfs[@]} > 0 )) || die "No SF numbers selected."
    require_sf_tools
    preflight_switchdev
    check_firmware_sf_capacity
    for sf in "${sfs[@]}"; do
        port=$(get_sf_port "$PF_PCI" "$PFNUM" "$sf" || true)
        [[ -n "$port" ]] || die "SF $sf does not exist."
        [[ -z "$(find_managed_config "$PF_PCI" "$sf" 2>/dev/null || true)" ]] ||
            die "SF $sf is already managed."
        path=$(config_path_for "$PF_PCI" "$sf")
        [[ ! -e "$path" ]] || die "Refusing to overwrite existing config $path."
        SF_NUM="$sf"
        REP_NAME=$(default_rep_name "$PF_DEV" "$PF_PCI" "$sf")
        preflight_representor_name "$port"
        mac=$(get_sf_field "$port" hw_addr || true); mac="${mac,,}"
        if ! valid_mac "$mac"; then
            mac=$(derive_sf_oui_mac "$PF_DEV" "$sf") ||
                die "Could not derive a MAC for SF $sf."
        fi
        mac_conflicts "$mac" "$port" &&
            die "MAC $mac for SF $sf is already used outside that SF."
    done
    echo "Adoption may rename representors and converts non-vDPA SFs to vDPA. Existing VFs are untouched."
    read -r -p "Type ADOPT to continue: " answer
    [[ "$answer" == ADOPT ]] || die "Cancelled; no changes were made."

    for sf in "${sfs[@]}"; do
        SF_NUM="$sf"; port=$(get_sf_port "$PF_PCI" "$PFNUM" "$sf")
        nested=$(get_sf_nested_devlink "$port" || true)
        vdpa_name=""; [[ -n "$nested" ]] && vdpa_name=$(get_sf_vdpa_name "$nested" || true)
        mac=$(get_sf_field "$port" hw_addr || true); mac="${mac,,}"
        if ! valid_mac "$mac" || [[ "$mac" == 00:00:00:00:00:00 ]]; then
            mac=$(derive_sf_oui_mac "$PF_DEV" "$sf") || die "Could not derive a MAC for SF $sf."
            # Active SF MACs are deliberately not changed in-place by ensure_sf_runtime.
            devlink port function set "$port" state inactive
            wait_for_sf_detached "$port" ||
                die "SF $sf did not detach within 10 seconds; its MAC was not changed."
            devlink port function set "$port" hw_addr "$mac"
        fi
        SF_MAC="$mac"; SF_MAC_MODE=adopted; SF_PREFIX=""
        VDPA_NAME="${vdpa_name:-$(default_vdpa_name "$PF_PCI" "$sf")}"
        vqp=""; mtu=""
        if [[ -n "$vdpa_name" ]]; then
            vqp=$(get_vdpa_config_field "$vdpa_name" max_vq_pairs || true)
            mtu=$(get_vdpa_config_field "$vdpa_name" mtu || true)
        fi
        VDPA_MAX_VQP="${vqp:-4}"; VDPA_MTU="${mtu:-1500}"
        REP_NAME=$(default_rep_name "$PF_DEV" "$PF_PCI" "$sf")
        PVE_VMID=""; CONFIG_FILE=""
        validate_config_values
        ensure_sf_runtime
        path=$(config_path_for "$PF_PCI" "$SF_NUM")
        save_sf_config "$path"
    done
    echo ">>> Adopted ${#sfs[@]} SF(s)."
    offer_boot_service
}

interactive_attach() {
    local sf vmid file
    read -r -p "Managed SF number: " sf
    [[ "$sf" =~ ^[0-9]+$ ]] || die "Invalid SF number."
    sf=$((10#$sf))
    file=$(find_managed_config "$PF_PCI" "$sf" 2>/dev/null || true)
    [[ -n "$file" ]] || die "SF $sf is not managed; adopt it first."
    load_sf_config "$file"; validate_config_values
    [[ -z "$PVE_VMID" ]] || die "SF $sf is already assigned to VM $PVE_VMID."
    read -r -p "Stopped Proxmox VM ID: " vmid
    [[ "$vmid" =~ ^[1-9][0-9]*$ ]] || die "Invalid VM ID."
    echo "This adds raw vhost-vdpa QEMU args. It does not connect $REP_NAME to a bridge or OVS."
    prompt_yes_no "Attach SF $sf to VM $vmid?" no || die "Cancelled."
    attach_to_vm "$vmid"
}

interactive_detach() {
    local sf file
    read -r -p "Managed SF number: " sf
    [[ "$sf" =~ ^[0-9]+$ ]] || die "Invalid SF number."
    sf=$((10#$sf))
    file=$(find_managed_config "$PF_PCI" "$sf" 2>/dev/null || true)
    [[ -n "$file" ]] || die "SF $sf is not managed."
    load_sf_config "$file"; validate_config_values
    prompt_yes_no "Detach SF $sf from VM ${PVE_VMID:-none}?" no || die "Cancelled."
    detach_from_vm
}

interactive_delete() {
    local input answer sf file port stable_link referenced_vm
    local -a sfs=()
    read -r -p "SF numbers/ranges to delete: " input
    parse_sf_set "$input" sfs || die "Invalid SF number/range expression."
    (( ${#sfs[@]} > 0 )) || die "No SF numbers selected."

    # Complete all destructive preflight before deleting the first SF.
    local selected_pci="$PF_PCI"
    for sf in "${sfs[@]}"; do
        file=$(find_managed_config "$selected_pci" "$sf" 2>/dev/null || true)
        if [[ -n "$file" ]]; then
            load_sf_config "$file"; validate_config_values
            [[ -z "$PVE_VMID" ]] || die "SF $sf is assigned to VM $PVE_VMID; detach it first."
        else
            port=$(get_sf_port "$selected_pci" "$PFNUM" "$sf" || true)
            [[ -n "$port" ]] || die "SF $sf does not exist and has no managed config."
        fi
        assert_runtime_sf_not_busy "$selected_pci" "$sf"
        stable_link=$(stable_vhost_link "$selected_pci" "$sf")
        referenced_vm=$(find_other_vm_for_link "" "$stable_link" || true)
        [[ -z "$referenced_vm" ]] ||
            die "$stable_link is still referenced by Proxmox VM $referenced_vm."
    done
    echo "This deletes ${#sfs[@]} SF(s) and their vDPA devices. Existing VFs and firmware settings are untouched."
    read -r -p "Type DELETE to continue: " answer
    [[ "$answer" == DELETE ]] || die "Cancelled; no changes were made."

    for sf in "${sfs[@]}"; do
        file=$(find_managed_config "$selected_pci" "$sf" 2>/dev/null || true)
        if [[ -n "$file" ]]; then
            load_sf_config "$file"
        else
            reset_config_vars
            PF_PCI="$selected_pci"
            SF_NUM="$sf"
            SF_MAC_MODE=none
            CONFIG_FILE=""
        fi
        validate_config_values
        delete_loaded_sf
    done
}

interactive_manager() {
    local choice
    [[ -t 0 && -t 1 ]] || die "Interactive mode requires a terminal."
    echo "mlx5 SF / hardware vDPA manager"
    echo "================================"
    choose_pf
    echo
    while true; do
        echo "Selected PF: $PF_PCI ($PF_DEV)"
        echo "  1) List SFs"
        echo "  2) Create one or multiple SF-backed vDPA devices"
        echo "  3) Adopt existing SFs"
        echo "  4) Attach a managed SF to a stopped Proxmox VM"
        echo "  5) Detach a managed SF from its Proxmox VM"
        echo "  6) Delete one or multiple SFs"
        echo "  7) Exit"
        read -r -p "Select action [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1) list_sfs "$PF_PCI" ;;
            2) interactive_create ;;
            3) interactive_adopt ;;
            4) interactive_attach ;;
            5) interactive_detach ;;
            6) interactive_delete ;;
            7) return 0 ;;
            *) echo "Invalid selection." ;;
        esac
        echo
    done
}

main() {
    if [[ "${1:-}" != --help && "${1:-}" != -h ]]; then
        [[ "$EUID" -eq 0 || "${SF_ALLOW_NON_ROOT:-false}" == true ]] || die "Run this script as root."
    fi
    trap on_exit EXIT

    case "${1:---interactive}" in
        --interactive|-i)
            (( $# == 1 )) || die "--interactive takes no additional arguments."
            interactive_manager
            ;;
        --list|-l)
            (( $# <= 2 )) || die "--list accepts at most one PF PCI address."
            list_sfs "${2:-}"
            ;;
        --apply)
            (( $# == 2 )) || die "--apply requires one configuration file."
            apply_sf_config "$2"
            ;;
        --apply-all)
            (( $# <= 2 )) || die "--apply-all accepts at most one directory."
            apply_all_sf_configs "${2:-$CONFIG_DIR}"
            ;;
        --attach)
            (( $# == 3 )) || die "--attach requires CONFIG and VMID."
            load_sf_config "$2"
            validate_config_values
            attach_to_vm "$3"
            ;;
        --detach)
            (( $# == 2 )) || die "--detach requires one configuration file."
            load_sf_config "$2"; validate_config_values; detach_from_vm
            ;;
        --delete)
            (( $# == 2 )) || die "--delete requires one configuration file."
            load_sf_config "$2"; validate_config_values; delete_loaded_sf
            ;;
        --help|-h)
            usage
            ;;
        *)
            usage >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
