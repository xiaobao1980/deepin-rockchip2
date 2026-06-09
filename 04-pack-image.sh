#!/bin/bash
#===============================================================================
# 04-pack-image.sh - 最终镜像打包脚本
# 用途: 将 U-Boot + 内核 + 根文件系统打包为可刷写的完整镜像
# 支持: GPT 分区 + extlinux 引导 (Armbian 风格)
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
IMAGE_SIZE_GB=${IMAGE_SIZE_GB:-8}
UBOOT_OFFSET=${UBOOT_OFFSET:-32768}      # U-Boot 起始扇区 (16MB)
ROOT_PART_LABEL="root"

# 输出文件名
IMAGE_NAME=${IMAGE_NAME:-"deepin-rockchip-arm64-25-desktop"}
IMAGE_DATE=$(date +%Y%m%d)

#------------------------------------------------------------------------------
# 显示帮助
#------------------------------------------------------------------------------
show_help() {
    cat << EOF
用法: $0 [选项] [板卡ID]

选项:
  -h, --help              显示此帮助信息
  -l, --list              列出可用的板卡
  -s, --size SIZE         镜像大小 (GB, 默认: ${IMAGE_SIZE_GB})
  -n, --name NAME         镜像文件名前缀 (默认: ${IMAGE_NAME})
  -o, --output DIR        输出目录 (默认: ${OUTPUT_DIR}/images)
  -u, --uboot-only        仅生成包含 U-Boot 的空镜像
  -r, --rootfs PATH       指定根文件系统路径 (默认: ${OUTPUT_DIR}/rootfs/deepin-rootfs)
  -c, --compress          压缩最终镜像 (xz)

板卡ID (指定要打包的板卡U-Boot):
  rk3588-generic          RK3588 Generic
  rk3588-rock5b           Radxa Rock 5B
  rk3588-opi5plus         Orange Pi 5 Plus
  rk3588-sige7            ArmSoM Sige7
  rk3576-rock4d           Radxa Rock 4D
  rk3576-sige5            ArmSoM Sige5
  ... 等等

示例:
  $0 rk3588-rock5b               # 打包 Rock 5B 镜像
  $0 -s 16 rk3588-opi5plus       # 16GB Orange Pi 5 Plus 镜像
  $0 -n myimage -c rk3588-generic # 自定义名称并压缩
  $0 -r /path/to/rootfs rk3588-rock5b  # 使用自定义根文件系统
EOF
}

