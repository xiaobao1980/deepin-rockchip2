#!/bin/bash
#===============================================================================
# 01-build-uboot.sh - U-Boot 与 Trusted Firmware-A 编译脚本
# 用途: 编译 RK3588/RK3576 多板卡 U-Boot 引导程序
# 支持: 15+ 款 Rockchip 开发板
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

#------------------------------------------------------------------------------
# 加载构建配置
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.buildconfig" ]; then
    source "${SCRIPT_DIR}/.buildconfig"
else
    BUILD_ROOT="${SCRIPT_DIR}"
    SOURCE_DIR="${BUILD_ROOT}/sources"
    OUTPUT_DIR="${BUILD_ROOT}/output"
    UBOOT_VERSION="v2025.07"
    TFA_VERSION="v2.13.0"
    RKBIN_REPO="https://github.com/armbian/rkbin"
    UBOOT_REPO="https://github.com/u-boot/u-boot"
    TFA_REPO="https://github.com/TrustedFirmware-A/trusted-firmware-a"
    JOBS=$(nproc)
    CROSS_COMPILE="aarch64-linux-gnu-"
    ARCH="arm64"
fi

#------------------------------------------------------------------------------
# 板卡配置数据库 (基于 armbian-build config/boards)
# 覆盖 RK3566 / RK3568 / RK3576 / RK3588 / RK3399
#------------------------------------------------------------------------------
declare -A BOARD_DEFCONFIGS
declare -A BOARD_PLATS
declare -A BOARD_DESC

# ======== RK3566 (四核 Cortex-A55, Mali-G52) ========
BOARD_DEFCONFIGS[rk3566-generic]="generic-rk3566_defconfig"
BOARD_PLATS[rk3566-generic]="rk3566"
BOARD_DESC[rk3566-generic]="RK3566 Generic"

BOARD_DEFCONFIGS[rk3566-rock-3c]="rock-3c-rk3566_defconfig"
BOARD_PLATS[rk3566-rock-3c]="rk3566"
BOARD_DESC[rk3566-rock-3c]="Radxa Rock 3C"

BOARD_DEFCONFIGS[rk3566-quartz64a]="quartz64-a-rk3566_defconfig"
BOARD_PLATS[rk3566-quartz64a]="rk3566"
BOARD_DESC[rk3566-quartz64a]="PINE64 Quartz64 Model A"

BOARD_DEFCONFIGS[rk3566-quartz64b]="quartz64-b-rk3566_defconfig"
BOARD_PLATS[rk3566-quartz64b]="rk3566"
BOARD_DESC[rk3566-quartz64b]="PINE64 Quartz64 Model B"

BOARD_DEFCONFIGS[rk3566-orangepi-3b]="orangepi-3b-rk3566_defconfig"
BOARD_PLATS[rk3566-orangepi-3b]="rk3566"
BOARD_DESC[rk3566-orangepi-3b]="Orange Pi 3B"

BOARD_DEFCONFIGS[rk3566-luckfox-core3566]="luckfox-core3566-rk3566_defconfig"
BOARD_PLATS[rk3566-luckfox-core3566]="rk3566"
BOARD_DESC[rk3566-luckfox-core3566]="Luckfox Core3566"

BOARD_DEFCONFIGS[rk3566-h96-tvbox]="h96-tvbox-3566-rk3566_defconfig"
BOARD_PLATS[rk3566-h96-tvbox]="rk3566"
BOARD_DESC[rk3566-h96-tvbox]="H96 TV Box 3566"

BOARD_DEFCONFIGS[rk3566-rk3566-box-demo]="rk3566-box-demo-rk3566_defconfig"
BOARD_PLATS[rk3566-rk3566-box-demo]="rk3566"
BOARD_DESC[rk3566-rk3566-box-demo]="RK3566 Box Demo"

# ======== RK3568 (四核 Cortex-A55, Mali-G52) ========
BOARD_DEFCONFIGS[rk3568-generic]="generic-rk3568_defconfig"
BOARD_PLATS[rk3568-generic]="rk3568"
BOARD_DESC[rk3568-generic]="RK3568 Generic"

BOARD_DEFCONFIGS[rk3568-rock-3a]="rock-3a-rk3568_defconfig"
BOARD_PLATS[rk3568-rock-3a]="rk3568"
BOARD_DESC[rk3568-rock-3a]="Radxa Rock 3A"

BOARD_DEFCONFIGS[rk3568-nanopi-r5s]="nanopi-r5s-rk3568_defconfig"
BOARD_PLATS[rk3568-nanopi-r5s]="rk3568"
BOARD_DESC[rk3568-nanopi-r5s]="FriendlyELEC NanoPi R5S"

BOARD_DEFCONFIGS[rk3568-nanopi-r5c]="nanopi-r5c-rk3568_defconfig"
BOARD_PLATS[rk3568-nanopi-r5c]="rk3568"
BOARD_DESC[rk3568-nanopi-r5c]="FriendlyELEC NanoPi R5C"

BOARD_DEFCONFIGS[rk3568-nanopi-r3s]="nanopi-r3s-rk3568_defconfig"
BOARD_PLATS[rk3568-nanopi-r3s]="rk3568"
BOARD_DESC[rk3568-nanopi-r3s]="FriendlyELEC NanoPi R3S"

BOARD_DEFCONFIGS[rk3568-nanopi-r3s-lts]="nanopi-r3s-lts-rk3568_defconfig"
BOARD_PLATS[rk3568-nanopi-r3s-lts]="rk3568"
BOARD_DESC[rk3568-nanopi-r3s-lts]="FriendlyELEC NanoPi R3S LTS"

BOARD_DEFCONFIGS[rk3568-nanopi-m5]="nanopi-m5-rk3568_defconfig"
BOARD_PLATS[rk3568-nanopi-m5]="rk3568"
BOARD_DESC[rk3568-nanopi-m5]="FriendlyELEC NanoPi M5"

BOARD_DEFCONFIGS[rk3568-odroid-m1]="odroid-m1-rk3568_defconfig"
BOARD_PLATS[rk3568-odroid-m1]="rk3568"
BOARD_DESC[rk3568-odroid-m1]="ODROID M1"

BOARD_DEFCONFIGS[rk3568-odroid-m1s]="odroid-m1s-rk3568_defconfig"
BOARD_PLATS[rk3568-odroid-m1s]="rk3568"
BOARD_DESC[rk3568-odroid-m1s]="ODROID M1S"

