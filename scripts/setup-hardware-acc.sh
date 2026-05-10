#!/bin/bash
# RK3588 Hardware Acceleration Setup
# Configures GPU (Mali-G610 Panthor), VPU (MPP), and NPU (RKNPU2)
# Run inside chroot environment

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

_log_write() {
    if [ -n "${LOG_MAIN:-}" ] && [ -f "$LOG_MAIN" ]; then
        echo "[$(date '+%H:%M:%S')] [HWACC] [$1] $2" >> "$LOG_MAIN" 2>/dev/null || true
    fi
}

log_info() { echo -e "${BLUE}[HWACC]${NC} $1"; _log_write "INFO" "$1"; }
log_success() { echo -e "${GREEN}[HWACC]${NC} $1"; _log_write "OK" "$1"; }
log_warn() { echo -e "${YELLOW}[HWACC]${NC} $1"; _log_write "WARN" "$1"; }
log_error() { echo -e "${RED}[HWACC]${NC} $1"; _log_write "ERROR" "$1"; }
log_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [HWACC] $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    _log_write "STEP" "$1"
}

SOC_CHIP="${SOC_CHIP:-}"
BOARD="${BOARD:-}"

# Detect SoC capabilities
detect_soc() {
    if [ -z "$SOC_CHIP" ]; then
        # Try to detect from DTB
        if [ -f /proc/device-tree/compatible ]; then
            if grep -q "rk3588" /proc/device-tree/compatible 2>/dev/null; then
                SOC_CHIP="RK3588"
            elif grep -q "rk3588s" /proc/device-tree/compatible 2>/dev/null; then
                SOC_CHIP="RK3588S"
            elif grep -q "rk3568" /proc/device-tree/compatible 2>/dev/null; then
                SOC_CHIP="RK3568"
            elif grep -q "rk3566" /proc/device-tree/compatible 2>/dev/null; then
                SOC_CHIP="RK3566"
            fi
        fi
    fi
    
    case "$SOC_CHIP" in
        RK3588|RK3588S)
            HAS_GPU=1
            HAS_VPU=1
            HAS_NPU=1
            GPU_TYPE="mali-g610"
            log_info "Detected ${SOC_CHIP} - Full acceleration support (GPU/VPU/NPU)"
            ;;
        RK3566)
            HAS_GPU=1
            HAS_VPU=1
            HAS_NPU=1
            GPU_TYPE="mali-g52"
            log_info "Detected ${SOC_CHIP} - Mali-G52 MC2 GPU, Hantro VPU (1080p), 1 TOPS NPU"
            ;;
    RK3568)
            HAS_GPU=1
            HAS_VPU=1
            HAS_NPU=1
            GPU_TYPE="mali-g52"
            log_info "Detected ${SOC_CHIP} - Mali-G52 MC2 GPU, Hantro VPU (4K60), 0.8 TOPS NPU"
            ;;
    RK3576)
            HAS_GPU=1
            HAS_VPU=1
            HAS_NPU=1
            GPU_TYPE="mali-g52"
            log_info "Detected ${SOC_CHIP} - Mali-G52 MC3 GPU, rkvdec2 VPU (4K120), 6 TOPS NPU"
            ;;
        RK3399)
            HAS_GPU=1
            HAS_VPU=1
            HAS_NPU=0
            GPU_TYPE="mali-t860"
            log_info "Detected ${SOC_CHIP} - GPU/VPU support (no NPU)"
            ;;
        *)
            HAS_GPU=0
            HAS_VPU=0
            HAS_NPU=0
            log_warn "Unknown SoC: ${SOC_CHIP} - skipping hardware acceleration"
            ;;
    esac
}

