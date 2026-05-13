#!/bin/bash
# Deepin 25 Rockchip Universal Image Builder
# Supports: RK3399, RK3566, RK3568, RK3588, RK3588S, RK3528, RK3576
# Author: Based on deepin community tutorial by @zc_zhu
# Usage: sudo ./build.sh -b <board_name> [-t <target_device>] [-d <desktop>] [-k only|skip]
#
# NOTE: No "set -e" here - we use explicit error handling per stage
# to ensure all stages (rootfs, uboot, kernel, system) are attempted

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DATE=$(date +%Y%m%d)
BUILD_START_TIME=$(date +%s)

# Default values
BOARD=""
TARGET_DEVICE=""
DESKTOP="dde"  # dde, minimal, server
KERNEL_ACTION="build"  # build, only, skip
ROOTFS_SIZE=""
ENABLE_GPU_OVERLAY="auto"
SOURCE_PROFILE="stable"
CUSTOM_SOURCES=""
BUILD_MODE="auto"

# Logging
LOG_DIR=""
LOG_MAIN=""
LOG_ENABLE=1

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# Logging System
# ============================================================

# Initialize logging - call after board config is loaded
init_logging() {
    LOG_DIR="${OUTPUT_DIR}/logs"
    LOG_MAIN="${LOG_DIR}/build.log"
    LOG_UBOOT="${LOG_DIR}/build-uboot.log"
    LOG_KERNEL="${LOG_DIR}/build-kernel.log"
    LOG_ROOTFS="${LOG_DIR}/build-rootfs.log"
    LOG_SYSTEM="${LOG_DIR}/setup-system.log"
    
    mkdir -p "$LOG_DIR"
    
    # Write log header
    {
        echo "========================================"
        echo "Deepin 25 Rockchip Image Builder Log"
        echo "========================================"
        echo "Build Date: $(date -Iseconds)"
        echo "Board: ${BOARD_NAME} (${BOARD})"
        echo "SoC: ${SOC_CHIP}"
        echo "Desktop: ${DESKTOP}"
        echo "Source Profile: ${SOURCE_PROFILE}"
        echo "Build Mode: ${BUILD_MODE}"
        echo "Kernel Action: ${KERNEL_ACTION}"
        echo "Host: $(uname -a)"
        echo "Working Directory: ${SCRIPT_DIR}"
        echo "Output Directory: ${OUTPUT_DIR}"
        echo "========================================"
        echo ""
    } >> "$LOG_MAIN"
    
    # Export for sub-scripts
    export LOG_DIR
    export LOG_MAIN
    export LOG_UBOOT
    export LOG_KERNEL
    export LOG_ROOTFS
    export LOG_SYSTEM
}

# Core logging function
_log_write() {
    local level="$1"
    local msg="$2"
    local prefix="${level}"
    local timestamp
    timestamp=$(date '+%H:%M:%S')
    
    if [ -n "${LOG_MAIN:-}" ] && [ -f "$LOG_MAIN" ]; then
        echo "[${timestamp}] [${prefix}] ${msg}" >> "$LOG_MAIN" 2>/dev/null || true
    fi
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    _log_write "INFO" "$1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
    _log_write "OK" "$1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    _log_write "WARN" "$1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    _log_write "ERROR" "$1"
}

log_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    _log_write "STEP" "$1"
}

