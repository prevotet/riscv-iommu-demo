#!/bin/bash
# =============================================================================
# 2_build_HB_jtag.sh — Build + déploiement via JTAG (sans carte SD)
# Usage: [ENV_VARS] ./2_build_HB_jtag.sh [TARGET]
#
# Targets (build) :
#   all           — build complet (défaut) : fpga + baremetal + bao + opensbi
#   clean         — supprime tous les artefacts
#   fpga          — synthèse CVA6 uniquement
#   fpga-dpr      — synthèse DPR (DPR_MODE=static|clean|all, RM=accel_A|accel_B)
#   hwicap-setup  — intègre l'IP AXI HWICAP dans le projet CVA6 (une seule fois)
#   baremetal     — compile baremetal.bin (config IOMMU attack)
#   bao           — compile BAO (config cva6-baremetal)
#   opensbi       — compile OpenSBI avec payload bao.bin
#   dpr-manager   — compile dpr_manager.bin (VM de service DPR)
#   bao-dpr       — compile BAO (config cva6-dpr-linux : DPR Manager + Linux)
#   opensbi-dpr   — compile OpenSBI avec payload bao-dpr.bin
#   all-dpr       — dpr-manager + bao-dpr + opensbi-dpr
#
# Targets (déploiement) :
#   program         — programme le bitstream FPGA via Vivado JTAG
#   openocd         — lance OpenOCD (bloquant, terminal dédié)
#   jtag-load       — charge fw_payload.bin via GDB → 0x80000000
#   jtag-load-dpr   — charge fw_payload.bin + bitstreams DPR via GDB
#   jtag            — OpenOCD bg + jtag-load (tout-en-un, firmware standard)
#   jtag-dpr        — OpenOCD bg + jtag-load-dpr (tout-en-un, DPR Manager+Linux)
#
# Layout DDR après jtag-load-dpr (ping-pong A↔B) :
#   0x80000000 : fw_payload.bin            (OpenSBI + BAO DPR Manager + Linux)
#   0x81000000 : partial_accel_A_accel1.bin  (slot 3 Mo)
#   0x81300000 : partial_accel_B_accel1.bin  (slot 3 Mo)
#   0x81600000 : partial_accel_A_accel2.bin  (slot 5 Mo)
#   0x81B00000 : partial_accel_B_accel2.bin  (slot 5 Mo)
#
# Variables d'environnement :
#   VIVADO_VERSION   (défaut: 2022.2)
#   VIVADO_DIR       (défaut: /tools/Xilinx/Vivado/$VIVADO_VERSION)
#   RISCV_BARE       (chemin vers riscv64-unknown-elf-)
#   RISCV            (répertoire toolchain Linux)
#   BUILD_DIR        (défaut: <root>/build)
#   JOBS             (défaut: nproc)
#   DRY_RUN=1        (affiche les commandes sans les exécuter)
#   FORCE_FPGA=1     (force la re-synthèse FPGA)
#   OPENOCD_CFG      (défaut: cva6/corev_apu/fpga/ariane.cfg)
#   OPENOCD_PORT     (défaut: 3333)
#   GDB              (défaut: ${CROSS_COMPILE}gdb)
#   RM_TARGET        (RM dont les bitstreams .bin sont en DDR, défaut: accel_B)
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VIVADO_VERSION="${VIVADO_VERSION:-2022.2}"
VIVADO_DIR="${VIVADO_DIR:-/tools/Xilinx/Vivado/${VIVADO_VERSION}}"

RISCV_BARE="${RISCV_BARE:-/home/jc/Software/riscv64-unknown-elf-gcc-10.1.0-2020.08.2-x86_64-linux-ubuntu14/bin/riscv64-unknown-elf-}"
RISCV_LINUX_DIR="${RISCV_LINUX_DIR:-/home/jc/Software/riscv}"
export RISCV="${RISCV:-$RISCV_LINUX_DIR}"

export CROSS_COMPILE="${CROSS_COMPILE:-$RISCV_BARE}"
export PATH="$RISCV_LINUX_DIR/bin:$PATH"

BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
JOBS="${JOBS:-$(nproc)}"
DRY_RUN="${DRY_RUN:-0}"

TOOLS_DIR="${TOOLS_DIR:-$BUILD_DIR/tools}"
BUILD_GUESTS_DIR="${BUILD_GUESTS_DIR:-$BUILD_DIR/guests}"
BUILD_BAO_DIR="${BUILD_BAO_DIR:-$BUILD_DIR/bao}"
BUILD_FIRMWARE_DIR="${BUILD_FIRMWARE_DIR:-$BUILD_DIR/firmware}"
BUILD_CVA6_DIR="${BUILD_CVA6_DIR:-$BUILD_DIR/hw}"
CONFIG_BAREMETAL_DIR="${CONFIG_BAREMETAL_DIR:-$BUILD_DIR/vm-configs/cva6-baremetal}"
BAO_SRCS="${BAO_SRCS:-$ROOT_DIR/bao-hypervisor}"

CVA6_FPGA="$ROOT_DIR/cva6/corev_apu/fpga"
HWICAP_DIR="$CVA6_FPGA/xilinx/xlnx_axi_hwicap"
WORK_DPR="$CVA6_FPGA/work-dpr"

# JTAG / OpenOCD
OPENOCD_CFG="${OPENOCD_CFG:-$CVA6_FPGA/ariane.cfg}"
OPENOCD_PORT="${OPENOCD_PORT:-3333}"
GDB="${GDB:-${CROSS_COMPILE}gdb}"

# Firmware OpenSBI (chemin de build partagé par OpenSBI)
FW_PAYLOAD="$ROOT_DIR/opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin"
# Copie nommée pour la config DPR+baremetal (évite l'écrasement entre configs)
FW_PAYLOAD_DPR_BM="$BUILD_FIRMWARE_DIR/fw_payload_dpr_bm.bin"
ADDR_FW="0x80000000"
# Layout DDR bitstreams (ping-pong A↔B, 4 slots)
ADDR_BS_A1="0x81000000"   # partial_accel_A_accel1.bin — slot 3 Mo
ADDR_BS_B1="0x81300000"   # partial_accel_B_accel1.bin — slot 3 Mo
ADDR_BS_A2="0x81600000"   # partial_accel_A_accel2.bin — slot 5 Mo
ADDR_BS_B2="0x81B00000"   # partial_accel_B_accel2.bin — slot 5 Mo