BOARD_DEFCONFIGS[rk3568-bananapi-m4zero]="bananapi-m4-zero-rk3568_defconfig"
BOARD_PLATS[rk3568-bananapi-m4zero]="rk3568"
BOARD_DESC[rk3568-bananapi-m4zero]="Banana Pi M4 Zero"

BOARD_DEFCONFIGS[rk3568-bananapi-m4berry]="bananapi-m4-berry-rk3568_defconfig"
BOARD_PLATS[rk3568-bananapi-m4berry]="rk3568"
BOARD_DESC[rk3568-bananapi-m4berry]="Banana Pi M4 Berry"

BOARD_DEFCONFIGS[rk3568-radxa-e25]="radxa-e25-rk3568_defconfig"
BOARD_PLATS[rk3568-radxa-e25]="rk3568"
BOARD_DESC[rk3568-radxa-e25]="Radxa E25"

BOARD_DEFCONFIGS[rk3568-radxa-e20c]="radxa-e20c-rk3568_defconfig"
BOARD_PLATS[rk3568-radxa-e20c]="rk3568"
BOARD_DESC[rk3568-radxa-e20c]="Radxa E20C"

BOARD_DEFCONFIGS[rk3568-radxa-e24c]="radxa-e24c-rk3568_defconfig"
BOARD_PLATS[rk3568-radxa-e24c]="rk3568"
BOARD_DESC[rk3568-radxa-e24c]="Radxa E24C"

BOARD_DEFCONFIGS[rk3568-hinlink-h28k]="hinlink-h28k-rk3568_defconfig"
BOARD_PLATS[rk3568-hinlink-h28k]="rk3568"
BOARD_DESC[rk3568-hinlink-h28k]="Hinlink H28K"

BOARD_DEFCONFIGS[rk3568-hinlink-h66k]="hinlink-h66k-rk3568_defconfig"
BOARD_PLATS[rk3568-hinlink-h66k]="rk3568"
BOARD_DESC[rk3568-hinlink-h66k]="Hinlink H66K"

BOARD_DEFCONFIGS[rk3568-hinlink-h68k]="hinlink-h68k-rk3568_defconfig"
BOARD_PLATS[rk3568-hinlink-h68k]="rk3568"
BOARD_DESC[rk3568-hinlink-h68k]="Hinlink H68K"

BOARD_DEFCONFIGS[rk3568-hinlink-h88k]="hinlink-h88k-rk3568_defconfig"
BOARD_PLATS[rk3568-hinlink-h88k]="rk3568"
BOARD_DESC[rk3568-hinlink-h88k]="Hinlink H88K"

BOARD_DEFCONFIGS[rk3568-hinlink-hnas]="hinlink-hnas-rk3568_defconfig"
BOARD_PLATS[rk3568-hinlink-hnas]="rk3568"
BOARD_DESC[rk3568-hinlink-hnas]="Hinlink HNAS"

BOARD_DEFCONFIGS[rk3568-hinlink-ht2]="hinlink-ht2-rk3568_defconfig"
BOARD_PLATS[rk3568-hinlink-ht2]="rk3568"
BOARD_DESC[rk3568-hinlink-ht2]="Hinlink HT2"

BOARD_DEFCONFIGS[rk3568-lckfb-taishanpi]="lckfb-taishanpi-rk3568_defconfig"
BOARD_PLATS[rk3568-lckfb-taishanpi]="rk3568"
BOARD_DESC[rk3568-lckfb-taishanpi]="LCKFB TaiShan Pi"

BOARD_DEFCONFIGS[rk3568-norco-emb-3531]="norco-emb-3531-rk3568_defconfig"
BOARD_PLATS[rk3568-norco-emb-3531]="rk3568"
BOARD_DESC[rk3568-norco-emb-3531]="Norco EMB-3531"

BOARD_DEFCONFIGS[rk3568-dusun-dsom-010r]="dusun-dsom-010r-rk3568_defconfig"
BOARD_PLATS[rk3568-dusun-dsom-010r]="rk3568"
BOARD_DESC[rk3568-dusun-dsom-010r]="Dusun DSOM-010R"

BOARD_DEFCONFIGS[rk3568-xiaobao-nas]="xiaobao-nas-rk3568_defconfig"
BOARD_PLATS[rk3568-xiaobao-nas]="rk3568"
BOARD_DESC[rk3568-xiaobao-nas]="XiaoBao NAS"

BOARD_DEFCONFIGS[rk3568-yy3568]="yy3568-rk3568_defconfig"
BOARD_PLATS[rk3568-yy3568]="rk3568"
BOARD_DESC[rk3568-yy3568]="YY3568"

BOARD_DEFCONFIGS[rk3568-9tripod-x3568-v4]="9tripod-x3568-v4-rk3568_defconfig"
BOARD_PLATS[rk3568-9tripod-x3568-v4]="rk3568"
BOARD_DESC[rk3568-9tripod-x3568-v4]="9tripod X3568 V4"

# ======== RK3576 (四核A72+四核A53, Mali-G52 MC3) ========
BOARD_DEFCONFIGS[rk3576-generic]="generic-rk3576_defconfig"
BOARD_PLATS[rk3576-generic]="rk3576"
BOARD_DESC[rk3576-generic]="RK3576 Generic"

BOARD_DEFCONFIGS[rk3576-evb]="evb-rk3576_defconfig"
BOARD_PLATS[rk3576-evb]="rk3576"
BOARD_DESC[rk3576-evb]="RK3576 EVB"

BOARD_DEFCONFIGS[rk3576-rock4d]="rock4d-rk3576_defconfig"
BOARD_PLATS[rk3576-rock4d]="rk3576"
BOARD_DESC[rk3576-rock4d]="Radxa Rock 4D"

BOARD_DEFCONFIGS[rk3576-armsom-sige5]="armsom-sige5-rk3576_defconfig"
BOARD_PLATS[rk3576-armsom-sige5]="rk3576"
BOARD_DESC[rk3576-armsom-sige5]="ArmSoM Sige5"

BOARD_DEFCONFIGS[rk3576-armsom-sige3]="armsom-sige3-rk3576_defconfig"
BOARD_PLATS[rk3576-armsom-sige3]="rk3576"
BOARD_DESC[rk3576-armsom-sige3]="ArmSoM Sige3"

BOARD_DEFCONFIGS[rk3576-armsom-sige1]="armsom-sige1-rk3576_defconfig"
BOARD_PLATS[rk3576-armsom-sige1]="rk3576"
BOARD_DESC[rk3576-armsom-sige1]="ArmSoM Sige1"

