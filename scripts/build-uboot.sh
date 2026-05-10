#!/bin/bash
# Build U-Boot and Trusted Firmware-A for Rockchip SoCs
# Supports: RK3399, RK3566, RK3568, RK3588, RK3588S
#
# NOTE: No "set -e" - we use explicit error checks to ensure all output is logged

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Write to main log if available
_log_write() {
    if [ -n "${LOG_MAIN:-}" ] && [ -f "$LOG_MAIN" ]; then
        echo "[$(date '+%H:%M:%S')] [U-Boot] [$1] $2" >> "$LOG_MAIN" 2>/dev/null || true
    fi
}

log_info() { echo -e "${BLUE}[INFO]${NC} [uboot] $1"; _log_write "INFO" "$1"; }
log_success() { echo -e "${GREEN}[OK]${NC} [uboot] $1"; _log_write "OK" "$1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} [uboot] $1"; _log_write "WARN" "$1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [uboot] $1"; _log_write "ERROR" "$1"; }
log_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [U-Boot] $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    _log_write "STEP" "$1"
}

# Check environment
if [ -z "$WORKSPACE" ] || [ -z "$SOC_CHIP" ] || [ -z "$UBOOT_DEFCONFIG" ]; then
    echo -e "${RED}[ERROR]${NC} Required environment variables not set. Run from build.sh."
    exit 1
fi

STAMP_DIR="${WORKSPACE}/.stamps"
UBOOT_DIR="${WORKSPACE}/u-boot"
TFA_DIR="${WORKSPACE}/trusted-firmware-a"
RKBIN_DIR="${WORKSPACE}/rkbin"
CROSS_COMPILE="aarch64-linux-gnu-"

# ============================================================
# Incremental check: skip if already compiled
# ============================================================
if [ -f "${STAMP_DIR}/stamp-uboot" ] && [ -f "${UBOOT_DIR}/u-boot-rockchip.bin" ]; then
    log_step "Building U-Boot for ${SOC_CHIP}"
    log_success "Found stamp + binaries - skipping U-Boot build"
    export UBOOT_ROCKCHIP_BIN="${UBOOT_DIR}/u-boot-rockchip.bin"
    export IDBLOADER_IMG="${UBOOT_DIR}/idbloader.img"
    export UBOOT_ITB="${UBOOT_DIR}/u-boot.itb"
    exit 0
fi

log_step "Building U-Boot for ${SOC_CHIP}"

cd "$WORKSPACE"

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
        
        # Show actual error
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

# ===== Clone/Update rkbin =====
log_info "Setting up rkbin binaries..."
if [ ! -d "$RKBIN_DIR" ]; then
    _git_clone_retry "https://github.com/armbian/rkbin" "$RKBIN_DIR" || {
        log_error "Failed to clone armbian/rkbin"
        exit 1
    }
else
    log_info "Updating rkbin..."
    cd "$RKBIN_DIR" && git pull 2>/dev/null || true && cd "$WORKSPACE"
fi

# Smart blob finder - auto-match closest version if exact not found
_find_best_blob() {
    local bin_dir="$1"
    local requested="$2"
    local soc_prefix="$3"
    
    # 1. Try exact match first
    if [ -f "${bin_dir}/${requested}" ]; then
        echo "${bin_dir}/${requested}"
        return 0
    fi
    
    # 2. Extract base pattern (remove version suffix like _v1.18.bin)
    local base_pattern=$(basename "$requested" | sed 's/_v[0-9.]*\.bin//' | sed 's/_eyescan//')
    local soc_path=$(dirname "$requested")
    
    # 3. Find all matching blobs for this SoC, sorted by version (newest first)
    local best_match=""
    best_match=$(find "${bin_dir}/${soc_path}" -maxdepth 1 -name "${base_pattern}*.bin" -print 2>/dev/null | sort -r | head -1)
    
    if [ -n "$best_match" ] && [ -f "$best_match" ]; then
        echo "$best_match"
        return 0
    fi
    
    # 4. Fallback: find any blob for this SoC
    best_match=$(find "${bin_dir}/${soc_path}" -maxdepth 1 -name "*${soc_prefix}*.bin" -print 2>/dev/null | grep -i "ddr" | sort -r | head -1)
    
    if [ -n "$best_match" ] && [ -f "$best_match" ]; then
        echo "$best_match"
        return 0
    fi
    
    return 1
}

