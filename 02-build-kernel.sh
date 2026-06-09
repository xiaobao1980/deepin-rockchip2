#!/bin/bash
#===============================================================================
# 02-build-kernel.sh - Linux 内核编译脚本
# 编译 Rockchip 的 Linux 6.1 内核并生成 deb 包
# 基于: Armbian linux-rockchip (rk-6.1-rkr5.1 分支)
#===============================================================================

# NOTE: No "set -e" - we use explicit error checks to ensure all output is logged

#------------------------------------------------------------------------------
# 颜色定义
#------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }

#------------------------------------------------------------------------------
# 加载构建配置
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.buildconfig" ]; then
    source "${SCRIPT_DIR}/.buildconfig"
else
    BUILD_ROOT="${SCRIPT_DIR}"
    SOURCE_DIR="${BUILD_ROOT}/sources"
    OUTPUT_DIR="${BUILD_ROOT}/output"
    # 注意: rk-6.1-rkr5.1 分支的 6.1.115 版本已包含 RK3588 HDMI 驱动
    # 不要切换到其他分支，保持此分支以确保 HDMI 正常工作
    KERNEL_BRANCH="rk-6.1-rkr5.1"
    KERNEL_REPO="https://github.com/armbian/linux-rockchip"
    JOBS=$(nproc)
    CROSS_COMPILE="aarch64-linux-gnu-"
    ARCH="arm64"
fi

#------------------------------------------------------------------------------
# 显示帮助
#------------------------------------------------------------------------------
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
  -h, --help          显示此帮助信息
  -c, --clean         清理后重新编译
  -m, --menuconfig    编译前启动 menuconfig 交互配置
  -n, --no-deb        仅编译内核，不生成 deb 包
  -j, --jobs N        指定并行编译线程数 (默认: ${JOBS})

示例:
  $0                  # 标准编译，生成 deb 包
  $0 -c               # 清理后全量重新编译
  $0 -m               # 先 menuconfig 再编译
  $0 -j 8             # 使用 8 线程编译
EOF
}

#------------------------------------------------------------------------------
# 统一 make 调用
#------------------------------------------------------------------------------
kernel_make() {
    local kernel_dir="${SOURCE_DIR}/linux-rockchip"
    cd "$kernel_dir" || return 1
    local -a params=(
        "ARCH=${ARCH}"
        "CROSS_COMPILE=${CROSS_COMPILE}"
        "LOCALVERSION=-vendor-rk35xx"
        "-j${JOBS}"
    )
    # ccache 支持
    if command -v ccache &>/dev/null; then
        params+=("CC=ccache ${CROSS_COMPILE}gcc")
    fi
    params+=("$@")
    make "${params[@]}"
}

#------------------------------------------------------------------------------
# 下载内核源码
#------------------------------------------------------------------------------
download_kernel() {
    step "准备内核源码..."

    mkdir -p "${SOURCE_DIR}"
    cd "${SOURCE_DIR}"

    if [ ! -d "linux-rockchip" ]; then
        info "克隆 Armbian linux-rockchip (${KERNEL_BRANCH})..."
        git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" linux-rockchip
    else
        # 检查当前分支是否匹配 KERNEL_BRANCH
        cd linux-rockchip
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        if [ "$current_branch" != "$KERNEL_BRANCH" ]; then
            warn "当前分支 '${current_branch}' 与目标 '${KERNEL_BRANCH}' 不匹配"
            info "重新克隆内核源码 (分支: ${KERNEL_BRANCH})..."
            cd ..
            rm -rf linux-rockchip
            git clone --depth=1 --branch "${KERNEL_BRANCH}" "${KERNEL_REPO}" linux-rockchip
        else
            info "内核源码已存在 (分支: ${KERNEL_BRANCH})"
            if [ "$CLEAN_BUILD" = "yes" ]; then
                info "清理内核源码..."
                git reset --hard HEAD
                git clean -fdx
            fi
        fi
    fi

    ok "内核源码准备完成"
}

