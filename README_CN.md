# Deepin 25 Rockchip 通用镜像构建工具

用于为基于 Rockchip SoC 的开发板创建 Deepin 25 (Crimson) ARM64 镜像的完整构建系统。

## 支持的硬件

| SoC | 开发板 | GPU 叠加层 |
|-----|--------|-----------|
| **RK3588** | Orange Pi 5 Plus, ROCK 5B, NanoPC-T6, QuartzPro64, 通用 | 是 (Panthor) |
| **RK3588S** | Orange Pi 5, ROCK 5A, 通用 | 是 (Panthor) |
| **RK3568** | NanoPi R5C/R5S, ROCK 3A, 通用 | 否 |
| **RK3566** | Orange Pi 3B, 通用 | 否 |
| **RK3399** | NanoPC-T4, ROCK Pi 4, 通用 | 否 |

## 功能特性

- **模块化板级配置系统** - 轻松添加新开发板
- **多源仓库支持** - 稳定版、测试版、HWE 硬件支持版、移植版及组合
- **使用 `mmdebstrap` 自动构建根文件系统** - 干净、可复现的根文件系统
- **使用 TF-A (Trusted Firmware-A) 编译 U-Boot** - 基于主线源码
- **基于 Armbian 源码编译 Linux 内核** - 带 Rockchip 补丁的 `linux-rockchip`
- **多种桌面环境** - DDE (Deepin 桌面)、最小化、服务器
- **设备树叠加层支持** - 通过叠加层实现 GPU 加速
- **完整的硬件加速** - GPU (Mali Panthor)、VPU (MPP)、NPU (RKNPU2)
- **镜像文件生成（含压缩和校验和）**
- **直接支持 TF 卡/eMMC 刷写**

### 硬件加速

| 组件 | RK3588/RK3588S | RK3568/RK3566 | RK3399 |
|-----------|---------------|---------------|--------|
| **GPU** | Mali-G610 (OpenGL/Vulkan/OpenCL) | Mali-G52 (OpenGL ES) | Mali-T860 |
| **VPU 解码** | H.264/265 8K60, VP9 8K60, AV1 4K60 | H.264/265 4K60 | H.264/265 4K60 |
| **VPU 编码** | H.264/265 8K30 | H.264/265 1080p60 | H.264/265 1080p30 |
| **NPU** | 6 TOPS INT8 | 1 TOPS INT8 | 不适用 |

## 前置要求

### 主机系统

- x86_64 Linux 系统 (Deepin 23+, Ubuntu 22.04+, Debian 12+)
- 互联网连接
- Root/sudo 权限

### 必需软件包

```bash
sudo apt update
sudo apt install -y \
    mmdebstrap qemu-user-static binfmt-support \
    parted dosfstools uuid-runtime \
    git build-essential crossbuild-essential-arm64 \
    libncurses-dev swig flex bison u-boot-tools \
    bc rsync libssh-dev kmod cpio libelf-dev \
    libssl-dev dwarves python3-pyelftools \
    libgnutls28-dev python3-dev python3-setuptools \
    wget curl vim
```

## 快速开始

### 1. 克隆构建工具

```bash
git clone <仓库地址> deepin-rockchip-builder
cd deepin-rockchip-builder
```

### 2. 为你的开发板构建镜像

```bash
# 列出可用的开发板
ls boards/

# 构建镜像（默认：DDE 桌面，输出到镜像文件）
sudo ./build.sh -b orangepi-5-plus

# 构建最小化系统到 TF 卡
sudo ./build.sh -b nanopi-r5c -t /dev/sda -d minimal

# 构建通用 RK3568
sudo ./build.sh -b generic-rk3568 -s 16
```

### 3. 刷写镜像

```bash
# 刷写到 TF 卡
sudo dd if=output/orangepi-5-plus-*.img of=/dev/sdX bs=4M status=progress conv=fsync

# 或使用生成的刷写辅助脚本
sudo ./output/orangepi-5-plus-*/flash-orangepi-5-plus.sh /dev/sdX
```

## 构建选项

