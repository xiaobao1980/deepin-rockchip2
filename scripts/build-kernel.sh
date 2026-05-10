#!/bin/bash
# Build Linux Kernel for Rockchip using Armbian linux-rockchip
# Supports all Rockchip SoCs
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
        echo "[$(date '+%H:%M:%S')] [Kernel] [$1] $2" >> "$LOG_MAIN" 2>/dev/null || true
    fi
}

log_info() { echo -e "${BLUE}[INFO]${NC} [kernel] $1"; _log_write "INFO" "$1"; }
log_success() { echo -e "${GREEN}[OK]${NC} [kernel] $1"; _log_write "OK" "$1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} [kernel] $1"; _log_write "WARN" "$1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [kernel] $1"; _log_write "ERROR" "$1"; }
log_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [Kernel] $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    _log_write "STEP" "$1"
}

# Check environment
if [ -z "$WORKSPACE" ] || [ -z "$SOC_CHIP" ] || [ -z "$KERNEL_DTB" ]; then
    echo -e "${RED}[ERROR]${NC} Required environment variables not set. Run from build.sh."
    exit 1
fi

STAMP_DIR="${WORKSPACE}/.stamps"
KERNEL_DIR="${WORKSPACE}/linux-rockchip"
CROSS_COMPILE="aarch64-linux-gnu-"
KERNEL_LOCALVERSION="-rockchip"

# ============================================================
# Incremental check: skip if already compiled
# ============================================================
if [ -f "${STAMP_DIR}/stamp-kernel" ]; then
    log_step "Building Kernel for ${SOC_CHIP}"
    KERNEL_DEBS=$(find "$WORKSPACE" -maxdepth 1 -name "linux-image-*.deb" 2>/dev/null | head -1)
    if [ -n "$KERNEL_DEBS" ] && [ -f "$KERNEL_DEBS" ]; then
        log_success "Found stamp + .deb packages - skipping kernel build"
        cp -v ${WORKSPACE}/linux-*.deb "${ROOTFS_MOUNT}/boot/" 2>/dev/null || true
        exit 0
    fi
    log_warn "Stamp exists but debs missing - will rebuild"
    rm -f "${STAMP_DIR}/stamp-kernel"
fi

# Also check without stamp (first run after manual build)
if [ "$KERNEL_ACTION" != "force" ]; then
    KERNEL_DEBS=$(find "$WORKSPACE" -maxdepth 1 -name "linux-image-*.deb" 2>/dev/null | head -1)
    if [ -n "$KERNEL_DEBS" ] && [ -f "$KERNEL_DEBS" ]; then
        log_step "Building Kernel for ${SOC_CHIP}"
        log_success "Kernel .deb packages found - copying to rootfs (use -k force to rebuild)"
        mkdir -p "${STAMP_DIR}"
        touch "${STAMP_DIR}/stamp-kernel"
        cp -v ${WORKSPACE}/linux-*.deb "${ROOTFS_MOUNT}/boot/" 2>/dev/null || true
        exit 0
    fi
fi

log_step "Building Kernel for ${SOC_CHIP}"

cd "$WORKSPACE"

# ============================================================
# Install build dependencies for kernel bindeb-pkg
# make bindeb-pkg uses dpkg-buildpackage which checks host deps
# ============================================================
log_info "Checking kernel build dependencies..."
KERNEL_BUILD_DEPS=""
[ ! -f /usr/include/openssl/ssl.h ] 2>/dev/null && KERNEL_BUILD_DEPS="${KERNEL_BUILD_DEPS} libssl-dev"
! command -v rsync &>/dev/null && KERNEL_BUILD_DEPS="${KERNEL_BUILD_DEPS} rsync"
! command -v bison &>/dev/null && KERNEL_BUILD_DEPS="${KERNEL_BUILD_DEPS} bison"
! command -v flex &>/dev/null && KERNEL_BUILD_DEPS="${KERNEL_BUILD_DEPS} flex"
! dpkg -l fakeroot &>/dev/null 2>&1 && KERNEL_BUILD_DEPS="${KERNEL_BUILD_DEPS} fakeroot"

if [ -n "$KERNEL_BUILD_DEPS" ]; then
    log_info "Installing kernel build deps:${KERNEL_BUILD_DEPS}"
    apt-get update -qq && apt-get install -y -qq ${KERNEL_BUILD_DEPS} 2>/dev/null || {
        log_warn "Failed to auto-install build deps"
        log_info "Please install manually: apt install -y${KERNEL_BUILD_DEPS}"
    }
fi

