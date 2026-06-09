#!/bin/bash
#===============================================================================
# 03-build-rootfs.sh - Deepin 25 根文件系统构建脚本
# 设计: 构建通用 rootfs(不含内核) → 备份 → 恢复后由 build-all.sh 安装内核
# 这样不同板卡共享同一个 rootfs 备份，但可安装不同内核
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
NC='\033[0m'

# 所有日志输出到 stderr，避免污染 $() 命令替换的输出
info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*" >&2; }

#------------------------------------------------------------------------------
# 配置
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.buildconfig" ]; then
    source "${SCRIPT_DIR}/.buildconfig"
else
    BUILD_ROOT="${SCRIPT_DIR}"
    OUTPUT_DIR="${BUILD_ROOT}/output"
fi

WORKSPACE="${OUTPUT_DIR}/rootfs/deepin-rootfs"
KERNEL_DEB_DIR="${OUTPUT_DIR}/kernel"
BACKUP_FILE="${OUTPUT_DIR}/rootfs/rootfs-backup.tar"

# 根分区 UUID
ROOT_UUID=""

# 主机名
TARGET_HOSTNAME="deepin-rockchip"

# 默认用户名/密码
DEFAULT_USER="deepin"
DEFAULT_USER_PASS="deepin"

# 是否仅从备份恢复（不构建）
RESTORE_ONLY="no"

# 是否在恢复后安装内核
INSTALL_KERNEL="no"

# 内核安装标记文件（防止重复安装）
KERNEL_INSTALLED_FLAG=".kernel-installed"

# 基础包 (mmdebstrap --include 用，最小化，避免依赖冲突)
BASE_PACKAGES=(
    ca-certificates
    systemd systemd-sysv
    passwd base-files
    apt
    locales
    tzdata
    hostname
    iproute2 iputils-ping
    netbase
    initramfs-tools
    busybox
    firmware-linux-free
    sudo
    vim nano
    curl wget
    e2fsprogs
    parted
    gdisk
    dosfstools
    dbus-user-session
    dbus-x11
    xdg-utils
    xdg-user-dirs
    network-manager
    wpasupplicant
    iw
    bluetooth
    bluez
    alsa-utils
    pipewire
    wireplumber
    polkitd
    upower
    apt-utils
    linux-firmware
    libc6:arm64
    openssh-server
    mesa-vulkan-drivers
    libglx-mesa0
    libgl1-mesa-dri
    libegl-mesa0
    libgbm1
    libdrm2
    glmark2
    glmark2-es2
    mesa-utils
    # 视频加速工具
    ffmpeg
    vainfo
)

# 桌面包 (chroot 内 apt install，分步安装避免依赖冲突)
DESKTOP_PACKAGES=(
    deepin-desktop-environment-core
    dde-api
    dde-application-manager
    dde-calendar
    dde-control-center
    dde-file-manager
    dde-launchpad
    dde-permission-manager
    dde-qt5integration
    dde-session
    dde-shell
    dde-tray-loader
    ddm
    deepin-album
    deepin-calculator
    deepin-editor
    deepin-icon-theme
    deepin-gtk-theme
    deepin-movie
    deepin-music
    deepin-terminal
    firefox
    fcitx5
    fcitx5-chinese-addons
    fonts-noto-cjk
    fonts-noto-color-emoji
    gedit
    kwayland-data
    treeland
    blueman
)

#------------------------------------------------------------------------------
# 智能镜像源配置
#------------------------------------------------------------------------------
# Deepin 25 仓库候选镜像列表
# 分为 beige（主仓库）和 hwe-25（硬件支持仓库）
MIRRORS_BEIGE=(
    "阿里云|https://mirrors.aliyun.com/deepin/beige/"
    "清华|https://mirrors.tuna.tsinghua.edu.cn/deepin/beige/"
    "中科大|https://mirrors.ustc.edu.cn/deepin/beige/"
    "腾讯云|https://mirrors.cloud.tencent.com/deepin/beige/"
    "华为云|https://repo.huaweicloud.com/deepin/beige/"
    "官方|https://community-packages.deepin.com/beige/"
)

# hwe-25 仓库只有官方源和 CDN 支持，第三方镜像未同步
MIRRORS_HWE=(
    "官方CDN|https://cdn-community-packages.deepin.com/hwe-25/"
    "官方|https://community-packages.deepin.com/hwe-25/"
)

# 测试单个镜像延迟（返回秒数，失败返回空）
mirror_test() {
    local url="$1"
    local timeout=5
    local test_url="${url}dists/crimson/InRelease"
    # 使用 curl 测速：只下载 HTTP 头，取时间
    curl -fsSL -o /dev/null --connect-timeout "$timeout" --max-time "$timeout" \
         -w "%{time_total}" "$test_url" 2>/dev/null
}

# 智能选择最快镜像
# 分别测试 beige 和 hwe-25 仓库，返回最佳 beige URL（hwe 镜像名写入变量）
# 用法: MIRROR_HWE=$(mirror_ranking)
mirror_ranking() {
    local -n best_hwe=${1:-MIRROR_HWE_RESULT}
    local best_url="" best_time="999" best_name="官方"
    local hwe_url="" hwe_time="999" hwe_name="官方"

    info "正在测试 beige 仓库镜像速度..."
    local entry name url latency
    for entry in "${MIRRORS_BEIGE[@]}"; do
        name="${entry%%|*}"; url="${entry##*|}"
        latency=$(mirror_test "$url")
        if [ -n "$latency" ]; then
            info "  ${name}: ${latency}s"
            if awk "BEGIN {exit !($latency < $best_time)}" 2>/dev/null; then
                best_time="$latency"; best_url="$url"; best_name="$name"
            fi
        else
            warn "  ${name}: 无法连接"
        fi
    done

    info "正在测试 hwe-25 仓库镜像速度..."
    local hwe_count=0
    for entry in "${MIRRORS_HWE[@]}"; do
        name="${entry%%|*}"; url="${entry##*|}"
        latency=$(mirror_test "$url" "dists/unstable/InRelease")
        if [ -n "$latency" ]; then
            info "  ${name}: ${latency}s"
            hwe_count=$((hwe_count + 1))
            if awk "BEGIN {exit !($latency < $hwe_time)}" 2>/dev/null; then
                hwe_time="$latency"; hwe_url="$url"; hwe_name="$name"
            fi
        else
            warn "  ${name}: 无法连接"
        fi
    done
    # hwe-25 只有官方源，不显示 "选中" 提示
    [ "$hwe_count" -eq 0 ] && warn "hwe-25 无可用镜像，使用官方源"

    [ -n "$best_url" ] && ok "选中 beige 源: ${best_name} (${best_time}s)"
    [ -n "$hwe_url" ] && ok "选中 hwe-25 源: ${hwe_name} (${hwe_time}s)"

    # 如果都失败，回退到官方
    [ -z "$best_url" ] && best_url="https://community-packages.deepin.com/beige/"
    [ -z "$hwe_url" ] && hwe_url="https://community-packages.deepin.com/hwe-25/"

    best_hwe="$hwe_url"
    echo "$best_url"
}

#------------------------------------------------------------------------------
# 帮助
#------------------------------------------------------------------------------
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
  -h, --help              显示此帮助
  -m, --minimal           最小化系统 (不含桌面)
  -n, --hostname NAME     设置主机名
  -u, --user USER         设置默认用户名
  -p, --password PASS     设置默认用户密码
  -c, --clean             清理后重新构建（同时删除旧备份）
  -r, --restore-only      仅从备份恢复，不重新构建
  -k, --install-kernel    恢复后安装内核到 rootfs

设计: 构建通用 rootfs(不含内核) → 备份 → 恢复后安装内核
      不同板卡共享同一个 rootfs 备份，但可安装不同内核
EOF
}

#------------------------------------------------------------------------------
# 准备
#------------------------------------------------------------------------------
prepare() {
    # clean 模式：删除旧备份并强制重新构建
    if [ "$CLEAN_BUILD" = "yes" ] && [ -f "$BACKUP_FILE" ]; then
        info "clean 模式：删除旧备份..."
        rm -f "$BACKUP_FILE"
    fi

    # 如果备份存在且非强制重建，直接解压恢复
    if [ -f "$BACKUP_FILE" ] && [ "$CLEAN_BUILD" != "yes" ]; then
        info "检测到 rootfs 备份，恢复中..."
        rm -rf "$WORKSPACE"
        mkdir -p "$WORKSPACE"
        tar xf "$BACKUP_FILE" -C "$WORKSPACE"
        # 从恢复的 fstab 读取 UUID
        ROOT_UUID=$(grep 'UUID=' "${WORKSPACE}/etc/fstab" 2>/dev/null | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -1)
        [ -z "$ROOT_UUID" ] && ROOT_UUID=$(uuidgen)
        ok "rootfs 已从备份恢复: ${BACKUP_FILE}"
        return 0
    fi

    # 正常构建流程
    if [ -d "$WORKSPACE" ]; then
        info "清理旧工作空间..."
        rm -rf "$WORKSPACE"
    fi
    mkdir -p "$WORKSPACE"
    ROOT_UUID=$(uuidgen)
    info "根分区 UUID: ${ROOT_UUID}"
}

#------------------------------------------------------------------------------
# mmdebstrap 构建基础根文件系统
#------------------------------------------------------------------------------
build_base() {
    step "使用 mmdebstrap 构建基础根文件系统..."

    local packages_str
    packages_str=$(IFS=,; echo "${BASE_PACKAGES[*]}")

    # 使用 crimson suite 的 beige 仓库 + hwe-25 仓库
    # 智能选择最快镜像源
    local mirror_beige mirror_hwe
    mirror_beige=$(mirror_ranking mirror_hwe)
    local repo_str
    repo_str="deb [trusted=yes] ${mirror_beige} crimson main commercial community"

    mmdebstrap \
        --hook-dir=/usr/share/mmdebstrap/hooks/merged-usr \
        --skip=check/empty \
        --include="${packages_str}" \
        --components="main,commercial,community" \
        --variant=minbase \
        --architectures=arm64 \
        "crimson" \
        "${WORKSPACE}" \
        "${repo_str}"

    ok "基础根文件系统构建完成"
}