usage() {
    cat << EOF
Deepin 25 Rockchip Universal Image Builder

Usage:
    sudo $0 -b <board_name> [options]

Required:
    -b BOARD        Board configuration name (see boards/ directory)

Optional:
    -t DEVICE       Target block device (e.g., /dev/sda, /dev/mmcblk0)
                    If not specified, will create a loopback image file
    -d DESKTOP      Desktop environment: dde (default), minimal, server
    -k ACTION       Kernel action: build (default), only, skip
                    'build' = download + compile, 'only' = use pre-built debs, 'skip' = reuse
    -s SIZE         Rootfs size in GB (auto-detected if not specified)
    -g GPU          Enable GPU overlay: auto (default), yes, no
    -r PROFILE      Source profile: stable (default), testing, hwe, ports,
                    stable+testing, stable+hwe, full, custom
    -c FILE         Custom sources.list file (used with -r custom)
    -m MODE         Build mode: auto (default), fast, compat
                    'fast' = skip merged-usr hook (2-3x faster, QEMU optimized)
                    'compat' = full merged-usr (slower, max compatibility)
    -h              Show this help

Supported Boards:
    RK3588:         orangepi-5-plus, rock-5b, nanopc-t6, quartzpro64
    RK3588S:        orangepi-5, rock-5a
    RK3568:         nanopi-r5c, nanopi-r5s, rock-3a, generic-rk3568
    RK3566:         orangepi-3b, generic-rk3566
    RK3399:         nanopc-t4, rock-pi-4, generic-rk3399

Source Profiles:
    stable          Community stable repository only (recommended)
    testing         Testing/development repository
    hwe             Hardware Enablement (newer Mesa/drivers)
    ports           ARM/ports optimized repository
    stable+testing  Stable with testing fallback
    stable+hwe      Stable with HWE for new hardware (recommended for RK3588)
    full            All repositories (maximum packages)
    custom          User-provided sources.list (-c required)

Examples:
    # Build for Orange Pi 5 Plus to image file
    sudo ./build.sh -b orangepi-5-plus

    # Build for Orange Pi 5 with minimal system to TF card
    sudo ./build.sh -b orangepi-5 -t /dev/sda -d minimal

    # Build for NanoPi R5C using pre-built kernel
    sudo ./build.sh -b nanopi-r5c -k only

    # Build for generic RK3568 with custom size
    sudo ./build.sh -b generic-rk3568 -s 8

    # Fast build mode (skip merged-usr hook, 2-3x faster for QEMU)
    sudo ./build.sh -b orangepi-5-plus -m fast

    # Build with HWE for new GPU hardware
    sudo ./build.sh -b orangepi-5-plus -r stable+hwe

    # Build with full repositories for development
    sudo ./build.sh -b rock-5b -r full -d dde

EOF
    exit 0
}

# Parse arguments
while getopts "b:t:d:k:s:g:r:c:m:h" opt; do
    case $opt in
        b) BOARD="$OPTARG" ;;
        t) TARGET_DEVICE="$OPTARG" ;;
        d) DESKTOP="$OPTARG" ;;
        k) KERNEL_ACTION="$OPTARG" ;;
        s) ROOTFS_SIZE="$OPTARG" ;;
        g) ENABLE_GPU_OVERLAY="$OPTARG" ;;
        r) SOURCE_PROFILE="$OPTARG" ;;
        c) CUSTOM_SOURCES="$OPTARG" ;;
        m) BUILD_MODE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate root
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root. Use: sudo $0 $@"
    exit 1
fi

# Validate board configuration
if [ -z "$BOARD" ]; then
    log_error "Board name is required. Use -b <board_name>"
    usage
fi

BOARD_CONFIG="${SCRIPT_DIR}/boards/${BOARD}/board.conf"
if [ ! -f "$BOARD_CONFIG" ]; then
    log_error "Board configuration not found: ${BOARD_CONFIG}"
    echo "Available boards:"
    ls -1 "${SCRIPT_DIR}/boards/" | sed 's/^/  - /'
    exit 1
fi

# Load board configuration
log_step "Loading board configuration: ${BOARD}"
source "$BOARD_CONFIG"

# Validate required board variables
REQUIRED_VARS="SOC_CHIP UBOOT_DEFCONFIG RKBIN_DDR RKBIN_BL31 TF_A_PLAT KERNEL_DTB"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        log_error "Missing required variable in board config: ${var}"
        exit 1
    fi
done