BOARD_DEFCONFIGS[rk3576-dshanpi-a1]="dshanpi-a1-rk3576_defconfig"
BOARD_PLATS[rk3576-dshanpi-a1]="rk3576"
BOARD_DESC[rk3576-dshanpi-a1]="DshanPi A1"

BOARD_DEFCONFIGS[rk3576-dshanpi-r1]="dshanpi-r1-rk3576_defconfig"
BOARD_PLATS[rk3576-dshanpi-r1]="rk3576"
BOARD_DESC[rk3576-dshanpi-r1]="DshanPi R1"

BOARD_DEFCONFIGS[rk3576-radxa-e52c]="radxa-e52c-rk3576_defconfig"
BOARD_PLATS[rk3576-radxa-e52c]="rk3576"
BOARD_DESC[rk3576-radxa-e52c]="Radxa E52C"

BOARD_DEFCONFIGS[rk3576-radxa-e54c]="radxa-e54c-rk3576_defconfig"
BOARD_PLATS[rk3576-radxa-e54c]="rk3576"
BOARD_DESC[rk3576-radxa-e54c]="Radxa E54C"

BOARD_DEFCONFIGS[rk3576-youyeetoo-r1-v3]="youyeetoo-r1-v3-rk3576_defconfig"
BOARD_PLATS[rk3576-youyeetoo-r1-v3]="rk3576"
BOARD_DESC[rk3576-youyeetoo-r1-v3]="Youyeetoo R1 V3"

BOARD_DEFCONFIGS[rk3576-forlinx-ok3506-s12]="forlinx-ok3506-s12-rk3576_defconfig"
BOARD_PLATS[rk3576-forlinx-ok3506-s12]="rk3576"
BOARD_DESC[rk3576-forlinx-ok3506-s12]="Forlinx OK3506 S12"

# ======== RK3588 (四核A76+四核A55, Mali-G610) ========
BOARD_DEFCONFIGS[rk3588-generic]="generic-rk3588_defconfig"
BOARD_PLATS[rk3588-generic]="rk3588"
BOARD_DESC[rk3588-generic]="RK3588 Generic EVB"

BOARD_DEFCONFIGS[rk3588-rock5b]="rock5b-rk3588_defconfig"
BOARD_PLATS[rk3588-rock5b]="rk3588"
BOARD_DESC[rk3588-rock5b]="Radxa Rock 5B"

BOARD_DEFCONFIGS[rk3588-rock5a]="rock5a-rk3588s_defconfig"
BOARD_PLATS[rk3588-rock5a]="rk3588"
BOARD_DESC[rk3588-rock5a]="Radxa Rock 5A"

BOARD_DEFCONFIGS[rk3588-rock5c]="rock-5c-rk3588s_defconfig"
BOARD_PLATS[rk3588-rock5c]="rk3588"
BOARD_DESC[rk3588-rock5c]="Radxa Rock 5C"

BOARD_DEFCONFIGS[rk3588-rock5b-plus]="rock-5b-plus-rk3588_defconfig"
BOARD_PLATS[rk3588-rock5b-plus]="rk3588"
BOARD_DESC[rk3588-rock5b-plus]="Radxa Rock 5B Plus"

BOARD_DEFCONFIGS[rk3588-rock5-itx]="rock-5-itx-rk3588_defconfig"
BOARD_PLATS[rk3588-rock5-itx]="rk3588"
BOARD_DESC[rk3588-rock5-itx]="Radxa Rock 5 ITX"

BOARD_DEFCONFIGS[rk3588-rock5-cmio]="rock-5-cmio-rk3588_defconfig"
BOARD_PLATS[rk3588-rock5-cmio]="rk3588"
BOARD_DESC[rk3588-rock5-cmio]="Radxa Rock 5 CMIO"

BOARD_DEFCONFIGS[rk3588-rock5-cm-rpi-cm4-io]="rock-5-cm-rpi-cm4-io-rk3588s_defconfig"
BOARD_PLATS[rk3588-rock5-cm-rpi-cm4-io]="rk3588"
BOARD_DESC[rk3588-rock5-cm-rpi-cm4-io]="Radxa Rock 5 CM + RPI CM4 IO"

BOARD_DEFCONFIGS[rk3588-rock5t]="rock-5t-rk3588_defconfig"
BOARD_PLATS[rk3588-rock5t]="rk3588"
BOARD_DESC[rk3588-rock5t]="Radxa Rock 5T"

BOARD_DEFCONFIGS[rk3588-opi5]="orangepi-5-rk3588_defconfig"
BOARD_PLATS[rk3588-opi5]="rk3588"
BOARD_DESC[rk3588-opi5]="Orange Pi 5"

BOARD_DEFCONFIGS[rk3588-opi5plus]="orangepi-5-plus-rk3588_defconfig"
BOARD_PLATS[rk3588-opi5plus]="rk3588"
BOARD_DESC[rk3588-opi5plus]="Orange Pi 5 Plus"

BOARD_DEFCONFIGS[rk3588-opi5-ultra]="orangepi-5-ultra-rk3588_defconfig"
BOARD_PLATS[rk3588-opi5-ultra]="rk3588"
BOARD_DESC[rk3588-opi5-ultra]="Orange Pi 5 Ultra"

BOARD_DEFCONFIGS[rk3588-opi5-max]="orangepi-5-max-rk3588_defconfig"
BOARD_PLATS[rk3588-opi5-max]="rk3588"
BOARD_DESC[rk3588-opi5-max]="Orange Pi 5 Max"

BOARD_DEFCONFIGS[rk3588-opi5b]="orangepi-5b-rk3588_defconfig"
BOARD_PLATS[rk3588-opi5b]="rk3588"
BOARD_DESC[rk3588-opi5b]="Orange Pi 5B"

BOARD_DEFCONFIGS[rk3588-opi5pro]="orangepi-5-pro-rk3588_defconfig"
BOARD_PLATS[rk3588-opi5pro]="rk3588"
BOARD_DESC[rk3588-opi5pro]="Orange Pi 5 Pro"

BOARD_DEFCONFIGS[rk3588-orangepi-4a]="orangepi-4a-rk3588s_defconfig"
BOARD_PLATS[rk3588-orangepi-4a]="rk3588"
BOARD_DESC[rk3588-orangepi-4a]="Orange Pi 4A"

