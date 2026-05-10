#!/bin/bash
# Setup System Configuration in Chroot
# Configures: hostname, users, fstab, bootloader, desktop, network
#
# NOTE: No "set -e" - we use explicit error checks to ensure all output is logged

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

_log_write() {
    if [ -n "${LOG_MAIN:-}" ] && [ -f "$LOG_MAIN" ]; then
        echo "[$(date '+%H:%M:%S')] [System] [$1] $2" >> "$LOG_MAIN" 2>/dev/null || true
    fi
}

log_info() { echo -e "${BLUE}[INFO]${NC} [system] $1"; _log_write "INFO" "$1"; }
log_success() { echo -e "${GREEN}[OK]${NC} [system] $1"; _log_write "OK" "$1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} [system] $1"; _log_write "WARN" "$1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [system] $1"; _log_write "ERROR" "$1"; }
log_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [System] $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    _log_write "STEP" "$1"
}

# Check environment
if [ -z "$ROOTFS_MOUNT" ] || [ -z "$SOC_CHIP" ]; then
    echo -e "${RED}[ERROR]${NC} Required environment variables not set. Run from build.sh."
    exit 1
fi

log_step "Configuring System"

# ===== Mount Virtual Filesystems =====
log_info "Mounting virtual filesystems..."
mount --bind /dev "${ROOTFS_MOUNT}/dev" || true
mount -t proc chproc "${ROOTFS_MOUNT}/proc" || true
mount -t sysfs chsys "${ROOTFS_MOUNT}/sys" || true
mount -t tmpfs -o "size=99%" tmpfs "${ROOTFS_MOUNT}/tmp" || true
mount -t tmpfs -o "size=99%" tmpfs "${ROOTFS_MOUNT}/var/tmp" || true

# ===== Chroot Setup Script =====
log_info "Preparing chroot configuration..."

# Determine kernel version
if [ -z "$KERNEL_VERSION" ]; then
    # Try to detect from copied debs
    KERNEL_DEB=$(ls "${ROOTFS_MOUNT}/boot/"linux-image-*.deb 2>/dev/null | head -1)
    if [ -n "$KERNEL_DEB" ]; then
        KERNEL_VERSION=$(basename "$KERNEL_DEB" | sed 's/linux-image-//' | sed 's/_.*//' | sed 's/-rockchip//')
    else
        KERNEL_VERSION="6.1.115"  # Fallback
    fi
fi

# Check if kernel debs exist in /boot
if ls "${ROOTFS_MOUNT}/boot/"linux-*.deb 1>/dev/null 2>&1; then
    INSTALL_KERNEL_DEBS=true
    KERNEL_DEBS_LIST=$(ls "${ROOTFS_MOUNT}/boot/"linux-*.deb 2>/dev/null | tr '\n' ' ')
else
    INSTALL_KERNEL_DEBS=false
fi

# Generate chroot script
CHROOT_SCRIPT="${ROOTFS_MOUNT}/tmp/setup-chroot.sh"
cat > "$CHROOT_SCRIPT" << 'CHROOT_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "=== Deepin 25 Rockchip System Configuration ==="

# ===== Install Kernel =====
echo "[1/8] Installing kernel..."
if [ "$INSTALL_KERNEL" = "true" ]; then
    cd /boot
    dpkg -i linux-*.deb || true
    rm -f /boot/linux-*.deb
    
    # Update initramfs
    update-initramfs -c -k "${KERNEL_VER}" 2>/dev/null || update-initramfs -u -k all || true
else
    echo "  Skipping kernel installation (no packages found)"
fi

# ===== Verify and Update APT Sources =====
echo "[2/8] Verifying APT sources..."
echo "Current sources.list:"
grep "^deb " /etc/apt/sources.list | head -5

# Update package lists
apt update -y

# ===== Install Desktop Environment =====
echo "[3/8] Configuring desktop environment: ${DESKTOP}"
case "${DESKTOP}" in
    dde)
        # Minimal DDE - core + base + display manager + Xorg only
        # Note: extras/firefox removed to save space (install manually if needed)
        apt install -y deepin-desktop-environment-core deepin-desktop-environment-base \
            ddm xserver-xorg
        
        # Disable lightdm, enable ddm (deepin display manager)
        systemctl disable lightdm 2>/dev/null || true
        systemctl enable ddm 2>/dev/null || true
        ;;
    minimal)
        echo "  Minimal system - no desktop"
        ;;
    server)
        echo "  Server system"
        apt install -y openssh-server ufw fail2ban
        systemctl enable ssh
        systemctl enable ufw
        ;;
esac

# ===== Hardware Acceleration Setup =====
echo "[4/8] Configuring hardware acceleration..."
if [ -x /tmp/setup-hardware-acc.sh ]; then
    export SOC_CHIP="${SOC_CHIP}"
    export BOARD="${BOARD}"
    bash /tmp/setup-hardware-acc.sh || echo "  Hardware acceleration setup had warnings"
else
    echo "  Hardware acceleration script not found, skipping"
fi

# ===== Basic System Configuration =====
echo "[5/8] Basic system configuration..."