| 选项 | 说明 | 默认值 |
|--------|-------------|---------|
| `-b 开发板` | 开发板配置名称（必需） | - |
| `-t 设备` | 目标块设备（`/dev/sda`） | 镜像文件 |
| `-d 桌面` | 桌面：`dde`、`minimal`、`server` | `dde` |
| `-k 动作` | 内核：`build`、`only`、`skip` | `build` |
| `-s 大小` | 根文件系统大小（GB） | 自动 (4-8) |
| `-g GPU` | GPU 叠加层：`auto`、`yes`、`no` | `auto` |
| `-r 配置` | 源配置（见下方） | `stable` |
| `-c 文件` | 自定义 sources.list 文件 | - |
| `-m 模式` | 构建模式：`auto`、`fast`、`compat` | `auto` |
| `-h` | 显示帮助 | - |

### 构建模式 (`-m`)

| 模式 | 说明 | 速度 | 兼容性 |
|------|-------------|-------|---------------|
| `auto` | 自动检测：QEMU 使用 fast，原生使用 compat | - | - |
| `fast` | 跳过 merged-usr hook，跳过 eatmydata fsync | **快 2-3 倍** | 良好 |
| `compat` | 完整 merged-usr hook，全部兼容性特性 | 较慢 | 最大 |

> **慢速构建提示：** 在使用 QEMU 的 x86_64 主机上使用 `-m fast`。`merged-usr` hook 会执行多次 chroot 操作，这在 QEMU 用户模式模拟下非常慢。`fast` 模式跳过此 hook 同时保持完整功能。

### 源配置 (`-r`)

| 配置 | 说明 | 使用场景 |
|---------|-------------|----------|
| `stable` | 仅社区稳定仓库 | 生产系统 |
| `testing` | 测试/开发仓库 | 测试新特性 |
| `hwe` | 硬件支持（更新的 Mesa/驱动） | 新 GPU 硬件 |
| `ports` | ARM/移植优化仓库 | ARM 专用软件包 |
| `stable+testing` | 稳定版带测试版回退 | 平衡稳定性/更新 |
| `stable+hwe` | 稳定版带 HWE 新硬件支持 | **RK3588 GPU 支持（默认）** |
| `full` | 全部仓库（稳定+测试+HWE） | 开发/最大软件包 |
| `custom` | 用户提供的 sources.list（需要 `-c`） | 自定义镜像源 |

## 示例

### Orange Pi 5 Plus (RK3588) 带 DDE
```bash
sudo ./build.sh -b orangepi-5-plus
```

### Orange Pi 5 (RK3588S) 刷写到 TF 卡
```bash
sudo ./build.sh -b orangepi-5 -t /dev/sda
```

### NanoPi R5C (RK3568) 最小化系统
```bash
sudo ./build.sh -b nanopi-r5c -d minimal -s 4
```

### ROCK 5B (RK3588) 使用预编译内核
```bash
# 将内核 .deb 文件放到 workspace/ 目录
sudo ./build.sh -b rock-5b -k only
```

### 通用 RK3568 服务器
```bash
sudo ./build.sh -b generic-rk3568 -d server -s 16
```

### 源配置示例

```bash
# 仅使用稳定版（生产就绪）
sudo ./build.sh -b nanopi-r5c -r stable

# 使用 HWE 获取新 GPU 硬件支持（RK3588 自动选择）
sudo ./build.sh -b orangepi-5-plus -r stable+hwe

# 使用测试仓库获取最新软件包
sudo ./build.sh -b rock-5b -r stable+testing

# 使用全部仓库（开发）
sudo ./build.sh -b orangepi-5 -r full

# 使用自定义镜像源
sudo ./build.sh -b generic-rk3568 -r custom -c /path/to/my-sources.list

# 快速构建模式（QEMU 模拟加速 2-3 倍）
sudo ./build.sh -b orangepi-5-plus -m fast

# 最大兼容性构建
sudo ./build.sh -b rock-5b -m compat
```

## 添加新开发板

1. 在 `boards/` 中创建新的开发板配置目录：

```bash
mkdir boards/myboard
cp boards/generic-rk3568/board.conf boards/myboard/board.conf
```

2. 编辑配置，填入开发板的特定参数：
   - `UBOOT_DEFCONFIG` - U-Boot defconfig 名称
   - `RKBIN_DDR` - DDR 初始化 blob 路径
   - `RKBIN_BL31` - ARM Trusted Firmware blob 路径
   - `KERNEL_DTB` - 设备树 blob 名称
   - `SERIAL_CONSOLE` - 串口控制台设备

3. 构建：

```bash
sudo ./build.sh -b myboard
```

## 板级配置参考

### 关键变量

