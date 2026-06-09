#!/bin/bash
#===============================================================================
# 05-flash-helper.sh - 刷写辅助脚本
# 用途: 帮助用户将镜像刷写到 SD 卡、eMMC、SPI Flash 或 NVMe
# 支持: rkdeveloptool / dd 等多种刷写方式
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
prompt() { echo -e "${BOLD}[PROMPT]${NC} $*"; }

#------------------------------------------------------------------------------
# 加载构建配置
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.buildconfig" ]; then
    source "${SCRIPT_DIR}/.buildconfig"
else
    BUILD_ROOT="${SCRIPT_DIR}"
    OUTPUT_DIR="${BUILD_ROOT}/output"
fi

#------------------------------------------------------------------------------
# 可配置变量
#------------------------------------------------------------------------------
IMAGES_DIR="${OUTPUT_DIR}/images"
BOOTLOADER_DIR="${OUTPUT_DIR}/bootloader"

#------------------------------------------------------------------------------
# 显示帮助
#------------------------------------------------------------------------------
show_help() {
    cat << EOF
用法: $0 <命令> [选项]

命令:
  sd          刷写 SD/TF 卡
  emmc        通过 MaskROM 模式刷写 eMMC
  spi         刷写 SPI Flash (仅 U-Boot)
  nvme        刷写 NVMe 硬盘
  list        列出可用镜像和设备
  bootonly    仅刷写 U-Boot (不刷系统)

通用选项:
  -h, --help          显示此帮助信息
  -i, --image FILE    指定镜像文件
  -d, --device DEV    指定目标设备 (如 /dev/sda)
  -b, --board ID      指定板卡 ID
  -y, --yes           自动确认 (危险)

示例:
  $0 list                               # 列出镜像和设备
  $0 sd -i image.img -d /dev/sda       # 刷写到 SD 卡
  $0 emmc -b rk3588-rock5b -i image.img # 通过 MaskROM 刷 eMMC
  $0 spi -b rk3588-opi5plus            # 刷写 U-Boot 到 SPI
  $0 nvme -i image.img -d /dev/nvme0n1  # 刷写到 NVMe
EOF
}