BOARD_DEFCONFIGS[rk3588-orangepi-4-lts]="orangepi-4-lts-rk3399_defconfig"
BOARD_PLATS[rk3588-orangepi-4-lts]="rk3588"
BOARD_DESC[rk3588-orangepi-4-lts]="Orange Pi 4 LTS"

BOARD_DEFCONFIGS[rk3588-cm3588]="cm3588-nas-rk3588_defconfig"
BOARD_PLATS[rk3588-cm3588]="rk3588"
BOARD_DESC[rk3588-cm3588]="CM3588 NAS"

# 别名: rk3588-cm3588-nas -> rk3588-cm3588
BOARD_DEFCONFIGS[rk3588-cm3588-nas]="cm3588-nas-rk3588_defconfig"
BOARD_PLATS[rk3588-cm3588-nas]="rk3588"
BOARD_DESC[rk3588-cm3588-nas]="CM3588 NAS"

BOARD_DEFCONFIGS[rk3588-coolpi4b]="coolpi-4b-rk3588s_defconfig"
BOARD_PLATS[rk3588-coolpi4b]="rk3588"
BOARD_DESC[rk3588-coolpi4b]="CoolPi 4B"

BOARD_DEFCONFIGS[rk3588-coolpi-cm5]="coolpi-cm5-rk3588_defconfig"
BOARD_PLATS[rk3588-coolpi-cm5]="rk3588"
BOARD_DESC[rk3588-coolpi-cm5]="CoolPi CM5"

BOARD_DEFCONFIGS[rk3588-coolpi-genbook]="coolpi-genbook-rk3588_defconfig"
BOARD_PLATS[rk3588-coolpi-genbook]="rk3588"
BOARD_DESC[rk3588-coolpi-genbook]="CoolPi GenBook"

BOARD_DEFCONFIGS[rk3588-sige7]="armsom-sige7-rk3588_defconfig"
BOARD_PLATS[rk3588-sige7]="rk3588"
BOARD_DESC[rk3588-sige7]="ArmSoM Sige7"

BOARD_DEFCONFIGS[rk3588-nanopi-r6s]="nanopi-r6s-rk3588s_defconfig"
BOARD_PLATS[rk3588-nanopi-r6s]="rk3588"
BOARD_DESC[rk3588-nanopi-r6s]="FriendlyELEC NanoPi R6S"

BOARD_DEFCONFIGS[rk3588-nanopi-r6c]="nanopi-r6c-rk3588s_defconfig"
BOARD_PLATS[rk3588-nanopi-r6c]="rk3588"
BOARD_DESC[rk3588-nanopi-r6c]="FriendlyELEC NanoPi R6C"

BOARD_DEFCONFIGS[rk3588-nanopi-m6]="nanopi-m6-rk3588_defconfig"
BOARD_PLATS[rk3588-nanopi-m6]="rk3588"
BOARD_DESC[rk3588-nanopi-m6]="FriendlyELEC NanoPi M6"

BOARD_DEFCONFIGS[rk3588-nanopct6]="nanopct6-rk3588_defconfig"
BOARD_PLATS[rk3588-nanopct6]="rk3588"
BOARD_DESC[rk3588-nanopct6]="FriendlyELEC NanoPC T6"

BOARD_DEFCONFIGS[rk3588-nanopct6-lts]="nanopct6-lts-rk3588_defconfig"
BOARD_PLATS[rk3588-nanopct6-lts]="rk3588"
BOARD_DESC[rk3588-nanopct6-lts]="FriendlyELEC NanoPC T6 LTS"

BOARD_DEFCONFIGS[rk3588-roc-pc]="roc-pc-rk3588s_defconfig"
BOARD_PLATS[rk3588-roc-pc]="rk3588"
BOARD_DESC[rk3588-roc-pc]="Station P3/ROC-PC"

BOARD_DEFCONFIGS[rk3588-station-m3]="station-m3-rk3588s_defconfig"
BOARD_PLATS[rk3588-station-m3]="rk3588"
BOARD_DESC[rk3588-station-m3]="Station M3"

BOARD_DEFCONFIGS[rk3588-bananapi-m7]="bananapi-m7-rk3588_defconfig"
BOARD_PLATS[rk3588-bananapi-m7]="rk3588"
BOARD_DESC[rk3588-bananapi-m7]="Banana Pi M7"

BOARD_DEFCONFIGS[rk3588-bananapi-m5pro]="bananapi-m5-pro-rk3588_defconfig"
BOARD_PLATS[rk3588-bananapi-m5pro]="rk3588"
BOARD_DESC[rk3588-bananapi-m5pro]="Banana Pi M5 Pro"

BOARD_DEFCONFIGS[rk3588-khadas-edge2]="khadas-edge2-rk3588_defconfig"
BOARD_PLATS[rk3588-khadas-edge2]="rk3588"
BOARD_DESC[rk3588-khadas-edge2]="Khadas Edge 2"

BOARD_DEFCONFIGS[rk3588-turing-rk1]="turing-rk1-rk3588_defconfig"
BOARD_PLATS[rk3588-turing-rk1]="rk3588"
BOARD_DESC[rk3588-turing-rk1]="Turing RK1"

BOARD_DEFCONFIGS[rk3588-mixtile-blade3]="mixtile-blade3-rk3588_defconfig"
BOARD_PLATS[rk3588-mixtile-blade3]="rk3588"
BOARD_DESC[rk3588-mixtile-blade3]="Mixtile Blade 3"

BOARD_DEFCONFIGS[rk3588-mixtile-core3588e]="mixtile-core3588e-rk3588_defconfig"
BOARD_PLATS[rk3588-mixtile-core3588e]="rk3588"
BOARD_DESC[rk3588-mixtile-core3588e]="Mixtile Core 3588E"

BOARD_DEFCONFIGS[rk3588-mixtile-edge2]="mixtile-edge2-rk3588_defconfig"
BOARD_PLATS[rk3588-mixtile-edge2]="rk3588"
BOARD_DESC[rk3588-mixtile-edge2]="Mixtile Edge 2"

BOARD_DEFCONFIGS[rk3588-mekotronics-r58x]="mekotronics-r58x-rk3588_defconfig"
BOARD_PLATS[rk3588-mekotronics-r58x]="rk3588"
BOARD_DESC[rk3588-mekotronics-r58x]="Mekotronics R58X"

BOARD_DEFCONFIGS[rk3588-mekotronics-r58x-pro]="mekotronics-r58x-pro-rk3588_defconfig"
BOARD_PLATS[rk3588-mekotronics-r58x-pro]="rk3588"
BOARD_DESC[rk3588-mekotronics-r58x-pro]="Mekotronics R58X Pro"