| 变量 | 说明 | 示例 |
|----------|-------------|---------|
| `SOC_CHIP` | SoC 标识 | `RK3588`, `RK3568` |
| `UBOOT_DEFCONFIG` | U-Boot 配置 | `orangepi-5-plus-rk3588_defconfig` |
| `RKBIN_DDR` | 相对于 rkbin/bin/ 的 DDR blob | `rk35/rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.18.bin` |
| `RKBIN_BL31` | 相对于 rkbin/bin/ 的 BL31 blob | `rk35/rk3588_bl31_v1.48.elf` |
| `TF_A_PLAT` | Trusted Firmware-A 平台 | `rk3588`, `rk3568` |
| `KERNEL_DTB` | 设备树 blob 文件名 | `rk3588-orangepi-5-plus.dtb` |
| `SERIAL_CONSOLE` | 串口控制台端口 | `ttyS2` |
| `SERIAL_BAUD` | 串口波特率 | `1500000` |

### 查找 U-Boot Defconfigs

```bash
git clone https://github.com/u-boot/u-boot --depth=1
grep -r "rk3588" u-boot/configs/ | head -20
```

### 查找 rkbin Blobs

```bash
git clone https://github.com/rockchip-linux/rkbin --depth=1
ls rkbin/bin/rk35/
```

## 项目结构

```
deepin-rockchip-builder/
├── build.sh              # 主构建脚本
├── boards/               # 开发板配置
│   ├── orangepi-5-plus/
│   │   └── board.conf
│   ├── orangepi-5/
│   │   └── board.conf
│   ├── orangepi-3b/
│   │   └── board.conf
│   ├── rock-5b/
│   │   └── board.conf
│   ├── rock-5a/
│   │   └── board.conf
│   ├── rock-5-itx/
│   │   └── board.conf
│   ├── nanopi-r5c/
│   │   └── board.conf
│   ├── nanopi-r5s/
│   │   └── board.conf
│   ├── rock-3a/
│   │   └── board.conf
│   ├── nanopc-t6/
│   │   └── board.conf
│   ├── generic-rk3588/
│   │   └── board.conf
│   ├── generic-rk3588s/
│   │   └── board.conf
│   ├── generic-rk3568/
│   │   └── board.conf
│   ├── generic-rk3566/
│   │   └── board.conf
│   ├── generic-rk3576/
│   │   └── board.conf
│   └── generic-rk3399/
│       └── board.conf
├── scripts/              # 构建脚本
│   ├── build-rootfs.sh   # 根文件系统创建
│   ├── build-uboot.sh    # U-Boot + TF-A 编译
│   ├── build-kernel.sh   # Linux 内核编译
│   ├── setup-system.sh   # 系统配置
│   ├── setup-hardware-acc.sh  # 硬件加速配置
│   ├── setup-sources.sh  # 软件源配置
│   └── pack-image.sh     # 镜像打包
├── overlays/             # 自定义 DT 叠加层
├── kernel-configs/       # 开发板专用内核配置
├── workspace/            # 构建工作区（生成）
└── output/               # 构建输出（生成）
```

## 构建流程

```
1. 环境设置
   └── 检查依赖、加载开发板配置

2. 目标准备
   ├── 创建镜像文件（或使用物理设备）
   ├── GPT 分区表
   └── 格式化 ext4 根文件系统

3. 根文件系统
   └── 使用 mmdebstrap 构建 Deepin 25 (crimson) 软件包

4. 引导加载程序
   ├── 克隆/更新 rkbin、TF-A、U-Boot
   ├── 构建 TF-A BL31
   └── 使用开发板配置构建 U-Boot

5. 内核
   ├── 克隆/更新 Armbian linux-rockchip
   ├── 配置并编译
   └── 生成 .deb 软件包

6. 系统配置 (chroot)
   ├── 安装内核软件包
   ├── 安装桌面环境
   ├── 配置 fstab、extlinux
   ├── 设置用户和密码
   └── 将引导加载程序写入引导扇区

7. 镜像打包
   ├── 卸载文件系统
   ├── 使用 xz 压缩
   ├── 生成校验和
   └── 创建刷写辅助脚本
```

## 硬件加速验证

首次启动后，验证硬件加速是否正常工作：

### GPU (RK3588 的 Mali-G610)