# =============================================================================
# Utilitaires
# =============================================================================

log_step()  { echo -e "\e[34m==>\e[0m \e[1m$*\e[0m"; }
log_ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

RUN() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m $*"
    else
        "$@"
    fi
}

copy_if_changed() {
    local src="$1" dst="$2"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
        RUN cp "$src" "$dst"
        log_ok "Copié : $src → $dst"
    else
        log_warn "Inchangé, copie ignorée : $dst"
    fi
}

# =============================================================================
# Vérification des prérequis
# =============================================================================

check_deps() {
    log_step "Vérification des prérequis"
    local missing=0

    for tool in make dtc git; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Outil manquant : $tool"
            missing=1
        fi
    done

    if [[ ! -d "$VIVADO_DIR" ]]; then
        log_error "Vivado introuvable : $VIVADO_DIR"
        missing=1
    fi

    if [[ ! -f "${CROSS_COMPILE}gcc" ]] && [[ "$DRY_RUN" != "1" ]]; then
        log_error "Compilateur introuvable : ${CROSS_COMPILE}gcc"
        missing=1
    fi

    [[ $missing -eq 1 ]] && { log_error "Prérequis manquants. Abandon."; exit 1; }
    log_ok "Tous les prérequis sont satisfaits"
}

# =============================================================================
# Création des répertoires
# =============================================================================

create_dirs() {
    log_step "Création des répertoires de build"
    RUN mkdir -p \
        "$BUILD_DIR" "$TOOLS_DIR/bin" "$BUILD_GUESTS_DIR" \
        "$BUILD_BAO_DIR" "$BUILD_FIRMWARE_DIR" \
        "$BUILD_CVA6_DIR" "$CONFIG_BAREMETAL_DIR"
    log_ok "Répertoires créés sous $BUILD_DIR"
}

# =============================================================================
# HWICAP setup (une seule fois)
# =============================================================================