# Hostname
echo "${HOSTNAME_STR}" > /etc/hostname

# Locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

# Timezone
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || true
dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true

# ===== Users =====
echo "[6/9] Setting up users..."

# Set root password (default: deepin)
echo "root:${ROOT_PASSWD}" | chpasswd

# Create render group for GPU access
getent group render >/dev/null || groupadd -r render 2>/dev/null || true

# Create regular user
if [ -n "$REGULAR_USER" ]; then
    if ! id "$REGULAR_USER" &>/dev/null; then
        useradd -m -G users,sudo,audio,video,netdev,render -s /bin/bash "${REGULAR_USER}"
        echo "${REGULAR_USER}:${USER_PASSWD}" | chpasswd
        echo "  User created: ${REGULAR_USER}"
    fi
fi

# ===== Network =====
echo "[7/9] Configuring network..."
systemctl enable NetworkManager
systemctl enable systemd-networkd 2>/dev/null || true

# ===== fstab =====
echo "[8/9] Configuring fstab..."
cat > /etc/fstab << EOF
# <file system>    <mount point>  <type>  <options>                   <dump>  <fsck>
UUID=${ROOT_UUID}  /              ext4    defaults,x-systemd.growfs    0       1
EOF

# ===== Bootloader (extlinux) =====
echo "[9/9] Configuring bootloader..."

