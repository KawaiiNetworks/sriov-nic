# sriov-nic

在 Linux/Proxmox VE 上初始化 SR-IOV 网卡，并管理 mlx5 SF-backed hardware vDPA。脚本同时支持：

- **普通 SR-IOV (`sriov`)**：创建 VF，适用于 Intel XXV710 (`i40e`) 等不支持 Linux switchdev representor 的网卡。
- **Switchdev (`switchdev`)**：通过 `devlink` 切换 e-switch、创建 VF 和 representor，适用于驱动与固件支持 switchdev 的网卡，例如部分 Intel E810 (`ice`) 和 NVIDIA/Mellanox ConnectX (`mlx5_core`)。
- **交互式配置**：自动列出支持 SR-IOV 的 PF，选择网卡、模式、VF 数量、MAC 策略及可选调优。
- **mlx5 SF / hardware vDPA**：对运行时确实暴露 SF 能力的 ConnectX-6 级及后续设备，支持单个/批量创建、采用和删除 SF，将 SF 转为硬件 vDPA，并分配给已停止的 Proxmox VM。
- **配置文件/开机启动**：适合 Proxmox VE 或 Debian 主机在启动时先恢复 PF/VF，再恢复 SF/vDPA。

> **危险操作警告**：应用配置会删除并重新创建目标 PF 的全部 VF，切换模式时还可能短暂中断 PF 流量。不要通过目标网口远程操作；请使用物理控制台、IPMI/iDRAC/iLO 或独立管理网卡，并先停止所有使用这些 VF 的虚拟机和进程。

## 网卡兼容性

| 网卡/驱动 | 普通 SR-IOV | Switchdev | 说明 |
|---|---:|---:|---|
| Intel XXV710 / `i40e` | 是 | 否 | 使用 `MODE=sriov`；没有 VF representor |
| Intel E810 / `ice` | 是 | 视内核、固件而定 | 用 `devlink dev eswitch show` 确认 |
| NVIDIA/Mellanox ConnectX / `mlx5_core` | 是 | 视型号、固件而定 | 推荐 profile 尝试 `smfs`；不支持时自动回退到当前 steering mode |
| NVIDIA/Mellanox mlx5 SF | 不使用 PCI VF | 必须 | 不按型号字符串猜测；要求内核、驱动和固件实际暴露 SF + vDPA 能力 |
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

Switchdev 还需要内核、驱动和固件支持 `devlink` e-switch。SF/vDPA 还要求 `iproute2` 提供 `vdpa`、内核提供 `mlx5_vdpa`/`vhost_vdpa`，并为目标 PF 启用 IOMMU；`mlxconfig`/`mstconfig` 仅用于只读显示固件 SF 配额。若需要 OVS 硬件卸载：

```bash
apt install -y openvswitch-switch
```

网卡固件/BIOS 必须启用所需能力。VF PCI 直通和 mlx5 hardware vDPA 都需要主机 IOMMU。本项目不会修改 BIOS、IOMMU、`vfio-pci` 或网卡永久 firmware 配置，也不会把 representor 自动接入 OVS/Linux bridge；仅 SF 管理器可在明确确认后为已停止的 Proxmox VM 添加/移除其专属 vhost-vdpa QEMU 参数。

## 快速使用：交互模式

```bash
chmod +x ./*.sh
sudo ./set-sriov.sh
```

也可以显式指定：

```bash
sudo ./set-sriov.sh --interactive
```

顶层向导先选择：

```text
1) Configure/uninstall PF and SR-IOV VFs
2) Manage mlx5 SF-backed hardware vDPA
```

PF/VF 向导会：

1. 扫描 `/sys/bus/pci/devices/*/sriov_totalvfs`；
2. 显示接口名、PCI 地址、驱动、当前/最大 VF 数量和 switchdev 能力；
3. 选择 PF 后检查已安装的 `sriov-nic.service` 是否管理该 PF；若是，可选择重新配置或交互式卸载；
4. 新配置时选择普通 SR-IOV 或 switchdev；
5. 选择 VF 数量；
6. 选择 MAC 策略、ring 调优和 NIC TC offload；mlx5/ice 会应用各自推荐的 switchdev profile；
7. 显示摘要，并要求输入大写 `APPLY` 后才执行网卡配置；
8. 网卡配置成功后，才询问是否保存、是否在 boot service 中启用 OVS offload；
9. 若配置保存在脚本目录中，会进一步询问是否**安装并启用** `sriov-nic.service`，让该配置在开机时自动重放。