do_hwicap_setup() {
    log_step "Configuration de l'IP AXI HWICAP"

    local SOC_PKG="$ROOT_DIR/cva6/corev_apu/tb/ariane_soc_pkg.sv"
    local PERIPH="$CVA6_FPGA/src/ariane_peripherals_xilinx.sv"
    local TOP="$CVA6_FPGA/src/ariane_xilinx.sv"
    local HWICAP_DIR="$CVA6_FPGA/xilinx/xlnx_axi_hwicap"

    mkdir -p "$HWICAP_DIR/tcl" "$HWICAP_DIR/ip"

    cat > "$HWICAP_DIR/Makefile" << 'EOF'
PROJECT:=xlnx_axi_hwicap
include ../common.mk
EOF

    cat > "$HWICAP_DIR/tcl/run.tcl" << 'EOF'
set partNumber $::env(XILINX_PART)
set boardName  $::env(XILINX_BOARD)
set ipName xlnx_axi_hwicap
create_project $ipName . -force -part $partNumber
set_property board_part $boardName [current_project]
create_ip -name axi_hwicap -vendor xilinx.com -library ip \
    -version 3.0 -module_name $ipName
set_property -dict [list \
    CONFIG.C_ICAP_EXTERNAL   {0} \
    CONFIG.C_DEVICE_ID       {0x03647093} \
    CONFIG.C_INCLUDE_STARTUP {1} \
    CONFIG.C_OPERATION       {1} \
] [get_ips $ipName]
generate_target {instantiation_template} \
    [get_files ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
generate_target all \
    [get_files ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
create_ip_run \
    [get_files -of_objects [get_fileset sources_1] \
    ./$ipName.srcs/sources_1/ip/$ipName/$ipName.xci]
launch_run -jobs 8 ${ipName}_synth_1
EOF
    log_ok "  → Fichiers IP créés"

    if ! grep -q "xlnx_axi_hwicap" "$CVA6_FPGA/Makefile"; then
        sed -i \
          's/xlnx_mig_7_ddr3\.xci/xlnx_mig_7_ddr3.xci \\\n       xlnx_axi_hwicap.xci/' \
          "$CVA6_FPGA/Makefile"
        log_ok "  → Makefile CVA6 mis à jour"
    fi

    if ! grep -q "HWICAP" "$SOC_PKG"; then
        sed -i 's/Debug     =  14/Debug     =  14,\n    HWICAP    =  15/' "$SOC_PKG"
        sed -i 's/localparam NB_PERIPHERALS = Debug + 1;/localparam NB_PERIPHERALS = HWICAP + 1;/' "$SOC_PKG"
        sed -i 's/localparam logic\[63:0\] DRAMLength/localparam logic[63:0] HWICAPLength   = 64'"'"'h1000;\n  localparam logic[63:0] DRAMLength/' "$SOC_PKG"
        sed -i 's/GPIOBase     = 64'"'"'h4000_0000,/GPIOBase     = 64'"'"'h4000_0000,\n    HWICAPBase   = 64'"'"'h4001_0000,/' "$SOC_PKG"
        log_ok "  → ariane_soc_pkg.sv mis à jour"
    else
        log_warn "  → HWICAP déjà dans ariane_soc_pkg.sv"
    fi

    if ! grep -q "HWICAP" "$TOP"; then
        sed -i "s/'{ idx: ariane_soc::GPIO.*GPIOLength      },/'{ idx: ariane_soc::GPIO,      start_addr: ariane_soc::GPIOBase,     end_addr: ariane_soc::GPIOBase      + ariane_soc::GPIOLength      },\n  '{ idx: ariane_soc::HWICAP,    start_addr: ariane_soc::HWICAPBase,   end_addr: ariane_soc::HWICAPBase    + ariane_soc::HWICAPLength    },/" "$TOP"
        sed -i 's/\.InclGPIO     ( 1'"'"'b1             ),/.InclGPIO     ( 1'"'"'b1             ),\n    .InclHWICAP   ( 1'"'"'b1             ),/' "$TOP"
        sed -i 's/\.gpio         ( master\[ariane_soc::GPIO\]     ),/.gpio         ( master[ariane_soc::GPIO]     ),\n    .hwicap       ( master[ariane_soc::HWICAP]   ),/' "$TOP"
        log_ok "  → ariane_xilinx.sv mis à jour"
    else
        log_warn "  → HWICAP déjà dans ariane_xilinx.sv"
    fi

    if ! grep -q "InclHWICAP" "$PERIPH"; then
        sed -i 's/parameter bit InclTimer    =  1,/parameter bit InclTimer    =  1,\n    parameter bit InclHWICAP   =  0,/' "$PERIPH"
        sed -i 's/AXI_BUS.Slave      timer           ,/AXI_BUS.Slave      timer           ,\n    AXI_BUS.Slave      hwicap          ,/' "$PERIPH"
        sed -i '/InclTimer.*gen_timer/,/end.*gen_timer/ { /end.*gen_timer/a\
\
    \/\/ HWICAP\
    if (InclHWICAP) begin : gen_hwicap\
        xlnx_axi_hwicap i_hwicap (\
            .s_axi_aclk    ( clk_i              ),\
            .s_axi_aresetn ( rst_ni             ),\
            .s_axi_awaddr  ( hwicap.aw_addr[8:0]),\
            .s_axi_awvalid ( hwicap.aw_valid    ),\
            .s_axi_awready ( hwicap.aw_ready    ),\
            .s_axi_wdata   ( hwicap.w_data[31:0]),\
            .s_axi_wstrb   ( hwicap.w_strb[3:0] ),\
            .s_axi_wvalid  ( hwicap.w_valid     ),\
            .s_axi_wready  ( hwicap.w_ready     ),\
            .s_axi_bresp   ( hwicap.b_resp      ),\
            .s_axi_bvalid  ( hwicap.b_valid     ),\
            .s_axi_bready  ( hwicap.b_ready     ),\
            .s_axi_araddr  ( hwicap.ar_addr[8:0]),\
            .s_axi_arvalid ( hwicap.ar_valid    ),\
            .s_axi_arready ( hwicap.ar_ready    ),\
            .s_axi_rdata   ( hwicap.r_data[31:0]),\
            .s_axi_rresp   ( hwicap.r_resp      ),\
            .s_axi_rvalid  ( hwicap.r_valid     ),\
            .s_axi_rready  ( hwicap.r_ready     ),\
            .ip2intc_irpt  ( irq_sources[7]     )\
        );\
        assign hwicap.b_id   = '"'"'0;\
        assign hwicap.b_user = '"'"'0;\
        assign hwicap.r_id   = '"'"'0;\
        assign hwicap.r_user = '"'"'0;\
        assign hwicap.r_last = 1'"'"'b1;\
    end
}' "$PERIPH"
        log_ok "  → ariane_peripherals_xilinx.sv mis à jour"
    else
        log_warn "  → InclHWICAP déjà dans ariane_peripherals_xilinx.sv"
    fi

    log_ok "HWICAP setup terminé."
}

# =============================================================================
# Cibles de build
# =============================================================================

do_clean() {
    log_step "Nettoyage de tous les artefacts"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" clean
    RUN make -C "$ROOT_DIR/bao-hypervisor"      clean
    RUN make -C "$ROOT_DIR/opensbi"             clean
    log_ok "Nettoyage terminé"
}

do_fpga() {
    log_step "Synthèse FPGA (CVA6)"
    mkdir -p "$ROOT_DIR/cva6/corev_apu/fpga/src/armor/SRC"
    mkdir -p "$ROOT_DIR/cva6/corev_apu/fpga/src/armor/Include"
    cp -f "$ROOT_DIR/armor/SRC/"*.sv    "$ROOT_DIR/cva6/corev_apu/fpga/src/armor/SRC"
    cp -f "$ROOT_DIR/armor/Include/"*.* "$ROOT_DIR/cva6/corev_apu/fpga/src/armor/Include"

    source "$VIVADO_DIR/settings64.sh"

    if [[ -f "$ROOT_DIR/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit" ]] && \
       [[ "${FORCE_FPGA:-0}" != "1" ]]; then
        log_warn "Synthèse déjà réalisée — FORCE_FPGA=1 pour forcer"
    else
        rm -rf "$ROOT_DIR/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit"
        [[ -d "$ROOT_DIR/cva6/build" ]] && RUN rm -rf "$ROOT_DIR/cva6/build"
        RUN make -C "$ROOT_DIR/cva6" fpga
    fi

    copy_if_changed \
        "$ROOT_DIR/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit" \
        "$BUILD_CVA6_DIR/ariane_xilinx.bit"
    log_ok "FPGA prêt"
}

do_fpga_dpr() {
    log_step "Synthèse FPGA DPR"
    source "$VIVADO_DIR/settings64.sh"

    local rm_to_build="${RM:-accel_default}"
    local dpr_log="$ROOT_DIR/dpr/dpr_build.log"

    if [[ "${DPR_MODE:-}" == "clean" ]]; then
        RUN make -C "$ROOT_DIR/dpr" dpr-clean 2>&1 | tee "$dpr_log"
        log_ok "Nettoyage DPR terminé"
        return
    elif [[ "${DPR_MODE:-}" == "all" ]]; then
        RUN make -C "$ROOT_DIR/dpr" dpr-all 2>&1 | tee "$dpr_log"
    elif [[ "${DPR_MODE:-}" == "static" ]]; then
        local force_flag=""
        [[ "${FORCE_FPGA:-0}" == "1" ]] && force_flag="FORCE_STATIC=1"
        RUN make -C "$ROOT_DIR/dpr" dpr-static $force_flag 2>&1 | tee "$dpr_log"
    else
        RUN make -C "$ROOT_DIR/dpr" dpr-partial RM="$rm_to_build" 2>&1 | tee "$dpr_log"
    fi

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Flux DPR échoué. Voir $dpr_log"
        grep "^ERROR:\|^CRITICAL" "$dpr_log" | tail -20
        exit 1
    fi

    if [[ -d "$ROOT_DIR/cva6/corev_apu/fpga/work-dpr" ]]; then
        RUN mkdir -p "$BUILD_CVA6_DIR/dpr"
        find "$ROOT_DIR/cva6/corev_apu/fpga/work-dpr" -name "*.bit" \
            -exec cp {} "$BUILD_CVA6_DIR/dpr/" \;
    fi
    log_ok "Flux DPR terminé"
}

do_baremetal() {
    log_step "Compilation guest baremetal"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 -j"$JOBS"
    copy_if_changed \
        "$ROOT_DIR/bao-baremetal-guest/build/cva6/baremetal.bin" \
        "$BUILD_GUESTS_DIR/baremetal.bin"
    log_ok "Baremetal compilé"
}

do_bao() {
    log_step "Compilation BAO (config cva6-baremetal)"
    RUN cp -R "$ROOT_DIR/vm-configs/"*  "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"
    RUN make -C "$BAO_SRCS" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 CONFIG=cva6-baremetal \
        CPPFLAGS="-DBAO_WRKDIR_IMGS=$BUILD_GUESTS_DIR -DLOGLEVEL=TRACE" \
        -j"$JOBS"
    copy_if_changed \
        "$BAO_SRCS/bin/cva6/cva6-baremetal/bao.bin" \
        "$BUILD_BAO_DIR/bao.bin"
    log_ok "BAO compilé"
}

do_opensbi() {
    log_step "Compilation OpenSBI (payload bao.bin)"
    RUN make -C "$ROOT_DIR/opensbi" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=fpga/ariane \
        FW_PAYLOAD=y FW_PAYLOAD_PATH="$BAO_SRCS/bin/cva6/cva6-baremetal/bao.bin" \
        -j"$JOBS"
    log_ok "OpenSBI compilé"
}

do_dpr_manager() {
    log_step "Compilation guest DPR Manager"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 \
        VARIANT=dpr_manager NAME=dpr_manager -j"$JOBS"
    copy_if_changed \
        "$ROOT_DIR/bao-baremetal-guest/build/cva6/dpr_manager.bin" \
        "$BUILD_GUESTS_DIR/dpr_manager.bin"
    log_ok "DPR Manager compilé → $BUILD_GUESTS_DIR/dpr_manager.bin"
}

do_bao_dpr_linux() {
    log_step "Compilation BAO (config cva6-dpr-linux)"
    RUN cp -R "$ROOT_DIR/vm-configs/"*  "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"
    RUN make -C "$BAO_SRCS" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 CONFIG=cva6-dpr-linux \
        CPPFLAGS="-DBAO_WRKDIR_IMGS=$BUILD_GUESTS_DIR -DLOGLEVEL=TRACE" \
        -j"$JOBS"
    copy_if_changed \
        "$BAO_SRCS/bin/cva6/cva6-dpr-linux/bao.bin" \
        "$BUILD_BAO_DIR/bao-dpr.bin"
    log_ok "BAO DPR compilé → $BUILD_BAO_DIR/bao-dpr.bin"
}

do_opensbi_dpr() {
    log_step "Compilation OpenSBI (payload bao-dpr.bin)"
    RUN make -C "$ROOT_DIR/opensbi" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=fpga/ariane \
        FW_PAYLOAD=y FW_PAYLOAD_PATH="$BUILD_BAO_DIR/bao-dpr.bin" \
        -j"$JOBS"
    log_ok "OpenSBI DPR compilé"
}

do_all() {
    create_dirs; do_fpga; do_baremetal; do_bao; do_opensbi
    log_ok "Build complet terminé. Artefacts dans : $BUILD_DIR"
}

do_all_dpr() {
    create_dirs; do_dpr_manager; do_bao_dpr_linux; do_opensbi_dpr
    log_ok "Build DPR terminé."
    log_ok "  DPR Manager : $BUILD_GUESTS_DIR/dpr_manager.bin"
    log_ok "  BAO DPR     : $BUILD_BAO_DIR/bao-dpr.bin"
    log_ok "  Firmware    : $FW_PAYLOAD"
}

# =============================================================================
# DPR Manager + Client baremetal ping-pong (config cva6-dpr-baremetal)
# =============================================================================

do_dpr_client() {
    log_step "Compilation DPR Client (VARIANT=dpr_client, PLATFORM=cva6-dpr-client)"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        PLATFORM=cva6-dpr-client VARIANT=dpr_client NAME=dpr_client \
        CROSS_COMPILE="$CROSS_COMPILE" \
        -j"$JOBS"
    local bin="$ROOT_DIR/bao-baremetal-guest/build/cva6/dpr_client.bin"
    RUN mkdir -p "$BUILD_GUESTS_DIR"
    copy_if_changed "$bin" "$BUILD_GUESTS_DIR/dpr_client.bin"
    log_ok "DPR Client compilé → $BUILD_GUESTS_DIR/dpr_client.bin"
}

do_bao_dpr_bm() {
    log_step "Compilation BAO (config cva6-dpr-baremetal)"
    RUN cp -R "$ROOT_DIR/vm-configs/"*  "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"
    RUN make -C "$BAO_SRCS" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 CONFIG=cva6-dpr-baremetal \
        CPPFLAGS="-DBAO_WRKDIR_IMGS=$BUILD_GUESTS_DIR -DLOGLEVEL=TRACE" \
        -j"$JOBS"
    copy_if_changed \
        "$BAO_SRCS/bin/cva6/cva6-dpr-baremetal/bao.bin" \
        "$BUILD_BAO_DIR/bao-dpr-bm.bin"
    log_ok "BAO DPR-BM compilé → $BUILD_BAO_DIR/bao-dpr-bm.bin"
}

do_opensbi_dpr_bm() {
    log_step "Compilation OpenSBI (payload bao-dpr-bm.bin)"
    RUN make -C "$ROOT_DIR/opensbi" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=fpga/ariane \
        FW_PAYLOAD=y FW_PAYLOAD_PATH="$BUILD_BAO_DIR/bao-dpr-bm.bin" \
        -j"$JOBS"
    RUN mkdir -p "$BUILD_FIRMWARE_DIR"
    copy_if_changed "$FW_PAYLOAD" "$FW_PAYLOAD_DPR_BM"
    log_ok "OpenSBI DPR-BM compilé → $FW_PAYLOAD_DPR_BM"
}

do_dpr_full() {
    log_step "Compilation du guest DPR Full (Service + Test)"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 \
        VARIANT=dpr_full NAME=dpr_manager \
        -j"$JOBS"
    copy_if_changed \
        "$ROOT_DIR/bao-baremetal-guest/build/cva6/dpr_manager.bin" \
        "$BUILD_GUESTS_DIR/dpr_manager.bin"
    log_ok "DPR Full compilé → $BUILD_GUESTS_DIR/dpr_manager.bin"
}

do_all_dpr_bm() {
    create_dirs
    do_dpr_full
    do_bao_dpr_bm
    do_opensbi_dpr_bm
    log_ok "Build DPR baremetal (Single VM) terminé."
    log_ok "  DPR Manager : $BUILD_GUESTS_DIR/dpr_manager.bin"
    log_ok "  BAO         : $BUILD_BAO_DIR/bao-dpr-bm.bin"
    log_ok "  Firmware    : $FW_PAYLOAD_DPR_BM"
}

# =============================================================================
# Programme le bitstream FPGA via Vivado JTAG
# =============================================================================

do_program() {
    log_step "Chargement du bitstream sur Genesys2"
    local dpr_bit="$BUILD_CVA6_DIR/dpr/static_full.bit"
    local std_bit="$BUILD_CVA6_DIR/ariane_xilinx.bit"
    local bit=""

    # Priorité : static_full.bit (DPR) > ariane_xilinx.bit (standard)
    # Le bitstream DPR contient l'HWICAP — nécessaire pour tout scénario DPR.
    if [[ -f "$dpr_bit" ]]; then
        bit="$dpr_bit"
        if [[ -f "$std_bit" ]] && [[ "$std_bit" -nt "$dpr_bit" ]]; then
            log_warn "ariane_xilinx.bit est plus récent que static_full.bit — pensez à rebuilder DPR"
        fi
    elif [[ -f "$std_bit" ]]; then
        log_warn "static_full.bit absent — utilisation du bitstream standard (sans HWICAP/DPR)"
        bit="$std_bit"
    else
        log_error "Aucun bitstream trouvé (ni $dpr_bit ni $std_bit)"
        exit 1
    fi
    log_ok "Bitstream sélectionné : $bit"

    source "$VIVADO_DIR/settings64.sh"

    local tcl_script
    tcl_script=$(mktemp /tmp/program_fpga_XXXXXX.tcl)
    trap "rm -f $tcl_script" EXIT

    cat > "$tcl_script" << EOF
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target
set dev [lindex [get_hw_devices xc7k*] 0]
current_hw_device \$dev
set_property PROGRAM.FILE {$bit} \$dev
program_hw_devices \$dev
close_hw_target
disconnect_hw_server
close_hw_manager
EOF

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m vivado -mode batch -source $tcl_script"
    else
        vivado -mode batch -nojournal -nolog -source "$tcl_script"
        log_ok "Bitstream chargé"
    fi
}

# =============================================================================
# JTAG — OpenOCD + GDB (déploiement sans carte SD)
# =============================================================================

#
# Lance OpenOCD en mode bloquant.
# À utiliser dans un terminal dédié avant d'appeler jtag-load ou jtag-load-dpr.
#
do_openocd() {
    log_step "Lancement OpenOCD (port GDB=$OPENOCD_PORT)"

    if [[ ! -f "$OPENOCD_CFG" ]]; then
        log_error "Config OpenOCD introuvable : $OPENOCD_CFG"
        log_error "  → Surcharger OPENOCD_CFG=<chemin>"
        exit 1
    fi

    log_ok "Config : $OPENOCD_CFG"
    log_warn "Ctrl+C pour arrêter OpenOCD"
    echo ""

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m openocd -f $OPENOCD_CFG"
    else
        openocd -f "$OPENOCD_CFG"
    fi
}

#
# Démarre OpenOCD en arrière-plan.
# Attend que le port GDB soit prêt (max 10 s) puis retourne le PID.
#
_openocd_start_bg() {
    if [[ ! -f "$OPENOCD_CFG" ]]; then
        log_error "Config OpenOCD introuvable : $OPENOCD_CFG"
        exit 1
    fi

    log_step "  → Démarrage OpenOCD en arrière-plan..."

    # Tuer tout OpenOCD résiduel sur le port JTAG/GDB
    local old_pid
    old_pid=$(lsof -ti tcp:"$OPENOCD_PORT" 2>/dev/null || true)
    if [[ -n "$old_pid" ]]; then
        log_warn "  → OpenOCD résiduel détecté (PID $old_pid) — arrêt..."
        kill "$old_pid" 2>/dev/null || true
        sleep 1
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m openocd -f $OPENOCD_CFG &"
        echo "0"
        return
    fi

    openocd -f "$OPENOCD_CFG" &>/tmp/openocd_bg.log &
    local ocd_pid=$!
    echo "$ocd_pid"

    local retries=20
    while ! nc -z localhost "$OPENOCD_PORT" 2>/dev/null; do
        sleep 0.5
        retries=$(( retries - 1 ))
        if [[ $retries -le 0 ]]; then
            log_error "OpenOCD ne répond pas sur le port $OPENOCD_PORT après 10 s"
            log_error "  → Log : /tmp/openocd_bg.log"
            kill "$ocd_pid" 2>/dev/null || true
            exit 1
        fi
    done
    # Vérifier que l'examen du target a réussi
    sleep 0.5
    if grep -q "examination failed\|Fatal:\|unable to halt" /tmp/openocd_bg.log 2>/dev/null; then
        log_error "OpenOCD a démarré mais l'examen du target a échoué :"
        grep "Error\|Fatal\|Warn.*fail\|unable" /tmp/openocd_bg.log >&2 || true
        log_error "  → Vérifiez que le FPGA est bien programmé et power-cyclé"
        kill "$ocd_pid" 2>/dev/null || true
        exit 1
    fi
    log_ok "  → OpenOCD prêt (PID $ocd_pid, port $OPENOCD_PORT)"
}

#
# Exécute un script GDB en mode batch.
#
_gdb_run() {
    local gdb_script="$1"

    if ! command -v "$GDB" &>/dev/null && [[ ! -f "$GDB" ]]; then
        log_error "GDB introuvable : $GDB"
        log_error "  → Surcharger GDB=<chemin complet>"
        exit 1
    fi

    log_step "  → Exécution GDB : $gdb_script"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m $GDB -batch -x $gdb_script"
        sed 's/^/  /' "$gdb_script"
    else
        "$GDB" -batch -x "$gdb_script"
    fi
}

#
# Charge fw_payload.bin via JTAG/GDB.
# Pré-requis : OpenOCD déjà lancé (do_openocd ou _openocd_start_bg).
#
# Layout DDR résultant :
#   0x80000000 : fw_payload.bin  (OpenSBI + BAO + VMs)
#
do_jtag_load() {
    log_step "Chargement firmware via JTAG (sans carte SD)"

    if [[ ! -f "$FW_PAYLOAD" ]]; then
        log_error "Firmware introuvable : $FW_PAYLOAD"
        log_error "  → Lancer 'opensbi' ou 'opensbi-dpr' d'abord"
        exit 1
    fi

    local fw_size
    fw_size=$(stat -c%s "$FW_PAYLOAD")
    log_ok "Firmware : $FW_PAYLOAD ($fw_size octets)"
    log_ok "Cible    : $ADDR_FW"

    local gdb_script
    gdb_script=$(mktemp /tmp/jtag_load_XXXXXX.gdb)
    trap "rm -f $gdb_script" EXIT

    cat > "$gdb_script" << EOF
set arch riscv:rv64
set remotetimeout 30
target remote localhost:${OPENOCD_PORT}
monitor reset halt
monitor sleep 200

# Chargement firmware OpenSBI + BAO
restore ${FW_PAYLOAD} binary ${ADDR_FW}

# Démarrage depuis l'entrée OpenSBI
set \$pc = ${ADDR_FW}
monitor resume
disconnect
quit
EOF

    _gdb_run "$gdb_script"
    log_ok "Firmware chargé — CVA6 démarré depuis $ADDR_FW"
}

#
# Charge fw_payload.bin + les 4 bitstreams partiels (ping-pong A↔B) via JTAG/GDB.
# Pré-requis : OpenOCD déjà lancé, les 4 fichiers .bin générés.
#
# Layout DDR résultant :
#   0x80000000 : fw_payload.bin              (OpenSBI + BAO DPR Manager + Linux)
#   0x81000000 : partial_accel_A_accel1.bin  (slot 3 Mo)
#   0x81300000 : partial_accel_B_accel1.bin  (slot 3 Mo)
#   0x81600000 : partial_accel_A_accel2.bin  (slot 5 Mo)
#   0x81B00000 : partial_accel_B_accel2.bin  (slot 5 Mo)
#
do_jtag_load_dpr() {
    log_step "Chargement firmware DPR + 4 bitstreams (ping-pong A↔B) via JTAG"

    local bs_a1="$WORK_DPR/partial_accel_A_accel1.bin"
    local bs_b1="$WORK_DPR/partial_accel_B_accel1.bin"
    local bs_a2="$WORK_DPR/partial_accel_A_accel2.bin"
    local bs_b2="$WORK_DPR/partial_accel_B_accel2.bin"

    local err=0
    [[ ! -f "$FW_PAYLOAD" ]] && { log_error "Firmware introuvable : $FW_PAYLOAD"
        log_error "  → Lancer 'opensbi-dpr' d'abord"; err=1; }
    [[ ! -f "$bs_a1" ]] && { log_error "Introuvable : $bs_a1"; err=1; }
    [[ ! -f "$bs_b1" ]] && { log_error "Introuvable : $bs_b1"; err=1; }
    [[ ! -f "$bs_a2" ]] && { log_error "Introuvable : $bs_a2"; err=1; }
    [[ ! -f "$bs_b2" ]] && { log_error "Introuvable : $bs_b2"; err=1; }
    [[ $err -ne 0 ]] && { log_error "  → Générer les bitstreams avec '3_build_B.sh dpr'"; exit 1; }

    # Vérification des tailles (slots max)
    local sz_a1=$(stat -c%s "$bs_a1") sz_b1=$(stat -c%s "$bs_b1")
    local sz_a2=$(stat -c%s "$bs_a2") sz_b2=$(stat -c%s "$bs_b2")
    local slot1=$((3 * 1024 * 1024))   # 3 Mo
    local slot2=$((5 * 1024 * 1024))   # 5 Mo
    [[ $sz_a1 -gt $slot1 ]] && log_warn "partial_accel_A_accel1.bin ($sz_a1 o) dépasse le slot de $slot1 o !"
    [[ $sz_b1 -gt $slot1 ]] && log_warn "partial_accel_B_accel1.bin ($sz_b1 o) dépasse le slot de $slot1 o !"
    [[ $sz_a2 -gt $slot2 ]] && log_warn "partial_accel_A_accel2.bin ($sz_a2 o) dépasse le slot de $slot2 o !"
    [[ $sz_b2 -gt $slot2 ]] && log_warn "partial_accel_B_accel2.bin ($sz_b2 o) dépasse le slot de $slot2 o !"

    log_ok "Firmware   : $FW_PAYLOAD ($(stat -c%s "$FW_PAYLOAD") o)"
    log_ok "Slot A1    : $bs_a1 ($(( sz_a1 / 4 )) mots) → $ADDR_BS_A1"
    log_ok "Slot B1    : $bs_b1 ($(( sz_b1 / 4 )) mots) → $ADDR_BS_B1"
    log_ok "Slot A2    : $bs_a2 ($(( sz_a2 / 4 )) mots) → $ADDR_BS_A2"
    log_ok "Slot B2    : $bs_b2 ($(( sz_b2 / 4 )) mots) → $ADDR_BS_B2"

    local gdb_script
    gdb_script=$(mktemp /tmp/jtag_dpr_XXXXXX.gdb)
    trap "rm -f $gdb_script" EXIT

    cat > "$gdb_script" << EOF
set arch riscv:rv64
set remotetimeout 30
target remote localhost:${OPENOCD_PORT}
monitor reset halt
monitor sleep 200

# Firmware OpenSBI + BAO (DPR Manager + Linux)
restore ${FW_PAYLOAD} binary ${ADDR_FW}

# Bitstreams partiels ping-pong A↔B (4 slots DDR)
restore ${bs_a1} binary ${ADDR_BS_A1}
restore ${bs_b1} binary ${ADDR_BS_B1}
restore ${bs_a2} binary ${ADDR_BS_A2}
restore ${bs_b2} binary ${ADDR_BS_B2}

# Démarrage depuis l'entrée OpenSBI
set \$pc = ${ADDR_FW}
monitor resume
disconnect
quit
EOF

    _gdb_run "$gdb_script"
    log_ok "Chargement terminé — CVA6 démarré depuis $ADDR_FW"
    log_ok "  DPR Manager (VM0) attend des commandes IPC à 0xF0000000"
    log_ok "  4 bitstreams disponibles (A/B × accel1/accel2) pour ping-pong"
}

#
# Séquence tout-en-un : OpenOCD en arrière-plan + jtag-load + arrêt OpenOCD.
#
do_jtag() {
    log_step "Séquence JTAG complète (firmware standard)"
    local ocd_pid
    ocd_pid=$(_openocd_start_bg)
    do_jtag_load
    if [[ "$DRY_RUN" != "1" ]] && [[ -n "$ocd_pid" ]]; then
        kill "$ocd_pid" 2>/dev/null || true
        log_ok "OpenOCD arrêté (PID $ocd_pid)"
    fi
}

#
# Séquence tout-en-un : OpenOCD en arrière-plan + jtag-load-dpr + arrêt OpenOCD.
#
do_jtag_dpr() {
    log_step "Séquence JTAG complète (DPR Manager + Linux)"
    local ocd_pid
    ocd_pid=$(_openocd_start_bg)
    do_jtag_load_dpr
    if [[ "$DRY_RUN" != "1" ]] && [[ -n "$ocd_pid" ]]; then
        kill "$ocd_pid" 2>/dev/null || true
        log_ok "OpenOCD arrêté (PID $ocd_pid)"
    fi
}

#
# Charge fw_payload_dpr_bm.bin + 4 bitstreams partiels (DPR Manager + Client baremetal).
# Pré-requis : OpenOCD déjà lancé, 'all-dpr-bm' exécuté.
#
# Layout DDR résultant :
#   0x82000000 : (BAO mappe dpr_client.bin ici au démarrage)
#   0x80000000 : fw_payload_dpr_bm.bin  (OpenSBI + BAO)
#   0x81000000 : partial_accel_A_accel1.bin  (slot 3 Mo)
#   0x81300000 : partial_accel_B_accel1.bin  (slot 3 Mo)
#   0x81600000 : partial_accel_A_accel2.bin  (slot 5 Mo)
#   0x81B00000 : partial_accel_B_accel2.bin  (slot 5 Mo)
#   0x90000000 : (BAO mappe dpr_manager.bin ici au démarrage)
#
do_jtag_load_dpr_bm() {
    log_step "Chargement firmware DPR baremetal + 4 bitstreams via JTAG"

    local bs_a1="$WORK_DPR/partial_accel_A_accel1.bin"
    local bs_b1="$WORK_DPR/partial_accel_B_accel1.bin"
    local bs_a2="$WORK_DPR/partial_accel_A_accel2.bin"
    local bs_b2="$WORK_DPR/partial_accel_B_accel2.bin"

    local err=0
    [[ ! -f "$FW_PAYLOAD_DPR_BM" ]] && { log_error "Firmware introuvable : $FW_PAYLOAD_DPR_BM"
        log_error "  → Lancer 'all-dpr-bm' d'abord"; err=1; }
    [[ ! -f "$bs_a1" ]] && { log_error "Introuvable : $bs_a1"; err=1; }
    [[ ! -f "$bs_b1" ]] && { log_error "Introuvable : $bs_b1"; err=1; }
    [[ ! -f "$bs_a2" ]] && { log_error "Introuvable : $bs_a2"; err=1; }
    [[ ! -f "$bs_b2" ]] && { log_error "Introuvable : $bs_b2"; err=1; }
    [[ $err -ne 0 ]] && { log_error "  → Générer les bitstreams avec '3_build_B.sh dpr'"; exit 1; }

    local sz_a1=$(stat -c%s "$bs_a1") sz_b1=$(stat -c%s "$bs_b1")
    local sz_a2=$(stat -c%s "$bs_a2") sz_b2=$(stat -c%s "$bs_b2")
    local slot1=$((3 * 1024 * 1024))
    local slot2=$((5 * 1024 * 1024))
    [[ $sz_a1 -gt $slot1 ]] && log_warn "partial_accel_A_accel1.bin ($sz_a1 o) dépasse le slot de $slot1 o !"
    [[ $sz_b1 -gt $slot1 ]] && log_warn "partial_accel_B_accel1.bin ($sz_b1 o) dépasse le slot de $slot1 o !"
    [[ $sz_a2 -gt $slot2 ]] && log_warn "partial_accel_A_accel2.bin ($sz_a2 o) dépasse le slot de $slot2 o !"
    [[ $sz_b2 -gt $slot2 ]] && log_warn "partial_accel_B_accel2.bin ($sz_b2 o) dépasse le slot de $slot2 o !"

    log_ok "Firmware   : $FW_PAYLOAD_DPR_BM ($(stat -c%s "$FW_PAYLOAD_DPR_BM") o)"
    log_ok "Slot A1    : $bs_a1 ($(( sz_a1 / 4 )) mots) → $ADDR_BS_A1"
    log_ok "Slot B1    : $bs_b1 ($(( sz_b1 / 4 )) mots) → $ADDR_BS_B1"
    log_ok "Slot A2    : $bs_a2 ($(( sz_a2 / 4 )) mots) → $ADDR_BS_A2"
    log_ok "Slot B2    : $bs_b2 ($(( sz_b2 / 4 )) mots) → $ADDR_BS_B2"

    local gdb_script
    gdb_script=$(mktemp /tmp/jtag_dpr_bm_XXXXXX.gdb)
    trap "rm -f $gdb_script" EXIT

    cat > "$gdb_script" << EOF
set arch riscv:rv64
set remotetimeout 30
target remote localhost:${OPENOCD_PORT}
monitor reset halt
monitor sleep 200

# Firmware OpenSBI + BAO (DPR Manager + Client baremetal)
restore ${FW_PAYLOAD_DPR_BM} binary ${ADDR_FW}

# Bitstreams partiels ping-pong A↔B (4 slots DDR)
restore ${bs_a1} binary ${ADDR_BS_A1}
restore ${bs_b1} binary ${ADDR_BS_B1}
restore ${bs_a2} binary ${ADDR_BS_A2}
restore ${bs_b2} binary ${ADDR_BS_B2}

set \$pc = ${ADDR_FW}
monitor resume
disconnect
quit
EOF

    _gdb_run "$gdb_script"
    log_ok "Chargement terminé — CVA6 démarré depuis $ADDR_FW"
    log_ok "  VM0 DPR Service (manager+test fusionné) lance le ping-pong automatiquement"
}

#
# Séquence tout-en-un : OpenOCD bg + jtag-load-dpr-bm + arrêt OpenOCD.
#
do_jtag_dpr_bm() {
    log_step "Séquence JTAG complète (DPR Manager + Client baremetal)"
    local ocd_pid
    ocd_pid=$(_openocd_start_bg)
    do_jtag_load_dpr_bm
    if [[ "$DRY_RUN" != "1" ]] && [[ -n "$ocd_pid" ]]; then
        kill "$ocd_pid" 2>/dev/null || true
        log_ok "OpenOCD arrêté (PID $ocd_pid)"
    fi
}

# =============================================================================
# Dispatch
# =============================================================================

TARGET="${1:-all}"
FORCE_FPGA=0

for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE_FPGA=1
done
export FORCE_FPGA

[[ "$TARGET" != "clean" ]] && check_deps

case "$TARGET" in
    all)           do_all ;;
    clean)         do_clean ;;
    fpga)          create_dirs; do_fpga ;;
    fpga-dpr)      create_dirs; do_fpga_dpr ;;
    hwicap-setup)  do_hwicap_setup ;;
    baremetal)     create_dirs; do_baremetal ;;
    bao)           create_dirs; do_bao ;;
    opensbi)       create_dirs; do_opensbi ;;
    dpr-manager)   create_dirs; do_dpr_manager ;;
    bao-dpr)       create_dirs; do_bao_dpr_linux ;;
    opensbi-dpr)   create_dirs; do_opensbi_dpr ;;
    all-dpr)       do_all_dpr ;;
    dpr-client)    create_dirs; do_dpr_client ;;
    bao-dpr-bm)    create_dirs; do_bao_dpr_bm ;;
    opensbi-dpr-bm) create_dirs; do_opensbi_dpr_bm ;;
    all-dpr-bm)    do_all_dpr_bm ;;
    program)       create_dirs; do_program ;;
    openocd)       do_openocd ;;
    jtag-load)     do_jtag_load ;;
    jtag-load-dpr) do_jtag_load_dpr ;;
    jtag-load-dpr-bm) do_jtag_load_dpr_bm ;;
    jtag)          do_jtag ;;
    jtag-dpr)      do_jtag_dpr ;;
    jtag-dpr-bm)   do_jtag_dpr_bm ;;
    *)
        log_error "Cible inconnue : '$TARGET'"
        echo ""
        echo "Usage: [ENV_VARS] $0 [TARGET]"
        echo ""
        echo "Targets de build :"
        echo "  all           — fpga + baremetal + bao + opensbi (défaut)"
        echo "  clean         — supprime tous les artefacts"
        echo "  fpga          — synthèse CVA6 (FORCE_FPGA=1 pour forcer)"
        echo "  fpga-dpr      — synthèse DPR"
        echo "                    DPR_MODE=static|clean|all  RM=accel_A|accel_B"
        echo "  hwicap-setup  — intègre l'IP AXI HWICAP (une seule fois)"
        echo "  baremetal     — compile baremetal.bin"
        echo "  bao           — compile BAO (config cva6-baremetal)"
        echo "  opensbi       — compile OpenSBI (payload bao.bin)"
        echo "  dpr-manager   — compile dpr_manager.bin (VM service DPR)"
        echo "  bao-dpr       — compile BAO (config cva6-dpr-linux)"
        echo "  opensbi-dpr   — compile OpenSBI (payload bao-dpr.bin)"
        echo "  all-dpr       — dpr-manager + bao-dpr + opensbi-dpr"
        echo "  dpr-client    — compile dpr_client.bin (VM ping-pong baremetal)"
        echo "  bao-dpr-bm    — compile BAO (config cva6-dpr-baremetal)"
        echo "  opensbi-dpr-bm — compile OpenSBI (payload bao-dpr-bm.bin)"
        echo "  all-dpr-bm    — dpr-full (service+test fusionné) + bao-dpr-bm + opensbi-dpr-bm"
        echo ""
        echo "Targets de déploiement JTAG :"
        echo "  program            — programme le bitstream FPGA via Vivado JTAG"
        echo "  openocd            — lance OpenOCD (bloquant, terminal dédié)"
        echo "  jtag-load          — charge fw_payload.bin → $ADDR_FW via GDB"
        echo "  jtag-load-dpr      — charge fw_payload.bin + 4 bitstreams (DPR Mgr + Linux)"
        echo "  jtag-load-dpr-bm   — charge fw_payload_dpr_bm.bin + 4 bitstreams (DPR Mgr + Client BM)"
        echo "  jtag               — OpenOCD bg + jtag-load (tout-en-un)"
        echo "  jtag-dpr           — OpenOCD bg + jtag-load-dpr (tout-en-un)"
        echo "  jtag-dpr-bm        — OpenOCD bg + jtag-load-dpr-bm (tout-en-un, ping-pong)"
        echo ""
        echo "Workflow ping-pong baremetal (tout-en-un) :"
        echo "  ./$(basename $0) all-dpr-bm    # compiler DPR Manager + Client + BAO + OpenSBI"
        echo "  ./$(basename $0) program       # programmer FPGA"
        echo "  ./$(basename $0) jtag-dpr-bm   # charger et démarrer"
        echo ""
        echo "Variables :"
        echo "  VIVADO_VERSION  (défaut: 2022.2)"
        echo "  VIVADO_DIR      (défaut: /tools/Xilinx/Vivado/\$VIVADO_VERSION)"
        echo "  CROSS_COMPILE   (défaut: riscv64-unknown-elf- toolchain)"
        echo "  BUILD_DIR       (défaut: <root>/build)"
        echo "  JOBS            (défaut: nproc)"
        echo "  DRY_RUN=1       (affiche sans exécuter)"
        echo "  OPENOCD_CFG     (défaut: cva6/corev_apu/fpga/ariane.cfg)"
        echo "  OPENOCD_PORT    (défaut: 3333)"
        echo "  GDB             (défaut: \${CROSS_COMPILE}gdb)"
        exit 1
        ;;
esac
