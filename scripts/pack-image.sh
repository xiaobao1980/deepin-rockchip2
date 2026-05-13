#!/bin/bash
# Pack final image and generate flash helper scripts

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} [image] $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} [image] $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} [image] $1"; }
log_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [Image] $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

if [ -z "$ROOTFS_MOUNT" ] || [ -z "$BOARD" ]; then
    echo -e "${RED}[ERROR]${NC} Required environment variables not set."
    exit 1
fi

log_step "Finalizing Image"

# Unmount rootfs
if mountpoint -q "$ROOTFS_MOUNT" 2>/dev/null; then
    log_info "Unmounting rootfs..."
    umount -R "$ROOTFS_MOUNT" 2>/dev/null || umount "$ROOTFS_MOUNT" 2>/dev/null || true
    sync
fi

# Detach loop device if using image file
if [ -n "$LOOP_DEV" ] && losetup "$LOOP_DEV" &>/dev/null; then
    log_info "Detaching loop device ${LOOP_DEV}..."
    losetup -d "$LOOP_DEV" 2>/dev/null || true
fi

# Image file finalization
if [ -n "$IMAGE_FILE" ] && [ -f "$IMAGE_FILE" ]; then
    log_step "Compressing Image"
    
    # Check image file size before compression
    IMG_SIZE=$(du -h "$IMAGE_FILE" 2>/dev/null | cut -f1)
    IMG_BYTES=$(stat -c%s "$IMAGE_FILE" 2>/dev/null || echo 0)
    log_info "Image file: ${IMG_SIZE} (${IMG_BYTES} bytes)"
    
    # Safety check: image should be > 100MB if rootfs was populated
    if [ "$IMG_BYTES" -lt 104857600 ]; then
        log_warn "Image file is suspiciously small (${IMG_SIZE})"
        log_warn "Expected at least 100MB for a populated rootfs"
        log_warn "The image may not boot correctly!"
    fi
    
    COMPRESSED="${IMAGE_FILE}.xz"
    
    # Remove existing compressed file if present
    if [ -f "$COMPRESSED" ]; then
        log_warn "Removing existing compressed file: ${COMPRESSED}"
        rm -f "$COMPRESSED"
    fi
    
    log_info "Compressing with xz (this may take a while)..."
    xz -T0 -v "$IMAGE_FILE"
    
    # Generate checksums
    log_info "Generating checksums..."
    cd "$(dirname "$COMPRESSED")"
    sha256sum "$(basename "$COMPRESSED")" > "$(basename "$COMPRESSED").sha256"
    md5sum "$(basename "$COMPRESSED")" > "$(basename "$COMPRESSED").md5"
    cd - > /dev/null
    
    log_success "Compressed image: ${COMPRESSED}"
    ls -lh "$COMPRESSED" "${COMPRESSED}.sha256" "${COMPRESSED}.md5"
    
    # Generate flash script
    FLASH_SCRIPT="${OUTPUT_DIR}/flash-$(basename "$BOARD").sh"
    cat > "$FLASH_SCRIPT" << EOF
#!/bin/bash
# Flash helper for ${BOARD_NAME} Deepin 25 image
# Generated: $(date)

IMAGE="\$(basename \"$COMPRESSED\")"

echo "=========================================="
echo "Deepin 25 Flash Helper"
echo "Board: ${BOARD_NAME} (${SOC_CHIP})"
echo "=========================================="

if [ \$# -lt 1 ]; then
    echo "Usage: sudo \$0 <device>"
    echo "  Example: sudo \$0 /dev/sdX"
    echo ""
    echo "WARNING: This will DESTROY all data on the target device!"
    exit 1
fi

DEVICE=\$1

# Verify device
if [ ! -b "\$DEVICE" ]; then
    echo "Error: \$DEVICE is not a valid block device"
    exit 1
fi

echo "Target device: \$DEVICE"
echo "Image: \$IMAGE"
read -p "Are you sure? This will erase all data! [y/N] " confirm

if [ "\$confirm" != "y" ] && [ "\$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

# Decompress if needed
if [[ "\$IMAGE" == *.xz ]]; then
    echo "Decompressing..."
    xz -dc "\$IMAGE" | sudo dd of="\$DEVICE" bs=4M status=progress conv=fsync
else
    sudo dd if="\$IMAGE" of="\$DEVICE" bs=4M status=progress conv=fsync
fi

echo ""
echo "Flash complete! Insert the card into your ${BOARD_NAME} and power on."
echo "Default login: root / deepin"
echo "Regular user:  deepin / deepin"
EOF
    chmod +x "$FLASH_SCRIPT"
    log_success "Flash script created: ${FLASH_SCRIPT}"
fi

# Generate info file
INFO_FILE="${OUTPUT_DIR}/build-info.txt"
cat > "$INFO_FILE" << EOF
Deepin 25 Rockchip Image Build Info
====================================
Build Date: $(date)
Board: ${BOARD_NAME} (${BOARD})
SoC: ${SOC_CHIP}
Desktop: ${DESKTOP}

Configuration:
  U-Boot Config: ${UBOOT_DEFCONFIG}
  Kernel DTB: ${KERNEL_DTB}
  DDR Blob: ${RKBIN_DDR}
  BL31: ${RKBIN_BL31}
  Serial: ${SERIAL_CONSOLE},${SERIAL_BAUD}
  GPU Overlay: ${ENABLE_GPU_OVERLAY}

Output Files:
  Bootloader: ${OUTPUT_DIR}/bootloader/
  Kernel: ${OUTPUT_DIR}/kernel/

Default Credentials:
  root / deepin
  deepin / deepin

Flash Instructions:
  TF Card: sudo dd if=*.img of=/dev/sdX bs=4M status=progress
  Or use: ./flash-${BOARD}.sh /dev/sdX

First Boot:
  1. Insert TF card into device
  2. Connect serial console (${SERIAL_CONSOLE} @ ${SERIAL_BAUD}bps) for debugging
  3. Power on
  4. Wait for first boot initialization (may take 2-5 minutes)
  5. Login with root/deepin
EOF

log_success "Build info written: ${INFO_FILE}"

# Summary
echo ""
log_step "Build Summary"
echo "  Board: ${BOARD_NAME} (${SOC_CHIP})"
echo "  Desktop: ${DESKTOP}"
echo "  Output: ${OUTPUT_DIR}"
echo ""
ls -lah "${OUTPUT_DIR}/"
echo ""
log_success "Image build complete!"
