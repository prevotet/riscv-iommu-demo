#!/bin/bash
# =============================================================================
# build.sh — Script de build flexible pour riscv-iommu-demo
# Usage: [ENV_VARS] ./build.sh [TARGET]
#
# Targets : all | clean | fpga | baremetal | bao | opensbi
#
# Variables d'environnement surchargeables :
#   VIVADO_VERSION, VIVADO_DIR
#   RISCV_BARE        (chemin vers riscv64-unknown-elf-)
#   RISCV             (répertoire RISCV)
#   BUILD_DIR         (répertoire de sortie)
#   DRY_RUN=1         (affiche les commandes sans les exécuter)
#   JOBS              (nombre de threads make, défaut: nproc)
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration — toutes les valeurs sont surchargeables
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VIVADO_VERSION="${VIVADO_VERSION:-2022.2}"
VIVADO_DIR="${VIVADO_DIR:-/tools/Xilinx/Vivado/${VIVADO_VERSION}}"

# Toolchain bare-metal : newlib construite en rv64imac / lp64 / medany
# (le guest est lie a PLAT_MEM_BASE=0x90000000, medlow ne peut pas l'atteindre)
RISCV_BARE="${RISCV_BARE:-/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf-}"
RISCV_LINUX_DIR="${RISCV_LINUX_DIR:-/usr}"
export RISCV="${RISCV:-$RISCV_LINUX_DIR}"

export CROSS_COMPILE="${CROSS_COMPILE:-$RISCV_BARE}"
export PATH="$RISCV_LINUX_DIR/bin:$PATH"

# OpenSBI v1.0 avec un GCC recent (defaut C23) :
#   - sbi_types.h fait `typedef int bool`, interdit depuis C23 -> -std=gnu11
#   - l'ISA devinee via `gcc -v --with-arch` est tronquee au premier `_`,
#     d'ou une -march sans zicsr/zifencei -> csrr/csrw non reconnus
OPENSBI_CC="${OPENSBI_CC:-${RISCV_BARE}gcc -std=gnu11}"
OPENSBI_RISCV_ISA="${OPENSBI_RISCV_ISA:-rv64imac_zicsr_zifencei}"

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

# =============================================================================
# Utilitaires
# =============================================================================

log_step()  { echo -e "\e[34m==>\e[0m \e[1m$*\e[0m"; }
log_ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

# Wrapper DRY_RUN : affiche la commande sans l'exécuter si DRY_RUN=1
RUN() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m $*"
    else
        "$@"
    fi
}

# Copie uniquement si le fichier source a changé
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
# Cibles de build
# =============================================================================

do_clean() {
    log_step "Nettoyage de tous les artefacts"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest"    clean
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" clean
    RUN make -C "$ROOT_DIR/bao-hypervisor"         clean
    RUN make -C "$ROOT_DIR/opensbi"                clean
    log_ok "Nettoyage terminé"
}