只查看可用 PF，不修改系统：

```bash
./set-sriov.sh --list
```

直接指定保存路径：

```bash
sudo ./set-sriov.sh --interactive --save ./sriov-nic.conf.pf0
```

## 交互式卸载已安装配置

仓库没有独立的 uninstall 命令。交互向导在选择 PF 后，仅在同时满足以下条件时显示卸载选项：

1. 存在 `/etc/systemd/system/sriov-nic.service`（测试/打包时可通过 `SRIOV_UNIT_PATH` 覆盖）；
2. unit 的 `ExecStart` 指向一个有效的 sriov-nic 安装目录；
3. 该安装目录中至少一个 `sriov-nic.conf*` 的 `PF_PCI` 与所选 PF 匹配。

单纯手动运行过脚本、当前存在 VF 或 switchdev 状态，但没有安装 service，不视为“旧安装”：本仓库不会在下次开机重放它，通常会随驱动重载/重启恢复。

检测到安装后菜单为：

```text
1) Reconfigure/update this PF
2) Uninstall this PF configuration
3) Cancel
```

交互式卸载可以：

- 将所选 PF 的 `sriov_numvfs` 清零；
- 将支持 e-switch 的设备切回 legacy；
- 当 PF 当前 MAC 与永久 MAC 不同时，询问是否恢复永久 MAC；
- 询问是否删除 service 安装目录中与该 PF 匹配的配置文件；
- 如果 service 没有其他 PF 配置依赖，询问是否 disable 并删除 unit；多 PF 安装只删除所选 PF 配置并保留共享 service。

卸载不会删除整个旧仓库目录，也不会自动关闭全局 OVS `hw-offload` 或接口 `hw-tc-offload`，因为这些设置可能仍被其他网卡使用。卸载要求输入大写 `UNINSTALL` 二次确认，并同样应通过带外管理通道执行。

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
ENABLE_HW_TC_OFFLOAD=false
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
ENABLE_HW_TC_OFFLOAD=true

# 通用/Intel ice 通常保持 auto；脚本只执行硬件实际暴露的属性。
FLOW_STEERING_MODE=auto
INLINE_MODE=auto
ENCAP_MODE=auto