#------------------------------------------------------------------------------
# 安全挂载（避免重复挂载）
#------------------------------------------------------------------------------
safe_mount() {
    local src="$1" dst="$2" mtype="${3:-}" opts="${4:-}"
    if mountpoint -q "$dst" 2>/dev/null; then
        warn "已挂载: $dst"
        return 0
    fi
    if [ -n "$mtype" ]; then
        mount -t "$mtype" "$src" "$dst"
    elif [ -n "$opts" ]; then
        mount -o "$opts" "$src" "$dst"
    else
        mount "$src" "$dst"
    fi
    info "挂载: $dst"
}

#------------------------------------------------------------------------------
# 挂载虚拟文件系统（参考 xiaobao1980: 含 /dev/pts）
#------------------------------------------------------------------------------
mount_vfs() {
    # 创建必要的运行时目录
    mkdir -p "${WORKSPACE}/run/dbus" "${WORKSPACE}/run/systemd"

    safe_mount proc   "${WORKSPACE}/proc"  proc   ""
    safe_mount sysfs  "${WORKSPACE}/sys"   sysfs  ""
    safe_mount /dev   "${WORKSPACE}/dev"    ""     "bind"
    safe_mount /dev/pts "${WORKSPACE}/dev/pts" "" "bind"

    # 复制 resolv.conf（-L 跟随符号链接）
    cp -L /etc/resolv.conf "${WORKSPACE}/etc/resolv.conf" 2>/dev/null || \
        echo "nameserver 223.5.5.5" > "${WORKSPACE}/etc/resolv.conf"
}

#------------------------------------------------------------------------------
# 卸载虚拟文件系统（逆序卸载，参考 xiaobao1980）
#------------------------------------------------------------------------------
umount_vfs() {
    # 逆序卸载：dev/pts → dev → sys → proc
    local mounts=(
        "${WORKSPACE}/dev/pts"
        "${WORKSPACE}/dev"
        "${WORKSPACE}/sys"
        "${WORKSPACE}/proc"
    )
    for mp in "${mounts[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || warn "卸载失败: $mp"
        fi
    done
}

#------------------------------------------------------------------------------
# chroot 执行命令
#------------------------------------------------------------------------------
chroot_exec() {
    chroot "$WORKSPACE" /bin/bash -c "$*"
}

#------------------------------------------------------------------------------
# 系统基础配置
#------------------------------------------------------------------------------


#------------------------------------------------------------------------------
# 更新 initramfs 配置（供备份恢复后调用，确保 hook 脚本和模块列表最新）
#------------------------------------------------------------------------------
update_initramfs_config() {
    info "更新 initramfs 配置..."

    # 更新 initramfs.conf（确保压缩格式为 gzip，busybox 启用）
    if [ -f "${WORKSPACE}/etc/initramfs-tools/initramfs.conf" ]; then
        sed -i 's/^COMPRESS=.*/COMPRESS=gzip/' "${WORKSPACE}/etc/initramfs-tools/initramfs.conf" 2>/dev/null || true
        sed -i 's/^BUSYBOX=.*/BUSYBOX=y/' "${WORKSPACE}/etc/initramfs-tools/initramfs.conf" 2>/dev/null || true
    fi

    # 显式列出关键模块：确保 Rockchip eMMC/SD 控制器和 ext4 在 initramfs 中
    cat > "${WORKSPACE}/etc/initramfs-tools/modules" << 'EOF'
# Rockchip MMC/SD 控制器（启动必需）
sdhci
sdhci_pltfm
sdhci_of_arasan
sdhci_of_dwcmsmc
dw_mmc
dw_mmc_rockchip
mmc_block
# SCSI/块设备
sd_mod
# 文件系统（initramfs 挂载 rootfs 必需）
ext4
# 分区表支持
gpt
EOF

    # 创建 initramfs 调试脚本
    mkdir -p "${WORKSPACE}/etc/initramfs-tools/scripts/init-premount"
    cat > "${WORKSPACE}/etc/initramfs-tools/scripts/init-premount/zz-debug-block" << 'DEBUG_EOF'
#!/bin/sh
# initramfs 调试：在尝试挂载 rootfs 前输出块设备信息
PREREQ=""
prereqs() {
    echo "$PREREQ"
}
case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

echo "===== Deepin Rockchip Initramfs Debug ====="
echo "root=${root}"
echo "ROOT=${ROOT}"
echo "ROOTFLAGS=${ROOTFLAGS}"
echo "ROOTFSTYPE=${ROOTFSTYPE}"

echo "--- Block devices ---"
ls -la /dev/block/ 2>/dev/null || true
ls -la /dev/mmcblk* 2>/dev/null || true
ls -la /dev/sd* 2>/dev/null || true

echo "--- blkid output ---"
if command -v blkid >/dev/null 2>&1; then
    blkid 2>/dev/null || true
else
    echo "blkid: NOT FOUND"
fi

echo "--- /proc/partitions ---"
cat /proc/partitions 2>/dev/null || true

echo "==========================================="
DEBUG_EOF
    chmod +x "${WORKSPACE}/etc/initramfs-tools/scripts/init-premount/zz-debug-block"

    # 创建/更新 initramfs hook：强制 busybox 链接覆盖 klibc 工具集
    mkdir -p "${WORKSPACE}/etc/initramfs-tools/hooks"
    cat > "${WORKSPACE}/etc/initramfs-tools/hooks/zz-busybox-fix" << 'HOOK_EOF'
#!/bin/sh
# 强制 busybox 命令进入 initramfs，覆盖 klibc 的有限工具集
PREREQ=""
prereqs() {
    echo "$PREREQ"
}
case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

# 显式 source initramfs-tools 的 hook 函数（copy_exec 等）
if [ -f /usr/share/initramfs-tools/hook-functions ]; then
    . /usr/share/initramfs-tools/hook-functions
fi

# 确保 busybox 存在
BUSYBOX=""
for p in /bin/busybox /usr/bin/busybox; do
    [ -x "$p" ] && { BUSYBOX="$p"; break; }
done

if [ -n "$BUSYBOX" ]; then
    # 复制 busybox 本体到 initramfs
    if type copy_exec >/dev/null 2>&1; then
        copy_exec "$BUSYBOX" /bin
    else
        mkdir -p "${DESTDIR}/bin"
        cp -a "$BUSYBOX" "${DESTDIR}/bin/busybox"
    fi

    # 关键修复：用 busybox 的静态链接 applet 覆盖所有可能冲突的工具
    for cmd in sh mount umount blkid sleep echo cat tail ls mkdir mknod \
               chmod chown ln df du env expr false find grep gzip hostname \
               kill mkfifo mktemp more mv pidof ping printf ps \
               pwd rm rmdir sed seq stat sync tee test touch tr true \
               uname uniq wc wget which xargs whoami readlink realpath \
               blockdev mke2fs mkfs.ext4 freeramdisk; do
        if "$BUSYBOX" --list 2>/dev/null | grep -q "^${cmd}$"; then
            for bindir in /bin /sbin /usr/bin /usr/sbin; do
                if [ -d "${DESTDIR}${bindir}" ]; then
                    # 强制覆盖：先删除已有的文件/链接，再创建 busybox 链接
                    if [ -e "${DESTDIR}${bindir}/${cmd}" ] && [ ! -L "${DESTDIR}${bindir}/${cmd}" ]; then
                        mv "${DESTDIR}${bindir}/${cmd}" "${DESTDIR}${bindir}/${cmd}.klibc" 2>/dev/null || rm -f "${DESTDIR}${bindir}/${cmd}" 2>/dev/null || true
                    fi
                    ln -sf /bin/busybox "${DESTDIR}${bindir}/${cmd}" 2>/dev/null || true
                fi
            done
        fi
    done

    # 确保 libblkid.so.1 存在（util-linux 的 blkid 万一被调用时需要）
    if type copy_exec >/dev/null 2>&1; then
        for libbin in /sbin/blkid /sbin/blockdev /sbin/fsck /sbin/fsck.ext4 /bin/mount /bin/umount; do
            if [ -x "$libbin" ] && [ ! -e "${DESTDIR}${libbin}" ]; then
                copy_exec "$libbin" "$(dirname "$libbin")" 2>/dev/null || true
            fi
        done
    fi
fi
HOOK_EOF
    chmod +x "${WORKSPACE}/etc/initramfs-tools/hooks/zz-busybox-fix"

    # 确保 initramfs-tools 安装并启用 busybox
    chroot_exec "apt-get install -y busybox initramfs-tools 2>/dev/null || true"

    ok "initramfs 配置已更新"
}

