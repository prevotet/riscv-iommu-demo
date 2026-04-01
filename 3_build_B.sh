#!/bin/bash
# =============================================================================
# 3_build_B.sh — Script de test DPR standalone (sans BAO, sans Linux)
# Usage: [ENV_VARS] ./3_build_B.sh [TARGET]
#
# Targets : dpr | baremetal | convert-bin | bitstreams | program | openocd | load | all
#
# Layout DDR (adresses fixes) :
#   0x81000000 : partial_accel_B_accel1.bin
#   0x81300000 : partial_accel_B_accel2.bin
#   0x90000000 : baremetal.bin
#
# Variables d'environnement :
#   VIVADO_VERSION, VIVADO_DIR
#   RISCV_BARE
#   RM_INIT           (RM chargé au démarrage, défaut: accel_A)
#   RM_TARGET         (RM cible après reconfiguration, défaut: accel_B)
#   FORCE_STATIC=1    (forcer la régénération du checkpoint statique)
#   FORCE_BAREMETAL=1 (forcer la recompilation du baremetal)
#   DRY_RUN=1
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VIVADO_VERSION="${VIVADO_VERSION:-2022.2}"
VIVADO_DIR="${VIVADO_DIR:-/tools/Xilinx/Vivado/${VIVADO_VERSION}}"

RISCV_BARE="${RISCV_BARE:-/home/jc/Software/riscv64-unknown-elf-gcc-10.1.0-2020.08.2-x86_64-linux-ubuntu14/bin/riscv64-unknown-elf-}"
export CROSS_COMPILE="${CROSS_COMPILE:-$RISCV_BARE}"

WORK_DPR="$ROOT_DIR/cva6/corev_apu/fpga/work-dpr"
BAREMETAL_DIR="$ROOT_DIR/bao-baremetal-guest"
BAREMETAL_BIN="$BAREMETAL_DIR/build/cva6/baremetal.bin"
BAREMETAL_ELF="$BAREMETAL_DIR/build/cva6/baremetal.elf"
OPENOCD_CFG="$ROOT_DIR/cva6/corev_apu/fpga/ariane.cfg"
DPR_DIR="$ROOT_DIR/dpr"

RM_INIT="${RM_INIT:-accel_A}"
RM_TARGET="${RM_TARGET:-accel_B}"
FORCE_STATIC="${FORCE_STATIC:-0}"
FORCE_BAREMETAL="${FORCE_BAREMETAL:-0}"

DRY_RUN="${DRY_RUN:-0}"

# Adresses fixes DDR
ADDR_BAREMETAL=90000000
ADDR_BS1=81000000
ADDR_BS2=81300000

# =============================================================================
# Utilitaires
# =============================================================================

log_step()  { echo -e "\e[34m==>\e[0m \e[1m$*\e[0m"; }
log_ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
log_skip()  { echo -e "\e[90m[SKIP]\e[0m $*"; }

RUN() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m $*"
    else
        "$@"
    fi
}

check_file() {
    if [[ ! -f "$1" ]]; then
        log_error "Fichier manquant : $1"
        exit 1
    fi
}

# =============================================================================
# Flow DPR — génération des bitstreams
# =============================================================================

do_dpr() {
    log_step "Flow DPR (statique + partiels)"
    source "$VIVADO_DIR/settings64.sh"

    # --- Étape 1 : Checkpoint statique ---
    local static_dcp="$WORK_DPR/static_routed.dcp"
    if [[ -f "$static_dcp" ]] && [[ "$FORCE_STATIC" != "1" ]]; then
        log_skip "Checkpoint statique déjà présent — FORCE_STATIC=1 pour forcer"
    else
        log_step "  → Génération du checkpoint statique..."
        RUN make -C "$DPR_DIR" dpr-static FORCE_STATIC=1
        log_ok "  → Checkpoint statique généré"
    fi

    # --- Étape 2 : Bitstreams partiels par RM ---
    for rm in accel_default "$RM_INIT" "$RM_TARGET"; do
        # Déduplique si RM_INIT == RM_TARGET (peu probable mais propre)
        local full_bit="$WORK_DPR/full_${rm}.bit"
        if [[ -f "$full_bit" ]]; then
            log_skip "Bitstream full_${rm}.bit déjà présent"
        else
            log_step "  → Génération RM : $rm"
            RUN make -C "$DPR_DIR" dpr-partial RM="$rm"
            log_ok "  → Bitstreams $rm générés"
        fi
    done

    # --- Étape 3 : Conversion .bit → .bin ---
    do_convert_bin
}

# =============================================================================
# Compilation du baremetal standalone
# =============================================================================