# 只有 PF/representor 使用 OVS bridge 时设为 true；Linux bridge 必须为 false。
OVS_HW_OFFLOAD=true
```

对于 ConnectX-5/6/7 等现代 `mlx5_core` 网卡，推荐：

```bash
FLOW_STEERING_MODE=recommended
INLINE_MODE=auto
```

`recommended` 会尝试 `smfs`：它由驱动直接管理硬件 steering，规则插入速度通常优于固件管理的 `dmfs`。部分 OEM 网卡/固件虽然暴露该参数，但不支持 SMFS；此时脚本会读取当前 runtime 值（通常为 `dmfs`）、给出警告并继续，而不会在 VF 已清零后中止。显式配置 `FLOW_STEERING_MODE=smfs` 仍采用严格模式，设置失败会报错退出。

`INLINE_MODE=auto` 表示保留硬件/驱动当前值，不再无条件强制 `transport`。交互向导自动使用上述推荐 profile，并在保存配置时写入最终实际模式。

应用并检查：

```bash
sudo ./set-sriov.sh ./sriov-nic.conf.pf0
devlink dev eswitch show pci/0000:03:00.0
devlink port show pci/0000:03:00.0
```

目标模式或 VF 数量需要改变时，脚本会先将 `sriov_numvfs` 设为 `0`，再切换 e-switch 并重新创建 VF。这同时满足 `ice` 等驱动“存在 VF 时不允许切换模式”的要求。如果设备已经处于目标模式且 VF 数量一致，则直接复用现有 VF，不重复执行 `devlink ... mode switchdev`，避免 mlx5 在 representor/资源已占用时返回 `device is busy`。

现代 mlx5 内核可能把 Ethernet devlink 端口暴露为父 PCI devlink 的 nested auxiliary 实例，例如 `auxiliary/mlx5_core.eth.0`。脚本会同时遍历父/嵌套 devlink，并在旧版 iproute2 上通过相同 `phys_switch_id` 与 `phys_port_name` 回退识别 representor。

## mlx5 SF / hardware vDPA 管理

`manage-sf.sh` 管理的是 upstream mlx5 SF 路径。SF 不创建独立 PCI BDF，而是通过父 PF 的 BAR 和 auxiliary bus 工作，因此不会消耗传统 PCI function/ARI 编号。SF 与 VF 可以共存，但 SF 必须使用 `switchdev` e-switch 模式；使用 switchdev 不代表必须使用 OVS。第一版只管理本机 `controller 0`，不操作外部 host controller/BlueField ECPF SF。

项目按能力而不是型号字符串放行。创建前会检查：

- PF 绑定 `mlx5_core` 且暴露 devlink e-switch；
- 内核 `CONFIG_MLX5_SF`、`mlx5_vdpa` 和 `vhost_vdpa`；
- IOMMU group、`vdpa` 工具及 QEMU `vhost-vdpa` backend；
- 固件当前暴露的 `PER_PF_NUM_SF`、`PF_TOTAL_SF`、`PF_SF_BAR_SIZE` 和 `PF_BAR2_ENABLE`。

固件检查只读。项目**不会**执行 `mstconfig set`/`mlxconfig set`。如果 SF 配额尚未配置，需在项目外设置并冷启动。

启动交互管理器：

```bash
sudo ./manage-sf.sh
# 或在 ./set-sriov.sh 顶层菜单选择 SF management
```

菜单支持：

- 列出现有及受管 SF；
- 用 `0`、`0-7`、`0,2,4-7` 等表达式单个或批量创建；
- 采用已经手工创建的 SF；
- 单个或批量删除；
- 将一个受管 vDPA SF 添加到/移出已停止的 Proxmox VM。

创建的目标 personality 固定为硬件 vDPA：

```text
enable_eth=false
enable_rdma=false
enable_roce=false
enable_vnet=true
```

例如，PF `0000:c1:00.0`、SF0 会得到确定性逻辑名和设备链接：

```text
vDPA name:  snc-0000c1000-s0
representor: enp193s0f0sf0r（过长时使用压缩 BDF 名）
VM path:    /dev/sriov-nic/0000-c1-00-0-sf0
```

`auxiliary/mlx5_core.sf.8`、devlink port index `32768` 和 `/dev/vhost-vdpa-0` 都是动态编号，配置文件不会依赖它们；每次恢复都按稳定身份 `PF_PCI + controller + pfnum + sfnum` 重新解析。

### SF MAC 策略

交互创建提供与 VF 类似的策略：

1. 不自动配置（此状态不能分配给 VM）；
2. 保留 PF 第 1-3 字节，**仅翻转第 4 字节**，保留第 5 字节，以 SF 编号作为第 6 字节；
3. 使用指定五字节前缀和 SF 编号；
4. 为每个 SF 输入完整 MAC。

选项 2 与 VF 选项 2 使用不同地址空间。假设 PF MAC 为 `b8:3f:d2:f4:c3:9e`：

```text
VF0（翻转第 4/5 字节）: b8:3f:d2:0b:3c:00
SF0（只翻转第 4 字节）: b8:3f:d2:0b:c3:00
SF1:                        b8:3f:d2:0b:c3:01
```

派生模式支持 SF 编号 0-255；更高编号要求显式 MAC。创建前会检查当前 netdev、VF/SF、vDPA 以及所有保存配置中的 MAC 冲突。

### 保存和非交互恢复

每个 SF 独立保存为项目目录下的 `sf-nic.conf*`，格式见 `sf-nic.example.conf`：

```bash
sudo ./manage-sf.sh --apply ./sf-nic.conf.0000-c1-00-0.sf0
sudo ./manage-sf.sh --apply-all .
sudo ./manage-sf.sh --list 0000:c1:00.0
```

批量创建只是一次操作多个 SF，之后仍可独立采用、分配和删除。批量中途失败时，仅回滚本轮新建的 SF/vDPA，不删除原有 VF 或手工 SF。

`set-sriov-all.sh` 的开机顺序是：

```text
sriov-nic.conf*（PF mode / VF）
→ sf-nic.conf*（SF / hardware vDPA / stable name）
→ OVS/networking
→ pve-guests
```

当 PF 上仍有 SF 时，现有 PF/VF 管理器拒绝切回 legacy、卸载 PF 配置或改变 VF 数量，防止先破坏 VF 后才发现 SF 正在使用 e-switch。重复应用相同 VF 数量不受影响。

### 添加到 Proxmox VM

SF 必须已经保存为受管配置，目标 VM 必须停止：

```bash
sudo ./manage-sf.sh --attach ./sf-nic.conf.0000-c1-00-0.sf0 100
sudo ./manage-sf.sh --detach ./sf-nic.conf.0000-c1-00-0.sf0
```

管理器只追加一个可精确识别的 `vhost-vdpa + virtio-net-pci` QEMU `args` 片段；解绑时只删除完全匹配的片段。如果用户后来手工修改导致无法精确匹配，脚本拒绝覆盖其他参数。一个稳定 vhost 路径不能分配给两台 VM。

VM 内看到的是 virtio-net，不是 mlx5 PCI 设备，因此不能用作 guest mlx5 RDMA 或 VFIO DPDK。该设备不支持常规无状态 PVE live migration；VM 迁移到其他节点前必须由目标节点提供等价的 SF/vDPA 和稳定路径。

本项目暂不管理 SF representor 的网络接线。添加到 VM 后，应手工将打印出的稳定 representor 名加入目标 OVS/Linux bridge 或用 TC 配置；否则 VM 可以看到 virtio-net，但不保证与外部网络连通。

## 配置项

| 配置项 | 值 | 说明 |
|---|---|---|
| `MODE` | `sriov` / `switchdev` | 工作模式 |
| `PF_PCI` | 如 `0000:03:00.0` | PF 的完整 PCI 地址 |
| `TOTAL_VFS` | 正整数 | VF 数量，不得超过 `sriov_totalvfs` |
| `MAC_MODE` | `none` | 不修改 PF/VF MAC，推荐默认值 |
|  | `pf-oui-invert` | 保留 PF MAC 前三字节，第 4/5 字节逐位取反，并用 VF 序号作为第 6 字节；结果确定 |
|  | `generated` | 为全部 VF 设置 `VF_PREFIX:00`、`:01`…… |
|  | `move-pf-to-vf0` | 将 PF 永久 MAC 交给 VF 0，并修改 PF MAC；兼容原仓库行为 |
| `VF_PREFIX` | 五个 MAC 字节 | 如 `02:00:00:03:00`；每张 PF 应唯一 |
| `SET_MAX_RING` | `true` / `false` | 尝试将支持的 RX/TX ring 调至最大，失败时跳过 |
| `BRING_REPRESENTORS_UP` | `auto` / `true` / `false` | 拉起 VF/SF representor；`auto` 在 switchdev 开启、普通 SR-IOV 关闭 |
| `ENABLE_HW_TC_OFFLOAD` | `auto` / `true` / `false` | 为 PF uplink、VF/SF representor 及主机可见 VF 自动执行 `ethtool -K ... hw-tc-offload on`；`auto` 在 switchdev 开启、普通 SR-IOV 关闭 |
| `FLOW_STEERING_MODE` | `recommended` / `auto` / `dmfs` / `smfs` / 驱动值 | `recommended` 在 mlx5 尝试 `smfs` 并自动回退到当前值；`auto` 表示不修改；显式值设置失败会退出 |
| `INLINE_MODE` | `recommended` / `auto` / `none` / `link` / `network` / `transport` | `recommended` 使用网卡 profile；`auto` 表示不修改 e-switch 当前值 |
| `ENCAP_MODE` | `auto` / `none` / `basic` | 可选 e-switch 属性 |
| `OVS_HW_OFFLOAD` | `true` / `false` | 是否把 OVS 全局 `hw-offload=true` 写入 OVSDB；Linux bridge 和普通 SR-IOV 应为 `false` |

配置文件通过 Bash `source` 加载，因此只应使用自己信任的配置文件。

### NIC TC offload 与 OVS offload

两项配置彼此独立：

- `ENABLE_HW_TC_OFFLOAD=true` 为所选 PF 的 uplink、VF/SF representor 和主机可见 VF 执行 `ethtool -K <接口> hw-tc-offload on`；不支持该 feature 的接口会跳过并给出警告。
- `OVS_HW_OFFLOAD=true` 让开机 helper 设置 OVS 全局 `other_config:hw-offload=true`。延迟启动模式只使用 OVSDB 的 `--no-wait` 写入，不会等待尚未启动的 `ovs-vswitchd`。

不使用 OVS 时只需要 NIC 的 `ENABLE_HW_TC_OFFLOAD=true`，并保持 `OVS_HW_OFFLOAD=false`。配置阶段 PF 通常尚未加入目标 bridge，因此交互向导不会根据当前 master/OVSDB 状态猜测未来拓扑；选择安装 service 后只会询问一次是否使用 Open vSwitch。只有用户回答是才保存 `OVS_HW_OFFLOAD=true`。

OVS TC flower 硬件卸载仍使用默认 `system` datapath；不要把 bridge 的 `datapath_type` 设置为 `tc`。实际卸载还要求 representor 被加入 OVS bridge，这属于网络拓扑配置，不由本项目自动完成。

### MAC 策略说明

默认推荐：

```bash
MAC_MODE=none
```

这样不会修改 PF MAC，VF MAC 可由 Proxmox、libvirt 或后续的 `ip link set ... vf ... mac ...` 设置。

如需保留网卡厂商 OUI、但为 VF 使用确定的新地址空间，可在交互向导选择第 2 项：

```bash
MAC_MODE=pf-oui-invert
```

假设 PF 永久 MAC 为 `b8:3f:d2:fb:a6:f6`，脚本保留前三字节，并把第 4/5 字节逐位取反：

```text
fb XOR ff = 04
a6 XOR ff = 59

