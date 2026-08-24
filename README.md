# sriov-nic

在 Linux/Proxmox VE 上初始化 SR-IOV 网卡。脚本同时支持：

- **普通 SR-IOV (`sriov`)**：创建 VF，适用于 Intel XXV710 (`i40e`) 等不支持 Linux switchdev representor 的网卡。
- **Switchdev (`switchdev`)**：通过 `devlink` 切换 e-switch、创建 VF 和 representor，适用于驱动与固件支持 switchdev 的网卡，例如部分 Intel E810 (`ice`) 和 NVIDIA/Mellanox ConnectX (`mlx5_core`)。
- **交互式配置**：自动列出支持 SR-IOV 的 PF，选择网卡、模式、VF 数量、MAC 策略及可选调优。
- **配置文件/开机启动**：适合 Proxmox VE 或 Debian 主机在启动时恢复配置。

> **危险操作警告**：应用配置会删除并重新创建目标 PF 的全部 VF，切换模式时还可能短暂中断 PF 流量。不要通过目标网口远程操作；请使用物理控制台、IPMI/iDRAC/iLO 或独立管理网卡，并先停止所有使用这些 VF 的虚拟机和进程。

## 网卡兼容性

| 网卡/驱动 | 普通 SR-IOV | Switchdev | 说明 |
|---|---:|---:|---|
| Intel XXV710 / `i40e` | 是 | 否 | 使用 `MODE=sriov`；没有 VF representor |
| Intel E810 / `ice` | 是 | 视内核、固件而定 | 用 `devlink dev eswitch show` 确认 |
| NVIDIA/Mellanox ConnectX / `mlx5_core` | 是 | 视型号、固件而定 | 交互模式会默认尝试 `dmfs` 与 `inline-mode transport` |
| 其他 SR-IOV 网卡 | 通常可以 | 自动检测 | 普通模式只依赖标准 SR-IOV sysfs 接口 |

出现于 `devlink dev show` 中，并不等于支持 switchdev。必须确认下面的命令成功：

```bash
devlink dev eswitch show pci/0000:03:00.0
```

## 依赖

Proxmox VE / Debian：

```bash
apt update
apt install -y iproute2 ethtool pciutils
```

Switchdev 还需要内核、驱动和固件支持 `devlink` e-switch。若需要 OVS 硬件卸载：

```bash
apt install -y openvswitch-switch
```

网卡固件/BIOS 必须启用 SR-IOV。VF PCI 直通还需要单独启用 IOMMU；本项目不会配置 BIOS、IOMMU、`vfio-pci`、OVS bridge 或虚拟机。

## 快速使用：交互模式

```bash
chmod +x ./*.sh
sudo ./set-sriov.sh
```

也可以显式指定：

```bash
sudo ./set-sriov.sh --interactive
```

向导会：

1. 扫描 `/sys/bus/pci/devices/*/sriov_totalvfs`；
2. 显示接口名、PCI 地址、驱动、当前/最大 VF 数量和 switchdev 能力；
3. 选择普通 SR-IOV 或 switchdev；
4. 选择 VF 数量；
5. 选择 MAC 策略与 ring 调优；
6. 显示摘要，并要求输入大写 `APPLY` 后才执行；
7. 成功后可保存为 `sriov-nic.conf.<接口名>`；
8. 若配置保存在脚本目录中，会进一步询问是否**安装并启用** `sriov-nic.service`，让该配置在开机时自动重放。

只查看可用 PF，不修改系统：

```bash
./set-sriov.sh --list
```

直接指定保存路径：

```bash
sudo ./set-sriov.sh --interactive --save ./sriov-nic.conf.pf0
```

## 普通 SR-IOV：Intel XXV710 示例

XXV710 使用 `i40e` 驱动，不支持 `devlink eswitch switchdev`。请选择普通 SR-IOV 模式。

交互方式：

```bash
sudo ./set-sriov.sh
# 选择 XXV710 PF
# 模式选择 1) Ordinary SR-IOV (legacy)
```

配置文件方式：

```bash
cp sriov-nic.example.conf sriov-nic.conf.xxv710-0
```

编辑为：

```bash
MODE=sriov
PF_PCI=0000:03:00.0
TOTAL_VFS=8

MAC_MODE=none
VF_PREFIX=02:00:00:03:00

SET_MAX_RING=true
BRING_REPRESENTORS_UP=false
FLOW_STEERING_MODE=auto
INLINE_MODE=auto
ENCAP_MODE=auto
OVS_HW_OFFLOAD=false
```

应用：

```bash
sudo ./set-sriov.sh ./sriov-nic.conf.xxv710-0
```

验证：

```bash
cat /sys/bus/pci/devices/0000:03:00.0/sriov_numvfs
ip -d link show <PF接口名>
lspci -D | grep -i 'Virtual Function'
```

## Switchdev 示例

先确认能力：

```bash
PF=0000:03:00.0
devlink dev eswitch show pci/$PF
```

配置示例：

```bash
MODE=switchdev
PF_PCI=0000:03:00.0
TOTAL_VFS=8

MAC_MODE=none
VF_PREFIX=02:00:00:03:00
SET_MAX_RING=true
BRING_REPRESENTORS_UP=true

# 通用/Intel ice 通常保持 auto；脚本只执行硬件实际暴露的属性。
FLOW_STEERING_MODE=auto
INLINE_MODE=auto
ENCAP_MODE=auto

# 使用 OVS hardware offload 时设为 true。
OVS_HW_OFFLOAD=true
```

对于支持相关参数的 `mlx5_core` 网卡，可以改为：

```bash
FLOW_STEERING_MODE=dmfs
INLINE_MODE=transport
```

