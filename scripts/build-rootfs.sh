#!/bin/bash
# Build Deepin 25 (Crimson) ARM64 Root Filesystem
# Uses mmdebstrap for clean rootfs creation with multi-source support
# Optimized for QEMU user-mode emulation speed
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
        echo "[$(date '+%H:%M:%S')] [RootFS] [$1] $2" >> "$LOG_MAIN" 2>/dev/null || true
    fi
}

log_info() { echo -e "${BLUE}[INFO]${NC} [rootfs] $1"; _log_write "INFO" "$1"; }
log_success() { echo -e "${GREEN}[OK]${NC} [rootfs] $1"; _log_write "OK" "$1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} [rootfs] $1"; _log_write "WARN" "$1"; }
log_error() { echo -e "${RED}[ERROR]${NC} [rootfs] $1"; _log_write "ERROR" "$1"; }
log_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [RootFS] $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    _log_write "STEP" "$1"
}

# Check required environment
if [ -z "$ROOTFS_MOUNT" ] || [ -z "$SOC_CHIP" ]; then
    log_error "Required environment variables not set. Run from build.sh."
    exit 1
fi

log_step "Building Deepin 25 Root Filesystem"

# Source profile setup
SOURCE_PROFILE="${SOURCE_PROFILE:-stable}"
SOURCES_DIR="${SOURCES_DIR:-${SCRIPT_DIR}/overlays/sources}"
CUSTOM_SOURCES="${CUSTOM_SOURCES:-}"

# Build speed mode: "fast" (no merged-usr hook) or "compat" (with merged-usr)
# "fast" is 2-3x faster but may have compatibility issues with some packages
BUILD_MODE="${BUILD_MODE:-auto}"

# Determine source file
if [ "$SOURCE_PROFILE" = "custom" ]; then
    SOURCE_FILE="$CUSTOM_SOURCES"
    log_info "Using custom sources: ${SOURCE_FILE}"
else
    SOURCE_FILE="${SOURCES_DIR}/${SOURCE_PROFILE}.list"
    log_info "Source profile: ${SOURCE_PROFILE}"
fi