# Resolve DDR blob path (auto-find if exact match not found)
if [ -n "$RKBIN_DDR" ]; then
    DDR_BLOB_FOUND=$(_find_best_blob "${RKBIN_DIR}/bin" "$RKBIN_DDR" "rk3588")
    if [ -n "$DDR_BLOB_FOUND" ]; then
        # Update RKBIN_DDR to the actual found path (relative to bin/)
        RKBIN_DDR="${DDR_BLOB_FOUND#${RKBIN_DIR}/bin/}"
        log_success "DDR blob resolved: ${RKBIN_DDR}"
    else
        log_warn "DDR blob not found in armbian/rkbin: ${RKBIN_DDR}"
        log_info "Trying rockchip-linux/rkbin as fallback..."
        rm -rf "$RKBIN_DIR"
        _git_clone_retry "https://github.com/rockchip-linux/rkbin" "$RKBIN_DIR" || {
            log_error "Failed to clone rockchip-linux/rkbin"
            exit 1
        }
        
        DDR_BLOB_FOUND=$(_find_best_blob "${RKBIN_DIR}/bin" "$RKBIN_DDR" "rk3588")
        if [ -n "$DDR_BLOB_FOUND" ]; then
            RKBIN_DDR="${DDR_BLOB_FOUND#${RKBIN_DIR}/bin/}"
            log_success "DDR blob resolved from fallback: ${RKBIN_DDR}"
        else
            log_error "DDR blob not found. Available blobs:"
            find "${RKBIN_DIR}/bin" -name "*.bin" | grep -E "rk3566|rk3568|rk3588" | head -20
            exit 1
        fi
    fi
fi

# Resolve BL31 blob path
if [ -n "$RKBIN_BL31" ]; then
    BL31_BLOB_FOUND=$(_find_best_blob "${RKBIN_DIR}/bin" "$RKBIN_BL31" "rk3588")
    if [ -n "$BL31_BLOB_FOUND" ]; then
        RKBIN_BL31="${BL31_BLOB_FOUND#${RKBIN_DIR}/bin/}"
        log_success "BL31 blob resolved: ${RKBIN_BL31}"
    else
        log_warn "BL31 blob not found: ${RKBIN_BL31}"
    fi
fi

if [ -n "$RKBIN_BL31" ] && [ ! -f "${RKBIN_DIR}/bin/${RKBIN_BL31}" ]; then
    log_error "BL31 blob not found: ${RKBIN_DIR}/bin/${RKBIN_BL31}"
    exit 1
fi

log_success "rkbin ready"

# ===== Clone/Update Trusted Firmware-A =====
log_info "Setting up Trusted Firmware-A..."
TFA_BRANCH="${TF_A_BRANCH:-v2.13.0}"

if [ ! -d "$TFA_DIR" ]; then
    _git_clone_retry "https://github.com/TrustedFirmware-A/trusted-firmware-a" "$TFA_DIR" "$TFA_BRANCH" || {
        log_error "Failed to clone TF-A"
        exit 1
    }
else
    cd "$TFA_DIR"
    CURRENT_BRANCH=$(git describe --tags 2>/dev/null || git branch --show-current)
    if [ "$CURRENT_BRANCH" != "$TFA_BRANCH" ]; then
        log_warn "TF-A branch mismatch. Re-cloning..."
        cd "$WORKSPACE"
        rm -rf "$TFA_DIR"
        _git_clone_retry "https://github.com/TrustedFirmware-A/trusted-firmware-a" "$TFA_DIR" "$TFA_BRANCH" || {
            log_error "Failed to clone TF-A"
            exit 1
        }
    else
        log_info "TF-A already at ${TFA_BRANCH}"
    fi
fi

cd "$WORKSPACE"

# ===== Build TF-A BL31 =====
log_step "Building TF-A BL31 for ${TF_A_PLAT}"