BOARD_DEFCONFIGS[rk3588-mekotronics-r58x-4g]="mekotronics-r58x-4g-rk3588_defconfig"
BOARD_PLATS[rk3588-mekotronics-r58x-4g]="rk3588"
BOARD_DESC[rk3588-mekotronics-r58x-4g]="Mekotronics R58X 4G"

BOARD_DEFCONFIGS[rk3588-mekotronics-r58hd]="mekotronics-r58hd-rk3588_defconfig"
BOARD_PLATS[rk3588-mekotronics-r58hd]="rk3588"
BOARD_DESC[rk3588-mekotronics-r58hd]="Mekotronics R58HD"

BOARD_DEFCONFIGS[rk3588-mekotronics-r58s2]="mekotronics-r58s2-rk3588_defconfig"
BOARD_PLATS[rk3588-mekotronics-r58s2]="rk3588"
BOARD_DESC[rk3588-mekotronics-r58s2]="Mekotronics R58S2"

BOARD_DEFCONFIGS[rk3588-mekotronics-r58-4x4]="mekotronics-r58-4x4-rk3588_defconfig"
BOARD_PLATS[rk3588-mekotronics-r58-4x4]="rk3588"
BOARD_DESC[rk3588-mekotronics-r58-4x4]="Mekotronics R58X-4x4"

BOARD_DEFCONFIGS[rk3588-mekotronics-r58-minipc]="mekotronics-r58-minipc-rk3588_defconfig"
BOARD_PLATS[rk3588-mekotronics-r58-minipc]="rk3588"
BOARD_DESC[rk3588-mekotronics-r58-minipc]="Mekotronics R58 MiniPC"

BOARD_DEFCONFIGS[rk3588-radxa-nio-12l]="radxa-nio-12l-rk3588_defconfig"
BOARD_PLATS[rk3588-radxa-nio-12l]="rk3588"
BOARD_DESC[rk3588-radxa-nio-12l]="Radxa NIO 12L"

BOARD_DEFCONFIGS[rk3588-retroidpocket-rp5]="retroidpocket-rp5-rk3588_defconfig"
BOARD_PLATS[rk3588-retroidpocket-rp5]="rk3588"
BOARD_DESC[rk3588-retroidpocket-rp5]="Retroid Pocket RP5"

BOARD_DEFCONFIGS[rk3588-retroidpocket-rpmini]="retroidpocket-rpmini-rk3588_defconfig"
BOARD_PLATS[rk3588-retroidpocket-rpmini]="rk3588"
BOARD_DESC[rk3588-retroidpocket-rpmini]="Retroid Pocket RPmini"

BOARD_DEFCONFIGS[rk3588-fxblox-rk1]="fxblox-rk1-rk3588_defconfig"
BOARD_PLATS[rk3588-fxblox-rk1]="rk3588"
BOARD_DESC[rk3588-fxblox-rk1]="FxBlox RK1"

BOARD_DEFCONFIGS[rk3588-gateway-dk]="gateway-dk-rk3588_defconfig"
BOARD_PLATS[rk3588-gateway-dk]="rk3588"
BOARD_DESC[rk3588-gateway-dk]="Gateway DK"

BOARD_DEFCONFIGS[rk3588-imb3588]="imb3588-rk3588_defconfig"
BOARD_PLATS[rk3588-imb3588]="rk3588"
BOARD_DESC[rk3588-imb3588]="iMB3588"

BOARD_DEFCONFIGS[rk3588-photonicat2]="photonicat2-rk3588_defconfig"
BOARD_PLATS[rk3588-photonicat2]="rk3588"
BOARD_DESC[rk3588-photonicat2]="Photonicat 2"

BOARD_DEFCONFIGS[rk3588-dg-svr-865-tiny]="dg-svr-865-tiny-rk3588_defconfig"
BOARD_PLATS[rk3588-dg-svr-865-tiny]="rk3588"
BOARD_DESC[rk3588-dg-svr-865-tiny]="DG SVR-865 Tiny"

BOARD_DEFCONFIGS[rk3588-cyber-aib]="cyber-aib-rk3588_defconfig"
BOARD_PLATS[rk3588-cyber-aib]="rk3588"
BOARD_DESC[rk3588-cyber-aib]="Cyber AIB RK3588"

BOARD_DEFCONFIGS[rk3588-coolpi-genbook]="coolpi-genbook-rk3588_defconfig"
BOARD_PLATS[rk3588-coolpi-genbook]="rk3588"
BOARD_DESC[rk3588-coolpi-genbook]="CoolPi GenBook"

BOARD_DEFCONFIGS[rk3588-youyeetoo-yy3588]="youyeetoo-yy3588-rk3588_defconfig"
BOARD_PLATS[rk3588-youyeetoo-yy3588]="rk3588"
BOARD_DESC[rk3588-youyeetoo-yy3588]="Youyeetoo YY3588"

BOARD_DEFCONFIGS[rk3588-indiedroid-nova]="indiedroid-nova-rk3588s_defconfig"
BOARD_PLATS[rk3588-indiedroid-nova]="rk3588"
BOARD_DESC[rk3588-indiedroid-nova]="Indiedroid Nova"

BOARD_DEFCONFIGS[rk3588-firefly-itx-3588j]="firefly-itx-3588j-rk3588_defconfig"
BOARD_PLATS[rk3588-firefly-itx-3588j]="rk3588"
BOARD_DESC[rk3588-firefly-itx-3588j]="Firefly ITX-3588J"

BOARD_DEFCONFIGS[rk3588-armsom-cm5-io]="armsom-cm5-io-rk3588_defconfig"
BOARD_PLATS[rk3588-armsom-cm5-io]="rk3588"
BOARD_DESC[rk3588-armsom-cm5-io]="ArmSoM CM5 IO"

# ======== RK3399 (双核A72+四核A53, Mali-T860) ========
BOARD_DEFCONFIGS[rk3399-generic]="generic-rk3399_defconfig"
BOARD_PLATS[rk3399-generic]="rk3399"
BOARD_DESC[rk3399-generic]="RK3399 Generic"

BOARD_DEFCONFIGS[rk3399-rockpro64]="rockpro64-rk3399_defconfig"
BOARD_PLATS[rk3399-rockpro64]="rk3399"
BOARD_DESC[rk3399-rockpro64]="PINE64 RockPro64"