configure_system() {
    step "系统基础配置..."

    # 主机名
    echo "$TARGET_HOSTNAME" > "${WORKSPACE}/etc/hostname"
    cat > "${WORKSPACE}/etc/hosts" << EOF
127.0.0.1       localhost
127.0.1.1       ${TARGET_HOSTNAME}
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

    # Locale: 生成 C.UTF-8 zh_CN.UTF-8 en_US.UTF-8（参考 xiaobao1980）
    chroot "$WORKSPACE" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y locales" 2>/dev/null || true
    chroot_exec "sed -i 's/# zh_CN.UTF-8/zh_CN.UTF-8/' /etc/locale.gen"
    chroot_exec "sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen"
    # 确保 C.UTF-8 也在列表中
    grep -q "C.UTF-8" "${WORKSPACE}/etc/locale.gen" 2>/dev/null || echo "C.UTF-8 UTF-8" >> "${WORKSPACE}/etc/locale.gen"
    chroot_exec "locale-gen"
    chroot_exec "update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh"
    # 写入默认 locale 文件
    echo 'LANG=zh_CN.UTF-8' > "${WORKSPACE}/etc/default/locale"
    echo 'LANGUAGE=zh_CN:zh' >> "${WORKSPACE}/etc/default/locale"

    # 时区
    chroot_exec "ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime"

    # fstab
    cat > "${WORKSPACE}/etc/fstab" << EOF
UUID=${ROOT_UUID}  /  ext4  defaults,x-systemd.growfs  0  1
EOF

    # 启用 systemd 服务
    chroot_exec "systemctl enable systemd-networkd"
    chroot_exec "systemctl enable systemd-resolved 2>/dev/null || true"

    # 配置 initramfs-tools: 强制使用 busybox（klibc 缺少 tail 等命令）
    info "配置 initramfs-tools 使用 busybox..."
    mkdir -p "${WORKSPACE}/etc/initramfs-tools"
    cat > "${WORKSPACE}/etc/initramfs-tools/initramfs.conf" << 'EOF'
MODULES=most
BUSYBOX=y
COMPRESS=gzip
DEVICE=
NFSROOT=auto
RUNSIZE=10%
FSTYPE=auto
EOF

    # 显式列出关键模块：确保 Rockchip eMMC/SD 控制器和 ext4 在 initramfs 中
    # 即使部分驱动已内置(y)，显式列出可确保模块依赖也被包含
    info "配置 initramfs 关键模块..."
    cat > "${WORKSPACE}/etc/initramfs-tools/modules" << 'EOF'
# Rockchip MMC/SD 控制器（启动必需）
sdhci
sdhci_pltfm
sdhci_of_arasan
sdhci_of_dwcmsmc
dw_mmc
dw_mmc_rockchip
mmc_block
# SCSI/块设备
sd_mod
# 文件系统（initramfs 挂载 rootfs 必需）
ext4
# 分区表支持
gpt
EOF

# 创建 initramfs local-premount 调试脚本：帮助排查 "Waiting for root file system" 循环
    # 此脚本在挂载 rootfs 之前运行，输出块设备和 UUID 检测信息到控制台
    info "添加 initramfs 调试脚本..."
    mkdir -p "${WORKSPACE}/etc/initramfs-tools/scripts/init-premount"
    cat > "${WORKSPACE}/etc/initramfs-tools/scripts/init-premount/zz-debug-block" << 'DEBUG_EOF'
#!/bin/sh
# initramfs 调试：在尝试挂载 rootfs 前输出块设备信息
PREREQ=""
prereqs() {
    echo "$PREREQ"
}
case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

echo "===== Deepin Rockchip Initramfs Debug ====="
echo "root=${root}"
echo "ROOT=${ROOT}"
echo "ROOTFLAGS=${ROOTFLAGS}"
echo "ROOTFSTYPE=${ROOTFSTYPE}"

# 列出所有块设备
echo "--- Block devices ---"
ls -la /dev/block/ 2>/dev/null || true
ls -la /dev/mmcblk* 2>/dev/null || true
ls -la /dev/sd* 2>/dev/null || true

# 尝试 blkid 检测
echo "--- blkid output ---"
if command -v blkid >/dev/null 2>&1; then
    blkid 2>/dev/null || true
else
    echo "blkid: NOT FOUND"
fi

# 检查 /proc/partitions
echo "--- /proc/partitions ---"
cat /proc/partitions 2>/dev/null || true

echo "==========================================="
DEBUG_EOF
    chmod +x "${WORKSPACE}/etc/initramfs-tools/scripts/init-premount/zz-debug-block"

    # 创建 initramfs hook：确保 busybox 命令可用 + util-linux 工具保留
    # 关键策略：
    # 1. 先用 copy_exec 复制 util-linux 的 blkid/mount/umount（确保库依赖完整）
    # 2. 然后复制 busybox 并覆盖 klibc 的有限工具集（但不覆盖 blkid/mount/umount）
    # 3. busybox 的 blkid 功能有限，无法正确读取 UUID，必须用 util-linux 版本
    mkdir -p "${WORKSPACE}/etc/initramfs-tools/hooks"
    cat > "${WORKSPACE}/etc/initramfs-tools/hooks/zz-busybox-fix" << 'HOOK_EOF'
#!/bin/sh
# 确保 busybox 命令可用，同时保留 util-linux 的 blkid/mount/umount
PREREQ=""
prereqs() {
    echo "$PREREQ"
}
case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

# source hook-functions 以使用 copy_exec
if [ -f /usr/share/initramfs-tools/hook-functions ]; then
    . /usr/share/initramfs-tools/hook-functions
fi

# === 步骤 1: 先复制 util-linux 的关键工具（确保库依赖完整）===
# blkid 必须保留 util-linux 版本，busybox 的 blkid 无法正确读取 UUID
if type copy_exec >/dev/null 2>&1; then
    for libbin in /usr/bin/blkid /sbin/blkid /bin/mount /bin/umount; do
        if [ -x "$libbin" ]; then
            copy_exec "$libbin" "$(dirname "$libbin")" 2>/dev/null || true
        fi
    done
fi

# === 步骤 2: 复制 busybox 到 initramfs ===
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

    # === 步骤 3: 用 busybox 覆盖 klibc 的有限工具集 ===
    # 注意：明确排除 blkid, mount, umount（保留 util-linux 版本）
    for cmd in sh sleep echo cat tail ls mkdir mknod \
               chmod chown ln df du env expr false find grep gzip hostname \
               kill mkfifo mktemp more mv pidof ping printf ps \
               pwd rm rmdir sed seq stat sync tee test touch tr true \
               uname uniq wc wget which xargs whoami readlink realpath \
               blockdev freeramdisk; do
        if "$BUSYBOX" --list 2>/dev/null | grep -q "^${cmd}$"; then
            for bindir in /bin /sbin /usr/bin /usr/sbin; do
                if [ -d "${DESTDIR}${bindir}" ]; then
                    local_path="${DESTDIR}${bindir}/${cmd}"
                    # 只覆盖 klibc 的有限版本（小文件，通常 < 50KB）
                    # 不覆盖 util-linux 的版本（有库依赖，更大）
                    if [ -e "$local_path" ] && [ ! -L "$local_path" ]; then
                        fsize=$(stat -c%s "$local_path" 2>/dev/null || echo 0)
                        if [ "$fsize" -lt 51200 ]; then
                            # 小于 50KB，很可能是 klibc 版本，备份后覆盖
                            mv "$local_path" "${local_path}.klibc" 2>/dev/null || rm -f "$local_path" 2>/dev/null || true
                            ln -sf /bin/busybox "$local_path" 2>/dev/null || true
                        fi
                    elif [ -L "$local_path" ] || [ ! -e "$local_path" ]; then
                        # 链接或不存在，直接创建 busybox 链接
                        ln -sf /bin/busybox "$local_path" 2>/dev/null || true
                    fi
                fi
            done
        fi
    done
fi
HOOK_EOF
    chmod +x "${WORKSPACE}/etc/initramfs-tools/hooks/zz-busybox-fix"

    # 安装 Mali GPU CSF 固件（Panthor 驱动必需）
    # 关键: 固件必须是未压缩的 .bin 文件，内核固件加载器无法直接读取 .zst
    info "安装 Mali GPU CSF 固件..."
    local mali_fw_dir="${WORKSPACE}/lib/firmware/arm/mali/arch10.8"
    mkdir -p "$mali_fw_dir"

    # 查找固件：同时检查 .bin 和 .bin.zst
    # linux-firmware 包可能提供 zstd 压缩的固件，需要解压
    local local_fw=""
    local local_fw_compressed=""

    # 1. 先找未压缩的 .bin
    for p in "${BUILD_ROOT}/firmware/mali_csffw.bin" \
             "${BUILD_ROOT}/sources/linux-firmware/arm/mali/arch10.8/mali_csffw.bin" \
             "/lib/firmware/arm/mali/arch10.8/mali_csffw.bin"; do
        [ -f "$p" ] && { local_fw="$p"; break; }
    done

    # 2. 没找到 .bin，找 .zst 压缩版本
    if [ -z "$local_fw" ]; then
        for p in "${BUILD_ROOT}/firmware/mali_csffw.bin.zst" \
                 "${BUILD_ROOT}/sources/linux-firmware/arm/mali/arch10.8/mali_csffw.bin.zst" \
                 "/lib/firmware/arm/mali/arch10.8/mali_csffw.bin.zst"; do
            [ -f "$p" ] && { local_fw_compressed="$p"; break; }
        done
    fi

    if [ -n "$local_fw" ]; then
        info "使用本地固件: $local_fw"
        cp -a "$local_fw" "${mali_fw_dir}/mali_csffw.bin"
    elif [ -n "$local_fw_compressed" ]; then
        info "使用压缩固件，正在解压: $local_fw_compressed"
        if command -v zstd &>/dev/null; then
            zstd -d "$local_fw_compressed" -o "${mali_fw_dir}/mali_csffw.bin" 2>/dev/null && \
                ok "固件解压成功" || warn "zstd 解压失败"
        elif command -v unzstd &>/dev/null; then
            unzstd "$local_fw_compressed" -o "${mali_fw_dir}/mali_csffw.bin" 2>/dev/null && \
                ok "固件解压成功" || warn "unzstd 解压失败"
        else
            warn "找到压缩固件但无解压工具 (zstd/unzstd)"
        fi
    elif command -v curl &>/dev/null; then
        # 3. 从网络下载（JeffyCN 的镜像，RK3588 G610 用）
        info "从网络下载 mali_csffw.bin..."
        local fw_urls=(
            "https://raw.githubusercontent.com/JeffyCN/mirrors/master/firmware/g610/mali_csffw.bin"
            "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/arm/mali/arch10.8/mali_csffw.bin"
        )
        local downloaded=""
        for url in "${fw_urls[@]}"; do
            if curl -sfL --connect-timeout 30 --max-time 120 "$url" -o "${mali_fw_dir}/mali_csffw.bin" 2>/dev/null; then
                downloaded="yes"
                info "固件下载成功: $url"
                break
            fi
        done
        if [ -z "$downloaded" ]; then
            warn "mali_csffw.bin 下载失败，Panthor GPU 驱动将无法加载"
            warn "请手动下载并放置到: ${mali_fw_dir}/mali_csffw.bin"
            warn "下载地址: https://raw.githubusercontent.com/JeffyCN/mirrors/master/firmware/g610/mali_csffw.bin"
        fi
    else
        warn "未找到 mali_csffw.bin 固件（.bin 或 .zst）"
        warn "Panthor GPU 驱动将无法加载"
        warn "请手动下载并放置到: ${mali_fw_dir}/mali_csffw.bin"
    fi

    # 确保固件在 initramfs 中可用（Panthor 驱动可能在早期启动时加载）
    if [ -f "${mali_fw_dir}/mali_csffw.bin" ]; then
        # 创建 initramfs firmware hook
        # 关键: 使用最简单的 cp 命令复制固件，避免依赖 hook-functions 中的函数
        # hook-functions 的 copy_file/copy_exec 在不同版本中名称和参数不一致
        cat > "${WORKSPACE}/etc/initramfs-tools/hooks/zz-mali-firmware" << 'MALI_FW_EOF'
#!/bin/sh
# 确保 Mali CSF 固件包含在 initramfs 中
# 注意：不使用 set -e，任何错误都不应导致 hook 失败
PREREQ=""
prereqs() {
    echo "$PREREQ"
}
case $1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac

# 使用最简单的 cp 命令复制固件，不依赖 hook-functions
FW_SRC="/lib/firmware/arm/mali/arch10.8/mali_csffw.bin"
if [ -f "$FW_SRC" ]; then
    mkdir -p "${DESTDIR}/lib/firmware/arm/mali/arch10.8"
    cp -a "$FW_SRC" "${DESTDIR}/lib/firmware/arm/mali/arch10.8/mali_csffw.bin"
fi
exit 0
MALI_FW_EOF
        chmod +x "${WORKSPACE}/etc/initramfs-tools/hooks/zz-mali-firmware"
        ok "Mali CSF 固件 hook 已创建"
    else
        warn "mali_csffw.bin 不存在，跳过 Panthor GPU 固件 hook"
    fi

    # 添加 CM3588 NAS 网卡重命名 udev 规则（参考 armbian cm3588-nas.csc）
    info "添加 CM3588 网卡重命名规则..."
    mkdir -p "${WORKSPACE}/etc/udev/rules.d"
    cat > "${WORKSPACE}/etc/udev/rules.d/70-persistent-net.rules" << 'EOF'
# CM3588 NAS: PCIe RTL8125 网卡重命名为 eth0
SUBSYSTEM=="net", ACTION=="add", KERNELS=="0004:41:00.0", NAME:="eth0"
EOF

    # 添加 CM3588 NAS 音频设备友好名称（参考 armbian cm3588-nas.csc）
    info "添加 CM3588 音频设备命名规则..."
    cat > "${WORKSPACE}/etc/udev/rules.d/90-naming-audios.rules" << 'EOF'
SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi0-sound", ENV{SOUND_DESCRIPTION}="HDMI-0 Audio Out"
SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmi1-sound", ENV{SOUND_DESCRIPTION}="HDMI-1 Audio Out"
SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-dp0-sound", ENV{SOUND_DESCRIPTION}="DisplayPort-Over-USB Audio Out"
SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-rt5616-sound", ENV{SOUND_DESCRIPTION}="Headphone Out/Mic In"
SUBSYSTEM=="sound", ENV{ID_PATH}=="platform-hdmiin-sound", ENV{SOUND_DESCRIPTION}="HDMI-IN Audio In"
EOF

    # ============================================
    # 写入 HWE (Hardware Enablement) 仓库
    # hwe-25 提供新内核、Mesa 驱动、硬件支持
    # ============================================
    info "配置 HWE 仓库..."
    mkdir -p "${WORKSPACE}/etc/apt/sources.list.d"
    cat > "${WORKSPACE}/etc/apt/sources.list.d/hwe.list" << 'EOF'
# Deepin 25 HWE (Hardware Enablement) Repository
# Provides newer kernel, Mesa drivers, and hardware support
# Essential for: GPU acceleration, new WiFi/BT chipsets
deb https://cdn-community-packages.deepin.com/hwe-25/ unstable main community commercial
#deb-src https://cdn-community-packages.deepin.com/hwe-25/ unstable main community commercial
EOF

    # ============================================
    # 应用商店 + 打印机源 + apt 行为优化
    # ============================================
    info "配置应用商店源与 apt 优化..."
    mkdir -p "${WORKSPACE}/etc/apt/sources.list.d"

    cat > "${WORKSPACE}/etc/apt/sources.list.d/appstore.list" << 'EOF'
# Deepin 25 App Store Repository
# 提供 deepin-app-store 及商业应用分发
deb https://community-store-packages.deepin.com/appstore eagle appstore
EOF

    cat > "${WORKSPACE}/etc/apt/sources.list.d/printer.list" << 'EOF'
# Deepin 25 Printer Driver Repository
deb https://community-packages.deepin.com/printer eagle non-free
EOF

    mkdir -p "${WORKSPACE}/etc/apt/apt.conf.d"
    cat > "${WORKSPACE}/etc/apt/apt.conf.d/99-apt-optimize" << 'EOF'
// apt 行为优化：锁冲突防护 + 性能优化 + 自动清理
APT::Get::Fix-Broken "true";
APT::Periodic::AutocleanInterval "7";
APT::Acquire::Queue-Mode "access";
APT::Acquire::Retries "3";
APT::Get::List-Cleanup "true";
DPkg::Lock::Timeout "30";
APT::Get::Clean "always";
APT::Get::AutomaticRemove "true";
APT::Acquire::http::Timeout "30";
APT::Acquire::https::Timeout "30";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

    # ============================================
    # Rockchip GPU/VPU 设备权限规则
    # 必须让 video/render 组用户访问 GPU 和 VPU 设备
    # 参考: Jellyfin Rockchip HWA 文档 + Deepin 论坛 RK3588 经验
    # ============================================
    info "添加 Rockchip GPU/VPU 设备权限规则..."
    mkdir -p "${WORKSPACE}/etc/udev/rules.d"
    cat > "${WORKSPACE}/etc/udev/rules.d/99-rk-device-permissions.rules" << 'EOF'
# Rockchip GPU/VPU/DRM 设备权限
# 让 video 组访问 GPU/VPU，render 组访问 DRI render 节点

# DRM DRI 设备 (GPU)
KERNEL=="renderD[0-9]*", SUBSYSTEM=="drm", MODE="0660", GROUP="render"
KERNEL=="card[0-9]*", SUBSYSTEM=="drm", MODE="0660", GROUP="video"

# Mali GPU 设备
KERNEL=="mali[0-9]*", MODE="0660", GROUP="video"

# MPP 视频编解码服务
KERNEL=="mpp_service", MODE="0660", GROUP="video"
KERNEL=="mpp-service", MODE="0660", GROUP="video"

# RGA 2D 图形处理
KERNEL=="rga", MODE="0660", GROUP="video"
KERNEL=="rga[0-9]*", MODE="0660", GROUP="video"

# IEP 图像处理引擎
KERNEL=="iep", MODE="0660", GROUP="video"

# 视频编解码器
KERNEL=="rkvdec", MODE="0660", GROUP="video"
KERNEL=="rkvdec[0-9]*", MODE="0660", GROUP="video"
KERNEL=="rkvenc", MODE="0660", GROUP="video"
KERNEL=="rkvenc[0-9]*", MODE="0660", GROUP="video"
KERNEL=="vepu", MODE="0660", GROUP="video"
KERNEL=="h265e", MODE="0660", GROUP="video"
KERNEL=="vpu_service", MODE="0660", GROUP="video"

# DMA-BUF heaps (MPP buffer allocation 必需)
# 注意: 必须用 SUBSYSTEM=="dma_heap" 匹配，KERNEL=="dma_heap/*" 无效
SUBSYSTEM=="dma_heap", KERNEL=="system",          MODE="0660", GROUP="video"
SUBSYSTEM=="dma_heap", KERNEL=="system-uncached", MODE="0660", GROUP="video"
SUBSYSTEM=="dma_heap", KERNEL=="cma",             MODE="0660", GROUP="video"
EOF

    # 确保 systemd-logind 不回收空闲会话的 device 权限
    if [ -f "${WORKSPACE}/etc/systemd/logind.conf" ]; then
        sed -i 's/^#*KillUserProcesses=.*/KillUserProcesses=no/' "${WORKSPACE}/etc/systemd/logind.conf"
        sed -i 's/^#*IdleAction=.*/IdleAction=ignore/' "${WORKSPACE}/etc/systemd/logind.conf"
    fi


    # ============================================
    # mpv 硬件加速配置 (rkmpp) - 全局默认
    # ============================================
    info "配置 mpv 硬件加速..."
    mkdir -p "${WORKSPACE}/etc/mpv"
    cat > "${WORKSPACE}/etc/mpv/mpv.conf" << 'MPV_EOF'
# mpv 硬件加速配置 - Rockchip RK3588 (X11 桌面环境)
vo=gpu
hwdec=rkmpp
hwdec-codecs=all
# 缓存设置
cache=yes
cache-secs=60
demuxer-max-bytes=50M
demuxer-max-back-bytes=25M
# 字幕
sub-auto=fuzzy
sub-font-size=40
# 界面
osc=no
border=no
MPV_EOF

    # 用户级配置模板（新用户自动继承）
    mkdir -p "${WORKSPACE}/etc/skel/.config/mpv"
    cp "${WORKSPACE}/etc/mpv/mpv.conf" "${WORKSPACE}/etc/skel/.config/mpv/mpv.conf"

    ok "系统基础配置完成"
}

