#!/bin/bash
#===============================================================================
# build-all.sh - 一键构建主控脚本
# 用途: 顺序执行环境准备 -> U-Boot编译 -> 内核编译 -> 根文件系统构建 -> 镜像打包
# 支持: RK3588/RK3576 多板卡批量构建
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
BOLD='\033[1m'
NC='\033[0m'

#------------------------------------------------------------------------------
# 日志初始化
#------------------------------------------------------------------------------
LOG_DIR="${BUILD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/logs"
LOG_FILE="${LOG_DIR}/$(basename "$0" .sh)-$(date +%Y%m%d_%H%M%S).log"

init_logging() {
    mkdir -p "$LOG_DIR"
    rm -f "${LOG_DIR}/latest-$(basename "$0" .sh).log"
    ln -s "$(basename "$LOG_FILE")" "${LOG_DIR}/latest-$(basename "$0" .sh).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    info "日志文件: $LOG_FILE"
}

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
highlight() { echo -e "${BOLD}$*${NC}"; }

#------------------------------------------------------------------------------
# 脚本路径
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#------------------------------------------------------------------------------
# 可配置变量
#------------------------------------------------------------------------------
# 构建步骤控制
DO_ENVSETUP=${DO_ENVSETUP:-yes}
DO_UBOOT=${DO_UBOOT:-yes}
DO_KERNEL=${DO_KERNEL:-yes}
DO_ROOTFS=${DO_ROOTFS:-yes}
DO_IMAGE=${DO_IMAGE:-yes}

# 板卡列表 (逗号分隔，或 "all")
BOARDS=${BOARDS:-"rk3588-generic,rk3588-rock5b,rk3588-opi5plus,rk3588-sige7,rk3576-rock4d,rk3576-sige5"}

# 镜像打包
PACK_BOARD=${PACK_BOARD:-"rk3588-generic"}   # 要打包为最终镜像的板卡
IMAGE_SIZE=${IMAGE_SIZE:-10}                    # 镜像大小 (GB)
COMPRESS=${COMPRESS:-no}                        # 默认不压缩镜像（压缩耗时太长，且 xz 覆盖有问题）

# 根文件系统
MINIMAL=${MINIMAL:-no}
HOSTNAME=${HOSTNAME:-deepin-rockchip}
USERNAME=${USERNAME:-deepin}
USERPASS=${USERPASS:-deepin}

#------------------------------------------------------------------------------
# 显示帮助
#------------------------------------------------------------------------------
show_help() {
    cat << EOF
用法: $0 [选项]

Deepin Rockchip 一键构建脚本
顺序执行: 环境准备 -> U-Boot -> 内核 -> 根文件系统 -> 镜像打包

选项:
  -h, --help              显示此帮助
  --only STEP             仅执行指定步骤 (envsetup|uboot|kernel|rootfs|image)
  --skip STEP             跳过指定步骤 (envsetup|uboot|kernel|rootfs|image)
  --boards LIST           板卡列表 (逗号分隔, 默认: ${BOARDS})
  --boards-all            编译所有支持的板卡
  --pack-board BOARD      打包镜像的板卡 (默认: ${PACK_BOARD})
  --image-size SIZE       镜像大小 GB (默认: ${IMAGE_SIZE})
  --no-compress           不压缩镜像
  --minimal               最小化根文件系统 (无桌面)
  --hostname NAME         主机名 (默认: ${HOSTNAME})
  --user NAME             用户名 (默认: ${USERNAME})
  --pass PASS             用户密码 (默认: ${USERPASS})
  --clean                 全量重新构建

环境变量控制:
  DO_ENVSETUP=no          跳过环境准备
  DO_UBOOT=no             跳过 U-Boot
  DO_KERNEL=no            跳过内核
  DO_ROOTFS=no            跳过根文件系统
  DO_IMAGE=no             跳过镜像打包

示例:
  $0                      # 完整构建流程
  $0 --only image         # 仅打包镜像
  $0 --skip envsetup      # 跳过环境准备
  $0 --boards rk3588-opi5plus,rk3588-rock5b
  $0 --boards-all --no-compress
  $0 --minimal --hostname myserver
  $0 --clean              # 全量重新构建

板卡列表:
  RK3588: rk3588-generic, rk3588-rock5b, rk3588-rock5a, rk3588-opi5plus,
          rk3588-coolpi4b, rk3588-cm3588, rk3588-sige7, rk3588-roc-pc
  RK3576: rk3576-generic, rk3576-evb, rk3576-rock4d, rk3576-sige5, rk3576-dshanpi
EOF
}

