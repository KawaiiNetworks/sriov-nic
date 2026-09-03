#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
MOCK="$ROOT/bin"; SYS="$ROOT/sys"; DEV="$ROOT/dev"; STATE="$ROOT/state"; CFG="$ROOT/config"; PVE="$ROOT/pve"
mkdir -p "$MOCK" "$SYS/bus/pci/devices/0000:c1:00.0/net" "$SYS/class/net/enp193s0f0np0" \
  "$SYS/kernel/iommu_groups/1" "$SYS/devices" "$SYS/bus/vdpa/devices" "$DEV" "$STATE" "$CFG" "$PVE"
: >"$PVE/100.conf"
: >"$STATE/vmargs"
mkdir -p "$SYS/drivers/mlx5_core"
ln -s "$SYS/drivers/mlx5_core" "$SYS/bus/pci/devices/0000:c1:00.0/driver"
ln -s "$SYS/kernel/iommu_groups/1" "$SYS/bus/pci/devices/0000:c1:00.0/iommu_group"
printf '6\n' >"$SYS/bus/pci/devices/0000:c1:00.0/sriov_numvfs"
printf 'b8:3f:d2:f4:c3:9e\n' >"$SYS/class/net/enp193s0f0np0/address"
printf 'switchdev\n' >"$STATE/mode"
printf 'eth0\n' >"$STATE/rep"
printf 'false\n' >"$STATE/enable_eth"
printf 'false\n' >"$STATE/enable_rdma"
printf 'false\n' >"$STATE/enable_roce"
printf 'false\n' >"$STATE/enable_vnet"
printf '0\n' >"$STATE/reloads"

cat >"$MOCK/devlink" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
S=$MOCK_STATE; SYS=$MOCK_SYS
show_sf() {
  [[ -e "$S/sf" ]] || return 1
  rep=$(<"$S/rep"); mac=$(<"$S/mac"); state=$(<"$S/sfstate")
  if [[ "$state" == active ]]; then op=attached; else op=detached; fi
  echo "pci/0000:c1:00.0/32768: type eth netdev $rep flavour pcisf controller 0 pfnum 0 sfnum 0 splittable false"
  echo "  function:"
  echo "    hw_addr $mac state $state opstate $op roce enable max_io_eqs 8"
  if [[ "$state" == active ]]; then
    echo "      nested_devlink:"
    echo "        auxiliary/mlx5_core.sf.8"
  fi
}
case "$1 $2 ${3:-}" in
  'dev show pci/0000:c1:00.0')
    echo 'pci/0000:c1:00.0:'
    echo '  auxiliary/mlx5_core.eth.0'
    ;;
  'dev eswitch show') echo "pci/0000:c1:00.0: mode $(<"$S/mode") inline-mode none encap-mode basic" ;;
  'dev eswitch set') echo switchdev >"$S/mode" ;;
  'port show ')
    echo 'pci/0000:c1:00.0/65535: type eth netdev enp193s0f0np0 flavour physical port 0 splittable false'
    show_sf || true
    ;;
  'port show pci/0000:c1:00.0/32768') show_sf ;;
  'port add pci/0000:c1:00.0')
    touch "$S/sf"; echo inactive >"$S/sfstate"; echo 00:00:00:00:00:00 >"$S/mac"
    rep=$(<"$S/rep"); mkdir -p "$SYS/class/net/$rep"
    show_sf
    ;;
  'port function set')
    port=$4; key=$5; value=$6
    case "$key" in
      hw_addr) echo "$value" >"$S/mac" ;;
      state) echo "$value" >"$S/sfstate" ;;
      *) exit 2 ;;
    esac
    ;;
  'port del pci/0000:c1:00.0/32768')
    rep=$(<"$S/rep"); rm -rf "$SYS/class/net/$rep"; rm -f "$S/sf" "$S/sfstate" "$S/mac" "$S/mgmt"
    ;;
  'dev param show')
    dev=$4; [[ "$dev" == auxiliary/mlx5_core.sf.8 ]] || exit 1
    [[ "$5" == name ]]; name=$6
    [[ -f "$S/$name" ]] || exit 1
    echo "$dev:"
    echo "  name $name type generic"
    echo '    values:'
    echo "      cmode driverinit value $(<"$S/$name")"
    ;;
  'dev param set')
    name=$6; value=$8; echo "$value" >"$S/$name"
    ;;
  'dev reload auxiliary/mlx5_core.sf.8')
    n=$(<"$S/reloads"); echo $((n+1)) >"$S/reloads"
    [[ "$(<"$S/enable_vnet")" == true ]] && touch "$S/mgmt"
    echo 'reload_actions_performed:'; echo '  driver_reinit'
    ;;
  *) echo "unexpected devlink args: $*" >&2; exit 64 ;;
esac
EOF