BOARD_DEFCONFIGS[rk3399-rockpi4b]="rock-pi-4b-rk3399_defconfig"
BOARD_PLATS[rk3399-rockpi4b]="rk3399"
BOARD_DESC[rk3399-rockpi4b]="Radxa Rock Pi 4B"

BOARD_DEFCONFIGS[rk3399-rockpi4a]="rock-pi-4a-rk3399_defconfig"
BOARD_PLATS[rk3399-rockpi4a]="rk3399"
BOARD_DESC[rk3399-rockpi4a]="Radxa Rock Pi 4A"

BOARD_DEFCONFIGS[rk3399-rockpi4bplus]="rock-pi-4bplus-rk3399_defconfig"
BOARD_PLATS[rk3399-rockpi4bplus]="rk3399"
BOARD_DESC[rk3399-rockpi4bplus]="Radxa Rock Pi 4B+"

BOARD_DEFCONFIGS[rk3399-rockpi4c]="rock-pi-4c-rk3399_defconfig"
BOARD_PLATS[rk3399-rockpi4c]="rk3399"
BOARD_DESC[rk3399-rockpi4c]="Radxa Rock Pi 4C"

BOARD_DEFCONFIGS[rk3399-rockpi4cplus]="rock-pi-4cplus-rk3399_defconfig"
BOARD_PLATS[rk3399-rockpi4cplus]="rk3399"
BOARD_DESC[rk3399-rockpi4cplus]="Radxa Rock Pi 4C+"

BOARD_DEFCONFIGS[rk3399-nanopim4]="nanopi-m4-rk3399_defconfig"
BOARD_PLATS[rk3399-nanopim4]="rk3399"
BOARD_DESC[rk3399-nanopim4]="FriendlyELEC NanoPi M4"

BOARD_DEFCONFIGS[rk3399-nanopim4v2]="nanopi-m4v2-rk3399_defconfig"
BOARD_PLATS[rk3399-nanopim4v2]="rk3399"
BOARD_DESC[rk3399-nanopim4v2]="FriendlyELEC NanoPi M4 V2"

BOARD_DEFCONFIGS[rk3399-nanopineo4]="nanopi-neo4-rk3399_defconfig"
BOARD_PLATS[rk3399-nanopineo4]="rk3399"
BOARD_DESC[rk3399-nanopineo4]="FriendlyELEC NanoPi Neo4"

BOARD_DEFCONFIGS[rk3399-nanopct4]="nanopct4-rk3399_defconfig"
BOARD_PLATS[rk3399-nanopct4]="rk3399"
BOARD_DESC[rk3399-nanopct4]="FriendlyELEC NanoPC T4"

BOARD_DEFCONFIGS[rk3399-orangepi-rk3399]="orangepi-rk3399_defconfig"
BOARD_PLATS[rk3399-orangepi-rk3399]="rk3399"
BOARD_DESC[rk3399-orangepi-rk3399]="Orange Pi RK3399"

BOARD_DEFCONFIGS[rk3399-orangepi4]="orangepi-4-rk3399_defconfig"
BOARD_PLATS[rk3399-orangepi4]="rk3399"
BOARD_DESC[rk3399-orangepi4]="Orange Pi 4"

BOARD_DEFCONFIGS[rk3399-orangepi4-lts]="orangepi-4-lts-rk3399_defconfig"
BOARD_PLATS[rk3399-orangepi4-lts]="rk3399"
BOARD_DESC[rk3399-orangepi4-lts]="Orange Pi 4 LTS"

BOARD_DEFCONFIGS[rk3399-firefly]="firefly-rk3399_defconfig"
BOARD_PLATS[rk3399-firefly]="rk3399"
BOARD_DESC[rk3399-firefly]="Firefly RK3399"

BOARD_DEFCONFIGS[rk3399-firefly-rk3399-roc-pc]="roc-rk3399-pc-rk3399_defconfig"
BOARD_PLATS[rk3399-firefly-rk3399-roc-pc]="rk3399"
BOARD_DESC[rk3399-firefly-rk3399-roc-pc]="Firefly ROC-RK3399-PC"

BOARD_DEFCONFIGS[rk3399-khadas-edge]="khadas-edge-rk3399_defconfig"
BOARD_PLATS[rk3399-khadas-edge]="rk3399"
BOARD_DESC[rk3399-khadas-edge]="Khadas Edge"

BOARD_DEFCONFIGS[rk3399-tinker-board-2]="tinker-board-2-rk3399_defconfig"
BOARD_PLATS[rk3399-tinker-board-2]="rk3399"
BOARD_DESC[rk3399-tinker-board-2]="ASUS Tinker Board 2"

BOARD_DEFCONFIGS[rk3399-tinker-edge-r]="tinker-edge-r-rk3399_defconfig"
BOARD_PLATS[rk3399-tinker-edge-r]="rk3399"
BOARD_DESC[rk3399-tinker-edge-r]="ASUS Tinker Edge R"

BOARD_DEFCONFIGS[rk3399-fine3399]="fine3399-rk3399_defconfig"
BOARD_PLATS[rk3399-fine3399]="rk3399"
BOARD_DESC[rk3399-fine3399]="Fine3399"

BOARD_DEFCONFIGS[rk3399-helios64]="helios64-rk3399_defconfig"
BOARD_PLATS[rk3399-helios64]="rk3399"
BOARD_DESC[rk3399-helios64]="Kobol Helios64"

BOARD_DEFCONFIGS[rk3399-station-p1]="station-p1-rk3399_defconfig"
BOARD_PLATS[rk3399-station-p1]="rk3399"
BOARD_DESC[rk3399-station-p1]="Station P1"

BOARD_DEFCONFIGS[rk3399-station-p2]="station-p2-rk3399_defconfig"
BOARD_PLATS[rk3399-station-p2]="rk3399"
BOARD_DESC[rk3399-station-p2]="Station P2"

BOARD_DEFCONFIGS[rk3399-station-m1]="station-m1-rk3399_defconfig"
BOARD_PLATS[rk3399-station-m1]="rk3399"
BOARD_DESC[rk3399-station-m1]="Station M1"

# ======== DEFAULT ========
DEFAULT_BOARDS=("rk3588-generic" "rk3588-rock5b" "rk3588-opi5" "rk3588-opi5plus" \
                "rk3576-generic" "rk3576-rock4d" "rk3576-armsom-sige5" \
                "rk3568-generic" "rk3568-rock-3a" "rk3568-nanopi-r5s" \
                "rk3566-generic" "rk3566-rock-3c" "rk3566-orangepi-3b" \
                "rk3399-generic" "rk3399-rockpro64" "rk3399-rockpi4b")