# Set defaults from board config if not specified
[ -z "$TARGET_DEVICE" ] && TARGET_DEVICE="${DEFAULT_DEVICE:-}"
[ -z "$ROOTFS_SIZE" ] && ROOTFS_SIZE="${DEFAULT_ROOTFS_SIZE:-8}"
[ "$ENABLE_GPU_OVERLAY" = "auto" ] && ENABLE_GPU_OVERLAY="${GPU_OVERLAY:-no}"

# Auto-increase rootfs size for DDE desktop (needs ~10GB+)
if [ "$DESKTOP" = "dde" ] && [ "$ROOTFS_SIZE" -lt 12 ]; then
    log_info "DDE desktop detected - increasing rootfs size from ${ROOTFS_SIZE}GB to 12GB"
    ROOTFS_SIZE=12
fi

# Validate and setup source profile
source "${SCRIPT_DIR}/scripts/setup-sources.sh" 2>/dev/null || true
if [ "$SOURCE_PROFILE" = "custom" ] && [ -z "$CUSTOM_SOURCES" ]; then
    log_error "Custom source profile requires -c <file>. Use -r stable for default."
    exit 1
fi
SOURCES_LIST_FILE="${SOURCES_DIR:-${SCRIPT_DIR}/overlays/sources}/${SOURCE_PROFILE}.list"
if [ "$SOURCE_PROFILE" != "custom" ] && [ ! -f "$SOURCES_LIST_FILE" ]; then
    log_error "Source profile '${SOURCE_PROFILE}' not found. Available profiles:"
    ls -1 "${SCRIPT_DIR}/overlays/sources/"*.list 2>/dev/null | sed 's/.*\//  /' | sed 's/.list$//'
    exit 1
fi

# Auto-select board-default source profile if user didn't override
if [ "$SOURCE_PROFILE" = "stable" ] && [ -n "${DEFAULT_SOURCE_PROFILE:-}" ]; then
    log_info "Using board-default source profile: ${DEFAULT_SOURCE_PROFILE}"
    SOURCE_PROFILE="$DEFAULT_SOURCE_PROFILE"
fi

# Export all variables for sub-scripts
export SCRIPT_DIR
export BOARD
export SOC_CHIP
export BOARD_NAME
export UBOOT_DEFCONFIG
export UBOOT_GIT_BRANCH
export RKBIN_DDR
export RKBIN_BL31
export TF_A_PLAT
export TF_A_BRANCH
export KERNEL_REPO
export KERNEL_BRANCH
export KERNEL_DEFCONFIG
export KERNEL_DTB
export KERNEL_DTB_DIR
export DT_OVERLAYS
export SERIAL_CONSOLE
export SERIAL_BAUD
export BOOT_PART_UUID
export ENABLE_GPU_OVERLAY
export DESKTOP
export KERNEL_ACTION
export TARGET_DEVICE
export ROOTFS_SIZE
export WORKSPACE
export OUTPUT_DIR
export EXTRA_PACKAGES
export BOOT_LABEL
export SOURCE_PROFILE
export CUSTOM_SOURCES
export SOURCES_DIR="${SCRIPT_DIR}/overlays/sources"
export BUILD_MODE

echo ""
log_info "Build Configuration:"
echo "  Board:          ${BOARD_NAME} (${BOARD})"
echo "  SoC:            ${SOC_CHIP}"
echo "  U-Boot Config:  ${UBOOT_DEFCONFIG}"
echo "  Kernel DTB:     ${KERNEL_DTB}"
echo "  DDR Blob:       ${RKBIN_DDR}"
echo "  BL31:           ${RKBIN_BL31}"
echo "  Target:         ${TARGET_DEVICE:-image file}"
echo "  Desktop:        ${DESKTOP}"
echo "  Rootfs Size:    ${ROOTFS_SIZE}GB"
echo "  GPU Overlay:    ${ENABLE_GPU_OVERLAY}"
echo "  Kernel Action:  ${KERNEL_ACTION}"
echo "  Source Profile: ${SOURCE_PROFILE}"
echo "  Build Mode:     ${BUILD_MODE}"
echo ""