if [ ! -f "$SOURCE_FILE" ]; then
    log_error "Source file not found: ${SOURCE_FILE}"
    log_info "Available profiles:"
    ls -1 "${SOURCES_DIR}"/*.list 2>/dev/null | sed 's/.*\//  /' | sed 's/.list$//' || true
    exit 1
fi

# Extract primary repository for mmdebstrap
REPOS=$(grep "^deb " "$SOURCE_FILE" | head -1 | sed 's/^deb //')
if [ -z "$REPOS" ]; then
    log_error "No valid deb repository found in ${SOURCE_FILE}"
    exit 1
fi

log_info "Primary repository: ${REPOS}"

# Deepin 25 settings
export dist_version="crimson"
export dist_name="deepin"
export arch="arm64"

# Core packages (NOTE: do not duplicate packages here!)
CORE_PACKAGES="ca-certificates,locales,sudo,apt,adduser,polkitd,systemd,network-manager,dbus-daemon,apt-utils,bash-completion,curl,vim,bash,deepin-keyring,init,ssh,net-tools,iputils-ping,lshw,iproute2,iptables,procps,wpasupplicant,dmidecode,ntpsec-ntpdate,linux-firmware,fdisk,initramfs-tools,isc-dhcp-client,pciutils,usbutils"

# Desktop-specific packages
DESKTOP_PACKAGES=""
CLI_PACKAGES=""

case "${DESKTOP}" in
    dde)
        log_info "Desktop: Deepin Desktop Environment (DDE)"
        # Minimal DDE - core only to save space
        # deepin-desktop-environment-base pulls in most needed packages
        # extras removed (too large: seetaface themes etc)
        # firefox removed (install separately if needed)
        DESKTOP_PACKAGES="deepin-desktop-environment-core,deepin-desktop-environment-base,ddm,xserver-xorg"
        ;;
    minimal)
        log_info "Desktop: Minimal (no GUI)"
        ;;
    server)
        log_info "Desktop: Server mode"
        CLI_PACKAGES="nginx,tor,openssh-server,ufw,fail2ban,smartmontools"
        ;;
    *)
        log_warn "Unknown desktop '${DESKTOP}', using minimal"
        DESKTOP="minimal"
        ;;
esac

ALL_PACKAGES="${CORE_PACKAGES}"
[ -n "$DESKTOP_PACKAGES" ] && ALL_PACKAGES="${ALL_PACKAGES},${DESKTOP_PACKAGES}"
[ -n "$CLI_PACKAGES" ] && ALL_PACKAGES="${ALL_PACKAGES},${CLI_PACKAGES}"
[ -n "$EXTRA_PACKAGES" ] && ALL_PACKAGES="${ALL_PACKAGES},${EXTRA_PACKAGES}"

if [[ "$SOURCE_PROFILE" == *"hwe"* ]]; then
    log_info "Adding HWE-specific packages..."
    HWE_PACKAGES="firmware-linux-nonfree,firmware-misc-nonfree"
    ALL_PACKAGES="${ALL_PACKAGES},${HWE_PACKAGES}"
fi

# ============================================================
# Speed Optimization: Install Prerequisites
# ============================================================

log_step "Configuring Speed Optimizations"

# Detect QEMU usage
if [ "$(uname -m)" != "aarch64" ]; then
    log_warn "Detected x86_64 host - QEMU user-mode emulation will be used"
    log_warn "This is inherently slower than native ARM64 builds"
    IS_CROSS_COMPILE=1
else
    IS_CROSS_COMPILE=0
fi

# Auto-detect build mode
if [ "$BUILD_MODE" = "auto" ]; then
    if [ "$IS_CROSS_COMPILE" = 1 ]; then
        BUILD_MODE="fast"
        log_info "Auto-selected FAST mode for QEMU cross-compile (2-3x speedup)"
    else
        BUILD_MODE="compat"
        log_info "Auto-selected COMPAT mode for native ARM64 build"
    fi
fi

# Install eatmydata (critical for speed)
if ! command -v eatmydata &>/dev/null; then
    log_info "Installing eatmydata..."
    apt-get update -qq && apt-get install -y -qq eatmydata 2>/dev/null || {
        log_warn "eatmydata install failed - build will be slower"
    }
fi

# Find eatmydata library for later use
EATMYDATA_LIB=""
for path in /usr/lib/x86_64-linux-gnu/libeatmydata.so \
          /usr/lib/aarch64-linux-gnu/libeatmydata.so \
          /usr/lib/libeatmydata.so; do
    if [ -f "$path" ]; then
        EATMYDATA_LIB="$path"
        break
    fi
done

if [ -n "$EATMYDATA_LIB" ]; then
    log_success "Found eatmydata: ${EATMYDATA_LIB}"
else
    log_warn "eatmydata library not found"
fi

# ============================================================
# GPG Key Setup for mmdebstrap
# ============================================================

log_step "Setting up Deepin GPG Keys"

# Deepin keys needed for repository verification
DEEPIN_KEYS=(
    "425956BB3E31DF51"
    "F5575F0BCD17A2D3"
)

# Create a temporary keyring for mmdebstrap (must be binary OpenPGP format)
KEYRING_DIR="${WORKSPACE}/keyrings"
mkdir -p "$KEYRING_DIR"
KEYRING_FILE="${KEYRING_DIR}/deepin-keyring.gpg"
rm -f "$KEYRING_FILE" "${KEYRING_FILE}.tmp"

# Use gpg to export in binary OpenPGP format (not GnuPG's internal .kbx format)
_keyring_add_key() {
    local keyid="$1"
    local key_armored="${KEYRING_DIR}/key-${keyid}.asc"
    
    # Fetch key as ASCII armored from keyserver
    log_info "Fetching GPG key ${keyid}..."
    
    # Try multiple keyservers
    for server in "keyserver.ubuntu.com" "keys.openpgp.org" "pgp.mit.edu"; do
        if gpg --no-default-keyring --no-options \
               --keyserver "${server}" \
               --recv-keys "$keyid" 2>/dev/null; then
            log_info "Key ${keyid} fetched from ${server}"
            break
        fi
    done
    
    # Export to binary OpenPGP format (apt/mmdebstrap compatible)
    if gpg --no-default-keyring --no-options --export "$keyid" > "$key_armored" 2>/dev/null; then
        cat "$key_armored" >> "${KEYRING_FILE}.tmp"
        rm -f "$key_armored"
        return 0
    fi
    
    # Fallback: download directly as armored from keyserver
    log_info "Trying direct HTTP download for key ${keyid}..."
    if curl -sL --max-time 30 \
        "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${keyid}" \
        -o "$key_armored" 2>/dev/null; then
        # Dearmor and append to keyring
        gpg --dearmor < "$key_armored" >> "${KEYRING_FILE}.tmp" 2>/dev/null
        rm -f "$key_armored"
        return 0
    fi
    
    return 1
}

# Build binary keyring from all keys
for keyid in "${DEEPIN_KEYS[@]}"; do
    _keyring_add_key "$keyid" || {
        log_warn "Failed to add key ${keyid}"
    }
done

# Verify and finalize keyring
if [ -f "${KEYRING_FILE}.tmp" ] && [ "$(stat -c%s "${KEYRING_FILE}.tmp" 2>/dev/null || echo 0)" -gt 100 ]; then
    mv "${KEYRING_FILE}.tmp" "$KEYRING_FILE"
    KEY_COUNT=$(gpg --dry-run --import "$KEYRING_FILE" 2>&1 | grep -c "^gpg:" || echo 0)
    log_success "GPG keyring ready (${KEY_COUNT} keys)"
    MMDEBSTRAP_OPTS+=(--keyring="$KEYRING_FILE")
else
    rm -f "${KEYRING_FILE}.tmp"
    log_warn "No GPG keys could be imported"
    log_info "Falling back to --allow-unsigned"
    MMDEBSTRAP_OPTS+=(--allow-unsigned)
fi

# ============================================================
# Build Rootfs
# ============================================================

log_step "Running mmdebstrap (mode: ${BUILD_MODE})"
log_info "Start time: $(date '+%H:%M:%S')"
BUILD_START_TS=$(date +%s)

# Base mmdebstrap options (always used)
MMDEBSTRAP_OPTS=(
    --skip=check/empty
    --dpkgopt='force-unsafe-io'
    --dpkgopt='force-confold'
    --dpkgopt='force-confdef'
    --aptopt="Acquire::Queue-Mode=host"
    --aptopt="Acquire::Parallelization=5"
    --aptopt="Acquire::Retries=3"
    --aptopt="APT::Install-Recommends=false"
    --aptopt="APT::Install-Suggests=false"
    --aptopt="Acquire::http::Timeout=30"
    --aptopt="Acquire::https::Timeout=30"
    --include="$ALL_PACKAGES"
    --components="main,commercial,community"
    --variant=minbase
    --architectures="${arch}"
)

# Add hook directory only in compat mode (the slow part!)
if [ "$BUILD_MODE" = "compat" ]; then
    if [ -d /usr/share/mmdebstrap/hooks/merged-usr ]; then
        log_info "Using merged-usr hook (slower but maximum compatibility)"
        MMDEBSTRAP_OPTS+=(--hook-dir=/usr/share/mmdebstrap/hooks/merged-usr)
    else
        log_warn "merged-usr hook not found, running without hooks"
    fi
else
    log_info "Fast mode: no hooks (maximum speed)"
fi

# Add verbose output for progress visibility
MMDEBSTRAP_OPTS+=(--verbose)

# Run mmdebstrap directly (eatmydata wrapper causes LD_PRELOAD errors in chroot)
# --dpkgopt='force-unsafe-io' already skips fsync, so eatmydata provides no benefit
log_info "Starting mmdebstrap..."
log_info "If this appears to hang, it's likely downloading packages. Be patient (5-30 mins)..."
mmdebstrap "${MMDEBSTRAP_OPTS[@]}" \
    "${dist_version}" \
    "${ROOTFS_MOUNT}" \
    "${REPOS}" &

# Monitor progress
MMDEBSTRAP_PID=$!
log_info "mmdebstrap PID: ${MMDEBSTRAP_PID}"

# Show periodic heartbeat while mmdebstrap runs
COUNTER=0
while kill -0 "$MMDEBSTRAP_PID" 2>/dev/null; do
    sleep 10
    COUNTER=$((COUNTER + 10))
    # Show progress every 30 seconds
    if [ $((COUNTER % 30)) -eq 0 ]; then
        MIN=$((COUNTER / 60))
        SEC=$((COUNTER % 60))
        if [ "$MIN" -gt 0 ]; then
            log_info "Still running... ${MIN}m${SEC}s elapsed (downloading/installing packages)"
        else
            log_info "Still running... ${SEC}s elapsed"
        fi
        # Show disk activity
        ROOTFS_SIZE_MB=$(du -sm "${ROOTFS_MOUNT}" 2>/dev/null | cut -f1 || echo "0")
        if [ "$ROOTFS_SIZE_MB" -gt 10 ]; then
            log_info "Rootfs size so far: ${ROOTFS_SIZE_MB} MB"
        fi
    fi
done

# Wait for mmdebstrap to finish and capture exit code
wait "$MMDEBSTRAP_PID"
MMDEBSTRAP_EXIT=$?

if [ "$MMDEBSTRAP_EXIT" -ne 0 ]; then
    log_error "mmdebstrap failed with exit code ${MMDEBSTRAP_EXIT}"
    exit 1
fi

BUILD_END_TS=$(date +%s)
BUILD_DURATION=$((BUILD_END_TS - BUILD_START_TS))
DURATION_MIN=$((BUILD_DURATION / 60))
DURATION_SEC=$((BUILD_DURATION % 60))

log_success "Rootfs created in ${DURATION_MIN}m ${DURATION_SEC}s"

# ============================================================
# Post-Install Speed Optimizations in Chroot
# ============================================================

log_step "Applying Post-Install Optimizations"

# Mount virtual filesystems for chroot
mount --bind/dev "${ROOTFS_MOUNT}/dev" 2>/dev/null || true
mount -t proc proc "${ROOTFS_MOUNT}/proc" 2>/dev/null || true
mount -t sysfs sysfs "${ROOTFS_MOUNT}/sys" 2>/dev/null || true

# Copy eatmydata library into chroot (if found on host) + install via apt
if [ -n "$EATMYDATA_LIB" ] && [ -f "$EATMYDATA_LIB" ]; then
    log_info "Copying eatmydata library into chroot..."
    mkdir -p "${ROOTFS_MOUNT}/usr/lib/aarch64-linux-gnu"
    cp -v "$EATMYDATA_LIB" "${ROOTFS_MOUNT}/usr/lib/aarch64-linux-gnu/" 2>/dev/null || true
fi

# Install eatmydata inside the chroot and configure speed settings
chroot "${ROOTFS_MOUNT}" /bin/bash -c '
    export DEBIAN_FRONTEND=noninteractive
    # Install eatmydata if not present
    if ! command -v eatmydata &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq eatmydata 2>/dev/null || true
    fi
    # Configure dpkg for speed (permanent)
    mkdir -p /etc/dpkg/dpkg.cfg.d
    echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/02speed
    echo "force-confold" >> /etc/dpkg/dpkg.cfg.d/02speed
    echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/unsafe-io
    # Create dpkg-fast wrapper
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/dpkg-fast << \EOF
#!/bin/bash
exec eatmydata /usr/bin/dpkg "$@"
EOF
    chmod +x /usr/local/bin/dpkg-fast
' || log_warn "Chroot post-setup partially failed"

# ============================================================
# Configure APT Sources in RootFS
# ============================================================

log_step "Configuring APT Sources"

# Copy full sources
cat > "${ROOTFS_MOUNT}/etc/apt/sources.list" << EOF
# Deepin 25 (Crimson) - Generated by Rockchip Image Builder
# Source Profile: ${SOURCE_PROFILE}
# Board: ${BOARD_NAME} (${BOARD})
# Build Date: $(date -Iseconds)
#
EOF
cat "$SOURCE_FILE" >> "${ROOTFS_MOUNT}/etc/apt/sources.list"

# Copy APT priority/pinning configuration if exists
PREF_FILE="${SOURCES_DIR}/${SOURCE_PROFILE}-priority.pref"
if [ -f "$PREF_FILE" ]; then
    log_info "Applying APT priority configuration..."
    mkdir -p "${ROOTFS_MOUNT}/etc/apt/preferences.d"
    cp "$PREF_FILE" "${ROOTFS_MOUNT}/etc/apt/preferences.d/10rockchip-builder.pref"
fi

# Keep reasonable speed settings in final system
cat > "${ROOTFS_MOUNT}/etc/apt/apt.conf.d/99speed" << 'APTCONF'
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
APT::Get::Assume-Yes "false";
APTCONF

# Show configured sources
log_info "Configured APT sources:"
grep "^deb " "${ROOTFS_MOUNT}/etc/apt/sources.list" | while read -r line; do
    echo "  ${line}"
done

# Unmount virtual filesystems
umount "${ROOTFS_MOUNT}/proc" 2>/dev/null || true
umount "${ROOTFS_MOUNT}/sys" 2>/dev/null || true
umount "${ROOTFS_MOUNT}/dev" 2>/dev/null || true

# Show what was created
log_info "Rootfs disk usage:"
df -h "${ROOTFS_MOUNT}" | head -2
log_info "Package count:"
chroot "${ROOTFS_MOUNT}" dpkg -l 2>/dev/null | wc -l | xargs echo "  Total packages:"

log_success "RootFS complete! (${DURATION_MIN}m ${DURATION_SEC}s)"