#------------------------------------------------------------------------------
# 应用一组内核配置（如果当前未设置的话）
#------------------------------------------------------------------------------
_kconfig_enable() {
    local cfg="$1"
    if ! grep -q "^CONFIG_${cfg}=y" .config 2>/dev/null && \
       ! grep -q "^CONFIG_${cfg}=m" .config 2>/dev/null; then
        ./scripts/config --enable "${cfg}"
    fi
}

_kconfig_module() {
    local cfg="$1"
    if ! grep -q "^CONFIG_${cfg}=" .config 2>/dev/null; then
        ./scripts/config --module "${cfg}"
    fi
}

_kconfig_disable() {
    local cfg="$1"
    if grep -q "^CONFIG_${cfg}=y" .config 2>/dev/null || \
       grep -q "^CONFIG_${cfg}=m" .config 2>/dev/null; then
        ./scripts/config --disable "${cfg}"
    fi
}

_kconfig_set_str() {
    local cfg="$1" val="$2"
    ./scripts/config --set-str "${cfg}" "${val}"
}

_kconfig_set_val() {
    local cfg="$1" val="$2"
    ./scripts/config --set-val "${cfg}" "${val}"
}

#------------------------------------------------------------------------------
# 配置内核（参考 armbian linux-rk35xx-vendor.config）
#------------------------------------------------------------------------------
configure_kernel() {
    step "配置内核..."

    local kernel_dir="${SOURCE_DIR}/linux-rockchip"
    cd "$kernel_dir"

    # ====== 1. 基础 defconfig ======
    local defconfig="rockchip_linux_defconfig"
    if [ -f "arch/arm64/configs/${defconfig}" ]; then
        info "使用 defconfig: ${defconfig}"
        make ARCH="${ARCH}" "${defconfig}"
    elif [ -f "arch/arm64/configs/rockchip_defconfig" ]; then
        info "使用 defconfig: rockchip_defconfig"
        make ARCH="${ARCH}" rockchip_defconfig
    else
        warn "未找到 Rockchip 默认配置，使用 defconfig"
        make ARCH="${ARCH}" defconfig
    fi

    # ====== 2. GPU 驱动配置：区分 RK3588 和 RK3576 ======
    # 架构对应关系：
    #   RK3588 (Mali-G610) → Panthor (CSF) 开源 DRM 驱动
    #   RK3576 (Mali-G52)  → Panfrost 开源 DRM 驱动
    # 注意：必须禁用 ARM 专有 Mali 驱动 (MALI_BIFROST/MIDGARD)，
    #       否则会与开源 DRM 驱动同时初始化同一 GPU 导致 RCU stall。
    info "配置 GPU 驱动: RK3588→Panthor, RK3576→Panfrost..."

    # 2.1 完全禁用 ARM 专有 Mali 驱动（避免与开源 DRM 驱动冲突）
    local mali_disabled=""
    for cfg in MALI_BIFROST MALI_MIDGARD MALI400 MALI450 \
               MALI_PLATFORM_THIRDPARTY MALI_EXPERT \
               MALI_BIFROST_EXPERT MALI_DEBUG MALI_PWRSOFT_765; do
        if grep -q "^CONFIG_${cfg}=y" .config 2>/dev/null || \
           grep -q "^CONFIG_${cfg}=m" .config 2>/dev/null; then
            _kconfig_disable "${cfg}"
            mali_disabled="${mali_disabled} ${cfg}"
        fi
    done
    # 同时禁用 ARM Mali 的 platform name 设置
    if grep -q "^CONFIG_MALI_PLATFORM_NAME=" .config 2>/dev/null; then
        ./scripts/config --undefine MALI_PLATFORM_NAME
        mali_disabled="${mali_disabled} MALI_PLATFORM_NAME"
    fi
    if [ -n "$mali_disabled" ]; then
        info "  -> 已禁用 ARM 专有 Mali 驱动:${mali_disabled}"
    fi

    # 2.2 保留并启用 CSF 底层支持（Panthor 驱动依赖，不是 ARM 专有驱动）
    # MALI_CSF_SUPPORT 是 ARM 固件接口层，Panthor (DRM_PANTHOR) 需要它
    if grep -q "^CONFIG_MALI_CSF_SUPPORT=" .config 2>/dev/null; then
        _kconfig_enable MALI_CSF_SUPPORT
        info "  -> 保留 MALI_CSF_SUPPORT (Panthor 依赖)"
    fi
    # MALI_DEVFREQ 是 GPU 频率调节框架，Panthor/Panfrost 都需要
    _kconfig_enable MALI_DEVFREQ

    # 2.3 启用开源 DRM GPU 驱动（作为模块，内核根据 GPU 硬件自动匹配）
    # RK3588 (Mali-G610, CSF 架构) → Panthor
    _kconfig_module DRM_PANTHOR
    # RK3576 (Mali-G52, Bifrost 架构) → Panfrost
    _kconfig_module DRM_PANFROST
    # Lima (Utgard 架构老 Mali) 也作为模块保留
    _kconfig_module DRM_LIMA
    info "  -> DRM_PANTHOR=m (RK3588), DRM_PANFROST=m (RK3576), DRM_LIMA=m"

    # ====== 3. 核心平台支持（Rockchip RK3588） ======
    for cfg in ARCH_ROCKCHIP NR_CPUS SERIAL_8250_SERIAL_DEV_BUS \
               ARM_SCMI_PROTOCOL ROCKCHIP_SIP ROCKCHIP_GRF \
               ROCKCHIP_IODOMAIN ROCKCHIP_PM_DOMAINS \
               ROCKCHIP_SYSTEM_MONITOR ROCKCHIP_CPUINFO \
               ROCKCHIP_IOMMU ROCKCHIP_SUSPEND_MODE; do
        _kconfig_enable "${cfg}"
    done

    # ====== 4. initramfs / rootfs 挂载支持 ======
    for cfg in BLK_DEV_INITRD RD_GZIP RD_XZ RD_ZSTD; do
        _kconfig_enable "${cfg}"
    done
    for cfg in EXT4_FS EXT4_FS_POSIX_ACL EXT4_FS_SECURITY; do
        _kconfig_enable "${cfg}"
    done
    # F2FS（闪存优化）+ Btrfs + XFS
    _kconfig_enable F2FS_FS
    _kconfig_enable F2FS_FS_SECURITY
    _kconfig_module BTRFS_FS
    _kconfig_module XFS_FS
    # NTFS3 读写支持
    _kconfig_module NTFS3_FS

    # ====== 5. 块设备 / NVMe / SATA ======
    for cfg in BLK_DEV_SD BLK_DEV_NVME NVME_MULTIPATH NVME_HWMON; do
        _kconfig_enable "${cfg}"
    done
    for cfg in NVME_FC NVME_TCP NVME_AUTH NVME_CORE; do
        _kconfig_enable "${cfg}"
    done
    for cfg in SATA_AHCI SATA_AHCI_PLATFORM; do
        _kconfig_enable "${cfg}"
    done

    # ====== 6. PCIe（RK3588 有 4 个控制器） ======
    for cfg in PCI PCIEPORTBUS PCIE_ROCKCHIP_HOST PCIE_DW_PLAT_HOST \
               PCIE_DW_ROCKCHIP; do
        _kconfig_enable "${cfg}"
    done

    # ====== 7. MMC/SD 启动支持 ======
    for cfg in MMC MMC_BLOCK MMC_SDHCI MMC_SDHCI_PLTFM \
               MMC_SDHCI_OF_ARASAN MMC_SDHCI_OF_DWCMSHC \
               MMC_DW MMC_DW_ROCKCHIP; do
        _kconfig_enable "${cfg}"
    done

    # ====== 8. USB 主机/设备/存储 ======
    for cfg in USB USB_OTG USB_XHCI_HCD USB_EHCI_HCD USB_EHCI_HCD_PLATFORM \
               USB_OHCI_HCD USB_OHCI_HCD_PLATFORM USB_STORAGE USB_UAS; do
        _kconfig_enable "${cfg}"
    done
    # USB DWC3（RK3588 内置）
    for cfg in USB_DWC3 USB_DWC2; do
        _kconfig_enable "${cfg}"
    done

    # ====== 9. 网络驱动（CM3588 用 RTL8125） ======
    # 有线网卡
    _kconfig_module R8168
    _kconfig_module R8169
    _kconfig_enable STMMAC_ETH
    # PHY
    _kconfig_enable REALTEK_PHY
    _kconfig_enable MOTORCOMM_PHY
    _kconfig_enable BROADCOM_PHY
    _kconfig_enable ROCKCHIP_PHY
    # 无线
    _kconfig_module WIREGUARD
    _kconfig_module RTL8723DS
    _kconfig_module RTL8821CU
    _kconfig_module RTL8822BU
    _kconfig_module RTL8189ES
    _kconfig_module RTL8852BS
    # Rockchip WiFi
    _kconfig_enable WL_ROCKCHIP
    _kconfig_enable WIFI_BUILD_MODULE
    _kconfig_module AP6XXX
    # WiFi 通用
    for cfg in ATH10K ATH10K_PCI ATH11K ATH11K_PCI RTW88 RTW89; do
        _kconfig_module "${cfg}"
    done

    # ====== 10. 声卡（CM3588 有 RT5616） ======
    for cfg in SOUND SND SND_SOC SND_SOC_ROCKCHIP SND_SOC_ROCKCHIP_I2S_TDM \
               SND_SOC_ROCKCHIP_SPDIF SND_SOC_RT5616 SND_SOC_WM8960; do
        _kconfig_enable "${cfg}"
    done

    # ====== 11. 显示/DRM ======
    # 注意: RK3588 的 HDMI 驱动在 rk-6.1-rkr5.1 中已内置
    # 不要添加不存在的配置项 (如 ROCKCHIP_DW_HDMI_QP / DRM_ROCKCHIP_VOP2)
    # 这些选项在 6.1 内核中不存在，添加会导致配置异常
    for cfg in DRM DRM_ROCKCHIP ROCKCHIP_ANALOGIX_DP ROCKCHIP_DW_HDMI \
               ROCKCHIP_DW_MIPI_DSI ROCKCHIP_LVDS ROCKCHIP_RGB \
               ROCKCHIP_MULTI_RGA; do
        _kconfig_enable "${cfg}"
    done
    _kconfig_enable FRAMEBUFFER_CONSOLE

    # ====== 12. MPP 视频编解码 ======
    for cfg in ROCKCHIP_MPP_SERVICE ROCKCHIP_MPP_RKVDEC2 \
               ROCKCHIP_MPP_RKVENC2 ROCKCHIP_MPP_AV1DEC; do
        _kconfig_enable "${cfg}"
    done

    # ====== 13. NPU（RKNN） ======
    _kconfig_enable ROCKCHIP_RKNPU

    # ====== 14. 调试/串口 ======
    _kconfig_enable FIQ_DEBUGGER
    _kconfig_enable FIQ_DEBUGGER_NO_SLEEP
    _kconfig_enable FIQ_DEBUGGER_CONSOLE
    # RCU 超时设为 60 秒（减少误报）
    if grep -q "^CONFIG_RCU_CPU_STALL_TIMEOUT=" .config 2>/dev/null; then
        _kconfig_set_val RCU_CPU_STALL_TIMEOUT 60
    fi

    # ====== 15. 虚拟化/KVM ======
    _kconfig_enable VIRTUALIZATION
    _kconfig_enable KVM

    # ====== 16. 模块签名不强制 ======
    # 确保自定义模块可以加载
    if grep -q "^CONFIG_MODULE_SIG_FORCE=y" .config 2>/dev/null; then
        warn "关闭 MODULE_SIG_FORCE（允许未签名模块加载）"
        ./scripts/config --disable MODULE_SIG_FORCE
    fi

    # ====== 17. 关键 olddefconfig 同步 ======
    info "同步配置依赖 (olddefconfig)..."
    kernel_make olddefconfig

    # ====== 18. 验证关键配置状态 ======
    info "关键内核配置摘要:"
    local cfg val
    for cfg in MALI_BIFROST MALI_MIDGARD BLK_DEV_INITRD EXT4_FS BLK_DEV_NVME \
               PCIE_ROCKCHIP_HOST MMC_BLOCK USB_STORAGE; do
        val=$(grep "^CONFIG_${cfg}=" .config 2>/dev/null || echo "# not set")
        info "  ${val}"
    done

    # ====== 19. 交互式配置 ======
    if [ "$MENUCONFIG" = "yes" ]; then
        kernel_make menuconfig
    fi

    ok "内核配置完成"
}

