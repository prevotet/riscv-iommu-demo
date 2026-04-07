#!/bin/bash
# =============================================================================
# 2_build_HB.sh — Script de build flexible pour riscv-iommu-demo
# Usage: [ENV_VARS] ./2_build_HB.sh [TARGET]
#
# Targets : all | clean | fpga | fpga-dpr | hwicap-setup | baremetal | bao |
#           opensbi | dpr-manager | bao-dpr | opensbi-dpr | all-dpr |
#           program | openocd | jtag-load | jtag-load-dpr | jtag | jtag-dpr |
#           sdcard
#
# Variables d'environnement surchargeables :
#   VIVADO_VERSION, VIVADO_DIR
#   RISCV_BARE        (chemin vers riscv64-unknown-elf-)
#   RISCV             (répertoire RISCV)
#   BUILD_DIR         (répertoire de sortie)
#   DRY_RUN=1         (affiche les commandes sans les exécuter)
#   JOBS              (nombre de threads make, défaut: nproc)
#   OPENOCD_CFG       (config OpenOCD, défaut: cva6/corev_apu/fpga/ariane.cfg)
#   OPENOCD_PORT      (port GDB OpenOCD, défaut: 3333)
#   RM_INIT           (RM chargé au boot FPGA, défaut: accel_A)
#   RM_TARGET         (RM dont les bitstreams partiels sont en DDR, défaut: accel_B)
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration — toutes les valeurs sont surchargeables
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

# Chemins dérivés (surchargeables également)
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

# DPR — RMs pour le chargement JTAG
RM_INIT="${RM_INIT:-accel_A}"
RM_TARGET="${RM_TARGET:-accel_B}"

# Firmware OpenSBI (chemin standard après build)
FW_PAYLOAD="$ROOT_DIR/opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin"
FW_ENTRY="0x80000000"

# Adresses DDR fixes
ADDR_FW="0x80000000"
ADDR_BS1="0x81000000"
ADDR_BS2="0x81300000"

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
        log_error "Vivado introuvable : $VIVADO_DIR (surcharger VIVADO_DIR ou VIVADO_VERSION)"
        missing=1
    fi

    if [[ ! -f "${CROSS_COMPILE}gcc" ]] && [[ "$DRY_RUN" != "1" ]]; then
        log_error "Compilateur bare-metal introuvable : ${CROSS_COMPILE}gcc"
        log_error "  → Surcharger CROSS_COMPILE ou RISCV_BARE"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        log_error "Des prérequis sont manquants. Abandon."
        exit 1
    fi

    log_ok "Tous les prérequis sont satisfaits"
}

# =============================================================================
# Initialisation des sous-modules
# =============================================================================

init_submodules() {
    log_step "Initialisation des sous-modules Git"
    RUN git -C "$ROOT_DIR" submodule sync --recursive
    RUN git -C "$ROOT_DIR" submodule foreach --recursive git reset --hard
    RUN git -C "$ROOT_DIR" submodule foreach --recursive git clean -fd
    RUN git -C "$ROOT_DIR" submodule update --init --recursive --force
    log_ok "Sous-modules initialisés"
}

# =============================================================================
# Création des répertoires de build
# =============================================================================

create_dirs() {
    log_step "Création des répertoires de build"
    RUN mkdir -p \
        "$BUILD_DIR" \
        "$TOOLS_DIR/bin" \
        "$BUILD_GUESTS_DIR" \
        "$BUILD_BAO_DIR" \
        "$BUILD_FIRMWARE_DIR" \
        "$BUILD_CVA6_DIR" \
        "$CONFIG_BAREMETAL_DIR"
    log_ok "Répertoires créés sous $BUILD_DIR"
}