# Check dependencies
log_step "Checking dependencies"

# Phase 1: Essential tools (all builds)
DEPS_ESSENTIAL="mmdebstrap qemu-aarch64-static mkfs.ext4 parted git make gcc"
MISSING=""
for dep in $DEPS_ESSENTIAL; do
    if ! command -v "$dep" &> /dev/null; then
        MISSING="${MISSING} ${dep}"
    fi
done

if [ -n "$MISSING" ]; then
    log_error "Missing essential dependencies: ${MISSING}"
    log_info "Install with: apt install -y mmdebstrap qemu-user-static binfmt-support parted git build-essential"
    exit 1
fi

# Phase 2: Cross compiler
if [ ! -x "/usr/bin/aarch64-linux-gnu-gcc" ]; then
    log_error "Cross compiler not found: aarch64-linux-gnu-gcc"
    log_info "Install with: apt install -y crossbuild-essential-arm64"
    exit 1
fi

# Phase 3: Build tools for U-Boot/Kernel compilation
DEPS_BUILD="flex bison swig python3 bc"
MISSING_BUILD=""
for dep in $DEPS_BUILD; do
    if ! command -v "$dep" &> /dev/null; then
        MISSING_BUILD="${MISSING_BUILD} ${dep}"
    fi
done

if [ -n "$MISSING_BUILD" ]; then
    log_warn "Missing build tools: ${MISSING_BUILD}"
    log_info "Auto-installing build dependencies..."
    apt-get update -qq && apt-get install -y -qq ${MISSING_BUILD} 2>/dev/null || {
        log_error "Failed to install build tools. Please install manually:"
        log_info "  apt install -y flex bison swig python3 bc"
        exit 1
    }
fi

