#!/bin/bash
set -e # 遇到错误立即退出

# ================= 环境变量检查 =================
# 使用 Bash 参数扩展检查变量是否存在，不存在则报错退出
: "${PF_DEV:?Error: Environment variable PF_DEV is not set.}"
: "${PF_PCI:?Error: Environment variable PF_PCI is not set.}"
: "${TOTAL_VFS:?Error: Environment variable TOTAL_VFS is not set.}"
: "${VF_PREFIX:?Error: Environment variable VF_PREFIX (e.g. 02:00:00:00:02) is not set.}"

# ================= 自动计算配置 =================
# PF_DUMMY_MAC 自动拼接 :00
PF_DUMMY_MAC="${VF_PREFIX}:00"

echo ">>> Starting Switchdev Setup for $PF_DEV ($PF_PCI)"
echo "    PF Dummy MAC: $PF_DUMMY_MAC"
echo "    VF Prefix:    $VF_PREFIX"

# 1. 获取原厂永久 MAC (留给 VF0 用)
ORIG_MAC=$(ethtool -P "$PF_DEV" | awk '{print $3}')
if [ -z "$ORIG_MAC" ]; then
    echo "Error: Could not read permanent MAC from $PF_DEV"
    exit 1
fi

# 2. 清零 VF (销毁旧状态，这比解绑驱动快且稳)
# echo 0 > "/sys/class/net/$PF_DEV/device/sriov_numvfs"

# 3. 切换模式
# 为了防止玄学问题，先切 legacy 再切 switchdev (可选，但推荐)
# devlink dev eswitch set pci/"$PF_PCI" mode legacy 2>/dev/null || true
devlink dev eswitch set pci/"$PF_PCI" mode switchdev

# 4. 生成新 VF
echo "$TOTAL_VFS" > "/sys/class/net/$PF_DEV/device/sriov_numvfs"
udevadm settle # 等待设备生成

# 5. 修改 MAC 地址
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

# 6. 拉起所有代表端口 (Representors)
# 匹配该物理口下的所有 v* 端口
# find "/sys/class/net/${PF_DEV}_v"* -maxdepth 0 -type l -exec basename {} \; 2>/dev/null | xargs -r -I {} ip link set dev {} up

echo ">>> Configuration Complete."