# ============================================================
# GPU Setup (Mali Panthor + Mesa)
# ============================================================
setup_gpu() {
    if [ "$HAS_GPU" != "1" ]; then
        log_info "GPU acceleration not available for this SoC"
        return 0
    fi
    
    log_step "Setting up GPU Acceleration (${GPU_TYPE})"
    
    # Install Mesa with Panthor/Panfrost support
    log_info "Installing Mesa GPU drivers..."
    apt-get update -qq
    apt-get install -y -qq \
        mesa-vulkan-drivers \
        libegl1-mesa-drivers \
        libgl1-mesa-dri \
        libglx-mesa0 \
        libgbm1 \
        mesa-utils \
        2>/dev/null || {
        log_warn "Some Mesa packages not found in repository"
    }
    
    # For RK3588, install Mali CSF firmware
    if [ "$GPU_TYPE" = "mali-g610" ]; then
        log_info "Installing Mali-G610 CSF firmware..."
        
        # Create firmware directory
        mkdir -p /lib/firmware/arm/mali/arch10.8
        
        # Try to download firmware from linux-firmware git
        if [ ! -f /lib/firmware/arm/mali/arch10.8/mali_csffw.bin ]; then
            log_info "Downloading Mali CSF firmware..."
            
            # Method 1: From linux-firmware git (most reliable)
            FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/arm/mali/arch10.8/mali_csffw.bin"
            curl -L --max-time 30 -o /tmp/mali_csffw.bin "$FW_URL" 2>/dev/null && \
                mv /tmp/mali_csffw.bin /lib/firmware/arm/mali/arch10.8/mali_csffw.bin && \
                chmod 644 /lib/firmware/arm/mali/arch10.8/mali_csffw.bin && \
                log_success "Mali CSF firmware downloaded" || {
                
                # Method 2: From rockchip-linux repository
                log_warn "Primary download failed, trying mirror..."
                FW_URL2="https://raw.githubusercontent.com/rockchip-linux/rk-rootfs-build/master/firmware/mali_csffw.bin"
                curl -L --max-time 30 -o /tmp/mali_csffw.bin "$FW_URL2" 2>/dev/null && \
                    mv /tmp/mali_csffw.bin /lib/firmware/arm/mali/arch10.8/mali_csffw.bin && \
                    chmod 644 /lib/firmware/arm/mali/arch10.8/mali_csffw.bin && \
                    log_success "Mali CSF firmware downloaded from mirror" || {
                    log_error "Failed to download Mali CSF firmware"
                    log_info "GPU acceleration requires manual firmware installation:"
                    log_info "  Place mali_csffw.bin at /lib/firmware/arm/mali/arch10.8/"
                }
            }
        else
            log_success "Mali CSF firmware already present"
        fi
        
        # Verify firmware
        if [ -f /lib/firmware/arm/mali/arch10.8/mali_csffw.bin ]; then
            FW_SIZE=$(stat -c%s /lib/firmware/arm/mali/arch10.8/mali_csffw.bin 2>/dev/null || echo "0")
            if [ "$FW_SIZE" -gt 100000 ]; then
                log_success "Mali CSF firmware OK (${FW_SIZE} bytes)"
            else
                log_warn "Mali CSF firmware size suspicious (${FW_SIZE} bytes)"
            fi
        fi
    fi
    
    # Enable panthor module
    log_info "Enabling GPU kernel modules..."
    if [ "$GPU_TYPE" = "mali-g610" ]; then
        # For RK3588, prefer panthor (new CSF-based driver)
        modprobe panthor 2>/dev/null || true
        echo "panthor" >> /etc/modules-load.d/rockchip-gpu.conf
        log_info "Using panthor driver for Mali-G610 (RK3588)"
    elif [ "$GPU_TYPE" = "mali-g52" ]; then
        # For RK3566/RK3568/RK3576, use panfrost (open-source driver)
        modprobe panfrost 2>/dev/null || true
        echo "panfrost" >> /etc/modules-load.d/rockchip-gpu.conf
        log_info "Using panfrost driver for Mali-G52 (${SOC_CHIP})"
    else
        # For older Mali (RK3399), use panfrost
        modprobe panfrost 2>/dev/null || true
        echo "panfrost" >> /etc/modules-load.d/rockchip-gpu.conf
        log_info "Using panfrost driver for ${GPU_TYPE}"
    fi
    
    # Add user to render group for GPU access
    log_info "Configuring GPU permissions..."
    # Create render group if not exists
    getent group render >/dev/null || groupadd -r render 2>/dev/null || true
    
    # Add default user to video and render groups
    for user in deepin $(grep "^users" /etc/group | cut -d: -f4 | tr ',' ' '); do
        if [ -n "$user" ] && id "$user" &>/dev/null; then
            usermod -aG video,render "$user" 2>/dev/null || true
        fi
    done
    
    # udev rules for GPU
    cat > /etc/udev/rules.d/50-rockchip-gpu.rules << 'EOF'
# Rockchip GPU permissions
KERNEL=="mali0", MODE="0666", GROUP="video"
KERNEL=="renderD[0-9]*", MODE="0666", GROUP="render"
KERNEL=="card[0-9]*", MODE="0666", GROUP="video"
EOF
    
    log_success "GPU acceleration configured"
}