cat >"$MOCK/vdpa" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
S=$MOCK_STATE; SYS=$MOCK_SYS; DEV=$MOCK_DEV
case "$1 $2 ${3:-}" in
  'mgmtdev show auxiliary/mlx5_core.sf.8')
    [[ -e "$S/mgmt" ]] || exit 1
    echo 'auxiliary/mlx5_core.sf.8: supported_classes net max_supported_vqs 65'
    ;;
  'dev show ')
    if [[ -e "$S/vdpa" ]]; then
      echo "$(<"$S/vname"): type network mgmtdev auxiliary/mlx5_core.sf.8 vendor_id 5555 max_vqs 9"
    fi
    ;;
  'dev config show')
    name=$4; [[ -e "$S/vdpa" && "$(<"$S/vname")" == "$name" ]] || exit 1
    echo "$name: mac $(<"$S/vmac") link up link_announce false max_vq_pairs $(<"$S/vqp") mtu $(<"$S/mtu")"
    ;;
  'dev add name')
    [[ "${MOCK_VDPA_FAIL_ADD:-0}" != 1 ]] || exit 95
    name=$4; shift 4
    mgmt=''; mac=''; mtu=''; vqp=''
    while (($#)); do
      case "$1" in
        mgmtdev) mgmt=$2; shift 2;; mac) mac=$2; shift 2;; mtu) mtu=$2; shift 2;; max_vqp) vqp=$2; shift 2;; *) exit 65;; esac
    done
    [[ "$mgmt" == auxiliary/mlx5_core.sf.8 ]]
    touch "$S/vdpa"; echo "$name" >"$S/vname"; echo "$mac" >"$S/vmac"; echo "$mtu" >"$S/mtu"; echo "$vqp" >"$S/vqp"
    mkdir -p "$SYS/devices/$name"; touch "$SYS/devices/$name/vhost-vdpa-0" "$DEV/vhost-vdpa-0"
    ln -s "$SYS/devices/$name" "$SYS/bus/vdpa/devices/$name"
    ;;
  'dev del '*)
    name=$3; [[ -e "$S/vdpa" && "$(<"$S/vname")" == "$name" ]]
    rm -f "$S/vdpa" "$S/vname" "$S/vmac" "$S/mtu" "$S/vqp" "$DEV/vhost-vdpa-0"
    rm -rf "$SYS/bus/vdpa/devices/$name" "$SYS/devices/$name"
    ;;
  *)
    # Handle `vdpa dev show NAME` separately because the case key has a value.
    if [[ "$1" == dev && "$2" == show && $# == 3 ]]; then
      [[ -e "$S/vdpa" && "$(<"$S/vname")" == "$3" ]] || exit 1
      echo "$3: type network mgmtdev auxiliary/mlx5_core.sf.8 vendor_id 5555 max_vqs 9"
    else
      echo "unexpected vdpa args: $*" >&2; exit 64
    fi
    ;;
esac
EOF

cat >"$MOCK/ip" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
S=$MOCK_STATE; SYS=$MOCK_SYS
if [[ "$1 $2 $3 $4" == '-o link show dev' ]]; then
  echo "1: $5: <BROADCAST> mtu 1500 state DOWN"
elif [[ "$1 $2 $3" == '-d link show' ]]; then
  echo "1: $4: <BROADCAST> mtu 1500"
elif [[ "$1 $2 $3" == 'link set dev' ]]; then
  old=$4; shift 4
  case "$1" in
    down|up) exit 0 ;;
    alias) exit 0 ;;
    name)
      new=$2; rm -rf "$SYS/class/net/$old"; mkdir -p "$SYS/class/net/$new"; echo "$new" >"$S/rep"
      ;;
    *) exit 66 ;;
  esac
else
  echo "unexpected ip args: $*" >&2; exit 64
fi
EOF
cat >"$MOCK/ethtool" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == -P ]] && { echo 'Permanent address: b8:3f:d2:f4:c3:9e'; exit 0; }
exit 1
EOF
cat >"$MOCK/mstconfig" <<'EOF'
#!/usr/bin/env bash
cat <<OUT
PER_PF_NUM_SF True(1)
PF_BAR2_ENABLE False(0)
PF_TOTAL_SF 8
PF_SF_BAR_SIZE 8
OUT
EOF
for c in modprobe udevadm; do cat >"$MOCK/$c" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
cat >"$MOCK/kvm" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == '-netdev help' ]]; then echo vhost-vdpa; exit 0; fi
exit 0
EOF
cat >"$MOCK/qm" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
S=$MOCK_STATE; P=$MOCK_PVE
case "$1" in
  config)
    [[ "$2" == 100 ]]
    echo 'name: testvm'
    if [[ -s "$S/vmargs" ]]; then echo "args: $(<"$S/vmargs")"; fi
    ;;
  status) [[ "$2" == 100 ]] && echo 'status: stopped' ;;
  showcmd)
    [[ "$2" == 100 ]]
    echo "/usr/bin/kvm $(<"$S/vmargs")"
    ;;
  set)
    [[ "$2" == 100 ]]; shift 2
    if [[ "$1" == --args ]]; then
      printf '%s\n' "$2" >"$S/vmargs"
      printf 'args: %s\n' "$2" >"$P/100.conf"
    elif [[ "$1 $2" == '--delete args' ]]; then
      : >"$S/vmargs"; : >"$P/100.conf"
    else
      exit 64
    fi
    ;;
  *) exit 64 ;;
