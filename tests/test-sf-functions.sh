#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Loading the file defines helpers without running main().
# shellcheck disable=SC1091 # The absolute path is computed from this test's location.
source "$REPO_DIR/manage-sf.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SYSFS_ROOT="$TMP/sys"
mkdir -p "$SYSFS_ROOT/class/net/enp193s0f0np0"
echo b8:3f:d2:f4:c3:9e >"$SYSFS_ROOT/class/net/enp193s0f0np0/address"

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [[ "$actual" != "$expected" ]]; then
        printf '%s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_eq "$(derive_sf_oui_mac enp193s0f0np0 0)" \
    b8:3f:d2:0b:c3:00 "option-2 SF0 MAC"
assert_eq "$(derive_sf_oui_mac enp193s0f0np0 255)" \
    b8:3f:d2:0b:c3:ff "option-2 SF255 MAC"
assert_eq "$(derive_prefix_mac 02:00:00:03:01 7)" \
    02:00:00:03:01:07 "generated SF7 MAC"
assert_eq "$(default_rep_name enp193s0f0np0 0000:c1:00.0 0)" \
    enp193s0f0sf0r "predictable representor name"
assert_eq "$(default_vdpa_name 0000:c1:00.0 0)" \
    snc-0000c1000-s0 "predictable vDPA name"

declare -a parsed=()
parse_sf_set '0,2,4-6,2' parsed
assert_eq "${parsed[*]}" '0 2 4 5 6' "range parser"
if parse_sf_set '6-4' parsed; then
    echo "descending SF range was incorrectly accepted" >&2
    exit 1
fi
if derive_sf_oui_mac enp193s0f0np0 256 >/dev/null; then
    echo "option-2 MAC unexpectedly accepted SF256" >&2
    exit 1
fi

long_name=$(default_rep_name verylongpfname0 0000:c1:00.0 65535)
(( ${#long_name} <= 15 )) || {
    echo "fallback representor name exceeds Linux IFNAMSIZ: $long_name" >&2
    exit 1
}

# Exercise the actual batch loop without hardware. Each selected SF must keep
# its own deterministic option-2 MAC, while capacity is checked once for 3.
PF_PCI=0000:c1:00.0
PF_DEV=enp193s0f0np0
PFNUM=0
SF_CONTROLLER=0
CONFIG_DIR="$TMP"
get_sf_port() { return 0; }
require_sf_tools() { :; }
preflight_switchdev() { :; }
check_firmware_sf_capacity() { :; }
preflight_batch_capacity() {
    [[ "$1" == 3 ]] || return 1
    echo "$1" >"$TMP/capacity"
}
validate_config_values() { :; }
mac_conflicts() { return 1; }
ensure_sf_runtime() { printf '%s %s\n' "$SF_NUM" "$SF_MAC" >>"$TMP/created"; }
vdpa() { return 1; }

printf '0-2\n2\n4\n1500\nCREATE\nn\n' | interactive_create >/dev/null
assert_eq "$(<"$TMP/capacity")" 3 "batch capacity"
assert_eq "$(<"$TMP/created")" \
    $'0 b8:3f:d2:0b:c3:00\n1 b8:3f:d2:0b:c3:01\n2 b8:3f:d2:0b:c3:02' \
    "batch creation"

echo "SF helper tests: OK"