VF0 b8:3f:d2:04:59:00
VF1 b8:3f:d2:04:59:01
...
```

该算法没有随机数，同一 PF 每次运行都会得到同一个结果；`VF_PREFIX` 会在运行时从 PF 永久 MAC 重新推导。旧配置名 `pf-oui-random` 仍作为兼容别名接受，但也会使用新的确定性取反算法。

该模式保留的是厂商 OUI，而不是本地管理位，理论上仍可能与同 OUI 的真实设备地址冲突；多台主机使用时应检查前缀唯一性。

如需使用本地管理地址并固定 VF MAC，可以使用：

```bash
MAC_MODE=generated
VF_PREFIX=02:00:00:03:00
```

前缀必须正好包含五个字节。建议第一个字节为 `02`（本地管理、单播地址），且不同 PF 使用不同前缀。

## 多张网卡

在脚本目录中为每个 PF 保存一个配置，并可为每个 SF 保存独立配置：

```text
sriov-nic.conf.pf0
sriov-nic.conf.pf1
sriov-nic.conf.pf2
sf-nic.conf.0000-c1-00-0.sf0
sf-nic.conf.0000-c1-00-0.sf1
```

批量应用：

```bash
sudo ./set-sriov-all.sh
```

该脚本先执行同目录中所有 `sriov-nic.conf*`，再执行所有 `sf-nic.conf*`。因此不要在该目录留下 `.bak`、`.disabled` 等仍匹配这些模式的备份文件。

## 开机自动配置

交互向导在网卡配置成功并将配置保存到脚本目录后，会询问是否**安装并启用** `sriov-nic.service`；选择安装后才进一步询问是否在该 boot service 中启用 OVS hardware offload。它会调用 `set-systemd-service.sh` 并执行 `systemctl enable sriov-nic.service`，但不会立即启动 service。

也可以手动执行（效果相同）：

```bash
sudo ./set-systemd-service.sh          # 生成 /etc/systemd/system/sriov-nic.service
sudo systemctl enable sriov-nic.service
sudo reboot
```

请先手动应用并确认配置正确，且项目目录要放在固定路径（如 `/opt/sriov-nic`），因为生成的 unit 中保存的是绝对路径。安装服务后不要移动或删除该目录。

不要在 PF 已属于正在运行的 OVS bridge 时直接执行 `systemctl start sriov-nic.service`：Intel `ice` 会以 `Uplink port cannot be a bridge port` 拒绝初始化 switchdev。应 enable 后重启，让 systemd 在 `ovs-vswitchd` 挂载 PF 之前配置网卡。

重启后检查：

```bash
systemctl status sriov-nic.service
journalctl -u sriov-nic.service -b --no-pager
```

如果任一保存配置设置了：

```bash
OVS_HW_OFFLOAD=true
```

systemd 顺序为：

```text
sriov-nic（明确 Before=ovs-vswitchd/openvswitch-switch/pve-guests）：
  创建 VF/representor、切换 switchdev、开启 NIC hw-tc-offload
  → 恢复 sf-nic.conf* 中的 SF/vDPA 和稳定设备链接