#------------------------------------------------------------------------------
# 安装桌面环境 (chroot 内 apt install，参考 xiaobao1980)
#------------------------------------------------------------------------------
install_desktop() {
    if [ "$MINIMAL" = "yes" ]; then
        info "最小化模式，跳过桌面安装"
        return 0
    fi

    step "安装桌面环境..."

    # 统一设置前端为 noninteractive（避免交互式配置提示）
    export DEBIAN_FRONTEND=noninteractive

    # 更新 apt 缓存
    chroot_exec "apt-get update"

    # 预装 Qt5 基础库（避免后续 DDE 组件依赖问题，参考 xiaobao1980）
    info "预装 Qt5 依赖..."
    chroot_exec "apt-get install -y --no-install-recommends libqt5concurrent5 libqt5core5a libqt5gui5 libqt5network5 libqt5widgets5 || true"

    # 统一安装 DDE 桌面环境（一次调用，--allow-downgrades 允许降级，参考 xiaobao1980）
    info "安装 DDE 桌面环境..."
    chroot "$WORKSPACE" /bin/bash << 'DESKTOP_EOF'
        set -e
        export DEBIAN_FRONTEND=noninteractive
        APT_INSTALL="apt-get install -fy --allow-downgrades --no-install-recommends"

        # 步骤1: 安装核心包（必需）
        echo "=== [1/3] 安装 DDE 核心包 ==="
        $APT_INSTALL \
            deepin-desktop-environment-core \
            deepin-desktop-environment-base \
            deepin-desktop-environment-cli \
            || true

        # 步骤2: 尝试安装 extras（可能因 dde-printer 等依赖断裂失败）
        echo "=== [2/3] 安装 DDE extras（容错）==="
        $APT_INSTALL deepin-desktop-environment-extras || {
            echo "警告: deepin-desktop-environment-extras 安装失败（dde-printer 依赖断裂），跳过"
            echo "尝试单独安装 extras 中的关键组件..."
            for pkg in deepin-album deepin-calculator deepin-editor deepin-movie deepin-music deepin-terminal; do
                apt-get install -fy --no-install-recommends "$pkg" 2>/dev/null || true
            done
        }

        # 步骤3: 安装其他工具
        echo "=== [3/3] 安装其他工具 ==="
        $APT_INSTALL \
            firefox \
            fcitx5 fcitx5-chinese-addons \
            fonts-noto-cjk fonts-noto-color-emoji \
            || true

        # 应用商店（ARM64 官方已支持，容错安装）
        echo "=== [AppStore] 安装 deepin-app-store ==="
        apt-get install -fy --no-install-recommends deepin-app-store 2>/dev/null || {
            echo "警告: deepin-app-store 安装失败，可能因网络或依赖问题"
            echo "      系统启动后可通过 sudo apt update && sudo apt install deepin-app-store 重试"
        }
DESKTOP_EOF

    # 启用显示管理器
    chroot_exec "systemctl enable lightdm 2>/dev/null || systemctl enable ddm 2>/dev/null || true"

    # ============================================
    # 安装镜像源切换工具（已安装系统可随时使用）
    # ============================================
    info "安装 apt-mirror-switch 工具..."
    cat > "${WORKSPACE}/usr/local/bin/apt-mirror-switch" << 'MIRROR_EOF'
#!/bin/bash
# apt-mirror-switch: 智能选择最快 Deepin 25 镜像源
# 用法: sudo apt-mirror-switch [--auto|--list|--show]

MIRRORS=(
    "阿里云|https://mirrors.aliyun.com/deepin/beige/"
    "清华|https://mirrors.tuna.tsinghua.edu.cn/deepin/beige/"
    "中科大|https://mirrors.ustc.edu.cn/deepin/beige/"
    "腾讯云|https://mirrors.cloud.tencent.com/deepin/beige/"
    "华为云|https://repo.huaweicloud.com/deepin/beige/"
    "官方|https://community-packages.deepin.com/beige/"
)

# hwe-25 只有官方源（第三方镜像未同步）
HWE_URL="https://cdn-community-packages.deepin.com/hwe-25/"

show_help() {
    echo "用法: $(basename "$0") [选项]"
    echo ""
    echo "选项:"
    echo "  --auto   自动测试并切换到最快镜像源 (默认)"
    echo "  --list   列出所有候选镜像源及其延迟"
    echo "  --show   显示当前使用的镜像源"
    echo "  -h       显示此帮助"
}

# 测试单个镜像延迟
mirror_test() {
    local url="$1"
    curl -fsSL -o /dev/null --connect-timeout 5 --max-time 5 \
         -w "%{time_total}" "${url}dists/crimson/InRelease" 2>/dev/null
}

# 列出所有镜像延迟
cmd_list() {
    echo "镜像源测速结果:"
    echo "========================"
    local entry name url latency
    for entry in "${MIRRORS[@]}"; do
        name="${entry%%|*}"
        url="${entry##*|}"
        latency=$(mirror_test "$url")
        if [ -n "$latency" ]; then
            printf "  %-8s %s  (%ss)\n" "$name" "$url" "$latency"
        else
            printf "  %-8s %s  (超时)\n" "$name" "$url"
        fi
    done
}

# 显示当前源
cmd_show() {
    if [ -f /etc/apt/sources.list ]; then
        echo "当前 apt 源:"
        grep "^deb" /etc/apt/sources.list | head -3
    else
        echo "未找到 /etc/apt/sources.list"
    fi
}

# 自动切换到最快镜像
cmd_auto() {
    echo "正在测试镜像源速度..."
    local best_url=""
    local best_time="999"
    local best_name="官方"
    local entry name url latency

    for entry in "${MIRRORS[@]}"; do
        name="${entry%%|*}"
        url="${entry##*|}"
        latency=$(mirror_test "$url")
        if [ -n "$latency" ]; then
            printf "  %-8s: %ss\n" "$name" "$latency"
            if awk "BEGIN {exit !($latency < $best_time)}" 2>/dev/null; then
                best_time="$latency"
                best_url="$url"
                best_name="$name"
            fi
        else
            printf "  %-8s: 超时\n" "$name"
        fi
    done

    if [ -z "$best_url" ]; then
        echo "错误: 所有镜像源均无法连接" >&2
        exit 1
    fi

    echo ""
    echo "选中: ${best_name} (${best_time}s)"
    echo ""

    # 备份并写入新配置
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d_%H%M%S)
    cat > /etc/apt/sources.list << EOF
deb [trusted=yes] ${best_url} crimson main commercial community
EOF

    echo "新配置已写入 /etc/apt/sources.list"
    echo "正在 apt update..."
    apt update
}