# Find kernel image and initrd
KERNEL_IMG=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
INITRD_IMG=$(ls /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
KERNEL_VER_DETECT=$(basename "$KERNEL_IMG" | sed 's/vmlinuz-//')

echo "  Kernel: ${KERNEL_IMG}"
echo "  Initrd: ${INITRD_IMG}"
echo "  Version: ${KERNEL_VER_DETECT}"

# Find DTB path
if [ -d "/usr/lib/linux-image-${KERNEL_VER_DETECT}/${DTB_DIR}" ]; then
    DTB_PATH="/usr/lib/linux-image-${KERNEL_VER_DETECT}/${DTB_DIR}/${KERNEL_DTB}"
elif [ -d "/boot/dtbs/${DTB_DIR}" ]; then
    DTB_PATH="/boot/dtbs/${KERNEL_DTB}"
else
    # Find DTB in kernel package
    DTB_PATH=$(find /usr/lib/linux-image-* -name "${KERNEL_DTB}" 2>/dev/null | head -1)
fi

mkdir -p /boot/extlinux

# Build extlinux.conf
cat > /boot/extlinux/extlinux.conf << EOF
default Deepin 25
menu title ${BOARD_NAME} Boot Menu
prompt 1
timeout 5

label Deepin 25
  menu label Deepin 25 (${BOARD_NAME})
  linux ${KERNEL_IMG}
  initrd ${INITRD_IMG}
  fdt ${DTB_PATH}
  append root=UUID=${ROOT_UUID} rootfs=ext4 rootwait rw console=${SERIAL_CON},${SERIAL_BAUD} console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory loglevel=3
EOF

# Add overlays if enabled
if [ "${ENABLE_GPU_OVERLAY}" = "yes" ] && [ -n "${DT_OVERLAYS}" ]; then
    OVERLAY_PATHS=""
    for overlay in ${DT_OVERLAYS}; do
        if [ -f "/usr/lib/linux-image-${KERNEL_VER_DETECT}/${DTB_DIR}/overlay/${overlay}" ]; then
            OVERLAY_PATHS="${OVERLAY_PATHS} /usr/lib/linux-image-${KERNEL_VER_DETECT}/${DTB_DIR}/overlay/${overlay}"
        elif [ -f "/boot/overlays/${overlay}" ]; then
            OVERLAY_PATHS="${OVERLAY_PATHS} /boot/overlays/${overlay}"
        fi
    done
    
    if [ -n "$OVERLAY_PATHS" ]; then
        echo "  fdtoverlays${OVERLAY_PATHS}" >> /boot/extlinux/extlinux.conf
    fi
fi

echo "  extlinux.conf created"

# ===== GPU/VPU/NPU Module Loading =====
echo "  Enabling Rockchip hardware modules..."

# GPU module
if [ "${ENABLE_GPU_OVERLAY}" = "yes" ]; then
    echo "  - GPU Panthor enabled"
    echo "panthor" >> /etc/modules-load.d/rockchip-hardware.conf
fi

# VPU modules  
echo "  - VPU modules enabled"
cat >> /etc/modules-load.d/rockchip-hardware.conf << 'HWMODS'
# VPU
hantro-vpu
rockchip_vdec
rockchip_venc
# NPU
rknpu
HWMODS

# ===== Enable Services =====
systemctl enable ssh
systemctl enable cron
systemctl enable dbus

# ===== Final Cleanup =====
echo "Cleaning up..."
apt clean
rm -rf /var/cache/apt/archives/*
rm -f /tmp/setup-chroot.sh /tmp/setup-hardware-acc.sh 2>/dev/null || true

echo "=== Configuration Complete ==="
CHROOT_EOF

chmod +x "$CHROOT_SCRIPT"

# Export variables to chroot environment via temporary env file
ENV_FILE="${ROOTFS_MOUNT}/tmp/setup-env.sh"
# Copy hardware acceleration script into chroot
cp "${SCRIPT_DIR}/scripts/setup-hardware-acc.sh" "${ROOTFS_MOUNT}/tmp/setup-hardware-acc.sh"
chmod +x "${ROOTFS_MOUNT}/tmp/setup-hardware-acc.sh"

HOSTNAME_STR_VAL=$(echo "${BOARD}" | tr '[:lower:]' '[:upper:]')-$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)

cat > "$ENV_FILE" << EOF
INSTALL_KERNEL=${INSTALL_KERNEL_DEBS}
KERNEL_VER=${KERNEL_VERSION}
DESKTOP=${DESKTOP}
HOSTNAME_STR='${HOSTNAME_STR_VAL}'
BOARD_NAME='${BOARD_NAME}'
BOARD='${BOARD}'
SOC_CHIP='${SOC_CHIP}'
ROOT_PASSWD='deepin'
REGULAR_USER='deepin'
USER_PASSWD='deepin'
ROOT_UUID='${BOOT_PART_UUID}'
KERNEL_DTB='${KERNEL_DTB}'
DTB_DIR='${KERNEL_DTB_DIR}'
SERIAL_CON='${SERIAL_CONSOLE}'
SERIAL_BAUD='${SERIAL_BAUD}'
DT_OVERLAYS='${DT_OVERLAYS}'
ENABLE_GPU_OVERLAY='${ENABLE_GPU_OVERLAY}'
EOF

# Run chroot configuration
log_info "Entering chroot environment..."
chroot "$ROOTFS_MOUNT" /bin/bash -c "source /tmp/setup-env.sh && /tmp/setup-chroot.sh"

log_success "System configuration complete!"

# ===== Write Bootloader to Image/Device =====
log_step "Installing Bootloader"

# Load U-Boot variables from stamp file (variables from build-uboot.sh sub-shell)
UBOOT_VARS_FILE="${WORKSPACE}/.stamps/uboot-vars"
if [ -f "$UBOOT_VARS_FILE" ]; then
    log_info "Loading U-Boot variables from ${UBOOT_VARS_FILE}"
    source "$UBOOT_VARS_FILE"
else
    log_info "No uboot-vars stamp file found, checking workspace..."
fi

# Also check workspace directly as fallback
if [ -z "${UBOOT_ROCKCHIP_BIN:-}" ] && [ -f "${WORKSPACE}/u-boot/u-boot-rockchip.bin" ]; then
    UBOOT_ROCKCHIP_BIN="${WORKSPACE}/u-boot/u-boot-rockchip.bin"
fi
if [ -z "${IDBLOADER_IMG:-}" ] && [ -f "${WORKSPACE}/u-boot/idbloader.img" ]; then
    IDBLOADER_IMG="${WORKSPACE}/u-boot/idbloader.img"
fi
if [ -z "${UBOOT_ITB:-}" ] && [ -f "${WORKSPACE}/u-boot/u-boot.itb" ]; then
    UBOOT_ITB="${WORKSPACE}/u-boot/u-boot.itb"
fi

# Write U-Boot to the boot sector (before partition 1 at 32K offset)
if [ -n "${UBOOT_ROCKCHIP_BIN:-}" ] && [ -f "$UBOOT_ROCKCHIP_BIN" ]; then
    log_info "Writing u-boot-rockchip.bin to ${ROOT_DEVICE}..."
    dd if="$UBOOT_ROCKCHIP_BIN" of="$ROOT_DEVICE" seek=1 bs=32k conv=fsync status=progress
    log_success "U-Boot written"
elif [ -n "${IDBLOADER_IMG:-}" ] && [ -n "${UBOOT_ITB:-}" ] && [ -f "$IDBLOADER_IMG" ] && [ -f "$UBOOT_ITB" ]; then
    log_info "Writing idbloader.img + u-boot.itb..."
    dd if="$IDBLOADER_IMG" of="$ROOT_DEVICE" seek=64 bs=512 conv=fsync status=progress
    dd if="$UBOOT_ITB" of="$ROOT_DEVICE" seek=16384 bs=512 conv=fsync status=progress
    log_success "U-Boot components written"
else
    log_warn "No U-Boot binaries available for writing"
    log_info "Expected paths:"
    ls -la "${WORKSPACE}/u-boot/"*rockchip*"${WORKSPACE}/u-boot/idbloader.img""${WORKSPACE}/u-boot/u-boot.itb" 2>/dev/null || true
fi

# Sync
sync

# ===== Unmount Virtual Filesystems =====
log_info "Unmounting virtual filesystems..."
umount "${ROOTFS_MOUNT}/tmp" 2>/dev/null || true
umount "${ROOTFS_MOUNT}/var/tmp" 2>/dev/null || true
umount "${ROOTFS_MOUNT}/proc" 2>/dev/null || true
umount "${ROOTFS_MOUNT}/sys" 2>/dev/null || true
umount "${ROOTFS_MOUNT}/dev" 2>/dev/null || true

log_success "Bootloader installation complete!"