→ prepare-ovs --defer-restart：按需确保 ovsdb-server 可用，用 ovs-vsctl --no-wait 写入 hw-offload=true
→ ovs-vswitchd/openvswitch-switch 正常启动，从 OVSDB 恢复 bridge/port
→ networking
→ pve-guests 自动启动 VM
```

`ovsdb-server` 只是数据库，不会把 PF 挂进 bridge；它可以在 sriov-nic 之前或期间独立启动，关键约束是 `ovs-vswitchd` 必须在 sriov-nic 完成之后启动。

这样 OVS 转发进程只会在网卡和 representor 准备完成之后启动，不会提前把 PF 设置为 `master ovs-system`。`--no-wait` 也避免 `ovs-vsctl` 等待 `ovs-vswitchd`、而 systemd 又让 `ovs-vswitchd` 等待 sriov-nic 的启动死锁。延迟模式不会在 sriov-nic service 内重启 OVS；手动直接运行 `prepare-ovs.sh` 时仍保留立即启动/重启 OVS 的行为。

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
ENABLE_HW_TC_OFFLOAD=true
OVS_HW_OFFLOAD=true
```

建议明确添加新配置项，尤其是 XXV710 必须设置：

```bash
MODE=sriov
MAC_MODE=none
OVS_HW_OFFLOAD=false
```