# 主逻辑
case "${1:-}" in
    --list|-l)  cmd_list ;;
    --show|-s)  cmd_show ;;
    --auto|-a|"") cmd_auto ;;
    -h|--help)  show_help ;;
    *) echo "未知选项: $1" >&2; show_help; exit 1 ;;
esac
MIRROR_EOF
    chmod +x "${WORKSPACE}/usr/local/bin/apt-mirror-switch"

    ok "桌面环境安装完成"
}


install_rkmpp() {
    step "安装 ffmpeg-rockchip (rkmpp 硬件加速)..."

    # 复制本地缓存（同上，省略）
    RKMPP_CACHE_HOST="${BUILD_ROOT}/sources/rkmpp-cache"
    RKMPP_CACHE_CHROOT="${WORKSPACE}/tmp/rkmpp-cache"
    if [ -d "$RKMPP_CACHE_HOST" ] && [ "$(ls -A "$RKMPP_CACHE_HOST" 2>/dev/null)" ]; then
        info "复制 rkmpp 本地缓存到 chroot..."
        mkdir -p "$RKMPP_CACHE_CHROOT"
        for d in libyuv mpp rga ffmpeg-rockchip; do
            if [ -d "${RKMPP_CACHE_HOST}/${d}" ] && [ ! -d "${RKMPP_CACHE_CHROOT}/${d}" ]; then
                cp -a "${RKMPP_CACHE_HOST}/${d}" "$RKMPP_CACHE_CHROOT/"
                ok "  缓存: ${d}"
            fi
        done
    fi

    chroot "$WORKSPACE" /bin/bash << 'RKMPP_EOF'
        set -e
        export DEBIAN_FRONTEND=noninteractive
        export ALLOW_ROOT=1

        # === 关键修改1: 不卸载系统 ffmpeg，避免破坏依赖链 ===
        # 只解除 hold，不卸载任何包
        for pkg in ffmpeg libavcodec60 libavdevice60 libavfilter9 libavformat60 \
                   libavutil58 libpostproc57 libswresample4 libswscale7; do
            apt-mark unhold "$pkg" 2>/dev/null || true
        done

        # 安装编译依赖（--no-upgrade 防止升级 mesa/libdrm）
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends --no-upgrade \
            git meson cmake pkg-config build-essential \
            libdrm-dev ninja-build nasm yasm \
            libtool autoconf automake wget curl

        # 设置 pkg-config 路径
        export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/pkgconfig:$PKG_CONFIG_PATH
        ldconfig

        BUILD_DIR="/tmp/rkmpp-build"
        mkdir -p "$BUILD_DIR"
        cd "$BUILD_DIR"

        # 智能克隆函数
        smart_clone() {
            local dir="$1"; shift
            local urls=("$@")
            if [ -d "$dir" ]; then
                echo "  使用已存在的 ${dir}"
                return 0
            fi
            if [ -d "/tmp/rkmpp-cache/${dir}" ]; then
                echo "  从本地缓存复制 ${dir}..."
                cp -a "/tmp/rkmpp-cache/${dir}" .
                return 0
            fi
            for url in "${urls[@]}"; do
                echo "  尝试: ${url}"
                if git clone --depth=1 --single-branch "$url" "$dir" 2>/dev/null; then
                    return 0
                fi
            done
            echo "  错误: 无法克隆 ${dir}"
            return 1
        }

        # === 1. 编译 libyuv ===
        echo "=== [1/4] 编译 libyuv ==="
        smart_clone libyuv "https://chromium.googlesource.com/libyuv/libyuv"
        cd libyuv
        cmake -B build -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DLIBYUV_BUILD_GTEST=OFF
        cmake --build build -j$(nproc) --target yuv
        cp -a build/libyuv.a /usr/local/lib/
        mkdir -p /usr/local/include/libyuv
        cp -a include/libyuv/*.h /usr/local/include/libyuv/
        cd "$BUILD_DIR"

        # === 2. 编译 mpp ===
        echo "=== [2/4] 编译 mpp ==="
        smart_clone mpp \
            "https://ghproxy.com/https://github.com/nyanmisaka/mpp.git" \
            "https://github.com/nyanmisaka/mpp.git"
        cd mpp
        cmake -B build -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release -DBUILD_TEST=OFF -DHAVE_DRM=ON
        cmake --build build -j$(nproc)
        cmake --install build
        ldconfig
        cd "$BUILD_DIR"

        # === 3. 编译 rga ===
        echo "=== [3/4] 编译 rga ==="
        smart_clone rga \
            "https://ghproxy.com/https://github.com/nyanmisaka/rga.git" \
            "https://github.com/nyanmisaka/rga.git"
        cd rga
        rga_opts=""
        if meson introspect --buildoptions meson.build 2>/dev/null | grep -q "ld_api"; then
            rga_opts="-Dld_api=true"
        fi
        meson setup build --prefix=/usr/local --buildtype=release $rga_opts
        meson compile -C build
        meson install -C build
        ldconfig
        cd "$BUILD_DIR"

        # === 4. 编译 ffmpeg-rockchip（安装到 /usr/local，不覆盖系统）===
        echo "=== [4/4] 编译 ffmpeg-rockchip ==="
        export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/pkgconfig:$PKG_CONFIG_PATH
        ldconfig
        pkg-config --exists rockchip_mpp && echo "mpp: OK" || echo "mpp: 未找到"
        pkg-config --exists librga && echo "rga: OK" || echo "rga: 未找到"

        smart_clone ffmpeg-rockchip \
            "https://ghproxy.com/https://github.com/nyanmisaka/ffmpeg-rockchip.git" \
            "https://github.com/nyanmisaka/ffmpeg-rockchip.git"
        cd ffmpeg-rockchip
        ./configure \
            --prefix=/usr/local \
            --libdir=/usr/local/lib/ffmpeg-rkmpp \
            --enable-gpl \
            --enable-version3 \
            --enable-libdrm \
            --enable-rkmpp \
            --enable-rkrga \
            --enable-ffplay \
            --enable-ffmpeg \
            --enable-ffprobe \
            --enable-shared \
            --disable-static \
            --extra-libs=-lpthread \
            --extra-libs=-lm \
            --extra-ldflags="-Wl,-rpath,/usr/local/lib/ffmpeg-rkmpp -Wl,-rpath,/usr/local/lib" \
            --enable-nonfree \
            2>&1 | tee configure.log
        make -j$(nproc)
        make install
        ldconfig
        cd "$BUILD_DIR"

        # === 关键修改2: 通过 PATH + alternatives 优先使用自定义 ffmpeg，不破坏系统包 ===
        echo "=== 配置 ffmpeg 优先级 ==="

        # 确保 /usr/local/bin 在 PATH 中优先
        if [ -f /etc/profile ]; then
            if ! grep -q 'PATH="/usr/local/bin' /etc/profile; then
                echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/profile
            fi
        fi

        # 关键修复：不再全局污染 ld.so.conf.d
        # ffmpeg 库通过 rpath 自包含在 /usr/local/lib/ffmpeg-rkmpp
        # 删除旧的污染配置（如果存在），避免系统显示管理器加载不兼容库
        rm -f /etc/ld.so.conf.d/99-local.conf
        ldconfig

        # 设置 alternatives（/usr/local 版本优先级 100，系统版本默认 50）
        for cmd in ffmpeg ffprobe ffplay; do
            if [ -f "/usr/local/bin/${cmd}" ]; then
                # 先移除旧的（避免冲突）
                update-alternatives --remove "${cmd}" "/usr/bin/${cmd}" 2>/dev/null || true
                update-alternatives --remove "${cmd}" "/usr/local/bin/${cmd}" 2>/dev/null || true
                # 重新安装，自定义版本优先级更高
                update-alternatives --install "/usr/bin/${cmd}" "${cmd}" "/usr/local/bin/${cmd}" 100 2>/dev/null || true
                update-alternatives --install "/usr/bin/${cmd}" "${cmd}" "/usr/bin/${cmd}.distrib" 50 2>/dev/null || true
                update-alternatives --set "${cmd}" "/usr/local/bin/${cmd}" 2>/dev/null || true
            fi
        done

        # === 关键修改3: 不阻止系统 ffmpeg 升级（避免依赖断裂）===
        # 删除旧的 pin 文件（如果存在）
        rm -f /etc/apt/preferences.d/ffmpeg-local

        # 改为只阻止自动安装 ffmpeg 的"推荐"依赖，不阻止包本身
        # 实际上，保留系统 ffmpeg 包是最安全的

        # === 安装 mpv（使用系统包，依赖系统 ffmpeg 库）===
        echo "=== 安装 mpv ==="
        apt-get install -y -qq --no-install-recommends \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            mpv vainfo 2>/dev/null || true

        # === 验证 ===
        echo ""
        echo "=== 验证 ffmpeg 版本 ==="
        ffmpeg_path=$(which ffmpeg 2>/dev/null || echo "")
        if [ -n "$ffmpeg_path" ]; then
            echo "ffmpeg 路径: $ffmpeg_path"
            echo "ffmpeg 版本:"
            ffmpeg -version 2>/dev/null | head -1 || true
            echo "ffmpeg 依赖库 (应包含 rkmpp 子目录，不影响系统):"
            ldd "$ffmpeg_path" 2>/dev/null | grep -E "libav|librockchip|librga" || true
        fi
        echo ""
        echo "=== rkmpp 解码器 ==="
        ffmpeg -decoders 2>/dev/null | grep rkmpp || echo "无 rkmpp 解码器"
        echo ""
        echo "=== rkmpp 编码器 ==="
        ffmpeg -encoders 2>/dev/null | grep rkmpp || echo "无 rkmpp 编码器"

        # === 关键修复: mpv 使用系统 ffmpeg 库，无法调用 rkmpp ===
        # 创建 mpv wrapper，通过 LD_LIBRARY_PATH 加载自定义 ffmpeg-rockchip 库
        echo "=== 创建 mpv rkmpp wrapper ==="
        if [ -x /usr/bin/mpv ] && [ ! -f /usr/bin/mpv.distrib ]; then
            mv /usr/bin/mpv /usr/bin/mpv.distrib
            cat > /usr/bin/mpv << 'MPV_WRAPPER'
#!/bin/bash
# mpv wrapper: 加载 ffmpeg-rockchip 自定义库以启用 rkmpp 硬件加速
# 库隔离在 /usr/local/lib/ffmpeg-rkmpp，避免污染系统其他程序
export LD_LIBRARY_PATH=/usr/local/lib/ffmpeg-rkmpp:/usr/local/lib:${LD_LIBRARY_PATH}
exec /usr/bin/mpv.distrib "$@"
MPV_WRAPPER
            chmod +x /usr/bin/mpv
            echo "mpv wrapper 已创建: /usr/bin/mpv -> /usr/bin/mpv.distrib"
        fi

        # 同时创建显式命令 mpv-rkmpp（供脚本/桌面调用）
        cat > /usr/local/bin/mpv-rkmpp << 'MPV_RKMPP'
#!/bin/bash
export LD_LIBRARY_PATH=/usr/local/lib/ffmpeg-rkmpp:/usr/local/lib:${LD_LIBRARY_PATH}
exec /usr/bin/mpv.distrib "$@"
MPV_RKMPP
        chmod +x /usr/local/bin/mpv-rkmpp

        # === 验证 mpv 是否能识别 rkmpp ===
        echo ""
        echo "=== 验证 mpv 硬件加速 ==="
        export LD_LIBRARY_PATH=/usr/local/lib/ffmpeg-rkmpp:/usr/local/lib:${LD_LIBRARY_PATH}
        mpv.distrib --no-config --msg-level=vd=debug --vo=gpu --hwdec=rkmpp /dev/null 2>&1 | head -5 || true
        echo "（若显示 'rkmpp' 则硬件加速可用）"

        # 清理
        cd /
        rm -rf "$BUILD_DIR"
RKMPP_EOF

    ok "ffmpeg-rockchip 安装完成（与系统 ffmpeg 共存）"
}

#------------------------------------------------------------------------------
# 配置 extlinux 引导 (使用占位符，由 pack-image.sh 替换 dtb)
#------------------------------------------------------------------------------
configure_boot() {
    step "配置 extlinux 引导..."

    # 使用占位符，由 04-pack-image.sh 根据实际安装的内核替换
    # __KV__ = 内核版本号 (如 6.1.115-rockchip)
    # __BOARD_DTB__ = 板卡设备树文件名 (如 rk3588-rock-5-itx.dtb)
    mkdir -p "${WORKSPACE}/boot/extlinux"
    cat > "${WORKSPACE}/boot/extlinux/extlinux.conf" << EOF
menu title Deepin 25 Rockchip Boot Menu
prompt 1
timeout 30
default deepin

label deepin
    menu label Deepin 25 (Rockchip)
    linux /boot/vmlinuz-__KV__
    initrd /boot/initrd.img-__KV__
    fdt /usr/lib/linux-image-__KV__/rockchip/__BOARD_DTB__
    append root=UUID=${ROOT_UUID} rootfstype=ext4 rootwait rw rootdelay=5 console=ttyS2,1500000 console=tty1

label recovery
    menu label Deepin 25 (Recovery)
    linux /boot/vmlinuz-__KV__
    initrd /boot/initrd.img-__KV__
    fdt /usr/lib/linux-image-__KV__/rockchip/__BOARD_DTB__
    append root=UUID=${ROOT_UUID} rootfstype=ext4 rootwait rw rootdelay=5 console=ttyS2,1500000 console=tty1 single
EOF

    ok "extlinux 配置完成 (dtb 占位符 __BOARD_DTB__)"
}

#------------------------------------------------------------------------------
# 安装本地 deb 包（参考 xiaobao1980）
# 注意: deb 路径必须在 chroot 内有效（使用相对路径或 chroot 内绝对路径）
#------------------------------------------------------------------------------
install_local_debs() {
    local dir="$1" name="${2:-$1}"

    if [ ! -d "$dir" ]; then
        warn "目录不存在: $dir"
        return 0
    fi

    local debs=()
    for f in "$dir"/*.deb; do
        [ -f "$f" ] && debs+=("$f")
    done

    if [ ${#debs[@]} -eq 0 ]; then
        warn "没有 .deb 文件: $dir"
        return 0
    fi

    info "安装 ${#debs[@]} 个包 (${name})..."

    # 过滤冲突包，同时转换为主机上的独立路径列表（用于复制判断）
    local install_debs_host=()
    for deb in "${debs[@]}"; do
        case "$deb" in
            *armbian-firmware*)
                warn "跳过 $deb (与 linux-firmware 冲突)"
                ;;
            *) install_debs_host+=("$deb") ;;
        esac
    done

    if [ ${#install_debs_host[@]} -gt 0 ]; then
        # 在 chroot 内使用通配符路径安装（避免主机路径在 chroot 内无效的问题）
        # deb 包必须在 chroot 内可访问的位置（如 /tmp/debs/）
        local chroot_deb_dir
        chroot_deb_dir=$(realpath --relative-to="$WORKSPACE" "$dir" 2>/dev/null || echo "$dir")
        chroot "$WORKSPACE" /bin/bash << DEB_EOF
            set -e
            export DEBIAN_FRONTEND=noninteractive
            # 使用 chroot 内的路径安装
            for d in /${chroot_deb_dir}/*.deb; do
                [ -f "\$d" ] || continue
                case "\$d" in
                    *armbian-firmware*) continue ;;
                esac
                echo "  -> 安装 \$(basename \$d)"
                dpkg -i "\$d" || true
            done
            apt-get install -fy --allow-downgrades --no-install-recommends || true
DEB_EOF
    fi
}

#------------------------------------------------------------------------------
# 安装内核 (在 rootfs 恢复后调用，不备份到通用 rootfs 中)
#------------------------------------------------------------------------------
install_kernel() {
    # 检查是否已安装过内核（通过标记文件）
    if [ -f "${WORKSPACE}/${KERNEL_INSTALLED_FLAG}" ]; then
        info "内核已在此 rootfs 中安装过，跳过重复安装"
        return 0
    fi

    step "安装内核..."

    local deb_dir="${KERNEL_DEB_DIR}"
    local image_deb
    image_deb=$(find "$deb_dir" -name "linux-image-*.deb" ! -name "*dbg*" | head -1)

    if [ -z "$image_deb" ]; then
        warn "未找到内核 deb 包"
        return 0
    fi

    info "使用内核包: $(basename "$image_deb")"
    mkdir -p "${WORKSPACE}/tmp/debs"
    cp "$image_deb" "${WORKSPACE}/tmp/debs/"

    local headers_deb
    headers_deb=$(find "$deb_dir" -name "linux-headers-*.deb" | head -1)
    [ -n "$headers_deb" ] && cp "$headers_deb" "${WORKSPACE}/tmp/debs/"

    # 使用统一的本地 deb 安装函数
    install_local_debs "${WORKSPACE}/tmp/debs" "kernel"
    rm -rf "${WORKSPACE}/tmp/debs"

    # 确保 busybox 在 initramfs 中可用
    chroot "$WORKSPACE" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall busybox" 2>/dev/null || true

    # 确保 initramfs-tools 使用 busybox（klibc 缺少 tail 等关键命令）
    if [ -f "${WORKSPACE}/etc/initramfs-tools/initramfs.conf" ]; then
        if ! grep -q "^BUSYBOX=y" "${WORKSPACE}/etc/initramfs-tools/initramfs.conf" 2>/dev/null; then
            info "设置 initramfs 强制使用 busybox..."
            sed -i 's/^BUSYBOX=.*/BUSYBOX=y/' "${WORKSPACE}/etc/initramfs-tools/initramfs.conf" 2>/dev/null || \
                echo "BUSYBOX=y" >> "${WORKSPACE}/etc/initramfs-tools/initramfs.conf"
        fi
    fi

    # 验证并确保 initramfs 生成
    local kernel_ver installed_initrd
    kernel_ver=$(ls "${WORKSPACE}/boot/vmlinuz-"* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
    if [ -n "$kernel_ver" ]; then
        installed_initrd="${WORKSPACE}/boot/initrd.img-${kernel_ver}"
        if [ ! -f "$installed_initrd" ] || [ ! -s "$installed_initrd" ]; then
            warn "initramfs 未生成，手动生成..."
            chroot "$WORKSPACE" /bin/bash -c "update-initramfs -c -k '${kernel_ver}'" 2>/dev/null || \
                chroot "$WORKSPACE" /bin/bash -c "mkinitramfs -o '/boot/initrd.img-${kernel_ver}' '${kernel_ver}'" 2>/dev/null || true
        fi

        # 验证 initramfs 完整性
        if [ -f "$installed_initrd" ] && [ -s "$installed_initrd" ]; then
            info "验证 initramfs 完整性..."
            local initramfs_cmds
            initramfs_cmds=$(zcat "$installed_initrd" 2>/dev/null | cpio -t --quiet 2>/dev/null || true)
            local missing_cmds=""
            for cmd in tail sh mount umount blkid sleep echo cat; do
                if ! echo "$initramfs_cmds" | grep -q "bin/${cmd}$" 2>/dev/null; then
                    if ! echo "$initramfs_cmds" | grep -q "${cmd}" 2>/dev/null; then
                        missing_cmds="${missing_cmds} ${cmd}"
                    fi
                fi
            done
            if [ -n "$missing_cmds" ]; then
                warn "initramfs 缺少命令:${missing_cmds}"
                chroot "$WORKSPACE" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall busybox initramfs-tools" 2>/dev/null || true
                chroot "$WORKSPACE" /bin/bash -c "update-initramfs -u -k '${kernel_ver}'" 2>/dev/null || true
            else
                ok "initramfs 已就绪且完整"
            fi
        else
            warn "initramfs 生成失败"
        fi
    fi

    # 创建标记文件，防止重复安装
    touch "${WORKSPACE}/${KERNEL_INSTALLED_FLAG}"

    ok "内核安装完成"
}

#------------------------------------------------------------------------------
# 配置用户（参考 xiaobao1980：更安全的 sudo 配置）
#------------------------------------------------------------------------------
configure_users() {
    step "配置用户..."

    # root 密码（不过期，参考 xiaobao1980）
    chroot_exec "echo 'root:${DEFAULT_USER_PASS}' | chpasswd"

    # 普通用户（检查是否已存在，参考 xiaobao1980）
    chroot "$WORKSPACE" /bin/bash << USER_EOF
        set -e
        export DEBIAN_FRONTEND=noninteractive

        if ! id "${DEFAULT_USER}" >/dev/null 2>&1; then
            echo "[INFO] 创建用户: ${DEFAULT_USER}"
            # 确保 sudo 组存在
            getent group sudo >/dev/null || groupadd sudo
            useradd -m -G sudo,audio,video,plugdev,users,netdev,bluetooth,input -s /bin/bash "${DEFAULT_USER}"
            echo "${DEFAULT_USER}:${DEFAULT_USER_PASS}" | chpasswd
        else
            echo "[WARN] 用户 ${DEFAULT_USER} 已存在，跳过创建"
        fi

        # sudo 配置（安全方式：使用 /etc/sudoers.d/）
        if [ -d /etc/sudoers.d ]; then
            echo "${DEFAULT_USER} ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/99-${DEFAULT_USER}"
            chmod 440 "/etc/sudoers.d/99-${DEFAULT_USER}"
        else
            # 回退到 /etc/sudoers
            [ -n "\$(tail -c1 /etc/sudoers)" ] && echo "" >> /etc/sudoers
            echo "${DEFAULT_USER} ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
        fi

        # 确保 deepin 用户有 mpv 硬件加速配置 (X11 rkmpp)
        mkdir -p /home/${DEFAULT_USER}/.config/mpv
        cp /etc/mpv/mpv.conf /home/${DEFAULT_USER}/.config/mpv/mpv.conf
        chown -R ${DEFAULT_USER}:${DEFAULT_USER} /home/${DEFAULT_USER}/.config
USER_EOF

    ok "用户配置完成（用户: ${DEFAULT_USER}, 密码: ${DEFAULT_USER_PASS}）"
}

#------------------------------------------------------------------------------
# 首次启动自动扩容（SD卡/eMMC/NVMe）
#------------------------------------------------------------------------------
install_firstboot() {
    step "配置首次启动自动扩容..."

    # 安装扩容工具
    chroot "$WORKSPACE" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y cloud-guest-utils gdisk parted 2>/dev/null || true"

    # 创建扩容脚本：growpart 扩展分区 + resize2fs 扩展文件系统
    cat > "${WORKSPACE}/usr/local/sbin/deepin-rockchip-firstboot" << 'FIRSTBOOT_EOF'
#!/bin/bash
# 首次启动自动扩容 root 分区（SD卡/eMMC/NVMe/SATA/USB）

MARKER="/var/lib/deepin-rockchip-firstboot-done"
LOG="/var/log/first-boot-expand.log"

# 只执行一次
[ -f "$MARKER" ] && exit 0

echo "[first-boot] 开始首次启动配置..." >> "$LOG"

# --- 步骤1: 扩容分区 + 文件系统 ---
ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || mount | grep " on / " | awk '{print $1}')
echo "[first-boot] root 设备: $ROOT_DEV" >> "$LOG"

PARTNUM=""
DISK_DEV=""

# 解析设备名：mmcblk/nvme/loop 用 %p*，sd/hd/vd 用 %%[0-9]*
if [[ "$ROOT_DEV" =~ ^/dev/(mmcblk|nvme|loop) ]]; then
    PARTNUM="${ROOT_DEV##*p}"
    DISK_DEV="${ROOT_DEV%p*}"
elif [[ "$ROOT_DEV" =~ ^/dev/(sd|hd|vd|xvd)[a-z]+([0-9]+)$ ]]; then
    PARTNUM="${BASH_REMATCH[2]}"
    DISK_DEV="${ROOT_DEV%%[0-9]*}"
else
    echo "[first-boot] 未知设备格式: $ROOT_DEV, 跳过分区扩容" >> "$LOG"
    DISK_DEV=""
fi

# 先扩容分区（growpart），再扩容文件系统（resize2fs）
if [ -n "$DISK_DEV" ] && [ -n "$PARTNUM" ]; then
    echo "[first-boot] 磁盘: $DISK_DEV, 分区号: $PARTNUM" >> "$LOG"

    # 检查是否有足够空间需要扩容
    DISK_SIZE=$(blockdev --getsize64 "$DISK_DEV" 2>/dev/null || echo 0)
    PART_SIZE=$(blockdev --getsize64 "$ROOT_DEV" 2>/dev/null || echo 0)
    SIZE_DIFF=$((DISK_SIZE - PART_SIZE))
    echo "[first-boot] 磁盘: ${DISK_SIZE}B, 分区: ${PART_SIZE}B, 差值: ${SIZE_DIFF}B" >> "$LOG"

    if [ "$SIZE_DIFF" -gt 10485760 ]; then
        echo "[first-boot] 正在扩容分区..." >> "$LOG"
        if growpart "$DISK_DEV" "$PARTNUM" >> "$LOG" 2>&1; then
            echo "[first-boot] 分区扩容成功" >> "$LOG"
            partprobe "$DISK_DEV" >> "$LOG" 2>&1 || true
            sleep 1
        else
            echo "[first-boot] growpart 失败或无需扩容" >> "$LOG"
        fi
    else
        echo "[first-boot] 分区已接近最大大小，跳过 growpart" >> "$LOG"
    fi
fi

# 扩容文件系统（无论分区是否扩容，都执行 resize2fs）
echo "[first-boot] 正在扩容文件系统..." >> "$LOG"
if resize2fs "$ROOT_DEV" >> "$LOG" 2>&1; then
    NEW_SIZE=$(df -h / | tail -1 | awk '{print $2}')
    echo "[first-boot] 文件系统扩容成功, root 大小: $NEW_SIZE" >> "$LOG"
else
    echo "[first-boot] resize2fs 失败" >> "$LOG"
fi

# --- 步骤2: SSH 主机密钥重新生成（带 apt 锁检测）---
echo "[first-boot] 重新生成 SSH 密钥..." >> "$LOG"
# 检测 apt 是否被其他进程持有（如 firstboot 后的自动更新）
for i in 1 2 3 4 5; do
    if ! lsof /var/lib/apt/lists/lock >/dev/null 2>&1 && \
       ! lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        break
    fi
    echo "[first-boot] 等待 apt 锁释放 (尝试 $i/5)..." >> "$LOG"
    sleep 2
done
rm -f /etc/ssh/ssh_host_*
dpkg-reconfigure -f noninteractive openssh-server 2>/dev/null || true

# --- 步骤3: 将普通用户加入 video/render 组（GPU/VPU 访问权限） ---
echo "[first-boot] 配置 GPU/VPU 用户权限..." >> "$LOG"
# 创建组（如果不存在）
getent group video >/dev/null || groupadd -r video
getent group render >/dev/null || groupadd -r render
# 将所有普通用户(UID>=1000)加入 video/render 组
while IFS=: read -r username _ uid _ _ _ _; do
    if [ "$uid" -ge 1000 ] && [ "$username" != "nobody" ]; then
        usermod -aG video,render "$username" 2>/dev/null && \
            echo "[first-boot] 用户 $username 已加入 video/render 组" >> "$LOG"
    fi
done < /etc/passwd

# --- 步骤4: 更新动态链接器缓存 ---
ldconfig

# 标记已完成
touch "$MARKER"
echo "[first-boot] 首次启动配置完成" >> "$LOG"
FIRSTBOOT_EOF
    chmod +x "${WORKSPACE}/usr/local/sbin/deepin-rockchip-firstboot"

    # 创建 systemd 服务
    cat > "${WORKSPACE}/etc/systemd/system/deepin-rockchip-firstboot.service" << 'EOF'
[Unit]
Description=Deepin Rockchip First Boot Root Expansion
After=systemd-remount-fs.service local-fs.target
Before=getty.target systemd-user-sessions.service
ConditionPathExists=!/var/lib/deepin-rockchip-firstboot-done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/deepin-rockchip-firstboot
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chroot_exec "systemctl enable deepin-rockchip-firstboot.service"
    ok "首次启动自动扩容已配置"
}