#------------------------------------------------------------------------------
# 编译内核并生成 deb 包
#------------------------------------------------------------------------------
build_kernel() {
    step "编译 Linux 内核..."

    local kernel_dir="${SOURCE_DIR}/linux-rockchip"
    cd "$kernel_dir"

    # 清理旧的 deb 包
    rm -f ../linux-*.deb ../linux-*.changes ../linux-*.buildinfo 2>/dev/null || true

    # 使用 bindeb-pkg: 内核自带的标准 deb 打包方式
    # 这会正确处理 LOCALVERSION=-rockchip，生成正确版本号的 deb 包
    info "编译中 (使用 ${JOBS} 线程)..."
    kernel_make bindeb-pkg

    # 检查 deb 包是否生成
    local deb_output_dir="${OUTPUT_DIR}/kernel"
    mkdir -p "$deb_output_dir"

    local f found=0
    for f in ../linux-image-*.deb ../linux-headers-*.deb ../linux-libc-dev_*.deb; do
        if [ -f "$f" ]; then
            mv "$f" "${deb_output_dir}/"
            ok "  -> $(basename "$f")"
            found=$((found + 1))
        fi
    done

    if [ "$found" -eq 0 ]; then
        error "未找到生成的 deb 包"
        return 1
    fi

    ok "共 ${found} 个 deb 包已生成"
}