do_baremetal() {
    log_step "Compilation baremetal standalone (PLATFORM=cva6)"

    if [[ -f "$BAREMETAL_BIN" ]] && [[ "$FORCE_BAREMETAL" != "1" ]]; then
        log_skip "Baremetal déjà compilé — FORCE_BAREMETAL=1 pour forcer"
        return
    fi

    RUN make -C "$BAREMETAL_DIR" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        SINGLE_CORE=y \
        -j"$(nproc)"

    check_file "$BAREMETAL_BIN"
    log_ok "Baremetal compilé : $BAREMETAL_BIN ($(( $(stat -c%s "$BAREMETAL_BIN") / 1024 )) KB)"
}

# =============================================================================
# Conversion des bitstreams .bit → .bin
# =============================================================================

do_convert_bin() {
    log_step "Conversion bitstreams partiels .bit → .bin"

    for accel in accel1 accel2; do
        local bit="$WORK_DPR/partial_${RM_TARGET}_${accel}.bit"
        local bin="$WORK_DPR/partial_${RM_TARGET}_${accel}.bin"

        check_file "$bit"

        # Vérifier si le .bin est plus récent que le .bit
        if [[ -f "$bin" ]] && [[ "$bin" -nt "$bit" ]]; then
            log_skip "$(basename $bin) déjà à jour"
            continue
        fi

        local offset
        offset=$(python3 -c "
data = open('$bit','rb').read()
idx = data.find(bytes.fromhex('AA995566'))
print(idx if idx >= 0 else -1)
")
        if [[ "$offset" -lt 0 ]]; then
            log_error "Sync word 0xAA995566 non trouvé dans $bit"
            exit 1
        fi

        log_step "  → $accel : header = $offset octets"
        RUN dd if="$bit" of="$bin" bs=1 skip="$offset" status=none

        check_file "$bin"
        log_ok "  → $(basename $bin) : $(( $(stat -c%s "$bin") / 1024 )) KB"
    done
}

# =============================================================================
# Vérification des bitstreams
# =============================================================================

do_check_bitstreams() {
    log_step "Vérification des bitstreams DPR"

    local full_bit="$WORK_DPR/full_${RM_INIT}.bit"
    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    local bs2="$WORK_DPR/partial_${RM_TARGET}_accel2.bin"

    check_file "$full_bit"
    check_file "$bs1"
    check_file "$bs2"

    local sz1=$(( $(stat -c%s "$bs1") / 4 ))
    local sz2=$(( $(stat -c%s "$bs2") / 4 ))

    log_ok "Bitstreams présents :"
    log_ok "  full    : $full_bit"
    log_ok "  partial1: $bs1 ($sz1 mots)"
    log_ok "  partial2: $bs2 ($sz2 mots)"
    echo ""
    log_ok "Constantes pour dpr_test.c :"
    log_ok "  #define BS_ACCEL1_ADDR  0x${ADDR_BS1}ULL"
    log_ok "  #define BS_ACCEL2_ADDR  0x${ADDR_BS2}ULL"
    log_ok "  #define BS_ACCEL1_WORDS ${sz1}UL"
    log_ok "  #define BS_ACCEL2_WORDS ${sz2}UL"
}

# =============================================================================
# Programmation du FPGA via Vivado JTAG
# =============================================================================

do_program() {
    log_step "Programmation du FPGA — full_${RM_INIT}.bit"

    local full_bit="$WORK_DPR/full_${RM_INIT}.bit"
    check_file "$full_bit"

    source "$VIVADO_DIR/settings64.sh"

    local tcl_script
    tcl_script=$(mktemp /tmp/program_XXXXXX.tcl)
    trap "rm -f $tcl_script" EXIT

    cat > "$tcl_script" << EOF
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7k*] 0]
current_hw_device \$dev
set_property PROGRAM.FILE {$full_bit} \$dev
program_hw_devices \$dev
puts "==> FPGA programmé avec full_${RM_INIT}.bit"
close_hw_target
disconnect_hw_server
close_hw_manager
EOF

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m vivado -mode batch -nojournal -nolog -source $tcl_script"
    else
        vivado -mode batch -nojournal -nolog -source "$tcl_script"
        log_ok "FPGA programmé"
    fi
}

# =============================================================================
# Lancement d'OpenOCD
# =============================================================================

do_openocd() {
    log_step "Lancement OpenOCD"
    check_file "$OPENOCD_CFG"
    log_ok "Config : $OPENOCD_CFG"
    log_ok "Ports  : telnet=4444  gdb=3333"
    log_warn "Ctrl+C pour arrêter OpenOCD"
    echo ""
    RUN openocd -f "$OPENOCD_CFG"
}

# =============================================================================
# Affichage des commandes de chargement
# =============================================================================

