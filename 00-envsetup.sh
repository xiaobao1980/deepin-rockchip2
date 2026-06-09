#!/bin/bash
#===============================================================================
# 00-envsetup.sh - 环境准备与依赖安装
# 用途: 配置构建主机，安装交叉编译工具链与构建依赖
# 支持: deepin 25 / Ubuntu 22.04+ / Debian 12+
#===============================================================================

set -e

#------------------------------------------------------------------------------
# 颜色定义
#------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

#------------------------------------------------------------------------------
# 日志初始化
#------------------------------------------------------------------------------
LOG_DIR="${BUILD_ROOT}/logs"
LOG_FILE="${LOG_DIR}/$(basename "$0" .sh)-$(date +%Y%m%d_%H%M%S).log"

init_logging() {
    mkdir -p "$LOG_DIR"
    # 清除旧的日志文件链接
    rm -f "${LOG_DIR}/latest-$(basename "$0" .sh).log"
    ln -s "$(basename "$LOG_FILE")" "${LOG_DIR}/latest-$(basename "$0" .sh).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "日志文件: $LOG_FILE"
}

#------------------------------------------------------------------------------
# 配置变量
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${SCRIPT_DIR}"
SOURCE_DIR="${BUILD_ROOT}/sources"
OUTPUT_DIR="${BUILD_ROOT}/output"

# 源码版本
UBOOT_VERSION="v2025.07"
TFA_VERSION="v2.13.0"
KERNEL_BRANCH="rk-6.1-rkr5.1"
RKBIN_REPO="https://github.com/armbian/rkbin"
UBOOT_REPO="https://github.com/u-boot/u-boot"
TFA_REPO="https://github.com/TrustedFirmware-A/trusted-firmware-a"
KERNEL_REPO="https://github.com/armbian/linux-rockchip"

# 并行编译任务数
JOBS=$(nproc)

#------------------------------------------------------------------------------
# 检测发行版
#------------------------------------------------------------------------------
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

#------------------------------------------------------------------------------
# 检查 root 权限
#------------------------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行此脚本: sudo $0"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# 安装构建依赖
#------------------------------------------------------------------------------
install_dependencies() {
    info "正在安装构建依赖..."
    local distro
    distro=$(detect_distro)

    case "$distro" in
        deepin|debian|ubuntu|linuxmint|pop)
            apt update -y

            # 基础构建依赖（分步安装，避免单个包失败导致全部中断）
            info "安装基础工具..."
            apt install -y \
                curl wget git git-lfs \
                mmdebstrap qemu-user qemu-user-static \
                binfmt-support \
                build-essential crossbuild-essential-arm64 \
                libncurses-dev libssl-dev libelf-dev \
                swig flex bison bc rsync kmod cpio \
                u-boot-tools \
                dwarves python3-pyelftools \
                libgnutls28-dev python3-dev python3-setuptools \
                uuid-runtime parted dosfstools e2fsprogs \
                zip unzip tar xz-utils \
                jq xmlstarlet \
                device-tree-compiler \
                libpython3-dev

            # 兼容性处理：usrmerge
            # Debian 12+/Ubuntu 24.04+ 已默认集成 usr-merge，包被废弃
            # 旧系统（Debian 11/Ubuntu 22.04）仍需要
            info "检查 usrmerge..."
            if ! dpkg -l usrmerge &>/dev/null && \
               ! dpkg -l usr-is-merged &>/dev/null 2>/dev/null; then
                if apt-cache show usrmerge &>/dev/null 2>/dev/null; then
                    apt install -y usrmerge
                else
                    warn "usrmerge 包不可用（系统可能已默认集成 usr-merge），跳过"
                fi
            else
                ok "usr-merge 已满足"
            fi

            # 兼容性处理：python3-distutils
            # Python 3.12+ 已移除 distutils，功能合并到 python3 标准库
            info "检查 python3-distutils..."
            if ! python3 -c "import distutils" &>/dev/null 2>/dev/null; then
                if apt-cache show python3-distutils &>/dev/null 2>/dev/null; then
                    apt install -y python3-distutils
                else
                    warn "python3-distutils 不可用（Python $(python3 --version 2>/dev/null | cut -d' ' -f2) 可能已集成），跳过"
                fi
            else
                ok "python3 distutils 已可用"
            fi
            ;;
        arch|manjaro)
            pacman -Sy --needed \
                base-devel aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils \
                git wget curl qemu-user-static-binfmt \
                parted dosfstools e2fsprogs \
                dtc uboot-tools \
                python python-pyelftools \
                jdk11-openjdk
            # mmdebstrap 需从 AUR 安装
            if ! command -v mmdebstrap &>/dev/null; then
                warn "请手动从 AUR 安装 mmdebstrap: yay -S mmdebstrap"
            fi
            ;;
        fedora|rhel|centos|rocky|almalinux)
            dnf install -y \
                gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
                git wget curl qemu-user-static \
                make gcc ncurses-devel openssl-devel elfutils-devel \
                flex bison bc rsync kmod \
                uboot-tools dtc \
                dwarves python3-pyelftools \
                parted dosfstools e2fsprogs \
                uuid-runtime
            # mmdebstrap 可能需要手动安装
            if ! command -v mmdebstrap &>/dev/null; then
                warn "mmdebstrap 不在官方源中，请检查 EPEL 或手动安装"
            fi
            ;;
        *)
            error "不支持的发行版: $distro"
            error "请手动安装以下工具链:"
            error "  - aarch64-linux-gnu- (交叉编译工具链)"
            error "  - mmdebstrap (根文件系统构建)"
            error "  - qemu-user-static (用户态模拟)"
            error "  - u-boot-tools (mkimage 等工具)"
            exit 1
            ;;
    esac

    ok "依赖安装完成"
}

