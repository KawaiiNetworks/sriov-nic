#!/bin/bash
set -e # 遇到错误立即退出

# ================= 配置文件加载 =================
CONFIG_FILE="$1"

if [ -z "$CONFIG_FILE" ]; then
    echo "Usage: $0 <path-to-config-file>"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file '$CONFIG_FILE' not found."
    exit 1
fi

# 加载配置文件
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ================= 环境变量检查 =================
: "${PF_PCI:?Error: Variable PF_PCI is not set in $CONFIG_FILE.}"
: "${TOTAL_VFS:?Error: Variable TOTAL_VFS is not set in $CONFIG_FILE.}"
: "${VF_PREFIX:?Error: Variable VF_PREFIX is not set in $CONFIG_FILE.}"

# ================= 自动获取网口名 (核心修改) =================
# 通过 PCI ID 在 sysfs 中反查网口名称
# 路径通常是 /sys/bus/pci/devices/0000:01:00.0/net/enp1s0
if [ ! -d "/sys/bus/pci/devices/$PF_PCI/net" ]; then
    echo "Error: No network interface found for PCI device $PF_PCI"
    echo "       Please verify the PCI ID and ensure the driver is loaded."
    exit 1
fi

# 获取该目录下的第一个文件夹名作为网卡名
PF_DEV=$(ls /sys/bus/pci/devices/$PF_PCI/net/ | head -n 1)

if [ -z "$PF_DEV" ]; then
    echo "Error: Could not resolve network device name from PCI ID $PF_PCI"
    exit 1
fi

# ================= 自动计算配置 =================
# PF_DUMMY_MAC 自动拼接 :00
PF_DUMMY_MAC="${VF_PREFIX}:00"

echo ">>> Starting Switchdev Setup for PCI: $PF_PCI (Detected Interface: $PF_DEV)"
echo "    PF Dummy MAC: $PF_DUMMY_MAC"
echo "    VF Prefix:    $VF_PREFIX"

# 1. 获取原厂永久 MAC (留给 VF0 用)
# ethtool 必须用网卡名，使用我们反查到的 PF_DEV
ORIG_MAC=$(ethtool -P "$PF_DEV" | awk '{print $3}')
if [ -z "$ORIG_MAC" ]; then
    echo "Error: Could not read permanent MAC from $PF_DEV"
    exit 1
fi

# 2. 清零 VF (销毁旧状态，这比解绑驱动快且稳)
echo 0 > "/sys/bus/pci/devices/$PF_PCI/sriov_numvfs"

# 3. 切换模式
# 为了防止玄学问题，先切 legacy 再切 switchdev (可选，但推荐)
# devlink dev eswitch set pci/"$PF_PCI" mode legacy 2>/dev/null || true
devlink dev param set pci/"$PF_PCI" name flow_steering_mode value "dmfs" cmode runtime
devlink dev eswitch set pci/"$PF_PCI" mode switchdev
devlink dev eswitch set pci/"$PF_PCI" inline-mode transport

# 4. 生成新 VF
echo "$TOTAL_VFS" > "/sys/bus/pci/devices/$PF_PCI/sriov_numvfs"
udevadm settle # 等待设备生成

# 5. 修改 MAC 地址
# 注意：ip link 命令必须使用 Interface Name ($PF_DEV)，不能用 PCI ID
echo "Configuring MAC addresses..."

# 5.1 先修改物理口 (PF) 为 Dummy MAC (后缀 :00)
ip link set dev "$PF_DEV" down
ip link set dev "$PF_DEV" address "$PF_DUMMY_MAC"
ip link set dev "$PF_DEV" up

# 5.2 VF 0 继承原厂物理 MAC
ip link set dev "$PF_DEV" vf 0 mac "$ORIG_MAC"

# 5.3 VF 1 ~ N 依次递增
# seq 生成从 1 到 TOTAL_VFS-1 的数字
for i in $(seq 1 $((TOTAL_VFS - 1))); do
    # 将数字转换为 2位十六进制 (01, 02 ... 0a, 0b ...)
    SUFFIX=$(printf "%02x" "$i")
    NEW_VF_MAC="${VF_PREFIX}:${SUFFIX}"
    
    # 设置 MAC
    ip link set dev "$PF_DEV" vf "$i" mac "$NEW_VF_MAC"
done

# 6. 拉起所有代表端口 (devlink 精准版)
echo "Bringing up representor ports via devlink..."
devlink port show pci/"$PF_PCI" 2>/dev/null | \
grep -o "netdev [^ ]*" | \
awk '{print $2}' | \
while read iface; do
    # 跳过 lo (虽然 devlink 通常不显示 lo) 和空的行
    [ -z "$iface" ] && continue
    
    echo "    Setting UP: $iface"
    ip link set dev "$iface" up
done

echo ">>> Configuration Complete."