#------------------------------------------------------------------------------
# 列出可用板卡
#------------------------------------------------------------------------------
list_boards() {
    local uboot_dir="${OUTPUT_DIR}/uboot"
    if [ ! -d "$uboot_dir" ]; then
        error "未找到 U-Boot 编译产物，请先运行 ./01-build-uboot.sh"
        exit 1
    fi

    echo "可用的板卡 (已编译 U-Boot):"
    echo "==========================="
    local board_dir
    for board_dir in "${uboot_dir}"/*; do
        if [ -d "$board_dir" ]; then
            local bid
            bid=$(basename "$board_dir")
            local desc="${BOARD_DESC[$bid]:-$bid}"
            local has_uboot="否"
            [ -f "${board_dir}/u-boot-rockchip.bin" ] && has_uboot="是"
            printf "  %-22s U-Boot: %-3s %s\n" "$bid" "$has_uboot" "$desc"
        fi
    done
}

#------------------------------------------------------------------------------
# 查找 U-Boot 目录
#------------------------------------------------------------------------------
find_uboot_dir() {
    local board_id=$1
    local uboot_dir="${OUTPUT_DIR}/uboot/${board_id}"

    if [ ! -d "$uboot_dir" ]; then
        error "未找到板卡 ${board_id} 的 U-Boot 编译产物"
        error "请先运行: ./01-build-uboot.sh ${board_id}"
        exit 1
    fi

    echo "$uboot_dir"
}

#------------------------------------------------------------------------------
# 查找根文件系统
#------------------------------------------------------------------------------
find_rootfs() {
    local rootfs_path="${ROOTFS_PATH:-${OUTPUT_DIR}/rootfs/deepin-rootfs}"

    if [ ! -d "$rootfs_path" ] || [ ! -f "${rootfs_path}/bin/bash" ]; then
        error "未找到有效的根文件系统: ${rootfs_path}"
        error "请先运行: ./03-build-rootfs.sh"
        exit 1
    fi

    echo "$rootfs_path"
}

#------------------------------------------------------------------------------
# 计算镜像参数
#------------------------------------------------------------------------------
calculate_image_params() {
    local rootfs_path=$1

    # 计算根文件系统大小
    local rootfs_size
    rootfs_size=$(du -sb "$rootfs_path" | cut -f1)
    local rootfs_size_gb=$(( (rootfs_size + 1024*1024*1024 - 1) / (1024*1024*1024) + 1 ))

    # 最小镜像大小
    local min_size=$(( ${UBOOT_OFFSET} * 512 + 100 * 1024 * 1024 ))  # U-Boot 区域 + 100MB
    min_size=$((min_size + rootfs_size))

    # 使用用户指定大小或自动计算
    local img_size_gb=$IMAGE_SIZE_GB
    local img_size_bytes=$((img_size_gb * 1024 * 1024 * 1024))

    if [ "$img_size_bytes" -lt "$min_size" ]; then
        local min_gb=$(( (min_size + 1024*1024*1024 - 1) / (1024*1024*1024) + 1 ))
        warn "指定大小 ${img_size_gb}GB 不足 (最小需要 ${min_gb}GB)"
        warn "自动调整镜像大小为 ${min_gb}GB"
        img_size_gb=$min_gb
        img_size_bytes=$((img_size_gb * 1024 * 1024 * 1024))
    fi

    # 计算扇区数 (512字节/扇区)
    local total_sectors=$((img_size_bytes / 512))

    # 单分区布局：只有 root 分区（含 /boot/extlinux/）
    # U-Boot SPL @ 扇区 64, 然后直接是 root 分区
    local root_start=${UBOOT_OFFSET}               # root 从 U-Boot 偏移后开始
    local root_end=$((total_sectors - 34))         # 预留 GPT 备份头

    echo "total_sectors=${total_sectors}"
    echo "root_start=${root_start}"
    echo "root_end=${root_end}"
    echo "img_size_gb=${img_size_gb}"
    echo "img_size_bytes=${img_size_bytes}"
}

#------------------------------------------------------------------------------
# 创建空镜像文件
#------------------------------------------------------------------------------
create_empty_image() {
    local img_file=$1
    local img_size_bytes=$2

    step "创建空白镜像文件..."

    rm -f "$img_file"
    truncate -s "${img_size_bytes}" "$img_file"

    ok "镜像文件创建: $(basename "$img_file") ($(numfmt --to=iec-i --suffix=B ${img_size_bytes}))"
}

#------------------------------------------------------------------------------
# 创建 GPT 分区表（单分区：只有 root）
#------------------------------------------------------------------------------
create_partitions() {
    local img_file=$1
    local rootfs_path=$2

    step "创建 GPT 分区表..."

    # 计算参数
    local params
    params=$(calculate_image_params "$rootfs_path")
    eval "$params"

    # 使用 parted 创建分区表
    parted -s "$img_file" mklabel gpt

    # 创建单个 root 分区 (ext4)，包含 /boot/
    parted -s "$img_file" unit s mkpart root ext4 "${root_start}" "${root_end}"

    # 显示分区表
    info "分区表:"
    parted -s "$img_file" unit MB print | grep -E "^ [0-9]"
}

#------------------------------------------------------------------------------
# 写入 U-Boot
#------------------------------------------------------------------------------
write_uboot() {
    local img_file=$1
    local board_id=$2
    local uboot_dir
    uboot_dir=$(find_uboot_dir "$board_id")

    step "写入 U-Boot (${board_id})..."

    # 查找可用的 U-Boot 镜像
    local uboot_img=""
    if [ -f "${uboot_dir}/u-boot-rockchip.bin" ]; then
        uboot_img="${uboot_dir}/u-boot-rockchip.bin"
    elif [ -f "${uboot_dir}/u-boot-rockchip-spi.bin" ]; then
        uboot_img="${uboot_dir}/u-boot-rockchip-spi.bin"
    elif [ -f "${uboot_dir}/idbloader.img" ] && [ -f "${uboot_dir}/u-boot.itb" ]; then
        # 使用分离式镜像
        info "使用分离式 U-Boot 镜像 (idbloader.img + u-boot.itb)"

        # 写入 idbloader 到偏移 0x40 扇区 (64 * 512 = 32KB)
        dd if="${uboot_dir}/idbloader.img" of="$img_file" seek=64 bs=512 conv=notrunc,fsync status=progress

        # 写入 u-boot.itb 到偏移 0x4000 扇区 (16384 * 512 = 8MB)
        dd if="${uboot_dir}/u-boot.itb" of="$img_file" seek=16384 bs=512 conv=notrunc,fsync status=progress

        ok "分离式 U-Boot 已写入"
        return 0
    fi

    if [ -z "$uboot_img" ]; then
        error "未找到可用的 U-Boot 镜像"
        error "请在 ${uboot_dir}/ 中检查以下文件之一:"
        error "  - u-boot-rockchip.bin"
        error "  - u-boot-rockchip-spi.bin"
        error "  - idbloader.img + u-boot.itb"
        exit 1
    fi

    # 写入完整 U-Boot 镜像
    info "使用镜像: $(basename "$uboot_img")"
    dd if="$uboot_img" of="$img_file" seek=64 bs=512 conv=notrunc,fsync status=progress

    ok "U-Boot 已写入"
}

#------------------------------------------------------------------------------
# 格式化分区（单分区：只有 root ext4）
#------------------------------------------------------------------------------
format_partitions() {
    local img_file=$1
    local rootfs_path=$2

    step "格式化分区..."

    # 获取分区信息
    local params
    params=$(calculate_image_params "$rootfs_path")
    eval "$params"

    # 使用 losetup 挂载分区
    local loop_dev
    loop_dev=$(losetup -f --show -P "$img_file")
    info "使用 loop 设备: ${loop_dev}"

    # 等待内核识别分区
    sleep 1
    partprobe "$loop_dev"
    sleep 1

    local root_dev="${loop_dev}p1"

    # 检查分区设备是否存在
    if [ ! -b "$root_dev" ]; then
        warn "分区设备未立即就绪，等待..."
        sleep 2
        partprobe "$loop_dev"
        sleep 2
    fi

    # 格式化 root 分区 (ext4)
    if [ -b "$root_dev" ]; then
        # 从根文件系统读取 UUID
        local root_uuid=""
        if [ -f "${rootfs_path}/etc/fstab" ]; then
            root_uuid=$(grep "UUID=" "${rootfs_path}/etc/fstab" | head -1 | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' || true)
        fi
        if [ -z "$root_uuid" ]; then
            root_uuid=$(uuidgen)
        fi

        # 关键修复: 只启用 U-Boot 确定支持的 ext4 特性
        # 禁用 metadata_csum/orphan_file/64bit/flex_bg/uninit_bg 等可能导致大文件读取失败的特性
        # U-Boot 确定支持的特性: extent,dir_index,filetype,has_journal,sparse_super
        # 显式指定 4K 块大小确保 U-Boot 兼容性
        mkfs.ext4 -F -L "${ROOT_PART_LABEL}" -U "$root_uuid" -b 4096 -I 256 \
            -O extent,dir_index,filetype,has_journal,sparse_super \
            "$root_dev"
        ok "root 分区已格式化 (ext4 U-Boot兼容, UUID=${root_uuid})"
    else
        error "root 分区设备未找到: ${root_dev}"
        losetup -d "$loop_dev"
        exit 1
    fi

    # 释放 loop 设备
    losetup -d "$loop_dev"

    ok "分区格式化完成"
}

#------------------------------------------------------------------------------
# 安装内核到已挂载的 rootfs（在复制根文件系统时调用）
#------------------------------------------------------------------------------
install_kernel_to_rootfs() {
    local mount_point=$1

    step "安装内核到 rootfs..."

    local deb_dir="${OUTPUT_DIR}/kernel"
    local image_deb
    image_deb=$(find "$deb_dir" -name "linux-image-*.deb" ! -name "*dbg*" | head -1)

    if [ -z "$image_deb" ]; then
        warn "未找到内核 deb 包，跳过内核安装"
        return 1
    fi

    info "使用内核包: $(basename "$image_deb")"

    # 挂载虚拟文件系统以便 chroot 中 dpkg 能正常工作
    mount --bind /dev "${mount_point}/dev"
    mount -t proc proc "${mount_point}/proc"
    mount -t sysfs sysfs "${mount_point}/sys"
    mount -t tmpfs tmpfs "${mount_point}/tmp"
    cp /etc/resolv.conf "${mount_point}/etc/resolv.conf"

    # 创建临时 deb 存放目录（必须在挂载 tmpfs 之后，否则被覆盖！）
    mkdir -p "${mount_point}/tmp/debs"
    cp "$image_deb" "${mount_point}/tmp/debs/"

    local headers_deb
    headers_deb=$(find "$deb_dir" -name "linux-headers-*.deb" | head -1)
    [ -n "$headers_deb" ] && cp "$headers_deb" "${mount_point}/tmp/debs/"

    # 关键修复：确保 initramfs 配置正确，避免安装内核后生成不完整的 initramfs
    # 必须在安装内核 deb 之前完成，因为 dpkg postinst 会自动触发 update-initramfs
    info "配置 initramfs..."
    mkdir -p "${mount_point}/etc/initramfs-tools"

    # 1. 确保 initramfs.conf 启用 busybox
    # 关键修复1: 将 initramfs 压缩改为 gzip（U-Boot 兼容性最好）
    # zstd 虽然压缩率更高，但某些 U-Boot 版本对大文件 zstd 解压缩支持不完整
    if [ -f "${mount_point}/etc/initramfs-tools/initramfs.conf" ]; then
        sed -i 's/^BUSYBOX=.*/BUSYBOX=y/' "${mount_point}/etc/initramfs-tools/initramfs.conf" 2>/dev/null || \
            echo "BUSYBOX=y" >> "${mount_point}/etc/initramfs-tools/initramfs.conf"
        sed -i 's/^COMPRESS=.*/COMPRESS=gzip/' "${mount_point}/etc/initramfs-tools/initramfs.conf" 2>/dev/null || \
            echo "COMPRESS=gzip" >> "${mount_point}/etc/initramfs-tools/initramfs.conf"
    else
        cat > "${mount_point}/etc/initramfs-tools/initramfs.conf" << 'EOF'
MODULES=most
BUSYBOX=y
COMPRESS=gzip
DEVICE=
NFSROOT=auto
RUNSIZE=10%
FSTYPE=auto
EOF
    fi

    # 2. 确保关键模块列表存在
    cat > "${mount_point}/etc/initramfs-tools/modules" << 'EOF'
sdhci
sdhci_pltfm
sdhci_of_arasan
dw_mmc
dw_mmc_rockchip
mmc_block
sd_mod
ext4
gpt
EOF

    # 3. 确保 zz-busybox-fix hook 存在且最新（覆盖备份中的旧版本）
    mkdir -p "${mount_point}/etc/initramfs-tools/hooks"
    cat > "${mount_point}/etc/initramfs-tools/hooks/zz-busybox-fix" << 'HOOK_EOF'
#!/bin/sh
# 确保 busybox 命令可用，同时保留 util-linux 的 blkid/mount/umount
# busybox 的 blkid 功能有限，无法正确读取 UUID，必须用 util-linux 版本
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in
    prereqs) prereqs; exit 0 ;;