do_load() {
    log_step "Commandes de chargement"

    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    local bs2="$WORK_DPR/partial_${RM_TARGET}_accel2.bin"

    check_file "$bs1"
    check_file "$bs2"
    check_file "$BAREMETAL_BIN"

    local sz1=$(( $(stat -c%s "$bs1") / 4 ))
    local sz2=$(( $(stat -c%s "$bs2") / 4 ))

    # Vérifier que accel1 ne déborde pas sur accel2
    local max_sz1=$(( 0x${ADDR_BS2} - 0x${ADDR_BS1} ))
    if [[ $(( sz1 * 4 )) -gt $max_sz1 ]]; then
        log_error "Bitstream accel1 trop grand : $(( sz1*4 )) > $max_sz1"
        exit 1
    fi

    log_ok "Bitstream accel1 : $sz1 mots ($(( sz1*4 )) octets) @ 0x${ADDR_BS1}"
    log_ok "Bitstream accel2 : $sz2 mots ($(( sz2*4 )) octets) @ 0x${ADDR_BS2}"
    log_ok "Baremetal        : $(stat -c%s "$BAREMETAL_BIN") octets @ 0x${ADDR_BAREMETAL}"
    echo ""
    echo "=== Commandes GDB ==="
    echo ""
    echo "riscv64-unknown-elf-gdb $BAREMETAL_ELF"
    echo "  target remote localhost:3333"
    echo "  restore $bs1 binary 0x${ADDR_BS1}"
    echo "  restore $bs2 binary 0x${ADDR_BS2}"
    echo "  load"
    echo "  set \$pc = 0x${ADDR_BAREMETAL}"
    echo "  continue"
    echo ""
    echo "=== Constantes pour dpr_test.c ==="
    echo ""
    echo "  #define BS_ACCEL1_ADDR  0x${ADDR_BS1}ULL"
    echo "  #define BS_ACCEL2_ADDR  0x${ADDR_BS2}ULL"
    echo "  #define BS_ACCEL1_WORDS ${sz1}UL"
    echo "  #define BS_ACCEL2_WORDS ${sz2}UL"
}

# =============================================================================
# All
# =============================================================================

do_all() {
    do_dpr
    do_baremetal
    do_program
    echo ""
    do_load
    log_warn "Lance OpenOCD dans un terminal dédié : ./3_build_B.sh openocd"
}

# =============================================================================
# Dispatch
# =============================================================================

TARGET="${1:-all}"

# Parsing des flags
for arg in "$@"; do
    case "$arg" in
        --force-static)    FORCE_STATIC=1 ;;
        --force-baremetal) FORCE_BAREMETAL=1 ;;
        --force)           FORCE_STATIC=1; FORCE_BAREMETAL=1 ;;
    esac
done

case "$TARGET" in
    all)          do_all ;;
    dpr)          source "$VIVADO_DIR/settings64.sh"; do_dpr ;;
    baremetal)    do_baremetal ;;
    convert-bin)  do_convert_bin ;;
    bitstreams)   do_check_bitstreams ;;
    program)      do_program ;;
    openocd)      do_openocd ;;
    load)         do_load ;;
    *)
        log_error "Cible inconnue : '$TARGET'"
        echo ""
        echo "Usage: [ENV_VARS] $0 [TARGET] [FLAGS]"
        echo ""
        echo "Workflow :"
        echo "  1. ./3_build_B.sh dpr          # générer les bitstreams"
        echo "  2. ./3_build_B.sh baremetal     # compiler le baremetal"
        echo "  3. ./3_build_B.sh program       # programmer le FPGA"
        echo "  4. ./3_build_B.sh openocd       # terminal 1 (bloquant)"
        echo "  5. ./3_build_B.sh load          # affiche les commandes GDB"
        echo "  Ou tout d'un coup :"
        echo "  ./3_build_B.sh all"
        echo ""
        echo "Targets :"
        echo "  all          — dpr + baremetal + program + load"
        echo "  dpr          — générer les bitstreams (statique + partiels)"
        echo "  baremetal    — compiler le guest baremetal standalone"
        echo "  convert-bin  — convertir les bitstreams .bit → .bin"
        echo "  bitstreams   — vérifier et afficher les constantes C"
        echo "  program      — programmer le FPGA"
        echo "  openocd      — lancer OpenOCD (bloquant)"
        echo "  load         — afficher les commandes GDB"
        echo ""
        echo "Flags :"
        echo "  --force           forcer la régénération de tout"
        echo "  --force-static    forcer uniquement le checkpoint statique"
        echo "  --force-baremetal forcer uniquement la recompilation baremetal"
        echo ""
        echo "Variables :"
        echo "  RM_INIT=accel_A      (RM chargé au démarrage)"
        echo "  RM_TARGET=accel_B    (RM cible après reconfiguration)"
        echo "  VIVADO_VERSION=2022.2"
        echo "  DRY_RUN=1"
        echo ""
        echo "Exemples :"
        echo "  ./3_build_B.sh all"
        echo "  ./3_build_B.sh dpr --force-static"
        echo "  RM_INIT=accel_B RM_TARGET=accel_A ./3_build_B.sh all"
        exit 1
        ;;
esac