#------------------------------------------------------------------------------
# 清理（参考 xiaobao1980：更彻底的清理）
#------------------------------------------------------------------------------
cleanup() {
    step "清理..."

    # 强制清理 apt 锁文件（防止打包后残留锁导致首次启动冲突）
    info "清理 apt 锁文件..."
    rm -f "${WORKSPACE}/var/lib/apt/lists/lock"
    rm -f "${WORKSPACE}/var/cache/apt/archives/lock"
    rm -f "${WORKSPACE}/var/lib/dpkg/lock"
    rm -f "${WORKSPACE}/var/lib/dpkg/lock-frontend"
    rm -f "${WORKSPACE}/var/lib/dpkg/triggers/Lock"
    rm -rf "${WORKSPACE}/var/lib/apt/lists/partial"/*
    rm -rf "${WORKSPACE}/var/cache/apt/archives/partial"/*

    # 清理 apt 缓存和包
    chroot_exec "apt-get clean"
    chroot_exec "apt-get autoremove -y 2>/dev/null || true"
    rm -rf "${WORKSPACE}/var/cache/apt/archives"/*
    rm -rf "${WORKSPACE}/var/lib/apt/lists"/*
    rm -rf "${WORKSPACE}/tmp"/*
    rm -rf "${WORKSPACE}/var/tmp"/*
    rm -rf "${WORKSPACE}/root/.cache" "${WORKSPACE}/home"/*/.cache 2>/dev/null || true

    # 清空所有日志文件（参考 xiaobao1980）
    find "${WORKSPACE}/var/log" -type f -exec sh -c '> {}' \; 2>/dev/null || true

    # 清除 bash history（参考 xiaobao1980）
    rm -f "${WORKSPACE}/root/.bash_history" "${WORKSPACE}/home"/*/.bash_history 2>/dev/null || true
    cat > "${WORKSPACE}/etc/profile.d/disable-history.sh" << 'EOF'
# Disable bash history for privacy
export HISTSIZE=0
export HISTFILESIZE=0
export HISTCONTROL=ignoreboth
EOF

    # 清除内核安装标记（确保备份的通用 rootfs 不含此标记）
    rm -f "${WORKSPACE}/${KERNEL_INSTALLED_FLAG}"

    chroot_exec "ldconfig"
    ok "清理完成"
}

#------------------------------------------------------------------------------
# 备份 rootfs
#------------------------------------------------------------------------------
backup_rootfs() {
    step "备份通用 rootfs..."
    tar cf "$BACKUP_FILE" -C "$WORKSPACE" .
    ok "rootfs 已备份: ${BACKUP_FILE} ($(du -sh "$BACKUP_FILE" | cut -f1))"
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    MINIMAL="no"
    CLEAN_BUILD="no"
    RESTORE_ONLY="no"
    INSTALL_KERNEL="no"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -m|--minimal) MINIMAL="yes"; shift ;;
            -n|--hostname) TARGET_HOSTNAME="$2"; shift 2 ;;
            -u|--user) DEFAULT_USER="$2"; shift 2 ;;
            -p|--password) DEFAULT_USER_PASS="$2"; shift 2 ;;
            -c|--clean) CLEAN_BUILD="yes"; shift ;;
            -r|--restore-only) RESTORE_ONLY="yes"; shift ;;
            -k|--install-kernel) INSTALL_KERNEL="yes"; shift ;;
            *) shift ;;
        esac
    done

    [ "$EUID" -ne 0 ] && { error "请使用 root 用户运行"; exit 1; }

    echo "========================================"
    echo "  Deepin 25 根文件系统构建"
    echo "========================================"

    prepare

    # restore-only 但备份不存在
    if [ "$RESTORE_ONLY" = "yes" ] && [ ! -f "$BACKUP_FILE" ]; then
        error "--restore-only 指定但备份不存在: ${BACKUP_FILE}"
        exit 1
    fi

    # 从备份恢复了（WORKSPACE 已有内容）
    if [ -f "${WORKSPACE}/etc/fstab" ] && [ "$CLEAN_BUILD" != "yes" ]; then
        info "从备份恢复，跳过构建流程"

        # 关键修复：从备份恢复时，initramfs 配置（hook 脚本、modules）可能已过时
        # 必须重新应用最新的 initramfs 配置，否则会导致 rootfs 挂载失败
        mount_vfs
        update_initramfs_config

        # 关键修复：从备份恢复时，首次启动扩容配置也可能已过时
        # 重新应用以确保扩容脚本和 systemd 服务是最新版本
        install_firstboot

        # 如果需要，安装内核到恢复的 rootfs
        if [ "$INSTALL_KERNEL" = "yes" ]; then
            install_kernel
            # 安装内核后重新生成 extlinux（此时内核版本号已知）
            configure_boot
        fi
        umount_vfs
    else
        # 正常完整构建（通用 rootfs，不含内核）
        build_base
        mount_vfs

        configure_system
        install_desktop
        configure_users
        configure_boot
        install_rkmpp
        install_firstboot
        cleanup

        umount_vfs

        # 备份通用 rootfs（不含内核）
        backup_rootfs
    fi

    echo ""
    echo "========================================"
    ok "根文件系统构建完成"
    echo "========================================"
    echo "  目录: ${WORKSPACE}"
    echo "  UUID: ${ROOT_UUID}"
    echo "  备份: ${BACKUP_FILE}"
    echo ""
    info "通用 rootfs 备份已完成（不含内核）"
    info "内核将在打包时根据板卡安装"
    info "使用 -c 强制重新构建"
    info "下一步: 运行 ./04-pack-image.sh 打包镜像"

    return 0
}

trap umount_vfs EXIT INT TERM
main "$@"
exit 0