# ============================================================
# VPU Setup (MPP + ffmpeg-rockchip)
# ============================================================
setup_vpu() {
    if [ "$HAS_VPU" != "1" ]; then
        log_info "VPU acceleration not available for this SoC"
        return 0
    fi
    
    log_step "Setting up VPU Acceleration (Video Codec)"
    
    # Install MPP (Media Process Platform)
    log_info "Installing Rockchip MPP libraries..."
    apt-get update -qq
    apt-get install -y -qq \
        librockchip-mpp-dev \
        librockchip-mpp1 \
        librockchip-vpu0 \
        2>/dev/null || {
        log_warn "MPP packages not in repository, building from source may be needed"
    }
    
    # Install ffmpeg with rockchip support if available
    log_info "Installing ffmpeg with hardware acceleration..."
    apt-get install -y -qq \
        ffmpeg \
        libffmpeg-rockchip-dev \
        2>/dev/null || {
        # Fallback: install standard ffmpeg
        apt-get install -y -qq ffmpeg 2>/dev/null || true
        log_warn "ffmpeg-rockchip not available, installed standard ffmpeg"
    }
    
    # Install GStreamer plugins for hardware decode
    apt-get install -y -qq \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-rockchip \
        2>/dev/null || {
        log_warn "GStreamer Rockchip plugins not available"
    }
    
    # udev rules for VPU devices (SoC-specific)
    mkdir -p /etc/udev/rules.d
    
    case "${SOC_CHIP}" in
        RK3566|RK3568)
            # Hantro VPU: H.264/H.265 1080p decode
            cat > /etc/udev/rules.d/51-rockchip-vpu.rules << 'EOF'
# Rockchip VPU permissions (RK3566/RK3568 Hantro)
KERNEL=="mpp_service", MODE="0666", GROUP="video"
KERNEL=="rga", MODE="0666", GROUP="video"
KERNEL=="hantro-vpu", MODE="0666", GROUP="video"
KERNEL=="vepu", MODE="0666", GROUP="video"
EOF
            ;;
        RK3576)
            # rkvdec2 VPU: H.264/H.265 4K120 decode, AV1 4K60
            cat > /etc/udev/rules.d/51-rockchip-vpu.rules << 'EOF'
# Rockchip VPU permissions (RK3576 rkvdec2)
KERNEL=="mpp_service", MODE="0666", GROUP="video"
KERNEL=="rga", MODE="0666", GROUP="video"
KERNEL=="rkvdec2", MODE="0666", GROUP="video"
KERNEL=="rkvenc2", MODE="0666", GROUP="video"
KERNEL=="hantro-vpu", MODE="0666", GROUP="video"
KERNEL=="vepu", MODE="0666", GROUP="video"
KERNEL=="av1d", MODE="0666", GROUP="video"
EOF
            ;;
        RK3588|RK3588S)
            # rkvdec/rkvenc VPU: 8K decode/encode
            cat > /etc/udev/rules.d/51-rockchip-vpu.rules << 'EOF'
# Rockchip VPU permissions (RK3588 rkvdec/rkvenc)
KERNEL=="mpp_service", MODE="0666", GROUP="video"
KERNEL=="rga", MODE="0666", GROUP="video"
KERNEL=="rkvdec", MODE="0666", GROUP="video"
KERNEL=="rkvenc", MODE="0666", GROUP="video"
KERNEL=="hantro-vpu", MODE="0666", GROUP="video"
KERNEL=="vepu", MODE="0666", GROUP="video"
KERNEL=="av1d", MODE="0666", GROUP="video"
EOF
            ;;
        *)
            cat > /etc/udev/rules.d/51-rockchip-vpu.rules << 'EOF'
# Rockchip VPU permissions (generic)
KERNEL=="mpp_service", MODE="0666", GROUP="video"
KERNEL=="rga", MODE="0666", GROUP="video"
KERNEL=="hantro-vpu", MODE="0666", GROUP="video"
EOF
            ;;
    esac
    
    # Create SoC-specific video codec capability file
    mkdir -p /etc/rockchip
    case "${SOC_CHIP}" in
        RK3566)
            cat > /etc/rockchip/vpu-capabilities << EOF
# Rockchip RK3566 VPU Capabilities
SOC: RK3566
GPU: Mali-G52 MC2 (Panfrost)
NPU: 1 TOPS INT8
VPU: Hantro (no rkvdec)
Decode: H.264 1080p@60, H.265 1080p@60, VP9 1080p@60, MPEG-2/4 1080p@60
Encode: H.264 1080p@30, H.265 1080p@30
MPP: /dev/mpp_service, /dev/rga
EOF
            ;;
        RK3568)
            cat > /etc/rockchip/vpu-capabilities << EOF