#------------------------------------------------------------------------------
# 显示帮助
#------------------------------------------------------------------------------
show_help() {
    cat << EOF
用法: $0 [选项] [板卡ID ...]

选项:
  -h, --help          显示此帮助信息
  -l, --list          列出所有支持的板卡
  -a, --all           编译所有板卡
  -t, --tfa-only      仅编译 Trusted Firmware-A
  -c, --clean         清理编译产物后重新编译

示例:
  $0                              # 编译默认板卡列表
  $0 rk3588-opi5plus             # 仅编译 Orange Pi 5 Plus
  $0 rk3588-rock5b rk3588-rock5a # 编译 Rock 5B 和 Rock 5A
  $0 -a                           # 编译所有支持的板卡
  $0 -c rk3588-generic            # 清理后重新编译

支持的板卡:
EOF
    local bid
    for bid in "${!BOARD_DEFCONFIGS[@]}"; do
        printf "  %-22s %s\n" "$bid" "${BOARD_DESC[$bid]}"
    done
}

#------------------------------------------------------------------------------
# 列出板卡
#------------------------------------------------------------------------------
list_boards() {
    local bid plat platforms=(rk3308 rk3328 rk3399 rk3566 rk3568 rk3588 rk3576)
    echo ""
    for plat in "${platforms[@]}"; do
        echo "${plat^^} 平台板卡:"
        printf '%*s\n' "${#plat}" '' | tr ' ' '-'
        for bid in "${!BOARD_DEFCONFIGS[@]}"; do
            if [[ "$bid" == ${plat}-* ]]; then
                printf "  %-26s %s\n" "$bid" "${BOARD_DESC[$bid]}"
            fi
        done
        echo ""
    done
}

#------------------------------------------------------------------------------
# 下载源码
#------------------------------------------------------------------------------
download_sources() {
    step "下载源码..."

    mkdir -p "${SOURCE_DIR}"
    cd "${SOURCE_DIR}"

    # 下载 rkbin
    if [ ! -d "rkbin" ]; then
        info "下载 rkbin (Rockchip 闭源固件)..."
        git clone --depth=1 "${RKBIN_REPO}"
    else
        info "rkbin 已存在，更新中..."
        cd rkbin && git pull && cd ..
    fi

    # 下载 U-Boot (使用 --depth=1 浅克隆，节省时间和空间)
    if [ ! -d "u-boot" ]; then
        info "下载 U-Boot ${UBOOT_VERSION}..."
        git clone --depth=1 --branch "${UBOOT_VERSION}" "${UBOOT_REPO}"
    else
        info "U-Boot 已存在"
    fi

    # 下载 TF-A
    if [ ! -d "trusted-firmware-a" ]; then
        info "下载 Trusted Firmware-A ${TFA_VERSION}..."
        git clone --depth=1 --branch "${TFA_VERSION}" "${TFA_REPO}"
    else
        info "TF-A 已存在"
    fi

    ok "源码准备完成"
}

#------------------------------------------------------------------------------
# 编译 Trusted Firmware-A (BL31)
# 参考 build.sh: make clean || true; ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make PLAT=rk3588 bl31
#------------------------------------------------------------------------------
build_tfa() {
    local plat=$1
    local tfa_dir="${SOURCE_DIR}/trusted-firmware-a"
    local tfa_out="${tfa_dir}/build/${plat}/release/bl31/bl31.elf"

    if [ -f "$tfa_out" ] && [ "$CLEAN_BUILD" != "yes" ]; then
        ok "TF-A BL31 (${plat}) 已编译，跳过"
        return 0
    fi

    step "编译 Trusted Firmware-A (BL31) for ${plat}..."

    # 检查 TF-A 是否支持该平台
    if [ ! -d "${tfa_dir}/plat/rockchip/${plat}" ]; then
        warn "TF-A 不支持 ${plat} 平台，跳过"
        return 1
    fi

    pushd "$tfa_dir" > /dev/null
    make clean 2>/dev/null || true
    ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE}" make PLAT="${plat}" bl31 -j"${JOBS}"
    popd > /dev/null

    if [ ! -f "$tfa_out" ]; then
        warn "TF-A BL31 编译失败: ${plat}"
        return 1
    fi

    ok "TF-A BL31 (${plat}) 编译完成"
}

#------------------------------------------------------------------------------
# 编译 U-Boot (单板卡)
#------------------------------------------------------------------------------
build_uboot_for_board() {
    local board_id=$1
    local defconfig="${BOARD_DEFCONFIGS[$board_id]}"
    local plat="${BOARD_PLATS[$board_id]}"
    local desc="${BOARD_DESC[$board_id]}"

    if [ -z "$defconfig" ]; then
        error "未知板卡ID: $board_id"
        return 1
    fi

    step "编译 U-Boot for ${desc} (${board_id})..."

    local uboot_dir="${SOURCE_DIR}/u-boot"
    local rkbin_dir="${SOURCE_DIR}/rkbin"
    local tfa_dir="${SOURCE_DIR}/trusted-firmware-a"
    local out_dir="${OUTPUT_DIR}/uboot/${board_id}"

    mkdir -p "$out_dir"

    # 查找 DDR blob
    local ddr_path
    ddr_path=$(find "${rkbin_dir}" -name "${plat}_ddr_*.bin" | head -1)
    if [ -z "$ddr_path" ]; then
        error "DDR blob 未找到: ${plat}_ddr_*.bin"
        return 1
    fi

    # 查找 BL31 (优先 TF-A 开源版本)
    local bl31_path="${tfa_dir}/build/${plat}/release/bl31/bl31.elf"
    if [ ! -f "$bl31_path" ]; then
        bl31_path=$(find "${rkbin_dir}" -name "${plat}_bl31*.elf" | head -1)
        if [ -n "$bl31_path" ]; then
            warn "使用 rkbin 闭源 BL31"
        else
            error "BL31 未找到: ${plat}"
            return 1
        fi
    fi

    # 编译 U-Boot (参考 build.sh 风格)
    pushd "$uboot_dir" > /dev/null

    info "应用 defconfig: ${defconfig}"
    ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" make "${defconfig}"

    info "编译中 (使用 ${JOBS} 线程)..."
    export BL31="$bl31_path"
    export ROCKCHIP_TPL="$ddr_path"
    ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" make -j"${JOBS}"

    popd > /dev/null

    # 收集输出文件
    local outputs_found=0
    local f
    for f in u-boot-rockchip.bin u-boot-rockchip-spi.bin idbloader.img u-boot.itb u-boot.bin; do
        if [ -f "${uboot_dir}/${f}" ]; then
            cp "${uboot_dir}/${f}" "${out_dir}/"
            ok "  -> ${f}"
            outputs_found=$((outputs_found + 1))
        fi
    done

    if [ "$outputs_found" -eq 0 ]; then
        error "U-Boot 编译未产生任何输出文件"
        return 1
    fi

    # 生成板卡信息文件
    cat > "${out_dir}/board-info.txt" << EOF
BOARD_ID=${board_id}
BOARD_DESC=${desc}
PLATFORM=${plat}
DEFCONFIG=${defconfig}
BUILD_TIME=$(date -Iseconds)
UBOOT_VERSION=${UBOOT_VERSION:-unknown}
TFA_VERSION=${TFA_VERSION:-unknown}
EOF

    ok "U-Boot for ${desc} 编译完成: ${out_dir}"
}