esac
EOF
cat >"$MOCK/modinfo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == mlx5_vdpa || "$1" == vhost_vdpa ]]
EOF
chmod +x "$MOCK"/*

cat >"$CFG/sf-nic.conf.test" <<EOF
PF_PCI=0000:c1:00.0
SF_CONTROLLER=0
SF_NUM=0
SF_MAC_MODE=pf-oui-invert-one
SF_MAC=b8:3f:d2:0b:c3:00
VDPA_NAME=snc-0000c1000-s0
VDPA_MAX_VQP=4
VDPA_MTU=1500
REP_NAME=enp193s0f0sf0r
PVE_VMID=
EOF

export MOCK_STATE="$STATE" MOCK_SYS="$SYS" MOCK_DEV="$DEV" MOCK_PVE="$PVE"
export PATH="$MOCK:$PATH" SYSFS_ROOT="$SYS" SF_DEV_ROOT="$DEV" SF_STABLE_DEV_DIR="$DEV/sriov-nic" SF_CONFIG_DIR="$CFG" PVE_QEMU_CONFIG_DIR="$PVE" SF_ALLOW_NON_ROOT=true
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$REPO_DIR/manage-sf.sh"

"$SCRIPT" --apply "$CFG/sf-nic.conf.test"
[[ -e "$STATE/sf" && -e "$STATE/vdpa" ]]
[[ "$(<"$STATE/mac")" == b8:3f:d2:0b:c3:00 ]]
[[ "$(<"$STATE/rep")" == enp193s0f0sf0r ]]
[[ "$(<"$STATE/reloads")" == 1 ]]
[[ -L "$DEV/sriov-nic/0000-c1-00-0-sf0" ]]
[[ "$(readlink "$DEV/sriov-nic/0000-c1-00-0-sf0")" == "$DEV/vhost-vdpa-0" ]]

"$SCRIPT" --apply "$CFG/sf-nic.conf.test"
[[ "$(<"$STATE/reloads")" == 1 ]]
[[ "$(<"$STATE/vname")" == snc-0000c1000-s0 ]]
"$SCRIPT" --list 0000:c1:00.0 | grep -q 'snc-0000c1000-s0'

"$SCRIPT" --attach "$CFG/sf-nic.conf.test" 100
args=$(<"$STATE/vmargs")
[[ "$args" == *'-netdev vhost-vdpa,'* ]]
[[ "$args" == *'queues=4'* && "$args" == *'mq=on,vectors=10'* ]]
[[ "$args" != *'iommu_platform'* && "$args" != *'disable-legacy'* ]]
grep -q '^PVE_VMID=100$' "$CFG/sf-nic.conf.test"
"$SCRIPT" --detach "$CFG/sf-nic.conf.test"
[[ ! -s "$STATE/vmargs" ]]
grep -q '^PVE_VMID=' "$CFG/sf-nic.conf.test"
if grep -q '^PVE_VMID=100$' "$CFG/sf-nic.conf.test"; then
  echo 'PVE_VMID was not cleared after detach' >&2
  exit 1
fi

"$SCRIPT" --delete "$CFG/sf-nic.conf.test"
[[ ! -e "$STATE/sf" && ! -e "$STATE/vdpa" && ! -e "$CFG/sf-nic.conf.test" ]]
[[ "$(<"$SYS/bus/pci/devices/0000:c1:00.0/sriov_numvfs")" == 6 ]]

# A vDPA creation failure must roll back only the newly-created SF and leave
# the pre-existing VF allocation untouched.
cat >"$CFG/sf-nic.conf.failure" <<EOF
PF_PCI=0000:c1:00.0
SF_CONTROLLER=0
SF_NUM=0
SF_MAC_MODE=pf-oui-invert-one
SF_MAC=b8:3f:d2:0b:c3:00
VDPA_NAME=snc-0000c1000-s0
VDPA_MAX_VQP=4
VDPA_MTU=1500
REP_NAME=enp193s0f0sf0r
PVE_VMID=
EOF
if MOCK_VDPA_FAIL_ADD=1 "$SCRIPT" --apply "$CFG/sf-nic.conf.failure" >"$ROOT/failure.out" 2>"$ROOT/failure.err"; then
  echo 'forced vDPA failure unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -e "$STATE/sf" && ! -e "$STATE/vdpa" ]]
[[ "$(<"$SYS/bus/pci/devices/0000:c1:00.0/sriov_numvfs")" == 6 ]]
grep -q 'Rolling back resources' "$ROOT/failure.err"

echo 'mock integration: OK'