esac
if [ -f /usr/share/initramfs-tools/hook-functions ]; then
    . /usr/share/initramfs-tools/hook-functions
fi

# 步骤 1: 先复制 util-linux 的关键工具（确保库依赖完整）
if type copy_exec >/dev/null 2>&1; then
    for libbin in /usr/bin/blkid /sbin/blkid /bin/mount /bin/umount; do
        if [ -x "$libbin" ]; then
            copy_exec "$libbin" "$(dirname "$libbin")" 2>/dev/null || true
        fi
    done
fi

# 步骤 2: 复制 busybox
BUSYBOX=""
for p in /bin/busybox /usr/bin/busybox; do
    [ -x "$p" ] && { BUSYBOX="$p"; break; }
done
if [ -n "$BUSYBOX" ]; then
    if type copy_exec >/dev/null 2>&1; then
        copy_exec "$BUSYBOX" /bin
    else
        mkdir -p "${DESTDIR}/bin"
        cp -a "$BUSYBOX" "${DESTDIR}/bin/busybox"
    fi
    # 步骤 3: 用 busybox 覆盖 klibc 工具（排除 blkid/mount/umount）
    for cmd in sh sleep echo cat tail ls mkdir mknod \
               chmod chown ln df du env expr false find grep gzip hostname \
               kill mkfifo mktemp more mv pidof ping printf ps pwd rm rmdir \
               sed seq stat sync tee test touch tr true uname uniq wc wget \
               which xargs whoami readlink realpath blockdev freeramdisk; do
        if "$BUSYBOX" --list 2>/dev/null | grep -q "^${cmd}$"; then
            for bindir in /bin /sbin /usr/bin /usr/sbin; do
                if [ -d "${DESTDIR}${bindir}" ]; then
                    local_path="${DESTDIR}${bindir}/${cmd}"
                    if [ -e "$local_path" ] && [ ! -L "$local_path" ]; then
                        fsize=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
                        if [ "$fsize" -lt 51200 ]; then
                            mv "$local_path" "${local_path}.klibc" 2>/dev/null || rm -f "$local_path" 2>/dev/null || true
                            ln -sf /bin/busybox "$local_path" 2>/dev/null || true
                        fi
                    elif [ -L "$local_path" ] || [ ! -e "$local_path" ]; then
                        ln -sf /bin/busybox "$local_path" 2>/dev/null || true
                    fi
                fi
            done
        fi
    done