# =============================================================================
# HWICAP — Création de la structure IP et intégration dans le projet CVA6
# =============================================================================
do_hwicap_setup() {
    log_step "Configuration de l'IP AXI HWICAP"

    local CVA6_FPGA="$ROOT_DIR/cva6/corev_apu/fpga"
    local SOC_PKG="$ROOT_DIR/cva6/corev_apu/tb/ariane_soc_pkg.sv"
    local PERIPH="$CVA6_FPGA/src/ariane_peripherals_xilinx.sv"
    local TOP="$CVA6_FPGA/src/ariane_xilinx.sv"
    local HWICAP_DIR="$CVA6_FPGA/xilinx/xlnx_axi_hwicap"

    # ------------------------------------------------------------------
    # 1. Créer la structure IP
    # ------------------------------------------------------------------
    log_step "  → Création xilinx/xlnx_axi_hwicap/"
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

    # ------------------------------------------------------------------
    # 2. Mettre à jour le Makefile CVA6
    # ------------------------------------------------------------------
    if ! grep -q "xlnx_axi_hwicap" "$CVA6_FPGA/Makefile"; then
        sed -i \
          's/xlnx_mig_7_ddr3\.xci/xlnx_mig_7_ddr3.xci \\\n       xlnx_axi_hwicap.xci/' \
          "$CVA6_FPGA/Makefile"
        log_ok "  → Makefile CVA6 mis à jour"
    fi

    # ------------------------------------------------------------------
    # 3. ariane_soc_pkg.sv — ajouter HWICAP index + adresse
    # ------------------------------------------------------------------
    if ! grep -q "HWICAP" "$SOC_PKG"; then
        # Ajouter HWICAP = 15 après Debug = 14 dans l'enum
        sed -i 's/Debug     =  14/Debug     =  14,\n    HWICAP    =  15/' "$SOC_PKG"
        # NB_PERIPHERALS = HWICAP + 1
        sed -i 's/localparam NB_PERIPHERALS = Debug + 1;/localparam NB_PERIPHERALS = HWICAP + 1;/' \
            "$SOC_PKG"
        # Ajouter HWICAPLength
        sed -i 's/localparam logic\[63:0\] DRAMLength/localparam logic[63:0] HWICAPLength   = 64'"'"'h1000;\n  localparam logic[63:0] DRAMLength/' \
            "$SOC_PKG"
        # Ajouter HWICAPBase dans l'enum des adresses (après GPIOBase)
        sed -i 's/GPIOBase     = 64'"'"'h4000_0000,/GPIOBase     = 64'"'"'h4000_0000,\n    HWICAPBase   = 64'"'"'h4001_0000,/' \
            "$SOC_PKG"
        log_ok "  → ariane_soc_pkg.sv mis à jour (HWICAP=15, base=0x4001_0000)"
    else
        log_warn "  → HWICAP déjà dans ariane_soc_pkg.sv"
    fi

    # ------------------------------------------------------------------
    # 4. ariane_xilinx.sv — addr_map + InclHWICAP + port + connexion
    # ------------------------------------------------------------------
    if ! grep -q "HWICAP" "$TOP"; then
        # Ajouter l'entrée addr_map après GPIO
        sed -i "s/'{ idx: ariane_soc::GPIO.*GPIOLength      },/'{ idx: ariane_soc::GPIO,      start_addr: ariane_soc::GPIOBase,     end_addr: ariane_soc::GPIOBase      + ariane_soc::GPIOLength      },\n  '{ idx: ariane_soc::HWICAP,    start_addr: ariane_soc::HWICAPBase,   end_addr: ariane_soc::HWICAPBase    + ariane_soc::HWICAPLength    },/" \
            "$TOP"
        # Ajouter InclHWICAP dans l'instanciation ariane_peripherals
        sed -i 's/\.InclGPIO     ( 1'"'"'b1             ),/.InclGPIO     ( 1'"'"'b1             ),\n    .InclHWICAP   ( 1'"'"'b1             ),/' \
            "$TOP"
        # Ajouter le port hwicap dans l'instanciation
        sed -i 's/\.gpio         ( master\[ariane_soc::GPIO\]     ),/.gpio         ( master[ariane_soc::GPIO]     ),\n    .hwicap       ( master[ariane_soc::HWICAP]   ),/' \
            "$TOP"
        log_ok "  → ariane_xilinx.sv mis à jour"
    else
        log_warn "  → HWICAP déjà dans ariane_xilinx.sv"
    fi

    # ------------------------------------------------------------------
    # 5. ariane_peripherals_xilinx.sv — port + paramètre + instanciation
    # ------------------------------------------------------------------
    if ! grep -q "InclHWICAP" "$PERIPH"; then
        # Ajouter le paramètre InclHWICAP
        sed -i 's/parameter bit InclTimer    =  1,/parameter bit InclTimer    =  1,\n    parameter bit InclHWICAP   =  0,/' \
            "$PERIPH"
        # Ajouter le port hwicap
        sed -i 's/AXI_BUS.Slave      timer           ,/AXI_BUS.Slave      timer           ,\n    AXI_BUS.Slave      hwicap          ,/' \
            "$PERIPH"
        # Ajouter l'instanciation à la fin du generate timer
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

    log_ok "HWICAP setup terminé. Séquence suivante :"
    log_ok "  DPR_MODE=clean ./2build_HB.sh fpga-dpr"
    log_ok "  FORCE_FPGA=1 DPR_MODE=static ./2build_HB.sh fpga-dpr"
    log_ok "  RM=accel_default ./2build_HB.sh fpga-dpr"
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
    mkdir -p $ROOT_DIR/cva6/corev_apu/fpga/src/armor/
    mkdir -p $ROOT_DIR/cva6/corev_apu/fpga/src/armor/SRC
    mkdir -p $ROOT_DIR/cva6/corev_apu/fpga/src/armor/Include
    cp -f $ROOT_DIR/armor/SRC/*.sv $ROOT_DIR/cva6/corev_apu/fpga/src/armor/SRC
    cp -f $ROOT_DIR/armor/Include/*.* $ROOT_DIR/cva6/corev_apu/fpga/src/armor/Include

    source "$VIVADO_DIR/settings64.sh"

    if [[ -f "$ROOT_DIR/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit" ]] && [[ "${FORCE_FPGA:-0}" != "1" ]]; then
        log_warn "Synthèse déjà réalisée — pour forcer, utiliser FORCE_FPGA=1 ou './2build_HB.sh fpga --force'"
    else
        log_warn "Mode force activé — suppression des fichiers .bit"
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
    log_step "Synthèse FPGA DPR (Dynamic Partial Reconfiguration)"

    source "$VIVADO_DIR/settings64.sh"

    local rm_to_build="${RM:-accel_default}"
    local dpr_log="$ROOT_DIR/dpr/dpr_build.log"

    log_step "  → Log DPR : $dpr_log"

    if [[ "${DPR_MODE:-}" == "clean" ]]; then
        log_step "  → Nettoyage des artefacts DPR"
        RUN make -C "$ROOT_DIR/dpr" dpr-clean 2>&1 | tee "$dpr_log"
        if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
            log_error "Nettoyage DPR échoué. Voir $dpr_log"
            exit 1
        fi
        log_ok "Nettoyage DPR terminé"
        return
    elif [[ "${DPR_MODE:-}" == "all" ]]; then
        log_step "  → Génération de TOUTES les configurations (dpr-all)"
        RUN make -C "$ROOT_DIR/dpr" dpr-all 2>&1 | tee "$dpr_log"
    elif [[ "${DPR_MODE:-}" == "static" ]]; then
        log_step "  → Génération de la base statique uniquement"
        local force_flag=""
        [[ "${FORCE_FPGA:-0}" == "1" ]] && force_flag="FORCE_STATIC=1"
        RUN make -C "$ROOT_DIR/dpr" dpr-static $force_flag 2>&1 | tee "$dpr_log"
    else
        log_step "  → Génération de la config partielle : $rm_to_build"
        RUN make -C "$ROOT_DIR/dpr" dpr-partial RM="$rm_to_build" 2>&1 | tee "$dpr_log"
    fi

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Flux DPR échoué. Voir $dpr_log"
        grep "^ERROR:\|^CRITICAL" "$dpr_log" | tail -20
        exit 1
    fi

    if [[ -d "$ROOT_DIR/cva6/corev_apu/fpga/work-dpr" ]]; then
        RUN mkdir -p "$BUILD_CVA6_DIR/dpr"
        log_step "  → Archivage des bitstreams DPR vers $BUILD_CVA6_DIR/dpr"
        find "$ROOT_DIR/cva6/corev_apu/fpga/work-dpr" -name "*.bit" \
            -exec cp {} "$BUILD_CVA6_DIR/dpr/" \;
    fi

    log_ok "Flux DPR terminé"
}

do_baremetal() {
    log_step "Compilation des guests baremetal"

    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        -j"$JOBS"

    copy_if_changed \
        "$ROOT_DIR/bao-baremetal-guest/build/cva6/baremetal.bin" \
        "$BUILD_GUESTS_DIR/baremetal.bin"

    log_ok "Guests baremetal compilés"
}

do_bao() {
    log_step "Compilation de BAO hypervisor"

    log_step "  → Copie des configurations VM et plateforme"
    RUN cp -R "$ROOT_DIR/vm-configs/"* "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"

    RUN make -C "$BAO_SRCS" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        CONFIG=cva6-baremetal \
        CPPFLAGS="-DBAO_WRKDIR_IMGS=$BUILD_GUESTS_DIR -DLOGLEVEL=TRACE" \
        -j"$JOBS"

    copy_if_changed \
        "$BAO_SRCS/bin/cva6/cva6-baremetal/bao.bin" \
        "$BUILD_BAO_DIR/bao.bin"

    log_ok "BAO compilé"
}

do_opensbi() {
    log_step "Compilation de OpenSBI"
    RUN make -C "$ROOT_DIR/opensbi" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=fpga/ariane \
        FW_PAYLOAD=y \
        FW_PAYLOAD_PATH="$BAO_SRCS/bin/cva6/cva6-baremetal/bao.bin" \
        -j"$JOBS"
    log_ok "OpenSBI compilé"
}

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

    cat > "$tcl_script" <<EOF
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
        if [[ $? -eq 0 ]]; then
            log_ok "Bitstream chargé"
        else
            log_error "Échec du chargement — voir la sortie Vivado ci-dessus"
            exit 1
        fi
    fi
}

# =============================================================================
# Flashage de la carte SD
# =============================================================================

do_sdcard() {
    log_step "Flashage de la carte SD"

    local fw="$ROOT_DIR/opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin"
    local device="${SDCARD_DEV:-}"

    if [[ ! -f "$fw" ]]; then
        log_error "Firmware introuvable : $fw (lancer 'do_opensbi' d'abord)"
        exit 1
    fi

    if [[ -z "$device" ]]; then
        log_step "  → Détection de la carte SD"
        sudo fdisk -l 2>/dev/null | grep -E "^Disk /dev/sd" || true
        read -rp "Entrer le device SD (ex: /dev/sdc) : " device
    fi

    if [[ ! -b "$device" ]]; then
        log_error "Device introuvable ou non-bloc : $device"
        exit 1
    fi

    log_warn "ATTENTION : $device va être entièrement réécrit !"
    read -rp "Confirmer (oui/NON) : " confirm
    if [[ "$confirm" != "oui" ]]; then
        log_warn "Opération annulée"
        return 0
    fi

    log_step "  → Partitionnement GPT de $device"
    RUN sudo sgdisk --clear \
        --new=1:2048:+32M \
        --new=2 \
        --typecode=1:3000 \
        --typecode=2:8300 \
        "$device" -g

    log_step "  → Écriture du firmware sur ${device}1"
    RUN sudo dd if="$fw" of="${device}1" oflag=sync bs=1M status=progress

    log_ok "Carte SD flashée sur $device"
}

# =============================================================================
# JTAG — OpenOCD + chargement firmware via GDB (sans carte SD)
# =============================================================================

#
# Lance OpenOCD en mode bloquant (terminal dédié).
# Utilise ariane.cfg fourni par le dépôt CVA6.
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
# _openocd_start_bg — démarre OpenOCD en arrière-plan, retourne son PID.
# Attend que le port GDB soit prêt (max 10 s).
#
_openocd_start_bg() {
    if [[ ! -f "$OPENOCD_CFG" ]]; then
        log_error "Config OpenOCD introuvable : $OPENOCD_CFG"
        exit 1
    fi

    log_step "  → Démarrage OpenOCD en arrière-plan..."
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m openocd -f $OPENOCD_CFG &"
        echo "0"   # PID fictif
        return
    fi

    openocd -f "$OPENOCD_CFG" &>/tmp/openocd_bg.log &
    local ocd_pid=$!
    echo "$ocd_pid"

    # Attendre que le port GDB soit ouvert
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
    log_ok "  → OpenOCD prêt (PID $ocd_pid, port $OPENOCD_PORT)"
}

#
# _gdb_run FILE_GDB — exécute un script GDB en mode batch et affiche le résultat.
#
_gdb_run() {
    local gdb_script="$1"

    if [[ ! -x "$(command -v "$GDB")" ]] 2>/dev/null && \
       [[ ! -f "$GDB" ]]; then
        log_error "GDB introuvable : $GDB"
        log_error "  → Surcharger GDB=<chemin complet>"
        exit 1
    fi

    log_step "  → Exécution du script GDB : $gdb_script"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m $GDB -batch -x $gdb_script"
        cat "$gdb_script" | sed 's/^/  /'
    else
        "$GDB" -batch -x "$gdb_script"
    fi
}

#
# do_jtag_load — charge fw_payload.bin via JTAG (sans carte SD).
#
# Pré-requis : OpenOCD déjà lancé (./2_build_HB.sh openocd dans un autre terminal).
# Layout DDR après chargement :
#   0x80000000 : fw_payload.bin  (OpenSBI + BAO + Linux)
#
do_jtag_load() {
    log_step "Chargement firmware via JTAG (sans carte SD)"

    if [[ ! -f "$FW_PAYLOAD" ]]; then
        log_error "Firmware introuvable : $FW_PAYLOAD"
        log_error "  → Lancer './2_build_HB.sh opensbi' ou './2_build_HB.sh opensbi-dpr' d'abord"
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
# Connexion à OpenOCD
set arch riscv:rv64
target remote localhost:${OPENOCD_PORT}
monitor halt

# Chargement firmware OpenSBI + BAO
restore ${FW_PAYLOAD} binary ${ADDR_FW}

# Mise à jour du PC et démarrage
set \$pc = ${ADDR_FW}
monitor resume
disconnect
quit
EOF

    _gdb_run "$gdb_script"
    log_ok "Firmware chargé — CVA6 en cours d'exécution depuis $ADDR_FW"
}

#
# do_jtag_load_dpr — charge fw_payload.bin + bitstreams partiels via JTAG.
#
# Pré-requis : OpenOCD déjà lancé.
# Layout DDR après chargement :
#   0x80000000 : fw_payload.bin            (OpenSBI + BAO DPR Manager + Linux)
#   0x81000000 : partial_${RM_TARGET}_accel1.bin
#   0x81300000 : partial_${RM_TARGET}_accel2.bin
#
do_jtag_load_dpr() {
    log_step "Chargement firmware DPR + bitstreams via JTAG"

    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    local bs2="$WORK_DPR/partial_${RM_TARGET}_accel2.bin"

    if [[ ! -f "$FW_PAYLOAD" ]]; then
        log_error "Firmware introuvable : $FW_PAYLOAD"
        log_error "  → Lancer './2_build_HB.sh opensbi-dpr' d'abord"
        exit 1
    fi
    if [[ ! -f "$bs1" ]]; then
        log_error "Bitstream accel1 introuvable : $bs1"
        log_error "  → Lancer 'RM_TARGET=$RM_TARGET ./2_build_HB.sh fpga-dpr' puis la conversion .bit→.bin"
        exit 1
    fi
    if [[ ! -f "$bs2" ]]; then
        log_error "Bitstream accel2 introuvable : $bs2"
        exit 1
    fi

    local sz1=$(( $(stat -c%s "$bs1") / 4 ))
    local sz2=$(( $(stat -c%s "$bs2") / 4 ))
    log_ok "Firmware  : $FW_PAYLOAD"
    log_ok "Bitstream1: $bs1 ($sz1 mots) → $ADDR_BS1"
    log_ok "Bitstream2: $bs2 ($sz2 mots) → $ADDR_BS2"

    local gdb_script
    gdb_script=$(mktemp /tmp/jtag_load_dpr_XXXXXX.gdb)
    trap "rm -f $gdb_script" EXIT

    cat > "$gdb_script" << EOF
# Connexion à OpenOCD
set arch riscv:rv64
target remote localhost:${OPENOCD_PORT}
monitor halt

# Chargement firmware OpenSBI + BAO (DPR Manager + Linux)
restore ${FW_PAYLOAD} binary ${ADDR_FW}

# Chargement des bitstreams partiels (RM_TARGET=${RM_TARGET})
restore ${bs1} binary ${ADDR_BS1}
restore ${bs2} binary ${ADDR_BS2}

# Mise à jour du PC et démarrage
set \$pc = ${ADDR_FW}
monitor resume
disconnect
quit
EOF

    _gdb_run "$gdb_script"
    log_ok "Firmware + bitstreams chargés — CVA6 en cours d'exécution"
    log_ok "  IPC DPR Manager disponible à 0xF0000000 dans chaque VM"
}

#
# do_jtag — séquence complète JTAG (sans carte SD) pour le firmware standard.
# Lance OpenOCD en arrière-plan, charge le firmware, arrête OpenOCD.
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
# do_jtag_dpr — séquence complète JTAG pour la config DPR Manager + Linux.
# Lance OpenOCD en arrière-plan, charge firmware + bitstreams, arrête OpenOCD.
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

# =============================================================================
# DPR Manager
# =============================================================================

do_dpr_manager() {
    log_step "Compilation du guest DPR Manager"

    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        VARIANT=dpr_manager \
        NAME=dpr_manager \
        -j"$JOBS"

    copy_if_changed \
        "$ROOT_DIR/bao-baremetal-guest/build/cva6/dpr_manager.bin" \
        "$BUILD_GUESTS_DIR/dpr_manager.bin"

    log_ok "DPR Manager compilé → $BUILD_GUESTS_DIR/dpr_manager.bin"
}

do_bao_dpr_linux() {
    log_step "Compilation de BAO (config cva6-dpr-linux)"

    RUN cp -R "$ROOT_DIR/vm-configs/"*  "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"

    RUN make -C "$BAO_SRCS" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        CONFIG=cva6-dpr-linux \
        CPPFLAGS="-DBAO_WRKDIR_IMGS=$BUILD_GUESTS_DIR -DLOGLEVEL=TRACE" \
        -j"$JOBS"

    copy_if_changed \
        "$BAO_SRCS/bin/cva6/cva6-dpr-linux/bao.bin" \
        "$BUILD_BAO_DIR/bao-dpr.bin"

    log_ok "BAO DPR compilé → $BUILD_BAO_DIR/bao-dpr.bin"
}

do_opensbi_dpr() {
    log_step "Compilation de OpenSBI (payload DPR Manager + Linux)"
    RUN make -C "$ROOT_DIR/opensbi" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=fpga/ariane \
        FW_PAYLOAD=y \
        FW_PAYLOAD_PATH="$BUILD_BAO_DIR/bao-dpr.bin" \
        -j"$JOBS"
    log_ok "OpenSBI DPR compilé"
}

do_all() {
    create_dirs
    do_fpga
    do_baremetal
    do_bao
    do_opensbi
    log_ok "Build complet terminé. Artefacts dans : $BUILD_DIR"
}

do_all_dpr() {
    create_dirs
    do_dpr_manager
    do_bao_dpr_linux
    do_opensbi_dpr
    log_ok "Build DPR terminé. Artefacts dans : $BUILD_DIR"
    log_ok "  DPR Manager : $BUILD_GUESTS_DIR/dpr_manager.bin"
    log_ok "  BAO DPR     : $BUILD_BAO_DIR/bao-dpr.bin"
    log_ok "  Firmware    : opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin"
}

# =============================================================================
# Dispatch
# =============================================================================

TARGET="${1:-all}"
FORCE_FPGA=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE_FPGA=1 ;;
    esac
done
export FORCE_FPGA

if [[ "$TARGET" != "clean" ]]; then
    check_deps
fi

case "$TARGET" in
    all)          do_all ;;
    clean)        do_clean ;;
    fpga)         create_dirs; do_fpga ;;
    fpga-dpr)     create_dirs; do_fpga_dpr ;;
    hwicap-setup) do_hwicap_setup ;;
    baremetal)    create_dirs; do_baremetal ;;
    bao)          create_dirs; do_bao ;;
    opensbi)      create_dirs; do_opensbi ;;
    dpr-manager)   create_dirs; do_dpr_manager ;;
    bao-dpr)       create_dirs; do_bao_dpr_linux ;;
    opensbi-dpr)   create_dirs; do_opensbi_dpr ;;
    all-dpr)       do_all_dpr ;;
    program)       create_dirs; do_program ;;
    openocd)       do_openocd ;;
    jtag-load)     do_jtag_load ;;
    jtag-load-dpr) do_jtag_load_dpr ;;
    jtag)          do_jtag ;;
    jtag-dpr)      do_jtag_dpr ;;
    sdcard)        do_sdcard ;;
    *)
        log_error "Cible inconnue : '$TARGET'"
        echo ""
        echo "Usage: [ENV_VARS] $0 [TARGET]"
        echo ""
        echo "Targets disponibles :"
        echo "  all           — build complet (défaut)"
        echo "  clean         — supprime tous les artefacts"
        echo "  fpga          — synthèse CVA6 uniquement"
        echo "                  FORCE_FPGA=1 ./2build_HB.sh fpga"
        echo "                  ./2build_HB.sh fpga --force"
        echo ""
        echo "  hwicap-setup  — crée l'IP AXI HWICAP et met à jour le Makefile CVA6"
        echo "                  FORCE_HWICAP=1 ./2build_HB.sh hwicap-setup  # écraser"
        echo ""
        echo "  fpga-dpr      — synthèse avec Reconfiguration Partielle Dynamique"
        echo "  DPR_MODE=clean  ./2build_HB.sh fpga-dpr"
        echo "  DPR_MODE=static ./2build_HB.sh fpga-dpr"
        echo "  FORCE_FPGA=1 DPR_MODE=static ./2build_HB.sh fpga-dpr"
        echo "  RM=accel_A ./2build_HB.sh fpga-dpr"
        echo "  DPR_MODE=all ./2build_HB.sh fpga-dpr"
        echo ""
        echo "  baremetal     — guests baremetal uniquement"
        echo "  bao           — hyperviseur BAO uniquement (config cva6-baremetal)"
        echo "  opensbi       — OpenSBI uniquement"
        echo ""
        echo "  dpr-manager   — compiler le guest DPR Manager (VM de service HWICAP)"
        echo "  bao-dpr       — BAO avec config cva6-dpr-linux (DPR Manager + Linux)"
        echo "  opensbi-dpr   — OpenSBI avec payload bao-dpr.bin"
        echo "  all-dpr       — dpr-manager + bao-dpr + opensbi-dpr"
        echo ""
        echo "  program       — charge le bitstream FPGA via Vivado JTAG"
        echo ""
        echo "Démarrage via JTAG (sans carte SD) :"
        echo "  openocd       — lancer OpenOCD (bloquant, terminal dédié)"
        echo "  jtag-load     — charger fw_payload.bin via GDB → $ADDR_FW"
        echo "                  OPENOCD déjà lancé requis"
        echo "  jtag-load-dpr — charger fw_payload.bin + bitstreams DPR via GDB"
        echo "                  RM_TARGET=$RM_TARGET  (bitstreams à $ADDR_BS1 / $ADDR_BS2)"
        echo "  jtag          — OpenOCD bg + jtag-load (tout-en-un)"
        echo "  jtag-dpr      — OpenOCD bg + jtag-load-dpr (tout-en-un)"
        echo ""
        echo "Workflow JTAG typique :"
        echo "  Terminal 1 : ./2_build_HB.sh openocd"
        echo "  Terminal 2 : ./2_build_HB.sh jtag-load        # firmware standard"
        echo "             : ./2_build_HB.sh jtag-load-dpr     # DPR Manager + Linux"
        echo "  Ou tout-en-un :"
        echo "             : ./2_build_HB.sh jtag"
        echo "             : ./2_build_HB.sh jtag-dpr"
        echo ""
        echo "  sdcard        — partitionne et flashe la carte SD"
        echo "                  SDCARD_DEV=/dev/sdc ./2build_HB.sh sdcard"
        echo ""
        echo "Variables d'environnement :"
        echo "  VIVADO_VERSION     (défaut: 2022.2)"
        echo "  VIVADO_DIR         (défaut: /tools/Xilinx/Vivado/\$VIVADO_VERSION)"
        echo "  CROSS_COMPILE      (défaut: riscv64-unknown-elf- toolchain)"
        echo "  BUILD_DIR          (défaut: <root>/build)"
        echo "  JOBS               (défaut: nproc)"
        echo "  DRY_RUN=1          (affiche les commandes sans les exécuter)"
        echo "  FORCE_HWICAP=1     (force la recréation des fichiers HWICAP)"
        echo "  OPENOCD_CFG        (défaut: cva6/corev_apu/fpga/ariane.cfg)"
        echo "  OPENOCD_PORT       (défaut: 3333)"
        echo "  GDB                (défaut: \${CROSS_COMPILE}gdb)"
        echo "  RM_INIT            (défaut: accel_A — RM programmé dans le FPGA)"
        echo "  RM_TARGET          (défaut: accel_B — RM dont les .bin sont en DDR)"
        exit 1
        ;;
esac