```bash
# 检查 GPU 驱动是否加载
dmesg | grep -E 'panthor|panfrost|mali'
# 预期输出：panthor driver initialized, Mali-G610 detected

# 检查 OpenGL
sudo apt install mesa-utils
glxinfo | grep "OpenGL renderer"
# 预期输出：Mali-G610 (Panfrost/Panthor)

# 检查 Vulkan
sudo apt install vulkan-tools
vulkaninfo | grep deviceName
# 预期输出：Mali-G610

# 检查 OpenCL
sudo apt install clinfo
clinfo | grep "Device Name"
# 预期输出：Mali-G610
```

### VPU (视频编解码)

```bash
# 检查 VPU 设备是否存在
ls -la /dev/mpp_service /dev/rga /dev/dma_heap /dev/dri/

# 检查 VPU 驱动是否加载
dmesg | grep -E 'rkvdec|rkvenc|hantro'

# 测试硬件解码
ffmpeg -hwaccel rkmpp -i test.mp4 -f null -

# 使用 MPP 测试
mpi_dec_test -t 7 -i test.h264
```

### NPU (RK3588 的 RKNPU2)

```bash
# 检查 NPU 驱动是否加载
dmesg | grep rknpu
# 预期输出：rknpu driver initialized

# 检查 NPU 设备
ls -la /dev/rknpu*

# 安装 RKNN 工具包（可选）
pip3 install rknnlite2

# 使用 Python 测试
python3 -c "from rknnlite.api import RKNNLite; print('RKNN OK')"
```

### GPU 固件

如果未检测到 GPU，可能缺少 Mali CSF 固件：

```bash
# 检查固件是否存在
ls -la /lib/firmware/arm/mali/arch10.8/mali_csffw.bin

# 如果缺失则手动下载
sudo mkdir -p /lib/firmware/arm/mali/arch10.8/
sudo curl -L -o /lib/firmware/arm/mali/arch10.8/mali_csffw.bin \
  https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/arm/mali/arch10.8/mali_csffw.bin
sudo chmod 644 /lib/firmware/arm/mali/arch10.8/mali_csffw.bin
```

## 故障排除

### 构建失败

**Q：mmdebstrap 报 GPG 错误**
```bash
# 手动导入 Deepin 密钥
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 425956BB3E31DF51
```

**Q：新开发板的 U-Boot 构建失败**
- 验证 U-Boot 源码中是否存在 `UBOOT_DEFCONFIG`
- 检查 `RKBIN_DDR` 和 `RKBIN_BL31` 路径是否正确

**Q：找不到内核 DTB**
- 检查 `KERNEL_DTB` 文件名是否与 Armbian 内核源码匹配
- 验证 `KERNEL_DTB_DIR` 是否正确（通常是 `rockchip`）

### 运行时问题

**Q：开发板无法启动**
- 连接串口控制台检查引导信息
- 验证引导加载程序写入是否正确：`sudo dd if=/dev/sdX bs=512 count=1 | xxd`
- 检查 `extlinux.conf` 中的 UUID 是否正确

**Q：RK3588 的 GPU 无法工作**
- 确保板级配置中 `ENABLE_GPU_OVERLAY=yes`
- 检查叠加层是否在 `extlinux.conf` 中加载
- 验证 `panthor` 模块是否加载：`lsmod | grep panthor`

**Q：没有网络连接**
- 检查 NetworkManager 是否运行：`systemctl status NetworkManager`
- 验证 DTB 是否有正确的以太网/PHY 配置

## 默认凭据

| 用户名 | 密码 |
|----------|----------|
| `root` | `deepin` |
| `deepin` | `deepin` |

## 贡献指南

1. Fork 本仓库
2. 在 `boards/` 中添加你的开发板配置
3. 测试构建
4. 提交包含开发板详情的 pull request

## 许可协议

本构建系统按原样提供给 Deepin 社区。基于 @zc_zhu 的原创教程。

## 参考资料

- [Orange Pi 5 Plus 原版教程](https://www.deepin.org/zh/deepin25-orangepi/)
- [Armbian Linux Rockchip](https://github.com/armbian/linux-rockchip)
- [U-Boot 主线](https://github.com/u-boot/u-boot)
- [Trusted Firmware-A](https://github.com/TrustedFirmware-A/trusted-firmware-a)
- [Rockchip rkbin](https://github.com/rockchip-linux/rkbin)
- [Deepin 社区](https://www.deepin.org/)