# Git clone with retry - shows real error output
_git_clone_retry() {
    local url="$1"
    local target="$2"
    local branch="${3:-}"
    local retries=3
    local attempt=1
    local err_log="/tmp/git-clone-err-$$"
    
    rm -rf "$target"
    
    while [ $attempt -le $retries ]; do
        log_info "Git clone attempt ${attempt}/${retries}: ${url}"
        if [ -n "$branch" ]; then
            if git clone -b "$branch" --depth=1 "$url" "$target" 2>"$err_log"; then
                rm -f "$err_log"
                return 0
            fi
        else
            if git clone --depth=1 "$url" "$target" 2>"$err_log"; then
                rm -f "$err_log"
                return 0
            fi
        fi
        
        if [ -f "$err_log" ] && [ -s "$err_log" ]; then
            log_error "Clone error: $(head -3 "$err_log")"
        fi
        
        rm -rf "$target"
        
        if [ $attempt -lt $retries ]; then
            log_warn "Clone failed, retrying in 10s..."
            sleep 10
        fi
        attempt=$((attempt + 1))
    done
    
    rm -f "$err_log"
    log_error "Git clone failed after ${retries} attempts: ${url}"
    log_info "If you are behind a proxy, set https_proxy environment variable"
    return 1
}

# ===== Clone/Update Kernel Source =====
KERNEL_REPO="${KERNEL_REPO:-https://github.com/armbian/linux-rockchip}"
KERNEL_BRANCH="${KERNEL_BRANCH:-rk-6.1-rkr5.1}"

if [ "$KERNEL_ACTION" = "only" ]; then
    log_info "Using pre-built kernel packages..."
    if [ ! -d "$KERNEL_DIR" ]; then
        log_error "Kernel directory not found for 'only' action: ${KERNEL_DIR}"
        exit 1
    fi
    # Find existing .deb packages
    KERNEL_DEBS=$(find "$WORKSPACE" -maxdepth 1 -name "linux-*.deb" 2>/dev/null || true)
    if [ -z "$KERNEL_DEBS" ]; then
        log_error "No pre-built kernel .deb packages found in ${WORKSPACE}"
        exit 1
    fi
    log_success "Found pre-built kernel packages"
    # Copy to rootfs
    cp -v ${WORKSPACE}/linux-*.deb "${ROOTFS_MOUNT}/boot/" 2>/dev/null || true
    log_success "Pre-built kernel packages copied"
    exit 0
fi

log_info "Setting up kernel source..."
if [ ! -d "$KERNEL_DIR" ]; then
    _git_clone_retry "$KERNEL_REPO" "$KERNEL_DIR" "$KERNEL_BRANCH" || {
        log_error "Failed to clone kernel source"
        exit 1
    }
else
    cd "$KERNEL_DIR"
    CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    
    if [ "$CURRENT_REMOTE" != "$KERNEL_REPO" ] || [ "$CURRENT_BRANCH" != "$KERNEL_BRANCH" ]; then
        log_warn "Kernel source mismatch. Re-cloning..."
        cd "$WORKSPACE"
        rm -rf "$KERNEL_DIR"
        _git_clone_retry "$KERNEL_REPO" "$KERNEL_DIR" "$KERNEL_BRANCH" || {
            log_error "Failed to clone kernel source"
            exit 1
        }
    else
        log_info "Kernel source already at ${KERNEL_BRANCH}"
    fi
fi

cd "$WORKSPACE"

# ===== Configure Kernel =====
log_step "Configuring Kernel"

cd "$KERNEL_DIR"

# ============================================================
# Kernel Configuration Priority (highest to lowest):
# 1. boards/<board>/kernel.config        (custom full .config)
# 2. boards/<board>/kernel_vendor.config (custom vendor .config)
# 3. boards/<board>/kernel.defconfig     (custom defconfig)
# 4. Armbian defconfig from arch/arm64/configs/
# 5. Generic rockchip_linux_defconfig
# ============================================================

KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-rockchip_linux_defconfig}"

# Priority 1-2: Full .config files (copied directly)
for cfg_name in "kernel.config" "kernel_vendor.config"; do
    BOARD_CONFIG="${SCRIPT_DIR}/boards/${BOARD}/${cfg_name}"
    if [ -f "$BOARD_CONFIG" ]; then
        log_info "Using custom full kernel config: ${BOARD_CONFIG}"
        cp "$BOARD_CONFIG" .config
        log_info "Running olddefconfig to resolve dependencies..."
        make ARCH=arm64 olddefconfig
        log_success "Kernel config ready (from ${cfg_name})"
        break
    fi
done