cd "$TFA_DIR"
make realclean 2>/dev/null || true
make CROSS_COMPILE="$CROSS_COMPILE" PLAT="$TF_A_PLAT" bl31 -j"$(nproc)"

BL31_ELF="${TFA_DIR}/build/${TF_A_PLAT}/release/bl31/bl31.elf"
if [ ! -f "$BL31_ELF" ]; then
    # Try alternative path
    BL31_ELF="${TFA_DIR}/build/${TF_A_PLAT}/release/bl31.elf"
fi

if [ ! -f "$BL31_ELF" ]; then
    log_error "BL31 build failed. Expected at: ${TFA_DIR}/build/${TF_A_PLAT}/release/bl31/bl31.elf"
    find "$TFA_DIR/build" -name "bl31.elf" 2>/dev/null || true
    exit 1
fi

log_success "TF-A BL31 built: ${BL31_ELF}"
cd "$WORKSPACE"

# ===== Clone/Update U-Boot =====
log_info "Setting up U-Boot..."
UBOOT_BRANCH="${UBOOT_GIT_BRANCH:-v2025.07}"

if [ ! -d "$UBOOT_DIR" ]; then
    _git_clone_retry "https://github.com/u-boot/u-boot" "$UBOOT_DIR" "$UBOOT_BRANCH" || {
        log_error "Failed to clone U-Boot"
        exit 1
    }
else
    cd "$UBOOT_DIR"
    CURRENT_BRANCH=$(git describe --tags 2>/dev/null || git branch --show-current)
    if [ "$CURRENT_BRANCH" != "$UBOOT_BRANCH" ]; then
        log_warn "U-Boot branch mismatch. Re-cloning..."
        cd "$WORKSPACE"
        rm -rf "$UBOOT_DIR"
        _git_clone_retry "https://github.com/u-boot/u-boot" "$UBOOT_DIR" "$UBOOT_BRANCH" || {
            log_error "Failed to clone U-Boot"
            exit 1
        }
    else
        log_info "U-Boot already at ${UBOOT_BRANCH}"
    fi
fi

cd "$WORKSPACE"

# ===== Build U-Boot =====
log_step "Building U-Boot (${UBOOT_DEFCONFIG})"

cd "$UBOOT_DIR"

# Export build variables
export BL31="$BL31_ELF"
export CROSS_COMPILE="$CROSS_COMPILE"

# Set DDR blob for RK35xx series
if [ -n "$RKBIN_DDR" ]; then
    export ROCKCHIP_TPL="${RKBIN_DIR}/bin/${RKBIN_DDR}"
    log_info "ROCKCHIP_TPL: ${ROCKCHIP_TPL}"
    
    if [ ! -f "$ROCKCHIP_TPL" ]; then
        log_error "DDR blob not found at ${ROCKCHIP_TPL}"
        exit 1
    fi
else
    log_info "No external DDR blob required for ${SOC_CHIP}"
    unset ROCKCHIP_TPL
fi

# Also copy BL31 to rkbin path for some builds
if [ -f "${RKBIN_DIR}/bin/${RKBIN_BL31}" ]; then
    export BL31_RKBIN="${RKBIN_DIR}/bin/${RKBIN_BL31}"
    log_info "BL31 (rkbin): ${BL31_RKBIN}"
fi

# Clean previous build
make distclean 2>/dev/null || true

# ============================================================
# U-Boot Configuration Priority (highest to lowest):
# 1. boards/<board>/u-boot.config     (custom full .config)
# 2. boards/<board>/u-boot.defconfig  (custom defconfig)
# 3. Standard defconfig from U-Boot configs/ directory
# ============================================================

CUSTOM_UBOOT_CONFIG="${SCRIPT_DIR}/boards/${BOARD}/u-boot.config"
CUSTOM_UBOOT_DEFCONFIG="${SCRIPT_DIR}/boards/${BOARD}/u-boot.defconfig"

if [ -f "$CUSTOM_UBOOT_CONFIG" ]; then
    # Priority 1: Custom full .config
    log_info "Using custom U-Boot config: ${CUSTOM_UBOOT_CONFIG}"
    cp "$CUSTOM_UBOOT_CONFIG" .config
    log_info "Running olddefconfig to resolve dependencies..."
    make olddefconfig