## 测试

仓库中的 SF 测试使用完全模拟的 sysfs/devlink/vDPA/PVE 环境，不会修改真实网卡，也不需要 root：

```bash
./tests/run.sh
```

覆盖选项 2 MAC、范围解析、稳定命名、创建与幂等恢复、VM attach/detach、删除、强制失败回滚、VF/SF 保存配置冲突，以及“SF 操作不改变已有 VF 数量”。静态检查可额外运行：

```bash
bash -n ./*.sh tests/*.sh
shellcheck ./*.sh tests/*.sh
```

## 常见错误

### `does not expose devlink e-switch mode`

网卡/驱动不支持 switchdev，或功能未由当前固件/内核暴露。改用：

```bash
MODE=sriov
```

XXV710 出现此结果是正常的。

### SF 固件资源未准备好

如果管理器报告 `PER_PF_NUM_SF` 未开启、`PF_TOTAL_SF=0` 或 `PF_SF_BAR_SIZE=0`，需要在项目外配置网卡固件并冷启动。项目只读检测这些字段，不会修改网卡 NVRAM。

### 有 SF 时无法切回 legacy 或改变 VF 数量

这是保护机制。VF 和 SF 可以在 switchdev 下共存，且相同 VF 数量可以重复应用；但仍有 SF 时不会重建 VF 或切回 legacy。先从 VM 解绑并用 `manage-sf.sh` 删除 SF。

### 添加 vDPA 后 VM 没有外网

项目暂不把 SF representor 加入 OVS/Linux bridge。使用 `manage-sf.sh --list` 找到稳定 representor 名，再手工接入目标网络。

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