fi
HOOK_EOF
    chmod +x "${mount_point}/etc/initramfs-tools/hooks/zz-busybox-fix"

    # 在 chroot 中安装内核 deb 包
    # dpkg postinst 会自动触发 update-initramfs，所以 hook 必须在之前就绪
    info "在 chroot 中安装内核..."
    chroot "$mount_point" /bin/bash << 'KERNEL_EOF'
        set -e
        export DEBIAN_FRONTEND=noninteractive
        # 先确保 busybox 和 initramfs-tools 已安装
        apt-get install -y busybox initramfs-tools 2>/dev/null || true
        # 逐个安装 deb 包（这会触发 update-initramfs）
        for d in /tmp/debs/*.deb; do
            if [ -f "$d" ]; then
                echo "  -> 安装 $(basename "$d")"
                dpkg -i "$d" || true
            fi
        done
        # 修复依赖
        apt-get install -f -y || true
        # 清理
        rm -rf /tmp/debs
KERNEL_EOF

    # 检查内核是否安装成功
    local kernel_ver_install=""
    if ls "${mount_point}/boot/vmlinuz-"* &>/dev/null; then
        kernel_ver_install=$(ls "${mount_point}/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
    fi

    if [ -z "$kernel_ver_install" ]; then
        warn "内核安装后未找到 vmlinuz，检查 deb 包内容..."
        # 注意: grep 无匹配时返回 1，需加 || true 防止 set -e 退出
        chroot "$mount_point" /bin/bash -c "dpkg -l | grep linux-image" || true
        # 尝试强制重新配置
        chroot "$mount_point" /bin/bash -c "dpkg --configure -a || true"
        # 再次检查
        if ls "${mount_point}/boot/vmlinuz-"* &>/dev/null; then
            kernel_ver_install=$(ls "${mount_point}/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
        fi
        # 如果仍不存在，尝试强制重新安装 deb 包
        if [ -z "$kernel_ver_install" ] && [ -n "$image_deb" ]; then
            warn "尝试强制重新安装内核..."
            cp "$image_deb" "${mount_point}/tmp/debs/" 2>/dev/null || true
            chroot "$mount_point" /bin/bash -c "dpkg -i --force-all /tmp/debs/*.deb 2>/dev/null; apt-get install -f -y || true"
            rm -rf "${mount_point}/tmp/debs"
            if ls "${mount_point}/boot/vmlinuz-"* &>/dev/null; then
                kernel_ver_install=$(ls "${mount_point}/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
            fi
        fi
    fi

    if [ -n "$kernel_ver_install" ]; then
        info "检测到内核版本: ${kernel_ver_install}"

        local initrd_path="${mount_point}/boot/initrd.img-${kernel_ver_install}"

        # 关键修复: 严格检查 initrd 文件状态
        # U-Boot 的 ext4 驱动无法读取符号链接作为 initrd，必须确保是普通文件
        local initrd_ok="no"
        local initrd_size=0

        # 诊断: 列出所有 initrd 相关文件
        info "检查 initrd 文件状态..."
        ls -la "${mount_point}/boot/" 2>/dev/null | grep -E "initrd|vmlinuz" || true

        if [ -L "$initrd_path" ]; then
            warn "initrd 是符号链接！U-Boot 无法读取符号链接作为 initrd"
            local link_target
            link_target=$(readlink "$initrd_path")
            warn "  链接目标: ${link_target}"
            # 处理绝对路径和相对路径
            local target_fullpath
            if [[ "$link_target" == /* ]]; then
                # 绝对路径: /boot/xxx 或 /xxx
                target_fullpath="${mount_point}${link_target}"
            else
                # 相对路径
                target_fullpath="${mount_point}/boot/${link_target}"
            fi
            info "  查找目标: ${target_fullpath}"
            if [ -f "$target_fullpath" ] && [ ! -L "$target_fullpath" ]; then
                info "复制链接目标替换符号链接..."
                cp -a "$target_fullpath" "${initrd_path}.real"
                rm -f "$initrd_path"
                mv "${initrd_path}.real" "$initrd_path"
                initrd_ok="yes"
            else
                warn "  链接目标不存在或也是符号链接"
            fi
        elif [ -f "$initrd_path" ]; then
            initrd_size=$(stat -c%s "$initrd_path" 2>/dev/null || echo 0)
            if [ "$initrd_size" -gt 1048576 ]; then
                initrd_ok="yes"
            else
                warn "initrd 文件大小异常: ${initrd_size} 字节 (预期 > 1MB)"
            fi
        fi

        # 如果 initrd 不正常，强制重新生成
        if [ "$initrd_ok" != "yes" ]; then
            warn "initrd 需要重新生成..."
            # 清理所有可能冲突的 initrd 文件和链接
            rm -f "${mount_point}/boot/initrd.img"* 2>/dev/null || true
            # 强制重新生成
            chroot "$mount_point" /bin/bash -c "update-initramfs -c -k '${kernel_ver_install}'" 2>/dev/null || {
                chroot "$mount_point" /bin/bash -c "mkinitramfs -o '/boot/initrd.img-${kernel_ver_install}' '${kernel_ver_install}'" 2>/dev/null || true
            }
            # 再次检查
            if [ -f "$initrd_path" ] && [ ! -L "$initrd_path" ]; then
                initrd_size=$(stat -c%s "$initrd_path" 2>/dev/null || echo 0)
                if [ "$initrd_size" -gt 1048576 ]; then
                    initrd_ok="yes"
                    ok "initrd 重新生成成功 (${initrd_size} 字节)"
                fi
            fi
        else
            info "initrd 文件正常: ${initrd_size} 字节"
        fi

        # 验证 initramfs 内容完整性
        if [ "$initrd_ok" = "yes" ]; then
            local initramfs_cmds
            initramfs_cmds=$(zcat "$initrd_path" 2>/dev/null | cpio -t --quiet 2>/dev/null || true)
            local critical_cmds="tail sh mount umount blkid sleep echo cat"
            local missing_cmds=""
            for cmd in $critical_cmds; do
                if ! echo "$initramfs_cmds" | grep -q "bin/${cmd}$" 2>/dev/null; then
                    if ! echo "$initramfs_cmds" | grep -q "${cmd}" 2>/dev/null; then
                        missing_cmds="${missing_cmds} ${cmd}"
                    fi
                fi
            done
            local has_busybox="no"
            echo "$initramfs_cmds" | grep -q "bin/busybox$" 2>/dev/null && has_busybox="yes"

            if [ -n "$missing_cmds" ]; then
                warn "initramfs 验证警告: 缺少命令${missing_cmds}"
            else
                ok "initramfs 验证通过 (busybox=${has_busybox})"
            fi
        else
            warn "initrd 最终检查失败！U-Boot 可能无法加载 initrd"
        fi
    else
        warn "未能检测到安装的内核版本，但继续打包（系统可能自行安装内核）"
    fi

    # 清理
    chroot "$mount_point" /bin/bash -c "rm -rf /tmp/debs"
    rm -f "${mount_point}/.kernel-installed" 2>/dev/null || true

    # 卸载虚拟文件系统
    umount "${mount_point}/tmp" 2>/dev/null || true
    umount "${mount_point}/proc" 2>/dev/null || true
    umount "${mount_point}/sys" 2>/dev/null || true
    umount "${mount_point}/dev" 2>/dev/null || true

    ok "内核安装完成"
}

#------------------------------------------------------------------------------
# 复制根文件系统
#------------------------------------------------------------------------------
copy_rootfs() {
    local img_file=$1
    local rootfs_path=$2
    local board_id=$3

    step "复制根文件系统 (${board_id})..."

    # 重新挂载 loop 设备
    local loop_dev
    loop_dev=$(losetup -f --show -P "$img_file")
    sleep 1
    partprobe "$loop_dev"
    sleep 1

    # 单分区布局：只有 p1 (root ext4)
    local root_dev="${loop_dev}p1"

    # 挂载 root 分区
    local mount_point="/tmp/deepin-img-mnt-$$"
    mkdir -p "$mount_point"
    mount "$root_dev" "$mount_point"

    # 复制根文件系统
    info "复制文件系统内容..."
    local total_files
    total_files=$(find "$rootfs_path" | wc -l)
    info "总文件数: ${total_files}"

    cp -a "${rootfs_path}"/* "$mount_point/"

    # 创建标志文件
    touch "$mount_point/.deepin-rockchip-image"

    # ============================================
    # 关键修复: 清理 rootfs 备份中的旧内核/initrd
    # 避免与新安装的内核产生冲突（符号链接/版本不匹配）
    # ============================================
    info "清理旧的内核和 initrd 文件..."
    # 保留目录结构，删除具体的内核文件
    for old_kernel in "${mount_point}/boot/vmlinuz-"* "${mount_point}/boot/initrd.img-"* "${mount_point}/boot/config-"* "${mount_point}/boot/System.map-"*; do
        if [ -e "$old_kernel" ]; then
            info "  删除旧内核文件: $(basename "$old_kernel")"
            rm -f "$old_kernel"
        fi
    done
    # 删除 /boot 下的 initrd.img 符号链接（指向旧版本）
    if [ -L "${mount_point}/boot/initrd.img" ]; then
        rm -f "${mount_point}/boot/initrd.img"
    fi
    # 删除 /usr/lib/linux-image-*/ 下的旧文件（避免 dpkg 冲突）
    rm -rf "${mount_point}/usr/lib/linux-image-"* 2>/dev/null || true

    # ============================================
    # 单分区布局：安装内核到 rootfs /boot/
    # ============================================
    install_kernel_to_rootfs "$mount_point"

    # 更新 extlinux.conf 中的 __KV__ 占位符为实际内核版本
    local kernel_ver
    kernel_ver=$(ls "${mount_point}/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
    if [ -n "$kernel_ver" ]; then
        info "检测到安装的内核版本: ${kernel_ver}"
        sed -i "s|__KV__|${kernel_ver}|g" "${mount_point}/boot/extlinux/extlinux.conf"
        ok "extlinux.conf 内核版本已更新: ${kernel_ver}"
    else
        warn "未检测到内核版本，extlinux.conf 中的 __KV__ 不会被替换"
    fi

    # 替换 dtb 占位符，并把 dtb 复制到 /boot/ 以便 U-Boot 读取
    local dtb_name=""
    case "${board_id}" in
        rk3588-rock5-itx)     dtb_name="rk3588-rock-5-itx.dtb" ;;
        rk3588-rock5b)        dtb_name="rk3588-rock-5b.dtb" ;;
        rk3588-rock5a)        dtb_name="rk3588s-rock-5a.dtb" ;;
        rk3588-rock5c)        dtb_name="rk3588s-rock-5c.dtb" ;;
        rk3588-rock5b-plus)   dtb_name="rk3588-rock-5b-plus.dtb" ;;
        rk3588-opi5)          dtb_name="rk3588-orangepi-5.dtb" ;;
        rk3588-opi5plus)      dtb_name="rk3588-orangepi-5-plus.dtb" ;;
        rk3588-opi5-ultra)    dtb_name="rk3588-orangepi-5-ultra.dtb" ;;
        rk3588-opi5-max)      dtb_name="rk3588-orangepi-5-max.dtb" ;;
        rk3588-opi5b)         dtb_name="rk3588-orangepi-5b.dtb" ;;
        rk3588-opi5pro)       dtb_name="rk3588-orangepi-5-pro.dtb" ;;
        rk3588-orangepi-4a)   dtb_name="rk3588s-orangepi-4a.dtb" ;;
        rk3588-nanopi-r6s)    dtb_name="rk3588s-nanopi-r6s.dtb" ;;
        rk3588-nanopi-r6c)    dtb_name="rk3588s-nanopi-r6c.dtb" ;;
        rk3588-nanopi-m6)     dtb_name="rk3588-nanopi-m6.dtb" ;;
        rk3588-nanopct6)      dtb_name="rk3588-nanopct6.dtb" ;;
        rk3588-nanopct6-lts)  dtb_name="rk3588-nanopct6-lts.dtb" ;;
        rk3588-roc-pc)        dtb_name="rk3588s-roc-pc.dtb" ;;
        rk3588-station-m3)    dtb_name="rk3588s-lubancat-4.dtb" ;;
        rk3588-cm3588)        dtb_name="rk3588-friendlyelec-cm3588-nas.dtb" ;;
        rk3588-cm3588-nas)    dtb_name="rk3588-friendlyelec-cm3588-nas.dtb" ;;
        rk3588-coolpi4b)      dtb_name="rk3588s-coolpi-4b.dtb" ;;
        rk3588-sige7)         dtb_name="rk3588-armsom-sige7.dtb" ;;
        rk3588-khadas-edge2)  dtb_name="rk3588-khadas-edge2.dtb" ;;
        rk3588-bananapi-m7)   dtb_name="rk3588-bananapi-m7.dtb" ;;
        rk3588-turing-rk1)    dtb_name="rk3588-turing-rk1.dtb" ;;
        rk3588-mixtile-blade3) dtb_name="rk3588-mixtile-blade3.dtb" ;;
        rk3588-indiedroid-nova) dtb_name="rk3588s-indiedroid-nova.dtb" ;;
        rk3576-rock4d)        dtb_name="rk3576-rock-4d.dtb" ;;
        rk3576-armsom-sige5)  dtb_name="rk3576-armsom-sige5.dtb" ;;
        rk3576-radxa-e52c)    dtb_name="rk3576-radxa-e52c.dtb" ;;
        rk3576-youyeetoo-r1-v3) dtb_name="rk3576-youyeetoo-r1-v3.dtb" ;;
        rk3568-rock-3a)       dtb_name="rk3568-rock-3a.dtb" ;;
        rk3568-nanopi-r5s)    dtb_name="rk3568-nanopi-r5s.dtb" ;;
        rk3568-odroid-m1)     dtb_name="rk3568-odroid-m1.dtb" ;;
        rk3568-bananapi-m4zero) dtb_name="rk3568-bananapi-m4zero.dtb" ;;
        rk3399-rockpro64)     dtb_name="rk3399-rockpro64.dtb" ;;
        rk3399-rockpi4b)      dtb_name="rk3399-rock-pi-4b.dtb" ;;
        rk3399-nanopim4v2)    dtb_name="rk3399-nanopi-m4v2.dtb" ;;
        rk3399-orangepi4)     dtb_name="rk3399-orangepi-4.dtb" ;;
    esac
    if [ -n "$dtb_name" ]; then
        # 先尝试从 /boot/ 目录查找（如果内核安装时已复制 dtb 到 boot）
        # 否则从 /usr/lib/linux-image-*/rockchip/ 查找
        local dtb_src=""
        local kernel_img_dir
        kernel_img_dir=$(find "${mount_point}/usr/lib/" -maxdepth 1 -type d -name "linux-image-*" 2>/dev/null | head -1)

        if [ -n "$kernel_img_dir" ]; then
            local dtb_in_lib="${kernel_img_dir}/rockchip/${dtb_name}"
            if [ -f "$dtb_in_lib" ]; then
                dtb_src="$dtb_in_lib"
            fi
        fi

        # 如果未找到，搜索整个 mount_point
        if [ -z "$dtb_src" ]; then
            dtb_src=$(find "$mount_point" -name "$dtb_name" -type f 2>/dev/null | head -1)
        fi

        local dtb_dst="${mount_point}/boot/${dtb_name}"
        if [ -n "$dtb_src" ] && [ -f "$dtb_src" ]; then
            cp -a "$dtb_src" "$dtb_dst"
            info "dtb 已复制到 /boot/: $dtb_name"
            # 更新 extlinux.conf：把 fdt 路径改为 /boot/xxx.dtb
            sed -i "s|fdt /usr/lib/linux-image-[^/]*/rockchip/__BOARD_DTB__|fdt /boot/${dtb_name}|g" "${mount_point}/boot/extlinux/extlinux.conf" 2>/dev/null || true
            sed -i "s|fdt /usr/lib/linux-image-[^/]*/rockchip/${dtb_name}|fdt /boot/${dtb_name}|g" "${mount_point}/boot/extlinux/extlinux.conf" 2>/dev/null || true
            sed -i "s|__BOARD_DTB__|${dtb_name}|g" "${mount_point}/boot/extlinux/extlinux.conf" 2>/dev/null || true
            ok "fdt 已更新为: /boot/${dtb_name}"
        else
            warn "dtb 源文件未找到: $dtb_name"
            # 列出找到的 dtb 以便调试
            find "$mount_point/boot" "$mount_point/usr/lib" -name "*.dtb" 2>/dev/null | head -10 | while read f; do
                warn "  找到 dtb: ${f#$mount_point}"
            done
            # 回退：只替换 __BOARD_DTB__ 占位符
            sed -i "s|__BOARD_DTB__|${dtb_name}|g" "${mount_point}/boot/extlinux/extlinux.conf" 2>/dev/null || true
        fi
    fi

    # ============================================
    # 复制 GPU overlay (Panthor for RK3588 Mali-G610)
    # ============================================
    local gpu_overlay="rockchip-rk3588-panthor-gpu.dtbo"
    if [ -n "$kernel_img_dir" ]; then
        local overlay_src="${kernel_img_dir}/rockchip/overlay/${gpu_overlay}"
        local overlay_dst="${mount_point}/boot/${gpu_overlay}"
        if [ -f "$overlay_src" ]; then
            cp -a "$overlay_src" "$overlay_dst"
            info "GPU overlay 已复制: ${gpu_overlay}"
            # 在 extlinux.conf 中添加 fdtoverlays 行
            if ! grep -q "fdtoverlays" "${mount_point}/boot/extlinux/extlinux.conf"; then
                sed -i "/^label deepin$/a\\    fdtoverlays /boot/${gpu_overlay}" "${mount_point}/boot/extlinux/extlinux.conf"
                sed -i "/^label recovery$/a\\    fdtoverlays /boot/${gpu_overlay}" "${mount_point}/boot/extlinux/extlinux.conf"
                ok "已添加 Panthor GPU overlay 到 extlinux.conf"
            fi
        else
            warn "GPU overlay 未找到: ${overlay_src}"
        fi
    fi

    # ============================================
    # 最终校验：确保 extlinux.conf 中的 UUID 与实际分区 UUID 一致
    # ============================================
    local actual_uuid img_uuid
    actual_uuid=$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)
    img_uuid=$(grep -oE 'root=UUID=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "${mount_point}/boot/extlinux/extlinux.conf" 2>/dev/null | head -1 | sed 's/root=UUID=//')

    if [ -n "$actual_uuid" ] && [ -n "$img_uuid" ] && [ "$actual_uuid" != "$img_uuid" ]; then
        warn "UUID 不匹配！镜像分区 UUID=${actual_uuid}，extlinux.conf UUID=${img_uuid}"
        warn "修复 extlinux.conf 中的 UUID..."
        sed -i "s|root=UUID=${img_uuid}|root=UUID=${actual_uuid}|g" "${mount_point}/boot/extlinux/extlinux.conf"
        sed -i "s|UUID=${img_uuid}|UUID=${actual_uuid}|g" "${mount_point}/etc/fstab" 2>/dev/null || true
    elif [ -n "$actual_uuid" ] && [ -n "$img_uuid" ]; then
        ok "UUID 校验通过: ${actual_uuid}"
    fi

    # 确保 rootdelay=5 存在（给块设备检测留时间）
    if ! grep -q "rootdelay=" "${mount_point}/boot/extlinux/extlinux.conf" 2>/dev/null; then
        info "添加 rootdelay=5 到内核参数..."
        sed -i 's|rootwait rw|rootwait rw rootdelay=5|g' "${mount_point}/boot/extlinux/extlinux.conf"
    fi

    # ============================================
    # 关键修复: 最终文件系统完整性检查
    # ============================================
    # 1. 确保 initrd 文件存在且是普通文件
    local final_initrd="${mount_point}/boot/initrd.img-${kernel_ver}"
    if [ -n "$kernel_ver" ]; then
        if [ ! -f "$final_initrd" ] || [ -L "$final_initrd" ]; then
            warn "最终检查: initrd 文件不存在或是符号链接！"
            warn "路径: ${final_initrd}"
            ls -la "${mount_point}/boot/initrd.img"* 2>/dev/null || true
        else
            local final_size
            final_size=$(stat -c%s "$final_initrd" 2>/dev/null || echo 0)
            ok "最终检查: initrd 存在 (${final_size} 字节)"
        fi
    fi

    # 2. 强制 flush 所有数据到磁盘
    info "强制同步数据到磁盘..."
    sync
    sleep 1
    sync

    # 3. umount 前运行 e2fsck 检查文件系统一致性
    umount "$mount_point"
    info "检查文件系统一致性..."
    e2fsck -fn "$root_dev" 2>/dev/null || true

    rmdir "$mount_point" 2>/dev/null || true
    losetup -d "$loop_dev"

    ok "根文件系统已复制到镜像"
}