#------------------------------------------------------------------------------
# 生成统一 bootloader 包
#------------------------------------------------------------------------------
pack_bootloader() {
    step "生成统一 bootloader 包..."

    local bootloader_dir="${OUTPUT_DIR}/bootloader"
    mkdir -p "$bootloader_dir"

    # 复制所有板卡的 U-Boot 产物
    local board_id
    for board_id in "${BUILT_BOARDS[@]}"; do
        local src_dir="${OUTPUT_DIR}/uboot/${board_id}"
        if [ -d "$src_dir" ]; then
            mkdir -p "${bootloader_dir}/${board_id}"
            cp "${src_dir}"/*.{bin,img,itb,dtb} "${bootloader_dir}/${board_id}/" 2>/dev/null || true
            cp "${src_dir}/board-info.txt" "${bootloader_dir}/${board_id}/" 2>/dev/null || true
        fi
    done

    # 查找并复制 SPL loader
    local spl_loader
    spl_loader=$(find "${SOURCE_DIR}/rkbin" -name "rk3588*_spl_loader_*.bin" -o -name "rk3576*_spl_loader_*.bin" 2>/dev/null | head -1)
    if [ -n "$spl_loader" ]; then
        cp "$spl_loader" "${bootloader_dir}/"
        ok "SPL loader: $(basename "$spl_loader")"
    fi

    # 创建索引文件
    cat > "${bootloader_dir}/README.txt" << EOF
Deepin Rockchip Bootloader Package
==================================
生成时间: $(date -Iseconds)
U-Boot 版本: ${UBOOT_VERSION}
TF-A 版本: ${TFA_VERSION}

目录结构:
EOF

    for board_id in "${BUILT_BOARDS[@]}"; do
        if [ -d "${bootloader_dir}/${board_id}" ]; then
            echo "  ${board_id}/ - ${BOARD_DESC[$board_id]}" >> "${bootloader_dir}/README.txt"
        fi
    done

    cat >> "${bootloader_dir}/README.txt" << EOF

刷写说明:
1. 进入 MaskROM 模式 (按住 Maskrom 按键上电)
2. 加载 SPL loader: rkdeveloptool db <spl_loader>.bin
3. 刷写 U-Boot:
   - SPI 方式: rkdeveloptool wl 0 <board>/u-boot-rockchip-spi.bin
   - eMMC 方式: rkdeveloptool wl 0x40 <board>/idbloader.img
                rkdeveloptool wl 0x4000 <board>/u-boot.itb
4. 重启: rkdeveloptool rd
EOF

    ok "Bootloader 包已生成: ${bootloader_dir}"
}

#------------------------------------------------------------------------------
# 主流程
#------------------------------------------------------------------------------
main() {
    local boards=()
    local build_all=false
    local tfa_only=false
    CLEAN_BUILD="no"

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
            -a|--all)
                build_all=true
                shift
                ;;
            -t|--tfa-only)
                tfa_only=true
                shift
                ;;
            -c|--clean)
                CLEAN_BUILD="yes"
                shift
                ;;
            -*)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                boards+=("$1")
                shift
                ;;
        esac
    done

    # 确定板卡列表
    if [ "$build_all" = true ]; then
        boards=("${!BOARD_DEFCONFIGS[@]}")
    elif [ ${#boards[@]} -eq 0 ]; then
        boards=("${DEFAULT_BOARDS[@]}")
    fi

    echo "========================================"
    echo "  U-Boot / TF-A 编译"
    echo "========================================"
    echo "  目标板卡: ${#boards[@]} 款"
    echo "  并行任务: ${JOBS}"
    echo ""

    # 下载源码
    download_sources

    # 编译 TF-A (为所有选中的平台编译 BL31)
    local plat
    local needed_plats=()
    local board_id

    for board_id in "${boards[@]}"; do
        plat="${BOARD_PLATS[$board_id]}"
        if [[ ! " ${needed_plats[@]} " =~ " ${plat} " ]]; then
            needed_plats+=("$plat")
        fi
    done

    info "需要编译/检查 TF-A 的平台: ${needed_plats[*]}"
    for plat in "${needed_plats[@]}"; do
        build_tfa "$plat" || warn "TF-A ${plat} 编译失败，将尝试 rkbin 闭源 BL31"
    done

    if [ "$tfa_only" = true ]; then
        ok "TF-A 编译完成，按请求跳过 U-Boot"
        exit 0
    fi

    # 编译各板卡 U-Boot
    BUILT_BOARDS=()
    local success=0 failed=0

    for board_id in "${boards[@]}"; do
        echo ""
        if build_uboot_for_board "$board_id"; then
            BUILT_BOARDS+=("$board_id")
            success=$((success + 1))
        else
            warn "板卡 ${board_id} 编译失败，继续下一款..."
            failed=$((failed + 1))
        fi
    done

    # 打包
    echo ""
    if [ ${#BUILT_BOARDS[@]} -gt 0 ]; then
        pack_bootloader
    fi

    # 汇总
    echo ""
    echo "========================================"
    ok "U-Boot 编译完成"
    echo "========================================"
    echo "  成功: ${success} 款板卡"
    echo "  失败: ${failed} 款板卡"
    echo "  输出目录: ${OUTPUT_DIR}/uboot/"
    echo "  Bootloader 包: ${OUTPUT_DIR}/bootloader/"
    echo ""
    info "下一步: 运行 ./02-build-kernel.sh 编译内核"
}

main "$@"
exit 0