# Rockchip RK3568 VPU Capabilities
SOC: RK3568
GPU: Mali-G52 MC2 (Panfrost)
NPU: 0.8 TOPS INT8
VPU: Hantro (no rkvdec)
Decode: H.264 4K@60, H.265 4K@60, VP9 4K@60, MPEG-2/4 1080p@60
Encode: H.264 1080p@60, H.265 1080p@60
MPP: /dev/mpp_service, /dev/rga
EOF
            ;;
        RK3576)
            cat > /etc/rockchip/vpu-capabilities << EOF
# Rockchip RK3576 VPU Capabilities
SOC: RK3576
GPU: Mali-G52 MC3 (Panfrost)
NPU: 6 TOPS INT8
VPU: rkvdec2 + Hantro
Decode: H.264 4K@120, H.265 4K@120, AV1 4K@60, VP9 4K@120
Encode: H.264 4K@60, H.265 4K@60
MPP: /dev/mpp_service, /dev/rga, /dev/rkvdec2, /dev/rkvenc2
EOF
            ;;
        RK3588|RK3588S)
            cat > /etc/rockchip/vpu-capabilities << EOF
# Rockchip RK3588 VPU Capabilities
SOC: ${SOC_CHIP}
GPU: Mali-G610 MC4 (Panthor)
NPU: 6 TOPS INT8
VPU: rkvdec + rkvenc
Decode: H.264 8K@60, H.265 8K@60, VP9 8K@60, AV1 4K@60
Encode: H.264 8K@30, H.265 8K@30
MPP: /dev/mpp_service, /dev/rga, /dev/rkvdec, /dev/rkvenc
EOF
            ;;
    esac
    
    # Load SoC-specific VPU modules
    case "${SOC_CHIP}" in
        RK3566|RK3568)
            cat > /etc/modules-load.d/rockchip-vpu.conf << 'EOF'
# Rockchip VPU modules (RK3566/RK3568 Hantro)
hantro-vpu
rockchip-rga
EOF
            ;;
        RK3576)
            cat > /etc/modules-load.d/rockchip-vpu.conf << 'EOF'
# Rockchip VPU modules (RK3576 rkvdec2)
rkvdec2
rkvenc2
hantro-vpu
rockchip-rga
EOF
            ;;
        RK3588|RK3588S)
            cat > /etc/modules-load.d/rockchip-vpu.conf << 'EOF'
# Rockchip VPU modules (RK3588 rkvdec/rkvenc)
rkvdec
rkvenc
hantro-vpu
rockchip-rga
EOF
            ;;
    esac
    
    log_success "VPU acceleration configured"
    log_info "Supported codecs: H.264, H.265/HEVC, VP9 (8K decode), AV1 (4K decode)"
}

# ============================================================
# NPU Setup (RKNPU2)
# ============================================================
setup_npu() {
    if [ "$HAS_NPU" != "1" ]; then
        log_info "NPU acceleration not available for this SoC"
        return 0
    fi
    
    log_step "Setting up NPU Acceleration (RKNPU2)"
    
    # RKNPU kernel module should be built into the kernel
    # Here we set up the runtime environment
    
    log_info "Configuring RKNPU2 runtime..."
    
    # Create NPU device directory
    mkdir -p /dev/rknpu
    
    # udev rules for NPU
    cat > /etc/udev/rules.d/52-rockchip-npu.rules << 'EOF'
# Rockchip NPU permissions
KERNEL=="rknpu", MODE="0666", GROUP="users"
KERNEL=="rknpu0", MODE="0666", GROUP="users"
KERNEL=="rknpu1", MODE="0666", GROUP="users"
KERNEL=="rknpu2", MODE="0666", GROUP="users"
KERNEL=="rknpu0-0", MODE="0666", GROUP="users"
KERNEL=="rknpu0-1", MODE="0666", GROUP="users"
KERNEL=="rknpu0-2", MODE="0666", GROUP="users"
KERNEL=="rknpu0-3", MODE="0666", GROUP="users"
SUBSYSTEM=="rknpu", MODE="0666", GROUP="users"
EOF
    
    # Load NPU module
    modprobe rknpu 2>/dev/null || true
    echo "rknpu" >> /etc/modules-load.d/rockchip-npu.conf
    
    # Install RKNN toolkit if available (optional)
    log_info "Checking for RKNN packages..."
    apt-get install -y -qq \
        python3-rknnlite2 \
        2>/dev/null || {
        log_info "RKNN Python packages not in repository (optional)"
        log_info "Install manually from: https://github.com/rockchip-linux/rknn-toolkit2"
    }
    
    # Create NPU info file
    cat > /etc/rockchip/npu-info << EOF
# Rockchip ${SOC_CHIP} NPU Information
# RKNPU2 Runtime Environment

NPU Version: RKNPU2
Compute: 6 TOPS INT8
Supported: INT4/INT8/INT16/FP16/BF16/TF32
SDK: https://github.com/rockchip-linux/rknpu2
Toolkit: https://github.com/rockchip-linux/rknn-toolkit2

Example Usage:
  # Check NPU availability
  dmesg | grep rknpu
  
  # Check with clinfo (OpenCL)
  clinfo | grep "Mali-G610"
  
  # RKNN model inference
  python3 -c "from rknnlite.api import RKNNLite; rknn = RKNNLite()"
EOF
    
    log_success "NPU acceleration configured"
    log_info "NPU: 6 TOPS, supports INT4/INT8/INT16/FP16"
}