#------------------------------------------------------------------------------
# 验证工具链
#------------------------------------------------------------------------------
verify_toolchain() {
    info "验证交叉编译工具链..."

    if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
        error "未找到 aarch64-linux-gnu-gcc，交叉编译工具链安装失败"
        exit 1
    fi

    local version
    version=$(aarch64-linux-gnu-gcc --version | head -1)
    ok "交叉编译器: $version"

    # 验证 qemu-user-static binfmt
    if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        warn "qemu-aarch64 binfmt 未注册，尝试注册..."
        systemctl restart systemd-binfmt 2>/dev/null || \
        update-binfmts --enable qemu-aarch64 2>/dev/null || \
        warn "请手动确保 qemu-user-static 的 binfmt 已注册"
    else
        ok "qemu-aarch64 binfmt 已注册"
    fi

    # 验证关键工具
    local tools="mmdebstrap mkimage uuidgen parted mkfs.ext4 dtc"
    for tool in $tools; do
        if command -v "$tool" &>/dev/null; then
            ok "$tool 已安装"
        else
            error "$tool 未安装，请检查依赖"
            exit 1
        fi
    done
}

#------------------------------------------------------------------------------
# 创建工作目录
#------------------------------------------------------------------------------
setup_directories() {
    info "创建工作目录结构..."

    mkdir -p "${SOURCE_DIR}"
    mkdir -p "${OUTPUT_DIR}"/uboot
    mkdir -p "${OUTPUT_DIR}"/kernel
    mkdir -p "${OUTPUT_DIR}"/rootfs
    mkdir -p "${OUTPUT_DIR}"/images
    mkdir -p "${OUTPUT_DIR}"/bootloader

    ok "目录结构已创建:"
    echo "  ${SOURCE_DIR}    - 源码目录"
    echo "  ${OUTPUT_DIR}/uboot      - U-Boot 输出"
    echo "  ${OUTPUT_DIR}/kernel     - 内核输出"
    echo "  ${OUTPUT_DIR}/rootfs     - 根文件系统"
    echo "  ${OUTPUT_DIR}/images     - 最终镜像"
    echo "  ${OUTPUT_DIR}/bootloader - 引导固件"
}

#------------------------------------------------------------------------------
# 保存构建配置
#------------------------------------------------------------------------------
save_build_config() {
    local config_file="${BUILD_ROOT}/.buildconfig"
    cat > "$config_file" << EOF
# 自动生成的构建配置文件
# 生成时间: $(date -Iseconds)

# 目录
BUILD_ROOT="${BUILD_ROOT}"
SOURCE_DIR="${SOURCE_DIR}"
OUTPUT_DIR="${OUTPUT_DIR}"
LOG_DIR="${LOG_DIR}"

# 源码版本
UBOOT_VERSION="${UBOOT_VERSION}"
TFA_VERSION="${TFA_VERSION}"
KERNEL_BRANCH="${KERNEL_BRANCH}"

# 源码仓库
RKBIN_REPO="${RKBIN_REPO}"
UBOOT_REPO="${UBOOT_REPO}"
TFA_REPO="${TFA_REPO}"
KERNEL_REPO="${KERNEL_REPO}"

# 编译参数
JOBS=${JOBS}
CROSS_COMPILE=aarch64-linux-gnu-
ARCH=arm64
EOF
    ok "构建配置已保存到: $config_file"
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    echo "========================================"
    echo "  Deepin Rockchip 构建环境准备"
    echo "========================================"
    echo ""

    check_root
    init_logging
    install_dependencies
    verify_toolchain
    setup_directories
    save_build_config

    echo ""
    echo "========================================"
    ok "环境准备完成！"
    echo "========================================"
    echo ""
    info "下一步: 运行 ./01-build-uboot.sh 编译 U-Boot"
    info "或运行 ./build-all.sh 一键构建全部"
}

main "$@"