do_fpga() {
    log_step "Synthèse FPGA (CVA6)"
    #cp -f $ROOT_DIR/cva6/corev_apu/rv_iommu/packages/dependencies/ariane_axi_soc_pkg.sv $ROOT_DIR/cva6/corev_apu/tb
    # Copy armor files 
    mkdir -p $ROOT_DIR/cva6/corev_apu/fpga/src/armor/
    mkdir -p $ROOT_DIR/cva6/corev_apu/fpga/src/armor/SRC
    mkdir -p $ROOT_DIR/cva6/corev_apu/fpga/src/armor/Include
    cp -f $ROOT_DIR/armor/SRC/*.sv $ROOT_DIR/cva6/corev_apu/fpga/src/armor/SRC
    cp -f $ROOT_DIR/armor/Include/*.* $ROOT_DIR/cva6/corev_apu/fpga/src/armor/Include

    # Overlay : fichiers du sous-module cva6 modifies et conserves dans le depot
    # principal, sinon effaces par le `git reset --hard` de init_submodules.
    # (arborescence miroir : cva6-overlay/<chemin relatif dans cva6/>)
    if [[ -d "$ROOT_DIR/cva6-overlay" ]]; then
        log_step "  → Overlay cva6 (run.tcl, …)"
        RUN cp -a "$ROOT_DIR/cva6-overlay/." "$ROOT_DIR/cva6/"
    fi

   # cp -f $ROOT_DIR/cva6/corev_apu/rv_iommu/packages/dependencies/ariane_soc_pkg.sv $ROOT_DIR/cva6/corev_apu/tb/ariane_soc_pkg.sv
    source "$VIVADO_DIR/settings64.sh"
    
    if [[ -f "$ROOT_DIR/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit" ]] && [[ "${FORCE_FPGA:-0}" != "1" ]]; then
        log_warn "Synthèse déjà réalisée — pour forcer, utiliser FORCE_FPGA=1 ou './build.sh fpga --force'"
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

do_baremetal() {
    log_step "Compilation des guests baremetal"

    # Copie du source principal depuis trust_gw
    #copy_if_changed \
     #   "$ROOT_DIR/trust_gw/bao-baremetal-guest/src/main.c" \
      #  "$ROOT_DIR/bao-baremetal-guest/src/main.c"

    log_step "  → Guest baremetal principal"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        -j"$JOBS"

    log_step "  → Guest baremetal"
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
    RUN cp -R "$ROOT_DIR/vm-configs/"*   "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"

    # Overlay : fichiers de bao-hypervisor modifies et conserves dans le depot
    # principal. Meme mecanisme et meme raison que cva6-overlay : bao-hypervisor
    # EST un sous-module suivi, mais init_submodules y fait `git reset --hard`
    # + `git clean -fd`, ce qui effacerait toute edition faite directement
    # dedans. La garder ici la met hors d'atteinte -- et evite d'avoir a
    # committer puis pousser un second depot pour un seul bit.
    # (arborescence miroir : bao-overlay/<chemin relatif dans bao-hypervisor/>)
    if [[ -d "$ROOT_DIR/bao-overlay" ]]; then
        log_step "  → Overlay bao (hcounteren, …)"
        RUN cp -a "$ROOT_DIR/bao-overlay/." "$BAO_SRCS/"
    fi

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
        CC="$OPENSBI_CC" \
        PLATFORM_RISCV_ISA="$OPENSBI_RISCV_ISA" \
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

    log_step "  → Bitstream : $bit"

    source "$VIVADO_DIR/settings64.sh"

    # Écriture du script TCL dans un fichier temporaire
    local tcl_script
    tcl_script=$(mktemp /tmp/program_fpga_XXXXXX.tcl)
    trap "rm -f $tcl_script" EXIT

    cat > "$tcl_script" <<EOF
open_hw_manager
connect_hw_server -url localhost:3121
# current_hw_target est OBLIGATOIRE : sans lui, open_hw_target devine une cible,
# se trompe de nom et sort « No devices detected on target » alors que le JTAG
# repond parfaitement. Constate le 2026-09-08 sur la Genesys2.
set targets [get_hw_targets -quiet]
if {[llength \$targets] == 0} {
    puts "ERREUR : aucune cible JTAG. Carte alimentee ? Cable branche ?"
    exit 1
}
current_hw_target [lindex \$targets 0]
open_hw_target
set dev [lindex [get_hw_devices xc7k*] 0]
current_hw_device \$dev
set_property PROGRAM.FILE {$bit} \$dev
program_hw_devices \$dev
close_hw_target
disconnect_hw_server
close_hw_manager
EOF

    log_step "  → Lancement de Vivado hw_server"
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

    # Vérification du firmware
    if [[ ! -f "$fw" ]]; then
        log_error "Firmware introuvable : $fw (lancer 'do_opensbi' d'abord)"
        exit 1
    fi

    # Détection automatique si SDCARD_DEV non défini
    if [[ -z "$device" ]]; then
        log_step "  → Détection de la carte SD"
        sudo fdisk -l 2>/dev/null | grep -E "^Disk /dev/sd" || true
        read -rp "Entrer le device SD (ex: /dev/sdc) : " device
    fi

    # Vérification que le device existe
    if [[ ! -b "$device" ]]; then
        log_error "Device introuvable ou non-bloc : $device"
        exit 1
    fi

    # Confirmation de sécurité
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


do_all() {
    #init_submodules
    create_dirs
    do_fpga
    do_baremetal
    do_bao
    do_opensbi
    log_ok "Build complet terminé. Artefacts dans : $BUILD_DIR"
}

# =============================================================================
# Dispatch
# =============================================================================

TARGET="${1:-all}"

FORCE_FPGA=0

# Parsing des flags optionnels
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_FPGA=1 ;;
    esac
done
export FORCE_FPGA

# Les cibles autres que clean vérifient les dépendances
if [[ "$TARGET" != "clean" ]]; then
    check_deps
fi

case "$TARGET" in
    all)       do_all ;;
    clean)     do_clean ;;
    fpga)      create_dirs; do_fpga ;;
    baremetal) create_dirs; do_baremetal ;;
    bao)       create_dirs; do_bao ;;
    opensbi)   create_dirs; do_opensbi ;;
    program)   create_dirs; do_program ;;
    sdcard)    do_sdcard ;;
    *)
        log_error "Cible inconnue : '$TARGET'"
        echo ""
        echo "Usage: [ENV_VARS] $0 [TARGET]"
        echo ""
        echo "Targets disponibles :"
        echo "  all        — build complet (défaut)"
        echo "  clean      — supprime tous les artefacts"
        echo "  fpga       — synthèse CVA6 uniquement (ajouter --force pour resynthétiser)"
        echo ""
        echo     "  FORCE_FPGA=1 ./build.sh fpga           # forcer via variable"
        echo "  ./build.sh fpga --force                # forcer via flag"
        echo "  baremetal  — guests baremetal uniquement"
        echo "  bao        — hyperviseur BAO uniquement"
        echo "  opensbi    — OpenSBI uniquement"
        echo "  sdcard     — partitionne et flashe la carte SD"
        echo "" 
        echo "  SDCARD_DEV=/dev/sdc ./build.sh sdcard   # sans prompt interactif"
        echo ""
        echo "Variables d'environnement :"
        echo "  VIVADO_VERSION     (défaut: 2022.2)"
        echo "  VIVADO_DIR         (défaut: /tools/Xilinx/Vivado/\$VIVADO_VERSION)"
        echo "  CROSS_COMPILE      (défaut: riscv64-unknown-elf- toolchain)"
        echo "  OPENSBI_CC         (défaut: \$RISCV_BARE gcc -std=gnu11)"
        echo "  OPENSBI_RISCV_ISA  (défaut: rv64imac_zicsr_zifencei)"
        echo "  BUILD_DIR          (défaut: <root>/build)"
        echo "  JOBS               (défaut: nproc)"
        echo "  DRY_RUN=1          (affiche les commandes sans les exécuter)"
        exit 1
        ;;
esac