应用并检查：

```bash
sudo ./set-sriov.sh ./sriov-nic.conf.pf0
devlink dev eswitch show pci/0000:03:00.0
devlink port show pci/0000:03:00.0
```

脚本在切换模式前会先将 `sriov_numvfs` 设为 `0`，再切换 e-switch，最后重新创建 VF。这同时满足 `ice` 等驱动“存在 VF 时不允许切换模式”的要求。

## 配置项

| 配置项 | 值 | 说明 |
|---|---|---|
| `MODE` | `sriov` / `switchdev` | 工作模式 |
| `PF_PCI` | 如 `0000:03:00.0` | PF 的完整 PCI 地址 |
| `TOTAL_VFS` | 正整数 | VF 数量，不得超过 `sriov_totalvfs` |
| `MAC_MODE` | `none` | 不修改 PF/VF MAC，推荐默认值 |
|  | `generated` | 为全部 VF 设置 `VF_PREFIX:00`、`:01`…… |
|  | `move-pf-to-vf0` | 将 PF 永久 MAC 交给 VF 0，并修改 PF MAC；兼容原仓库行为 |
| `VF_PREFIX` | 五个 MAC 字节 | 如 `02:00:00:03:00`；每张 PF 应唯一 |
| `SET_MAX_RING` | `true` / `false` | 尝试将支持的 RX/TX ring 调至最大，失败时跳过 |
| `BRING_REPRESENTORS_UP` | `true` / `false` | switchdev 下拉起 representor |
| `FLOW_STEERING_MODE` | `auto` / 驱动值 | `auto` 表示不修改；`dmfs` 主要用于 mlx5 |
| `INLINE_MODE` | `auto` / `none` / `link` / `network` / `transport` | 可选 e-switch 属性 |
| `ENCAP_MODE` | `auto` / `none` / `basic` | 可选 e-switch 属性 |
| `OVS_HW_OFFLOAD` | `true` / `false` | 开机服务是否启用并重启 OVS；普通 SR-IOV 应为 `false` |

配置文件通过 Bash `source` 加载，因此只应使用自己信任的配置文件。

### MAC 策略说明

默认推荐：

```bash
MAC_MODE=none
```

这样不会修改 PF MAC，VF MAC 可由 Proxmox、libvirt 或后续的 `ip link set ... vf ... mac ...` 设置。

如需固定 VF MAC，可以使用：

```bash
MAC_MODE=generated
VF_PREFIX=02:00:00:03:00
```

前缀必须正好包含五个字节。建议第一个字节为 `02`（本地管理、单播地址），且不同 PF 使用不同前缀。

## 多张网卡

在脚本目录中为每个 PF 保存一个配置：

```text
sriov-nic.conf.pf0
sriov-nic.conf.pf1
sriov-nic.conf.pf2
```

批量应用：

```bash
sudo ./set-sriov-all.sh
```

该脚本会执行同目录中所有 `sriov-nic.conf*` 文件。因此不要在该目录留下 `sriov-nic.conf.bak`、`sriov-nic.conf.disabled` 等仍匹配该模式的备份文件。

## 开机自动配置

交互向导在配置保存到脚本目录后，会直接询问是否**安装并启用** `sriov-nic.service`；同意后它会调用 `set-systemd-service.sh` 并执行 `systemctl enable sriov-nic.service`。

也可以手动执行（效果相同）：

```bash
sudo ./set-systemd-service.sh          # 生成 /etc/systemd/system/sriov-nic.service
sudo systemctl enable sriov-nic.service
```

请先手动应用并确认配置正确，且项目目录要放在固定路径（如 `/opt/sriov-nic`），因为生成的 unit 中保存的是绝对路径。安装服务后不要移动或删除该目录。

测试服务：

```bash
sudo systemctl start sriov-nic.service
systemctl status sriov-nic.service
journalctl -u sriov-nic.service -b --no-pager
```

如果任一保存配置设置了：

```bash
OVS_HW_OFFLOAD=true
```

服务会先执行：

```bash
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
systemctl restart openvswitch-switch.service
```

没有配置请求 OVS offload 时，不会要求安装或重启 OVS。

## 从旧版配置升级

旧版三行配置仍可使用：

```bash
PF_PCI=0000:03:00.0
TOTAL_VFS=8
VF_PREFIX=02:00:00:03:00
```

为兼容旧行为，它会被解释为：

```bash
MODE=switchdev
MAC_MODE=move-pf-to-vf0
FLOW_STEERING_MODE=dmfs
INLINE_MODE=transport
OVS_HW_OFFLOAD=true
```

建议明确添加新配置项，尤其是 XXV710 必须设置：

```bash
MODE=sriov
MAC_MODE=none
OVS_HW_OFFLOAD=false
```

## 常见错误

### `does not expose devlink e-switch mode`

网卡/驱动不支持 switchdev，或功能未由当前固件/内核暴露。改用：

```bash
MODE=sriov
```

XXV710 出现此结果是正常的。

### 写 `sriov_numvfs` 时出现 `Device or resource busy`

至少一个 VF 正被虚拟机、`vfio-pci`、DPDK 或其他进程占用。停止使用者后重试。

### `Changing eswitch mode is allowed only if there is no VFs created`

说明 VF 没有成功清零，通常是 VF 仍被占用。脚本本身会先写入 `0`，应检查日志以及：

```bash
cat /sys/bus/pci/devices/<PF_PCI>/sriov_numvfs
lspci -Dnnk
```

### 执行后网络中断

模式切换、PF MAC 修改、VF 重建和 OVS 重启都可能导致中断。请从独立管理通道恢复；不要在目标 PF 承载当前 SSH 会话时应用。