#------------------------------------------------------------------------------
# 列出可用镜像和设备
#------------------------------------------------------------------------------
cmd_list() {
    step "可用镜像:"
    if [ -d "$IMAGES_DIR" ] && [ "$(ls -A "${IMAGES_DIR}/"*.img* 2>/dev/null)" ]; then
        local img
        for img in "${IMAGES_DIR}"/*.img*; do
            local size
            size=$(ls -lh "$img" | awk '{print $5}')
            printf "  %-50s %s\n" "$(basename "$img")" "$size"
        done
    else
        warn "  未找到镜像文件 (${IMAGES_DIR})"
    fi

    echo ""
    step "可用 Bootloader:"
    if [ -d "$BOOTLOADER_DIR" ]; then
        local board_dir
        for board_dir in "${BOOTLOADER_DIR}"/*; do
            if [ -d "$board_dir" ]; then
                local bid
                bid=$(basename "$board_dir")
                local has_uboot="否"
                [ -f "${board_dir}/u-boot-rockchip.bin" ] && has_uboot="是"
                printf "  %-22s U-Boot: %-3s\n" "$bid" "$has_uboot"
            fi
        done
    else
        warn "  未找到 Bootloader (${BOOTLOADER_DIR})"
    fi

    echo ""
    step "可用存储设备:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E "disk|loop" || true
}

#------------------------------------------------------------------------------
# 确认危险操作
#------------------------------------------------------------------------------
confirm_danger() {
    local target=$1
    local action=$2

    if [ "$AUTO_YES" = "yes" ]; then
        return 0
    fi

    echo ""
    warn "========================================"
    warn "  危险操作确认"
    warn "========================================"
    warn "  操作: ${action}"
    warn "  目标: ${target}"
    warn "  警告: 此操作将擦除目标设备上的所有数据"
    warn "========================================"
    echo ""
    prompt "确认继续? [y/N] "
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        info "操作已取消"
        exit 0
    fi
}

#------------------------------------------------------------------------------
# 查找镜像文件
#------------------------------------------------------------------------------
find_image() {
    local specified=$1

    if [ -n "$specified" ]; then
        if [ -f "$specified" ]; then
            echo "$specified"
            return 0
        fi
        if [ -f "${IMAGES_DIR}/${specified}" ]; then
            echo "${IMAGES_DIR}/${specified}"
            return 0
        fi
        error "指定的镜像不存在: ${specified}"
        exit 1
    fi

    # 自动查找最新的镜像
    local latest
    latest=$(ls -t "${IMAGES_DIR}"/*.img 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        echo "$latest"
        return 0
    fi

    latest=$(ls -t "${IMAGES_DIR}"/*.img.xz 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        echo "$latest"
        return 0
    fi

    error "未找到可用镜像，请使用 -i 指定"
    exit 1
}

#------------------------------------------------------------------------------
# 查找板卡 bootloader
#------------------------------------------------------------------------------
find_board_bootloader() {
    local board_id=$1
    local board_dir="${BOOTLOADER_DIR}/${board_id}"

    if [ ! -d "$board_dir" ]; then
        error "未找到板卡 ${board_id} 的 bootloader"
        error "请先运行: ./01-build-uboot.sh ${board_id}"
        exit 1
    fi

    echo "$board_dir"
}

#------------------------------------------------------------------------------
# 解压 xz 镜像
#------------------------------------------------------------------------------
decompress_if_needed() {
    local img=$1
    if [[ "$img" == *.xz ]]; then
        info "解压 xz 压缩镜像..."
        local tmp_img="/tmp/deepin-flash-img-$$.img"
        xz -dc "$img" > "$tmp_img"
        echo "$tmp_img"
    else
        echo "$img"
    fi
}

#------------------------------------------------------------------------------
# SD 卡刷写
#------------------------------------------------------------------------------
cmd_sd() {
    local img=$(find_image "$IMAGE_FILE")
    local dev="${DEVICE:-}"
    local board="${BOARD_ID:-}"

    if [ -z "$dev" ]; then
        echo ""
        info "可用磁盘设备:"
        lsblk -d -o NAME,SIZE,TYPE,MODEL,STATE | grep disk || true
        echo ""
        prompt "请输入目标 SD 卡设备 (如 /dev/sda): "
        read -r dev
    fi

    if [ ! -b "$dev" ]; then
        error "设备不存在: ${dev}"
        exit 1
    fi

    confirm_danger "$dev" "将镜像刷写到 SD 卡"

    step "刷写镜像到 SD 卡..."
    info "镜像: $(basename "$img")"
    info "设备: ${dev}"

    # 取消挂载
    umount "${dev}"* 2>/dev/null || true

    # 如果需要，解压镜像
    local real_img
    real_img=$(decompress_if_needed "$img")

    # 使用 dd 刷写系统镜像
    dd if="$real_img" of="$dev" bs=4M status=progress conv=fsync

    # 清理临时文件
    if [ "$real_img" != "$img" ]; then
        rm -f "$real_img"
    fi

    # 如果有指定板卡，同时烧录 U-Boot 到 SD 卡启动分区
    if [ -n "$board" ]; then
        local uboot_dir="${BOOTLOADER_DIR}/${board}"
        if [ -d "$uboot_dir" ]; then
            step "烧录 U-Boot 到 SD 卡..."
            # idbloader.img -> 扇区 64 (0x40)
            if [ -f "${uboot_dir}/idbloader.img" ]; then
                info "  -> idbloader.img @ 扇区 64"
                dd if="${uboot_dir}/idbloader.img" of="$dev" seek=64 bs=512 conv=fsync
            fi
            # u-boot.itb -> 扇区 0x4000 (16384)
            if [ -f "${uboot_dir}/u-boot.itb" ]; then
                info "  -> u-boot.itb @ 扇区 0x4000"
                dd if="${uboot_dir}/u-boot.itb" of="$dev" seek=16384 bs=512 conv=fsync
            fi
            ok "U-Boot 烧录完成"
        else
            warn "未找到板卡 ${board} 的 U-Boot 文件，跳过 U-Boot 烧录"
            info "可用板卡:"
            ls "${BOOTLOADER_DIR}/" 2>/dev/null || true
        fi
    fi

    sync
    ok "SD 卡刷写完成"
    info "请安全拔出 SD 卡并插入开发板启动"
}

#------------------------------------------------------------------------------
# eMMC 刷写 (通过 MaskROM)
# 注意: rkdeveloptool 需要 root 权限访问 USB 设备
#------------------------------------------------------------------------------
cmd_emmc() {
    local img=$(find_image "$IMAGE_FILE")
    local board="${BOARD_ID:-}"

    if [ -z "$board" ]; then
        error "请指定板卡 ID: -b <board_id>"
        echo "可用板卡:"
        ls "${BOOTLOADER_DIR}/" 2>/dev/null || true
        exit 1
    fi

    # 检查 rkdeveloptool
    if ! command -v rkdeveloptool &>/dev/null; then
        error "rkdeveloptool 未安装"
        info "安装方法:"
        info "  git clone https://github.com/rockchip-linux/rkdeveloptool"
        info "  cd rkdeveloptool && make && sudo make install"
        exit 1
    fi

    # 确定 sudo 前缀（rkdeveloptool 需要 root 权限访问 USB）
    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo &>/dev/null; then
            SUDO="sudo"
            info "使用 sudo 获取 USB 访问权限"
        else
            error "需要 root 权限访问 USB 设备"
            error "请使用 sudo 运行此脚本，或以 root 用户执行"
            exit 1
        fi
    fi

    step "eMMC 刷写 (${board})"
    info "镜像: $(basename "$img")"

    # 等待设备进入 MaskROM
    info "请将设备进入 MaskROM 模式 (按住 Maskrom 键上电)"
    info "等待设备连接..."

    local retry=0
    while true; do
        if ${SUDO} rkdeveloptool ld 2>/dev/null | grep -qE "(Maskrom|Loader)"; then
            ok "设备已连接"
            break
        fi
        sleep 2
        retry=$((retry + 1))
        if [ $retry -gt 30 ]; then
            error "等待超时，请检查设备连接"
            error "  1. 确保 USB 线缆连接可靠（推荐使用 USB-A 转 USB-C）"
            error "  2. 按住 Maskrom 键后上电/按复位键"
            error "  3. 检查 rkdeveloptool 是否有 USB 权限: sudo rkdeveloptool ld"
            exit 1
        fi
        echo -n "."
    done

    # ========================================================================
    # 查找 SPL loader：严格按 SoC 型号匹配 + 版本号排序
    # RK3588 必须使用 rk3588_* loader，不能用 rk356x/rk3528 等
    # ======================================================================
    local spl_loader=""
    local rkbin_dir="${SOURCE_DIR:-${BUILD_ROOT}/sources}/rkbin"

    # 从板卡数据库确定 SoC 型号（如 rk3588）
    local soc_id=""
    case "$board" in
        rk3588-*) soc_id="rk3588" ;;
        rk3568-*) soc_id="rk3568" ;;
        rk3566-*) soc_id="rk3566" ;;
        rk3528-*) soc_id="rk3528" ;;
        rk3576-*) soc_id="rk3576" ;;
        *)
            # 从板卡 ID 前缀推断
            soc_id="${board%%-*}"
            ;;
    esac
    info "板卡 SoC 型号: ${soc_id}"

    # 辅助函数：从文件名提取版本号（如 v1.19.113 -> 1.19.113）
    _extract_version() {
        local fname="$(basename "$1")"
        echo "$fname" | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null || echo "0.0.0"
    }

    # 辅助函数：过滤匹配 SoC 的 loader，选择版本号最高的
    _select_best_loader() {
        local target_soc="$1"; shift
        local best="" best_ver="0.0.0"
        for f in "$@"; do
            [ -f "$f" ] || continue
            local fname
            fname=$(basename "$f")
            # 严格匹配 SoC 前缀（rk3588_ 不能匹配 rk3568_）
            if ! echo "$fname" | grep -q "^${target_soc}_"; then
                continue
            fi
            local ver
            ver=$(_extract_version "$f")
            local a1 a2 a3 b1 b2 b3
            IFS='.' read -r a1 a2 a3 <<< "$best_ver"
            IFS='.' read -r b1 b2 b3 <<< "$ver"
            if [ "$b1" -gt "${a1:-0}" ] 2>/dev/null || \
               ([ "$b1" -eq "${a1:-0}" ] 2>/dev/null && [ "$b2" -gt "${a2:-0}" ] 2>/dev/null) || \
               ([ "$b1" -eq "${a1:-0}" ] 2>/dev/null && [ "$b2" -eq "${a2:-0}" ] 2>/dev/null && [ "$b3" -gt "${a3:-0}" ] 2>/dev/null); then
                best="$f"
                best_ver="$ver"
            fi
        done
        echo "$best"
    }

    # 收集所有 loader 候选
    local all_loaders=()

    # 1. 在 BOOTLOADER_DIR 中查找（限制为匹配 SoC 的）
    while IFS= read -r f; do
        [ -n "$f" ] && all_loaders+=("$f")
    done < <(find "${BOOTLOADER_DIR}" -name "${soc_id}*_spl_loader_*.bin" 2>/dev/null)

    # 2. 在 rkbin/bin/rk35 中查找
    if [ -d "${rkbin_dir}/bin/rk35" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] && all_loaders+=("$f")
        done < <(find "${rkbin_dir}/bin/rk35" -name "${soc_id}*spl_loader*.bin" 2>/dev/null)
    fi

    # 3. 在 rkbin 全局查找（限制搜索范围避免误匹配）
    while IFS= read -r f; do
        [ -n "$f" ] && all_loaders+=("$f")
    done < <(find "${rkbin_dir}" -name "${soc_id}*spl_loader*.bin" -maxdepth 3 2>/dev/null)

    # 4. 常用路径（版本从高到低）
    if [ "$soc_id" = "rk3588" ]; then
        local common_paths=(
            "${rkbin_dir}/bin/rk35/rk3588_spl_loader_v1.19.113.bin"
            "${rkbin_dir}/bin/rk35/rk3588_spl_loader_v1.15.113.bin"
            "${rkbin_dir}/bin/rk35/rk3588_spl_loader_v1.12.109.bin"
            "${rkbin_dir}/bin/rk35/rk3588_spl_loader_v1.08.111.bin"
        )
        for p in "${common_paths[@]}"; do
            [ -f "$p" ] && all_loaders+=("$p")
        done
    fi

    # 从匹配的候选中选择版本号最高的
    if [ ${#all_loaders[@]} -gt 0 ]; then
        spl_loader=$(_select_best_loader "$soc_id" "${all_loaders[@]}")
    fi

    # 加载 SPL loader
    if [ -n "$spl_loader" ] && [ -f "$spl_loader" ]; then
        info "加载 SPL loader: $(basename "$spl_loader")"
        info "路径: ${spl_loader}"
        if ! ${SUDO} rkdeveloptool db "$spl_loader"; then
            error "SPL loader 加载失败"
            error "可能原因:"
            error "  1. 权限不足: 请使用 sudo 运行"
            error "  2. USB 连接问题: 更换 USB 端口/线缆（建议用 USB 2.0 端口）"
            error "  3. 设备未进入 MaskROM 模式: 按住 Maskrom 键再上电"
            error "  4. Loader 文件不兼容: 尝试其他版本的 spl_loader"
            exit 1
        fi
        info "SPL loader 加载成功，等待设备切换到 Loader 模式..."
        # 等待设备从 MaskROM 切换到 Loader 模式（需要 3-10 秒）
        sleep 3
        local wait_retry=0
        while [ $wait_retry -lt 20 ]; do
            if ${SUDO} rkdeveloptool ld 2>/dev/null | grep -qE "(Loader|Download)"; then
                ok "设备已进入 Loader 模式，可以写入镜像"
                break
            fi
            sleep 1
            wait_retry=$((wait_retry + 1))
            echo -n "."
        done
        if [ $wait_retry -ge 20 ]; then
            warn "设备可能未完全进入 Loader 模式，但继续尝试写入..."
        fi
    else
        error "未找到 SPL loader"
        error "请确保 rkbin 仓库已下载:"
        error "  ${rkbin_dir}"
        error "或手动下载 RK3588 loader:"
        error "  https://github.com/rockchip-linux/rkbin/raw/master/bin/rk35/rk3588_spl_loader_v1.19.113.bin"
        exit 1
    fi

    # 查找板卡的 idbloader.img（用于烧录到 boot0）
    local board_dir="${BOOTLOADER_DIR}/${board}"
    local idbloader_img=""
    if [ -f "${board_dir}/idbloader.img" ]; then
        idbloader_img="${board_dir}/idbloader.img"
    fi

    # 如果需要，解压镜像
    local real_img
    real_img=$(decompress_if_needed "$img")

    # 写入镜像到 eMMC 扇区 0（完整镜像，含 idbloader/u-boot 在 MBR 区域）
    info "写入镜像到 eMMC (这可能需要几分钟)..."
    if ! ${SUDO} rkdeveloptool wl 0 "$real_img"; then
        error "镜像写入失败"
        exit 1
    fi
    ok "镜像写入完成"

    # =========================================================================
    # 将 idbloader 烧录到 eMMC boot0 分区（关键步骤！）
    # Rockchip ROM 默认从 eMMC boot0 加载 SPL，如果 boot0 为空则进入 MaskROM
    # =========================================================================
    if [ -n "$idbloader_img" ] && [ -f "$idbloader_img" ]; then
        info "烧录 idbloader 到 eMMC boot0 分区..."

        # 方案 1：使用 rkdeveloptool ul 命令写入 boot0（标准方式）
        if ${SUDO} rkdeveloptool ul "$idbloader_img"; then
            ok "idbloader 已烧录到 boot0"

            # 验证 boot0 内容（某些版本的 rkdeveloptool 支持读取）
            info "验证 boot0 写入..."
            local boot0_verify="${TMPDIR:-/tmp}/boot0-verify-$(date +%s).bin"
            if ${SUDO} rkdeveloptool rl 0 0x4000 "$boot0_verify" 2>/dev/null; then
                if diff "$idbloader_img" "$boot0_verify" >/dev/null 2>&1; then
                    ok "boot0 验证通过"
                else
                    warn "boot0 验证: 内容可能不一致（大小不同或写入偏移问题）"
                fi
                rm -f "$boot0_verify"
            else
                info "当前 rkdeveloptool 版本不支持 boot0 读取验证，跳过"
            fi
        else
            warn "============================================"
            warn "boot0 烧录失败！eMMC 将无法自动启动"
            warn "============================================"
            warn ""
            warn "原因分析："
            warn "  rkdeveloptool 'ul' 命令需要特定版本的工具"
            warn "  或设备当前模式不支持直接写入 boot0"
            warn ""
            warn "【备选方案】使用 SD 卡启动后修复 boot0："
            warn "  1. 用 SD 卡启动系统"
            warn "  2. 将 idbloader.img 复制到 /tmp/"
            warn "  3. 执行以下 U-Boot 命令（在串口控制台按 Ctrl+C 进入）："
            warn ""
            warn "     mmc dev 0 0"
            warn "     fatload mmc 1:1 0x40000000 /tmp/idbloader.img"
            warn "     mmc write 0x40000000 0 0x4000"
            warn "     mmc bootbus 0 2 0 0"
            warn "     mmc partconf 0 1 0 0"
            warn "     reset"
            warn ""
            warn "【或从 Linux 系统修复 boot0】："
            warn "  1. SD 卡启动后，找到 eMMC 设备（通常是 /dev/mmcblk0）"
            warn "  2. 执行："
            warn "     dd if=/tmp/idbloader.img of=/dev/mmcblk0boot0 bs=512 seek=0"
            warn "     echo 0 > /sys/block/mmcblk0boot0/force_ro"
            warn "     mmc bootpart enable 1 0 /dev/mmcblk0"
            warn ""
            warn "【应急方案】使用 'ul' 前尝试工具更新："
            warn "  git clone https://github.com/rockchip-linux/rkdeveloptool"
            warn "  cd rkdeveloptool && cmake . && make && sudo make install"
            warn ""
        fi
    else
        warn "未找到 idbloader.img，跳过 boot0 烧录"
        warn "  查找路径: ${board_dir}/idbloader.img"
        warn "  这会导致 eMMC 无法自动启动（需要外部启动介质如 SD 卡）"
    fi

    # 重启
    info "刷写完成，重启设备..."
    ${SUDO} rkdeveloptool rd

    # 清理
    if [ "$real_img" != "$img" ]; then
        rm -f "$real_img"
    fi

    ok "eMMC 刷写完成，设备正在重启"
}

#------------------------------------------------------------------------------
# SPI Flash 刷写 (仅 U-Boot)
#------------------------------------------------------------------------------
cmd_spi() {
    local board="${BOARD_ID:-}"

    if [ -z "$board" ]; then
        error "请指定板卡 ID: -b <board_id>"
        exit 1
    fi

    local board_dir
    board_dir=$(find_board_bootloader "$board")

    # 检查 rkdeveloptool
    if ! command -v rkdeveloptool &>/dev/null; then
        error "rkdeveloptool 未安装"
        exit 1
    fi

    # 确定 sudo 前缀
    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo &>/dev/null; then
            SUDO="sudo"
        else
            error "需要 root 权限"
            exit 1
        fi
    fi

    # 查找 SPI U-Boot 镜像
    local uboot_spi="${board_dir}/u-boot-rockchip-spi.bin"
    local uboot_full="${board_dir}/u-boot-rockchip.bin"

    local uboot_img=""
    if [ -f "$uboot_spi" ]; then
        uboot_img="$uboot_spi"
    elif [ -f "$uboot_full" ]; then
        uboot_img="$uboot_full"
        warn "未找到专用 SPI 镜像，使用通用镜像"
    fi

    if [ -z "$uboot_img" ]; then
        error "未找到可用的 U-Boot 镜像"
        exit 1
    fi

    confirm_danger "SPI Flash" "刷写 U-Boot 到 SPI Flash (${board})"

    step "刷写 U-Boot 到 SPI Flash (${board})"
    info "U-Boot: $(basename "$uboot_img")"

    # 等待设备
    info "请将设备进入 MaskROM 模式"
    local retry=0
    while true; do
        if ${SUDO} rkdeveloptool ld 2>/dev/null | grep -qE "(Maskrom|Loader)"; then
            ok "设备已连接"
            break
        fi
        sleep 2
        retry=$((retry + 1))
        if [ $retry -gt 30 ]; then
            error "等待超时"
            exit 1
        fi
        echo -n "."
    done

    # 查找 SPL loader（严格按 SoC 型号匹配）
    local spl_loader=""
    local rkbin_dir="${SOURCE_DIR:-${BUILD_ROOT}/sources}/rkbin"
    local soc_id="${board%%-*}"

    spl_loader=$(find "${BOOTLOADER_DIR}" -name "${soc_id}*_spl_loader_*.bin" 2>/dev/null | head -1)
    if [ -z "$spl_loader" ] && [ -d "${rkbin_dir}/bin/rk35" ]; then
        spl_loader=$(find "${rkbin_dir}/bin/rk35" -name "${soc_id}*spl_loader*.bin" 2>/dev/null | head -1)
    fi
    if [ -z "$spl_loader" ]; then
        spl_loader=$(find "${rkbin_dir}" -name "${soc_id}*spl_loader*.bin" -maxdepth 3 2>/dev/null | head -1)
    fi
    if [ -n "$spl_loader" ] && [ -f "$spl_loader" ]; then
        info "加载 SPL: $(basename "$spl_loader")"
        ${SUDO} rkdeveloptool db "$spl_loader" || warn "loader 加载失败，继续尝试..."
        sleep 1
    fi

    # 写入 SPI
    info "写入 U-Boot 到 SPI Flash..."
    ${SUDO} rkdeveloptool wl 0 "$uboot_img"

    # 重启
    ${SUDO} rkdeveloptool rd

    ok "SPI Flash U-Boot 刷写完成"
}

#------------------------------------------------------------------------------
# NVMe 刷写
#------------------------------------------------------------------------------
cmd_nvme() {
    local img=$(find_image "$IMAGE_FILE")
    local dev="${DEVICE:-}"

    if [ -z "$dev" ]; then
        dev="/dev/nvme0n1"
        warn "未指定 NVMe 设备，使用默认: ${dev}"
    fi

    if [ ! -b "$dev" ]; then
        error "NVMe 设备不存在: ${dev}"
        error "请确保 NVMe 硬盘已正确连接"
        exit 1
    fi

    confirm_danger "$dev" "将镜像刷写到 NVMe 硬盘"

    step "刷写镜像到 NVMe..."
    info "镜像: $(basename "$img")"
    info "设备: ${dev}"

    # 取消挂载
    umount "${dev}"* 2>/dev/null || true
    umount "${dev}p"* 2>/dev/null || true

    # 解压镜像
    local real_img
    real_img=$(decompress_if_needed "$img")

    # 刷写
    dd if="$real_img" of="$dev" bs=4M status=progress conv=fsync

    # 清理
    if [ "$real_img" != "$img" ]; then
        rm -f "$real_img"
    fi

    sync
    ok "NVMe 刷写完成"
    info "注意: NVMe 启动需要先烧写 U-Boot 到 SPI Flash"
}

#------------------------------------------------------------------------------
# 仅刷写 U-Boot
#------------------------------------------------------------------------------
cmd_bootonly() {
    local board="${BOARD_ID:-}"
    local dev="${DEVICE:-}"

    if [ -z "$board" ]; then
        error "请指定板卡 ID: -b <board_id>"
        exit 1
    fi

    local board_dir
    board_dir=$(find_board_bootloader "$board")

    if [ -n "$dev" ] && [ -b "$dev" ]; then
        # 直接刷写到设备 (SD/eMMC)
        confirm_danger "$dev" "刷写 U-Boot 到 ${dev} (${board})"

        local uboot_bin="${board_dir}/u-boot-rockchip.bin"
        if [ ! -f "$uboot_bin" ]; then
            error "未找到 u-boot-rockchip.bin"
            exit 1
        fi

        info "刷写 U-Boot 到 ${dev}..."
        dd if="$uboot_bin" of="$dev" seek=64 bs=512 conv=notrunc,fsync status=progress
        sync
        ok "U-Boot 刷写完成"
    else
        # 使用 rkdeveloptool (MaskROM)
        cmd_spi
    fi
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    local command=""
    IMAGE_FILE=""
    DEVICE=""
    BOARD_ID=""
    AUTO_YES="no"

    # 解析全局选项和命令
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -i|--image)
                IMAGE_FILE="$2"
                shift 2
                ;;
            -d|--device)
                DEVICE="$2"
                shift 2
                ;;
            -b|--board)
                BOARD_ID="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_YES="yes"
                shift
                ;;
            -*)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                if [ -z "$command" ]; then
                    command="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$command" ]; then
        show_help
        exit 1
    fi

    case "$command" in
        list)
            cmd_list
            ;;
        sd)
            cmd_sd
            ;;
        emmc)
            cmd_emmc
            ;;
        spi)
            cmd_spi
            ;;
        nvme)
            cmd_nvme
            ;;
        bootonly)
            cmd_bootonly
            ;;
        *)
            error "未知命令: ${command}"
            show_help
            exit 1
            ;;
    esac
}

# 清理函数
cleanup() {
    # 清理临时解压的镜像
    rm -f /tmp/deepin-flash-img-*.img 2>/dev/null || true
}
trap cleanup EXIT

main "$@"