elif [ -f "$CUSTOM_UBOOT_DEFCONFIG" ]; then
    # Priority 2: Custom defconfig file
    log_info "Using custom U-Boot defconfig: ${CUSTOM_UBOOT_DEFCONFIG}"
    # Copy to U-Boot configs/ directory as a named defconfig
    mkdir -p configs
    cp "$CUSTOM_UBOOT_DEFCONFIG" "configs/${BOARD}_custom_defconfig"
    make "${BOARD}_custom_defconfig"
else
    # Priority 3: Standard defconfig
    log_info "Configuring U-Boot with ${UBOOT_DEFCONFIG}..."
    make "${UBOOT_DEFCONFIG}"
fi

# Build
log_info "Compiling U-Boot..."
make -j"$(nproc)"

# Find output files
UBOOT_ROCKCHIP_BIN=""
IDBLOADER_IMG=""
UBOOT_ITB=""

if [ -f "${UBOOT_DIR}/u-boot-rockchip.bin" ]; then
    UBOOT_ROCKCHIP_BIN="${UBOOT_DIR}/u-boot-rockchip.bin"
fi

if [ -f "${UBOOT_DIR}/u-boot-rockchip-spi.bin" ]; then
    UBOOT_ROCKCHIP_SPI="${UBOOT_DIR}/u-boot-rockchip-spi.bin"
fi

if [ -f "${UBOOT_DIR}/idbloader.img" ]; then
    IDBLOADER_IMG="${UBOOT_DIR}/idbloader.img"
fi

if [ -f "${UBOOT_DIR}/u-boot.itb" ]; then
    UBOOT_ITB="${UBOOT_DIR}/u-boot.itb"
fi

# Summary
echo ""
log_success "U-Boot Build Complete!"
echo "  Output files:"
[ -n "$UBOOT_ROCKCHIP_BIN" ] && echo "    u-boot-rockchip.bin: ${UBOOT_ROCKCHIP_BIN}"
[ -n "$UBOOT_ROCKCHIP_SPI" ] && echo "    u-boot-rockchip-spi.bin: ${UBOOT_ROCKCHIP_SPI}"
[ -n "$IDBLOADER_IMG" ] && echo "    idbloader.img: ${IDBLOADER_IMG}"
[ -n "$UBOOT_ITB" ] && echo "    u-boot.itb: ${UBOOT_ITB}"
echo ""

# Copy outputs
mkdir -p "${OUTPUT_DIR}/bootloader"
[ -n "$UBOOT_ROCKCHIP_BIN" ] && cp "$UBOOT_ROCKCHIP_BIN" "${OUTPUT_DIR}/bootloader/"
[ -n "$UBOOT_ROCKCHIP_SPI" ] && cp "$UBOOT_ROCKCHIP_SPI" "${OUTPUT_DIR}/bootloader/"
[ -n "$IDBLOADER_IMG" ] && cp "$IDBLOADER_IMG" "${OUTPUT_DIR}/bootloader/"
[ -n "$UBOOT_ITB" ] && cp "$UBOOT_ITB" "${OUTPUT_DIR}/bootloader/"

log_success "Bootloader files copied to ${OUTPUT_DIR}/bootloader/"

# Save variables to stamp file for setup-system.sh to read
mkdir -p "${WORKSPACE}/.stamps"
UBOOT_VARS_FILE="${WORKSPACE}/.stamps/uboot-vars"
cat > "$UBOOT_VARS_FILE" << EOF
# U-Boot variables generated by build-uboot.sh
# Board: ${BOARD} (${SOC_CHIP})
UBOOT_ROCKCHIP_BIN='${UBOOT_ROCKCHIP_BIN}'
IDBLOADER_IMG='${IDBLOADER_IMG}'
UBOOT_ITB='${UBOOT_ITB}'
BL31_ELF='${BL31_ELF}'
EOF
touch "${WORKSPACE}/.stamps/stamp-uboot"
log_success "U-Boot build stamp and variables saved"