#------------------------------------------------------------------------------
# 验证镜像
#------------------------------------------------------------------------------
verify_image() {
    local img_file=$1

    step "验证镜像..."

    # 检查分区表
    if parted -s "$img_file" print &>/dev/null; then
        ok "分区表有效"
    else
        warn "分区表验证出现问题"
    fi

    # 检查文件系统（单分区：只有 p1）
    local loop_dev
    loop_dev=$(losetup -f --show -P "$img_file")
    sleep 1

    if [ -b "${loop_dev}p1" ]; then
        local fsck_out
        fsck_out=$(fsck -n "${loop_dev}p1" 2>&1) && ok "root 文件系统检查通过" || warn "root 文件系统检查: ${fsck_out}"
    fi

    losetup -d "$loop_dev"

    # 镜像大小
    local img_size
    img_size=$(stat -c%s "$img_file")
    ok "镜像大小: $(numfmt --to=iec-i --suffix=B ${img_size})"
}

#------------------------------------------------------------------------------
# 生成镜像信息
#------------------------------------------------------------------------------
generate_image_info() {
    local img_file=$1
    local board_id=$2
    local info_file="${img_file%.img}-info.txt"
    local img_size
    img_size=$(stat -c%s "$img_file")

    cat > "$info_file" << EOF
DEEPIN ROCKCHIP IMAGE
=====================
Image:        $(basename "$img_file")
Size:         $(numfmt --to=iec-i --suffix=B ${img_size})
Board:        ${board_id}
Date:         $(date -Iseconds)
U-Boot:       ${UBOOT_VERSION:-unknown}
Kernel:       ${KERNEL_VERSION:-unknown}
Deepin:       ${DEEPIN_VERSION:-beige}
Partitions:   GPT (单分区)
  - root:     ext4 (含 /boot/ 的全部空间)

BOOTLOADER INFO
===============
$(cat "${OUTPUT_DIR}/uboot/${board_id}/board-info.txt" 2>/dev/null || echo "N/A")

刷写说明
========
SD 卡启动:
  dd if=$(basename "$img_file") of=/dev/sdX bs=4M status=progress

eMMC 烧写 (MaskROM 模式):
  rkdeveloptool db <spl_loader>.bin
  rkdeveloptool wl 0x40000 $(basename "$img_file")
  rkdeveloptool rd

NVMe 启动 (需先烧写 U-Boot 到 SPI):
  1. 将 U-Boot 烧写到 SPI Flash
  2. 将本镜像写入 NVMe 硬盘
  3. 从 NVMe 启动
EOF

    ok "镜像信息: $info_file"
}