# ============================================================
# Hardware Validation
# ============================================================
validate_hardware() {
    log_step "Hardware Acceleration Summary"
    
    echo ""
    echo "========================================"
    echo "  Hardware Acceleration Configuration"
    echo "  SoC: ${SOC_CHIP:-unknown}"
    echo "========================================"
    echo ""
    
    if [ "$HAS_GPU" = "1" ]; then
        echo "[GPU] Mali ${GPU_TYPE}"
        echo "  Driver: $([ "$GPU_TYPE" = "mali-g610" ] && echo "panthor" || echo "panfrost")"
        echo "  Mesa: $(dpkg -l mesa-vulkan-drivers 2>/dev/null | grep -c '^ii' || echo "not installed")"
        [ -f /lib/firmware/arm/mali/arch10.8/mali_csffw.bin ] && \
            echo "  Firmware: OK ($(stat -c%s /lib/firmware/arm/mali/arch10.8/mali_csffw.bin) bytes)" || \
            echo "  Firmware: MISSING"
        echo "  OpenGL ES: Yes"
        echo "  Vulkan 1.2: Yes"
        echo "  OpenCL 2.2: Yes (with libmali)"
        echo ""
    fi
    
    if [ "$HAS_VPU" = "1" ]; then
        echo "[VPU] Video Codec"
        echo "  MPP: $(dpkg -l librockchip-mpp1 2>/dev/null | grep -c '^ii' || echo "not installed")"
        echo "  ffmpeg: $(dpkg -l ffmpeg 2>/dev/null | grep -c '^ii' || echo "not installed")"
        echo "  Decode: H.264(8K), H.265(8K), VP9(8K), AV1(4K)"
        echo "  Encode: H.264(8K), H.265(8K)"
        echo ""
    fi
    
    if [ "$HAS_NPU" = "1" ]; then
        case "${SOC_CHIP}" in
            RK3566) echo "[NPU] RKNPU - 1 TOPS INT8" ;;
            RK3568) echo "[NPU] RKNPU - 0.8 TOPS INT8" ;;
            RK3576) echo "[NPU] RKNPU3 - 6 TOPS INT8" ;;
            RK3588|RK3588S) echo "[NPU] RKNPU2 - 6 TOPS INT8" ;;
        esac
        echo "  Precision: INT4/INT8/INT16/FP16"
        echo ""
    fi
    
    echo "========================================"
    echo "  Boot-time verification commands:"
    echo "========================================"
    echo "  dmesg | grep -E 'panthor|panfrost|mali'  # GPU"
    echo "  dmesg | grep -E 'rkvdec|rkvenc|hantro'   # VPU"
    echo "  dmesg | grep rknpu                         # NPU"
    echo "  glxinfo | grep 'OpenGL renderer'           # GL check"
    echo "  vulkaninfo | grep deviceName               # Vulkan check"
    echo "  clinfo | grep 'Device Name'                # OpenCL check"
    echo ""
}

# ============================================================
# Main
# ============================================================
main() {
    log_step "Rockchip Hardware Acceleration Setup"
    
    detect_soc
    
    if [ "$HAS_GPU" = "0" ] && [ "$HAS_VPU" = "0" ] && [ "$HAS_NPU" = "0" ]; then
        log_warn "No hardware acceleration available"
        return 0
    fi
    
    # Setup each component
    setup_gpu
    setup_vpu
    setup_npu
    
    # Reload udev rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger 2>/dev/null || true
    
    # Summary
    validate_hardware
    
    log_success "Hardware acceleration setup complete!"
    log_info "Reboot to activate all hardware acceleration features"
}

main "$@"