#------------------------------------------------------------------------------
# 记录构建时间
#------------------------------------------------------------------------------
BUILD_START=0
step_start() {
    local name=$1
    BUILD_START=$(date +%s)
    echo ""
    echo "========================================"
    highlight "  开始: ${name}"
    echo "========================================"
    echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

step_end() {
    local name=$1
    local status=$2
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - BUILD_START))
    local mins=$((duration / 60))
    local secs=$((duration % 60))

    echo ""
    if [ "$status" = "ok" ]; then
        echo "========================================"
        ok "  完成: ${name}"
        ok "  耗时: ${mins}分${secs}秒"
        echo "========================================"
    else
        echo "========================================"
        error "  失败: ${name}"
        error "  耗时: ${mins}分${secs}秒"
        echo "========================================"
    fi
    echo ""
}

#------------------------------------------------------------------------------
# 执行步骤
#------------------------------------------------------------------------------
run_step() {
    local step_name=$1
    local script=$2
    shift 2

    if [ "${!step_name}" != "yes" ]; then
        info "跳过 ${step_name}"
        return 0
    fi

    step_start "$script"
    local script_path="${SCRIPT_DIR}/${script}"

    if [ ! -x "$script_path" ]; then
        chmod +x "$script_path"
    fi

    if "$script_path" "$@"; then
        step_end "$script" "ok"
        return 0
    else
        step_end "$script" "fail"
        return 1
    fi
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --only)
                DO_ENVSETUP="no"
                DO_UBOOT="no"
                DO_KERNEL="no"
                DO_ROOTFS="no"
                DO_IMAGE="no"
                case "$2" in
                    envsetup) DO_ENVSETUP="yes" ;;
                    uboot)    DO_UBOOT="yes"    ;;
                    kernel)   DO_KERNEL="yes"   ;;
                    rootfs)   DO_ROOTFS="yes"   ;;
                    image)    DO_IMAGE="yes"    ;;
                    *)
                        error "未知步骤: $2"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --skip)
                case "$2" in
                    envsetup) DO_ENVSETUP="no" ;;
                    uboot)    DO_UBOOT="no"    ;;
                    kernel)   DO_KERNEL="no"   ;;
                    rootfs)   DO_ROOTFS="no"   ;;
                    image)    DO_IMAGE="no"    ;;
                    *)
                        error "未知步骤: $2"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --boards)
                BOARDS="$2"
                # 自动将 PACK_BOARD 设置为第一个编译的板卡
                PACK_BOARD="${BOARDS%%,*}"
                shift 2
                ;;
            --boards-all)
                BOARDS="all"
                shift
                ;;
            --pack-board)
                PACK_BOARD="$2"
                shift 2
                ;;
            --image-size)
                IMAGE_SIZE="$2"
                shift 2
                ;;
            --no-compress)
                COMPRESS="no"
                shift
                ;;
            --minimal)
                MINIMAL="yes"
                shift
                ;;
            --hostname)
                HOSTNAME="$2"
                shift 2
                ;;
            --user)
                USERNAME="$2"
                shift 2
                ;;
            --pass)
                USERPASS="$2"
                shift 2
                ;;
            --clean)
                CLEAN_FLAG="--clean"
                CLEAN_BUILD="yes"
                shift
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

    # 检查 root
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行: sudo $0"
        exit 1
    fi

    # 脚本可执行权限
    chmod +x "${SCRIPT_DIR}"/*.sh

    init_logging
    local overall_start
    overall_start=$(date +%s)

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                          ║"
    echo "║     Deepin 25 Rockchip 多板卡镜像一键构建                ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  构建计划:"
    echo "    [${DO_ENVSETUP}yes${NC}] 环境准备"
    echo "    [${DO_UBOOT}yes${NC}] U-Boot 编译"
    echo "    [${DO_KERNEL}yes${NC}] 内核编译"
    echo "    [${DO_ROOTFS}yes${NC}] 根文件系统"
    echo "    [${DO_IMAGE}yes${NC}] 镜像打包"
    echo ""
    echo "  板卡: ${BOARDS}"
    echo "  打包: ${PACK_BOARD}"
    echo ""

    local has_error=false

    # Step 1: 环境准备
    if ! run_step "DO_ENVSETUP" "00-envsetup.sh"; then
        has_error=true
    fi

    # Step 2: U-Boot
    local uboot_args
    if [ "$BOARDS" = "all" ]; then
        uboot_args="--all ${CLEAN_FLAG}"
    else
        # 替换逗号为空格
        uboot_args="${BOARDS//,/ } ${CLEAN_FLAG}"
    fi
    if ! $has_error && ! run_step "DO_UBOOT" "01-build-uboot.sh" ${uboot_args}; then
        has_error=true
    fi

    # Step 3: 内核
    local kernel_args="${CLEAN_FLAG}"
    if ! $has_error && ! run_step "DO_KERNEL" "02-build-kernel.sh" ${kernel_args}; then
        has_error=true
    fi

    # Step 4: 根文件系统
    # 智能复用：如果备份存在且非 clean 模式，自动从备份恢复并安装内核
    local rootfs_backup="${OUTPUT_DIR:-${SCRIPT_DIR}/output}/rootfs/rootfs-backup.tar"
    local rootfs_args=""
    [ "$MINIMAL" = "yes" ] && rootfs_args="${rootfs_args} --minimal"
    rootfs_args="${rootfs_args} --hostname ${HOSTNAME}"
    rootfs_args="${rootfs_args} --user ${USERNAME} --password ${USERPASS}"
    rootfs_args="${rootfs_args} ${CLEAN_FLAG}"
    if [ -f "$rootfs_backup" ] && [ "$CLEAN_BUILD" != "yes" ]; then
        info "检测到 rootfs 备份，将自动复用并安装内核"
        rootfs_args="${rootfs_args} --restore-only --install-kernel"
    fi
    if ! $has_error && ! run_step "DO_ROOTFS" "03-build-rootfs.sh" ${rootfs_args}; then
        has_error=true
    fi

    # Step 5: 镜像打包
    # 04-pack-image.sh 期望板卡ID作为位置参数（不是 --board 选项）
    local img_args=""
    img_args="${img_args} --size ${IMAGE_SIZE}"
    [ "$COMPRESS" = "yes" ] && img_args="${img_args} --compress"
    if ! $has_error && ! run_step "DO_IMAGE" "04-pack-image.sh" ${img_args} "${PACK_BOARD}"; then
        has_error=true
    fi

    # 汇总
    local overall_end
    overall_end=$(date +%s)
    local total_duration=$((overall_end - overall_start))
    local total_mins=$((total_duration / 60))
    local total_secs=$((total_duration % 60))

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    if [ "$has_error" = false ]; then
        echo "║                                                          ║"
        echo "║              构建全部完成                                ║"
        echo "║                                                          ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    else
        echo "║                                                          ║"
        echo "║              构建部分失败                                ║"
        echo "║                                                          ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    fi
    echo ""
    echo "  总耗时: ${total_mins}分${total_secs}秒"
    echo ""

    if [ "$has_error" = false ]; then
        local output_dir="${SCRIPT_DIR}/output"
        echo "  输出目录:"
        echo "    ${output_dir}/bootloader/  - U-Boot 固件"
        echo "    ${output_dir}/kernel/      - 内核 deb 包"
        echo "    ${output_dir}/rootfs/      - 根文件系统"
        echo "    ${output_dir}/images/      - 最终镜像"
        echo ""
        echo "  刷写命令:"
        echo "    ./05-flash-helper.sh list                    # 查看镜像"
        echo "    ./05-flash-helper.sh sd -d /dev/sdX          # 刷写 SD 卡"
        echo "    ./05-flash-helper.sh emmc -b ${PACK_BOARD}   # 刷写 eMMC"
        echo "    ./05-flash-helper.sh spi -b ${PACK_BOARD}    # 刷写 SPI"
        echo ""
    fi
}

main "$@"