#------------------------------------------------------------------------------
# 压缩镜像
#------------------------------------------------------------------------------
compress_image() {
    local img_file=$1

    step "压缩镜像..."

    info "使用 xz 压缩 (多线程)..."
    xz -T0 -vf "$img_file"

    local xz_file="${img_file}.xz"
    local orig_size
    orig_size=$(stat -c%s "$img_file" 2>/dev/null || echo "0")
    local xz_size
    xz_size=$(stat -c%s "$xz_file")

    ok "压缩完成: $(basename "$xz_file")"
    ok "  原始大小: $(numfmt --to=iec-i --suffix=B ${orig_size})"
    ok "  压缩大小: $(numfmt --to=iec-i --suffix=B ${xz_size})"
    ok "  压缩率: $(( 100 - xz_size * 100 / orig_size ))%"
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    local board_id=""
    local compress="no"
    local rootfs_path=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                list_boards
                exit 0
                ;;
            -s|--size)
                IMAGE_SIZE_GB="$2"
                shift 2
                ;;
            -n|--name)
                IMAGE_NAME="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -r|--rootfs)
                rootfs_path="$2"
                shift 2
                ;;
            -c|--compress)
                compress="yes"
                shift
                ;;
            -u|--uboot-only)
                UBOOT_ONLY="yes"
                shift
                ;;
            -*)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                board_id="$1"
                shift
                ;;
        esac
    done

    # 检查板卡 ID
    if [ -z "$board_id" ]; then
        error "请指定板卡 ID"
        echo ""
        list_boards
        exit 1
    fi

    # 检查 root
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行: sudo $0"
        exit 1
    fi

    # 查找根文件系统
    rootfs_path=$(find_rootfs)

    echo "========================================"
    echo "  Deepin Rockchip 镜像打包"
    echo "========================================"
    echo "  板卡: ${board_id}"
    echo "  镜像大小: ${IMAGE_SIZE_GB}GB"
    echo "  根文件系统: ${rootfs_path}"
    echo ""

    # 计算镜像参数
    local params
    params=$(calculate_image_params "$rootfs_path")
    eval "$params"

    # 输出文件路径
    local output_dir="${OUTPUT_DIR}/images"
    mkdir -p "$output_dir"
    local img_file="${output_dir}/${IMAGE_NAME}-${board_id}-${IMAGE_DATE}.img"

    # 创建镜像
    create_empty_image "$img_file" "$img_size_bytes"

    # 创建分区
    create_partitions "$img_file" "$rootfs_path"

    # 写入 U-Boot
    write_uboot "$img_file" "$board_id"

    # 格式化分区
    format_partitions "$img_file" "$rootfs_path"

    # 复制根文件系统
    if [ "${UBOOT_ONLY:-no}" != "yes" ]; then
        copy_rootfs "$img_file" "$rootfs_path" "$board_id"
    fi

    # 验证
    verify_image "$img_file"

    # 生成信息文件
    generate_image_info "$img_file" "$board_id"

    # 压缩
    if [ "$compress" = "yes" ]; then
        compress_image "$img_file"
        img_file="${img_file}.xz"
    fi

    echo ""
    echo "========================================"
    ok "镜像打包完成"
    echo "========================================"
    highlight "  镜像文件: ${img_file}"
    if [ -f "$img_file" ]; then
        ls -lh "$img_file"
    fi
    echo ""
    info "刷写命令:"
    info "  dd if=${img_file%.xz} of=/dev/sdX bs=4M status=progress"
}

main "$@"
exit 0
