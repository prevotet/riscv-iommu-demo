#!/bin/bash
# =============================================================================
# 2_build_HB_sdcard.sh — Build + déploiement via carte SD
# Usage: [ENV_VARS] ./2_build_HB_sdcard.sh [TARGET]
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
#   program       — programme le bitstream FPGA via Vivado JTAG
#   sdcard        — partitionne et flashe la carte SD avec fw_payload.bin
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
#   SDCARD_DEV       (ex: /dev/sdc — évite la demande interactive)
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

FW_PAYLOAD="$ROOT_DIR/opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin"

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
    CONFIG.C_INCLUDE_STARTUP {0} \
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
# Programme le bitstream FPGA via Vivado JTAG
# =============================================================================

do_program() {
    log_step "Chargement du bitstream sur Genesys2"
    local bit="$BUILD_CVA6_DIR/ariane_xilinx.bit"

    if [[ ! -f "$bit" ]]; then
        log_error "Bitstream introuvable : $bit"
        exit 1
    fi

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
# Flashage de la carte SD
# =============================================================================

do_sdcard() {
    log_step "Flashage de la carte SD"

    if [[ ! -f "$FW_PAYLOAD" ]]; then
        log_error "Firmware introuvable : $FW_PAYLOAD"
        log_error "  → Lancer 'opensbi' ou 'opensbi-dpr' d'abord"
        exit 1
    fi

    local device="${SDCARD_DEV:-}"

    if [[ -z "$device" ]]; then
        log_step "  → Périphériques disponibles :"
        sudo fdisk -l 2>/dev/null | grep -E "^Disk /dev/sd" || true
        read -rp "Entrer le device SD (ex: /dev/sdc) : " device
    fi

    if [[ ! -b "$device" ]]; then
        log_error "Device introuvable ou non-bloc : $device"
        exit 1
    fi

    log_warn "ATTENTION : $device va être entièrement réécrit !"
    log_warn "Firmware   : $FW_PAYLOAD ($(stat -c%s "$FW_PAYLOAD") octets)"
    read -rp "Confirmer (oui/NON) : " confirm
    [[ "$confirm" != "oui" ]] && { log_warn "Annulé."; return 0; }

    log_step "  → Partitionnement GPT de $device"
    RUN sudo sgdisk --clear \
        --new=1:2048:+32M \
        --new=2 \
        --typecode=1:3000 \
        --typecode=2:8300 \
        "$device" -g

    log_step "  → Écriture du firmware sur ${device}1"
    RUN sudo dd if="$FW_PAYLOAD" of="${device}1" oflag=sync bs=1M status=progress

    log_ok "Carte SD flashée sur $device"
    log_ok "Séquence de démarrage : insérer la carte, mettre sous tension, le CVA6 démarre depuis $device"
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
    all)          do_all ;;
    clean)        do_clean ;;
    fpga)         create_dirs; do_fpga ;;
    fpga-dpr)     create_dirs; do_fpga_dpr ;;
    hwicap-setup) do_hwicap_setup ;;
    baremetal)    create_dirs; do_baremetal ;;
    bao)          create_dirs; do_bao ;;
    opensbi)      create_dirs; do_opensbi ;;
    dpr-manager)  create_dirs; do_dpr_manager ;;
    bao-dpr)      create_dirs; do_bao_dpr_linux ;;
    opensbi-dpr)  create_dirs; do_opensbi_dpr ;;
    all-dpr)      do_all_dpr ;;
    program)      create_dirs; do_program ;;
    sdcard)       do_sdcard ;;
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
        echo ""
        echo "Targets de déploiement :"
        echo "  program       — programme le bitstream FPGA via Vivado JTAG"
        echo "  sdcard        — partitionne et flashe la carte SD avec fw_payload.bin"
        echo "                    SDCARD_DEV=/dev/sdc ./$(basename $0) sdcard"
        echo ""
        echo "Workflow carte SD :"
        echo "  1. ./$(basename $0) all          # ou all-dpr pour DPR Manager"
        echo "  2. ./$(basename $0) program       # charger le bitstream FPGA"
        echo "  3. ./$(basename $0) sdcard        # flasher la carte SD"
        echo "  4. Insérer la carte SD, mettre sous tension"
        echo ""
        echo "Variables :"
        echo "  VIVADO_VERSION  (défaut: 2022.2)"
        echo "  VIVADO_DIR      (défaut: /tools/Xilinx/Vivado/\$VIVADO_VERSION)"
        echo "  CROSS_COMPILE   (défaut: riscv64-unknown-elf- toolchain)"
        echo "  BUILD_DIR       (défaut: <root>/build)"
        echo "  JOBS            (défaut: nproc)"
        echo "  DRY_RUN=1       (affiche sans exécuter)"
        echo "  SDCARD_DEV      (ex: /dev/sdc)"
        exit 1
        ;;
esac