# If no .config set yet, try defconfig path
if [ ! -f .config ]; then
    # Priority 3: Custom defconfig file
    BOARD_DEFCONFIG="${SCRIPT_DIR}/boards/${BOARD}/kernel.defconfig"
    if [ -f "$BOARD_DEFCONFIG" ]; then
        log_info "Using custom defconfig: ${BOARD_DEFCONFIG}"
        make ARCH=arm64 defconfig KBUILD_DEFCONFIG="$BOARD_DEFCONFIG"
    # Priority 4: Armbian defconfig in arch/arm64/configs/
    elif [ -f "arch/arm64/configs/${KERNEL_DEFCONFIG}" ]; then
        log_info "Using Armbian defconfig: ${KERNEL_DEFCONFIG}"
        make ARCH=arm64 "${KERNEL_DEFCONFIG}"
    # Priority 5: Generic defconfig
    else
        log_info "Using generic defconfig: ${KERNEL_DEFCONFIG}"
        make ARCH=arm64 "${KERNEL_DEFCONFIG}"
    fi
    log_success "Kernel config ready (from defconfig)"
fi

# ===== Build Kernel =====
log_step "Compiling Kernel"

# Clean any old debs
rm -f ../linux-*.deb ../linux-*.changes ../linux-*.buildinfo 2>/dev/null || true

# Build kernel and packages
make ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" bindeb-pkg LOCALVERSION="$KERNEL_LOCALVERSION" -j"$(nproc)"

# Find built packages
cd "$WORKSPACE"
KERNEL_DEBS=$(ls -t linux-image-*.deb 2>/dev/null | head -1)
KERNEL_HDRS=$(ls -t linux-headers-*.deb 2>/dev/null | head -1)
KERNEL_LIBC=$(ls -t linux-libc-dev_*.deb 2>/dev/null | head -1)

if [ -z "$KERNEL_DEBS" ]; then
    log_error "Kernel build failed - no .deb packages found"
    exit 1
fi

log_success "Kernel packages built:"
echo "  Image: ${KERNEL_DEBS}"
[ -n "$KERNEL_HDRS" ] && echo "  Headers: ${KERNEL_HDRS}"
[ -n "$KERNEL_LIBC" ] && echo "  Libc-dev: ${KERNEL_LIBC}"

# Extract kernel version
KERNEL_VERSION=$(echo "$KERNEL_DEBS" | sed 's/linux-image-//' | sed 's/_.*//' | sed 's/-rockchip//')
export KERNEL_VERSION
log_info "Kernel version: ${KERNEL_VERSION}"

# ===== Copy to RootFS =====
log_info "Copying kernel packages to rootfs..."
cp -v ${WORKSPACE}/linux-*.deb "${ROOTFS_MOUNT}/boot/"

# Also copy DTB files
log_info "Copying DTB files..."
DTB_SOURCE="${KERNEL_DIR}/arch/arm64/boot/dts/${KERNEL_DTB_DIR}/${KERNEL_DTB}"
if [ -f "$DTB_SOURCE" ]; then
    mkdir -p "${ROOTFS_MOUNT}/boot/dtbs"
    cp -v "$DTB_SOURCE" "${ROOTFS_MOUNT}/boot/dtbs/"
    log_success "DTB copied: ${KERNEL_DTB}"
else
    log_warn "DTB not found at ${DTB_SOURCE}"
    log_info "Will use DTB from kernel package"
fi

# Copy overlays if specified
if [ -n "$DT_OVERLAYS" ]; then
    log_info "Copying device tree overlays..."
    OVERLAY_DIR="${KERNEL_DIR}/arch/arm64/boot/dts/${KERNEL_DTB_DIR}/overlay"
    if [ -d "$OVERLAY_DIR" ]; then
        mkdir -p "${ROOTFS_MOUNT}/boot/overlays"
        for overlay in $DT_OVERLAYS; do
            OVERLAY_SRC="${OVERLAY_DIR}/${overlay}"
            if [ -f "$OVERLAY_SRC" ]; then
                cp -v "$OVERLAY_SRC" "${ROOTFS_MOUNT}/boot/overlays/"
                log_success "Overlay copied: ${overlay}"
            else
                log_warn "Overlay not found: ${OVERLAY_SRC}"
            fi
        done
    else
        log_warn "Overlay directory not found: ${OVERLAY_DIR}"
    fi
fi

# Copy kernel packages to output
mkdir -p "${OUTPUT_DIR}/kernel"
cp -v ${WORKSPACE}/linux-*.deb "${OUTPUT_DIR}/kernel/" 2>/dev/null || true

# Mark as successfully built for incremental builds
mkdir -p "${WORKSPACE}/.stamps"
touch "${WORKSPACE}/.stamps/stamp-kernel"
log_success "Kernel build stamp created"

log_success "Kernel build and installation complete!"