# Phase 4: Fix script permissions
for script in "${SCRIPT_DIR}"/scripts/*.sh; do
    if [ -f "$script" ] && [ ! -x "$script" ]; then
        chmod +x "$script"
        log_info "Fixed permission: $(basename "$script")"
    fi
done

log_success "All dependencies satisfied"

# Fix script permissions (ensure all sub-scripts are executable)
for script in "${SCRIPT_DIR}"/scripts/*.sh; do
    if [ -f "$script" ] && [ ! -x "$script" ]; then
        chmod +x "$script"
        log_info "Fixed permission: $(basename "$script")"
    fi
done

# Create workspace
export WORKSPACE="${SCRIPT_DIR}/workspace/${BOARD}"
export OUTPUT_DIR="${SCRIPT_DIR}/output/${BOARD}-${BUILD_DATE}"
mkdir -p "$WORKSPACE" "$OUTPUT_DIR"

# Initialize logging
init_logging
log_info "Logging initialized: ${LOG_MAIN}"

# Setup target device (physical device or image file)
setup_target() {
    if [ -n "$TARGET_DEVICE" ]; then
        if [ ! -b "$TARGET_DEVICE" ]; then
            log_error "Block device not found: ${TARGET_DEVICE}"
            exit 1
        fi
        export ROOT_DEVICE="$TARGET_DEVICE"
        export ROOT_PART="${TARGET_DEVICE}1"
        export IMAGE_FILE=""
        log_info "Using physical device: ${TARGET_DEVICE}"
    else
        # Create image file
        export IMAGE_FILE="${OUTPUT_DIR}/${BOARD}-deepin25-${BUILD_DATE}.img"
        log_info "Creating image file: ${IMAGE_FILE} (${ROOTFS_SIZE}GB)"
        dd if=/dev/zero of="$IMAGE_FILE" bs=1M count=$((${ROOTFS_SIZE} * 1024)) status=progress
        export ROOT_DEVICE="${IMAGE_FILE}"
        export ROOT_PART=""
    fi
}

# Partition target
partition_target() {
    log_step "Partitioning target"
    
    local device="$ROOT_DEVICE"
    
    # Create GPT partition table
    parted --script "$device" \
        mklabel gpt \
        mkpart primary ext4 16MiB 100%
    
    # Sync
    sync
    sleep 2
    partprobe "$device" 2>/dev/null || true
    sleep 1
    
    # Determine partition name
    if [ -n "$IMAGE_FILE" ]; then
        # Setup loop device for image file
        LOOP_DEV=$(losetup -f --show -P "$IMAGE_FILE")
        export LOOP_DEV
        export ROOT_PART="${LOOP_DEV}p1"
        log_info "Loop device: ${LOOP_DEV}"
    else
        export ROOT_PART="${device}1"
        # Handle mmcblk naming
        if [[ "$device" == *mmcblk* ]]; then
            export ROOT_PART="${device}p1"
        fi
    fi
    
    # Generate UUID and format
    if [ -z "$BOOT_PART_UUID" ]; then
        BOOT_PART_UUID=$(uuidgen)
        export BOOT_PART_UUID
    fi
    
    log_info "Formatting ${ROOT_PART} with UUID ${BOOT_PART_UUID}..."
    mkfs.ext4 -F -U "$BOOT_PART_UUID" -L "${BOOT_LABEL:-root}" "$ROOT_PART"
    
    sync
    log_success "Partition created and formatted"
}

# Mount root partition
mount_rootfs() {
    log_step "Mounting root filesystem"
    mkdir -p "$WORKSPACE/rootfs"
    mount "$ROOT_PART" "$WORKSPACE/rootfs"
    export ROOTFS_MOUNT="$WORKSPACE/rootfs"
    log_success "Mounted ${ROOT_PART} to ${ROOTFS_MOUNT}"
}

# ============================================================
# Incremental Build: Stamp / Cache System
# ============================================================

STAMP_DIR="${WORKSPACE}/.stamps"
mkdir -p "$STAMP_DIR"

stamp_set() { touch "${STAMP_DIR}/stamp-$1"; }
stamp_check() { [ -f "${STAMP_DIR}/stamp-$1" ]; }
stamp_clear() { rm -f "${STAMP_DIR}/stamp-$1"; }

# Check if compiled U-Boot binaries exist
uboot_is_built() {
    local uboot_dir="${WORKSPACE}/u-boot"
    [ -f "${uboot_dir}/u-boot-rockchip.bin" ] && return 0
    [ -f "${uboot_dir}/idbloader.img" ] && [ -f "${uboot_dir}/u-boot.itb" ] && return 0
    return 1
}

# Check if kernel debs exist
kernel_is_built() {
    local ws="$WORKSPACE"
    # Check for kernel image .deb in workspace parent or workspace itself
    local debs=$(find "$ws" -maxdepth 1 -name "linux-image-*.deb" 2>/dev/null | head -1)
    [ -n "$debs" ] && [ -f "$debs" ] && return 0
    return 1
}

# Check if rootfs has been populated (has essential dirs)
rootfs_is_built() {
    local rf="${WORKSPACE}/rootfs"
    [ -d "${rf}/usr/bin" ] && [ -d "${rf}/etc" ] && [ -f "${rf}/var/lib/dpkg/status" ] && return 0
    return 1
}

# ============================================================
# Execute script with logging - shows to BOTH terminal and log file
# ============================================================
run_script() {
    local script_path="$1"
    local log_file="$2"
    local script_name
    script_name=$(basename "$script_path")
    local exit_code=0
    
    log_step "Running ${script_name}"
    [ -n "$log_file" ] && log_info "Log file: ${log_file}"
    
    if [ -n "$log_file" ] && [ -d "$(dirname "$log_file")" ]; then
        # stdbuf -oL forces line buffering so output is not lost on crash/exit
        stdbuf -oL "${script_path}" 2>&1 | stdbuf -oL tee -a "$log_file"
        exit_code=${PIPESTATUS[0]}
    else
        stdbuf -oL "${script_path}" 2>&1
        exit_code=$?
    fi
    
    if [ $exit_code -ne 0 ]; then
        log_error "${script_name} failed with exit code ${exit_code}"
        [ -n "$log_file" ] && log_info "See log: ${log_file}"
        return $exit_code
    fi
    
    log_success "${script_name} completed"
    return 0
}

# Main build process
main() {
    # Open log descriptor for tee
    exec 9>>"$LOG_MAIN"
    
    log_step "Deepin 25 Rockchip Image Builder"
    log_info "Board: ${BOARD_NAME} (${SOC_CHIP})"
    log_info "Output: ${OUTPUT_DIR}"
    log_info "Main log: ${LOG_MAIN}"
    
    setup_target || { log_error "setup_target failed"; exit 1; }
    partition_target || { log_error "partition_target failed"; exit 1; }
    mount_rootfs || { log_error "mount_rootfs failed"; exit 1; }
    
    # ============================================================
    # Stage 1: Root Filesystem
    # ============================================================
    if stamp_check "rootfs"; then
        log_step "Stage 1/5: Root Filesystem"
        log_success "Found stamp - rootfs already built, skipping"
    elif rootfs_is_built; then
        log_step "Stage 1/5: Root Filesystem"
        log_success "Existing rootfs detected, creating stamp and skipping"
        stamp_set "rootfs"
    else
        log_step "Stage 1/5: Root Filesystem"
        run_script "${SCRIPT_DIR}/scripts/build-rootfs.sh" "$LOG_ROOTFS" || {
            log_error "RootFS build failed - aborting"
            exit 1
        }
        stamp_set "rootfs"
    fi
    
    # ============================================================
    # Stage 2: U-Boot
    # ============================================================
    local uboot_ok=0
    if stamp_check "uboot"; then
        log_step "Stage 2/5: U-Boot"
        log_success "Found stamp - U-Boot already built, skipping"
        uboot_ok=1
    elif uboot_is_built; then
        log_step "Stage 2/5: U-Boot"
        log_success "Compiled U-Boot binaries found, creating stamp and skipping"
        stamp_set "uboot"
        uboot_ok=1
    else
        log_step "Stage 2/5: U-Boot"
        run_script "${SCRIPT_DIR}/scripts/build-uboot.sh" "$LOG_UBOOT" || {
            log_error "U-Boot build script failed"
        }
        if uboot_is_built; then
            stamp_set "uboot"
            uboot_ok=1
            log_success "U-Boot binaries verified"
        else
            log_error "U-Boot binaries missing after build"
            log_error "Check build log: ${LOG_UBOOT}"
            exit 1
        fi
    fi
    
    # ============================================================
    # Stage 3: Kernel
    # ============================================================
    local kernel_ok=0
    if [ "$KERNEL_ACTION" = "skip" ]; then
        log_step "Stage 3/5: Kernel"
        log_info "Skipping kernel build (-k skip)"
        kernel_ok=1
    elif stamp_check "kernel"; then
        log_step "Stage 3/5: Kernel"
        log_success "Found stamp - kernel already built, copying debs to rootfs"
        cp -v ${WORKSPACE}/linux-*.deb "${WORKSPACE}/rootfs/boot/" 2>/dev/null || true
        kernel_ok=1
    elif kernel_is_built; then
        log_step "Stage 3/5: Kernel"
        log_success "Kernel .deb packages found, creating stamp and copying"
        stamp_set "kernel"
        cp -v ${WORKSPACE}/linux-*.deb "${WORKSPACE}/rootfs/boot/" 2>/dev/null || true
        kernel_ok=1
    else
        log_step "Stage 3/5: Kernel"
        run_script "${SCRIPT_DIR}/scripts/build-kernel.sh" "$LOG_KERNEL" || {
            log_warn "Kernel build failed"
        }
        if kernel_is_built; then
            stamp_set "kernel"
            kernel_ok=1
            # Copy kernel packages to rootfs for chroot installation
            if [ -d "${WORKSPACE}/rootfs/boot" ]; then
                log_info "Copying kernel .deb packages to rootfs..."
                if ls ${WORKSPACE}/linux-*.deb 1>/dev/null 2>&1; then
                    cp -v ${WORKSPACE}/linux-*.deb "${WORKSPACE}/rootfs/boot/" 2>/dev/null || true
                fi
            fi
            log_success "Kernel .deb packages verified"
        else
            log_error "Kernel .deb packages missing after build"
        fi
    fi
    
    # Abort if both U-Boot and Kernel are missing
    if [ $uboot_ok -eq 0 ] && [ $kernel_ok -eq 0 ]; then
        log_error "========================================"
        log_error "CRITICAL: Both U-Boot and Kernel failed!"
        log_error "The image would NOT be bootable."
        log_error "Check network connectivity (GitHub access)"
        log_error "U-Boot log: ${LOG_UBOOT}"
        log_error "Kernel log: ${LOG_KERNEL}"
        log_error "========================================"
        exit 1
    fi
    
    if [ $uboot_ok -eq 0 ] || [ $kernel_ok -eq 0 ]; then
        log_warn "========================================"
        [ $uboot_ok -eq 0 ] && log_warn "U-Boot is MISSING"
        [ $kernel_ok -eq 0 ] && log_warn "Kernel is MISSING"
        log_warn "========================================"
    fi
    
    # ============================================================
    # Stage 4: System Configuration
    # ============================================================
    if stamp_check "system"; then
        log_step "Stage 4/5: System Configuration"
        log_success "Found stamp - system already configured, skipping"
    else
        log_step "Stage 4/5: System Configuration"
        run_script "${SCRIPT_DIR}/scripts/setup-system.sh" "$LOG_SYSTEM" || {
            log_warn "System setup had warnings"
        }
        stamp_set "system"
    fi
    
    # ============================================================
    # Stage 5: Pack Image
    # ============================================================
    log_step "Stage 5/5: Pack Image"
    run_script "${SCRIPT_DIR}/scripts/pack-image.sh" "$LOG_MAIN" || {
        log_warn "Image packaging had warnings"
    }
    
    # Show summary
    BUILD_END_TIME=$(date +%s)
    BUILD_DURATION=$((BUILD_END_TIME - BUILD_START_TIME))
    DURATION_MIN=$((BUILD_DURATION / 60))
    DURATION_SEC=$((BUILD_DURATION % 60))
    
    log_step "Build Complete!"
    log_success "Board: ${BOARD_NAME} (${SOC_CHIP})"
    log_success "Duration: ${DURATION_MIN}m ${DURATION_SEC}s"
    
    if [ -n "$IMAGE_FILE" ]; then
        log_success "Image: ${IMAGE_FILE}"
        ls -lh "$IMAGE_FILE"
        echo ""
        log_info "Flash to TF card:"
        echo "  sudo dd if=${IMAGE_FILE} of=/dev/sdX bs=4M status=progress conv=fsync"
        echo ""
    else
        log_success "System installed to: ${TARGET_DEVICE}"
    fi
    
    # Log file summary
    echo ""
    log_step "Build Logs"
    log_info "Main log:    ${LOG_MAIN}"
    log_info "RootFS log:  ${LOG_ROOTFS}"
    log_info "U-Boot log:  ${LOG_UBOOT}"
    log_info "Kernel log:  ${LOG_KERNEL}"
    log_info "System log:  ${LOG_SYSTEM}"
    echo ""
    
    log_info "Insert TF card/eMMC and power on your device!"
    
    # Close log descriptor
    exec 9>&-
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    if mountpoint -q "$WORKSPACE/rootfs" 2>/dev/null; then
        umount -R "$WORKSPACE/rootfs" 2>/dev/null || true
    fi
    if [ -n "$LOOP_DEV" ] && losetup "$LOOP_DEV" &>/dev/null; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# Run main build
main "$@"