#------------------------------------------------------------------------------
# 生成内核信息文件
#------------------------------------------------------------------------------
generate_kernel_info() {
    local deb_output_dir="${OUTPUT_DIR}/kernel"
    local kernel_deb
    kernel_deb=$(ls -t "${deb_output_dir}"/linux-image-*.deb 2>/dev/null | head -1)
    local kernel_version=""
    if [ -n "$kernel_deb" ]; then
        kernel_version=$(basename "$kernel_deb" | sed 's/linux-image-//;s/_.*//')
    fi

    cat > "${deb_output_dir}/kernel-info.txt" << EOF
KERNEL_VERSION=${kernel_version}
KERNEL_BRANCH=${KERNEL_BRANCH}
BUILD_TIME=$(date -Iseconds)
CROSS_COMPILE=${CROSS_COMPILE}
JOBS=${JOBS}
DEFCONFIG=rockchip_linux_defconfig
EOF

    ok "内核信息已保存"
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    CLEAN_BUILD="no"
    MENUCONFIG="no"

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -c|--clean)
                CLEAN_BUILD="yes"
                shift
                ;;
            -m|--menuconfig)
                MENUCONFIG="yes"
                shift
                ;;
            -j|--jobs)
                JOBS="$2"
                shift 2
                ;;
            -*)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                shift
                ;;
        esac
    done

    echo "========================================"
    echo "  Linux 内核编译"
    echo "========================================"
    echo "  源码分支: ${KERNEL_BRANCH}"
    echo "  并行任务: ${JOBS}"
    echo ""

    download_kernel
    configure_kernel
    build_kernel || {
        error "内核编译失败"
        return 1
    }
    generate_kernel_info

    echo ""
    echo "========================================"
    ok "内核编译完成"
    echo "========================================"
    echo "  输出目录: ${OUTPUT_DIR}/kernel/"
    echo ""
    info "下一步: 运行 ./03-build-rootfs.sh 构建根文件系统"

    return 0
}

main "$@"
exit $?
