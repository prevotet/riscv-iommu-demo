#!/bin/bash
# =============================================================================
# build.sh — Script de build flexible pour riscv-iommu-demo
# Usage: [ENV_VARS] ./build.sh [TARGET]
#
# Targets : all | clean | fpga | baremetal | linux | bao | opensbi
#
# Variables d'environnement surchargeables :
#   VIVADO_VERSION, VIVADO_DIR
#   RISCV_BARE        (chemin vers riscv64-unknown-elf-)
#   RISCV_LINUX_DIR   (chemin vers riscv64-linux-gnu toolchain)
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
CONFIG_BAREMETAL_LINUX_DIR="${CONFIG_BAREMETAL_LINUX_DIR:-$BUILD_DIR/vm-configs/cva6-baremetal-linux}"
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
        "$CONFIG_BAREMETAL_LINUX_DIR"
    log_ok "Répertoires créés sous $BUILD_DIR"
}

# =============================================================================
# Cibles de build
# =============================================================================

do_clean() {
    log_step "Nettoyage de tous les artefacts"
    RUN make -C "$ROOT_DIR/linux"                  ARCH=riscv mrproper
    RUN make -C "$ROOT_DIR/linux/tools/lloader"    clean
    RUN make -C "$ROOT_DIR/bao-baremetal-guest"    clean
    RUN make -C "$ROOT_DIR/bao-baremetal-guest-reconf" clean
    RUN make -C "$ROOT_DIR/bao-hypervisor"         clean
    RUN make -C "$ROOT_DIR/opensbi"                clean
    log_ok "Nettoyage terminé"
}

do_fpga() {
    log_step "Synthèse FPGA (CVA6)"
    source "$VIVADO_DIR/settings64.sh"
    if [[ -d "$ROOT_DIR/cva6/build" ]]; then
        log_warn "Synthèse déjà réalisée — pour forcer, supprimer cva6/build"
    else
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
    copy_if_changed \
        "$ROOT_DIR/trust_gw/bao-baremetal-guest/src/main.c" \
        "$ROOT_DIR/bao-baremetal-guest/src/main.c"

    log_step "  → Guest baremetal principal"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        -j"$JOBS"

    log_step "  → Guest baremetal reconf"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest-reconf" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        -j"$JOBS"

    copy_if_changed \
        "$ROOT_DIR/bao-baremetal-guest/build/cva6/baremetal.bin" \
        "$BUILD_GUESTS_DIR/baremetal.bin"
    copy_if_changed \
        "$ROOT_DIR/bao-baremetal-guest-reconf/build/cva6/baremetal.bin" \
        "$BUILD_GUESTS_DIR/baremetal2.bin"

    log_ok "Guests baremetal compilés"
}

do_linux() {
    log_step "Compilation du noyau Linux (RISC-V)"
    RUN make -C "$ROOT_DIR/linux" \
        ARCH=riscv \
        CROSS_COMPILE=riscv64-linux-gnu- \
        KBUILD_DEFCONFIG=defconfig \
        O=build \
        -j"$JOBS" \
        defconfig Image

    log_step "  → Génération du DTB"
    local dts_dir="$ROOT_DIR/linux/arch/riscv/boot/dts/cva6"
    RUN dtc "$dts_dir/cva6-ariane-minimal.dts" -o "$dts_dir/cva6-ariane-minimal.dtb"

    log_step "  → lloader"
    RUN make -C "$ROOT_DIR/linux/tools/lloader" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        ARCH=rv64 \
        IMAGE="../../build/arch/riscv/boot/Image" \
        DTB="../../arch/riscv/boot/dts/cva6/cva6-ariane-minimal.dtb" \
        TARGET=linux-rv64-cva6

    log_ok "Noyau Linux compilé"
}

do_bao() {
    log_step "Compilation de BAO hypervisor"

    log_step "  → Copie des configurations VM et plateforme"
    RUN cp -R "$ROOT_DIR/vm-configs/"*   "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"

    RUN make -C "$BAO_SRCS" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        CONFIG=cva6-baremetal-linux \
        CPPFLAGS="-DBAO_WRKDIR_IMGS=$BUILD_GUESTS_DIR" \
        -j"$JOBS"

    copy_if_changed \
        "$BAO_SRCS/bin/cva6/cva6-baremetal-linux/bao.bin" \
        "$BUILD_BAO_DIR/bao.bin"

    log_ok "BAO compilé"
}

do_opensbi() {
    log_step "Compilation de OpenSBI"
    RUN make -C "$ROOT_DIR/opensbi" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=fpga/ariane \
        FW_PAYLOAD=y \
        FW_PAYLOAD_PATH="$BAO_SRCS/bin/cva6/cva6-baremetal-linux/bao.bin" \
        -j"$JOBS"
    log_ok "OpenSBI compilé"
}

do_all() {
    init_submodules
    create_dirs
    do_fpga
    do_baremetal
    do_linux
    do_bao
    do_opensbi
    log_ok "Build complet terminé. Artefacts dans : $BUILD_DIR"
}

# =============================================================================
# Dispatch
# =============================================================================

TARGET="${1:-all}"

# Les cibles autres que clean vérifient les dépendances
if [[ "$TARGET" != "clean" ]]; then
    check_deps
fi

case "$TARGET" in
    all)       do_all ;;
    clean)     do_clean ;;
    fpga)      create_dirs; do_fpga ;;
    baremetal) create_dirs; do_baremetal ;;
    linux)     create_dirs; do_linux ;;
    bao)       create_dirs; do_bao ;;
    opensbi)   create_dirs; do_opensbi ;;
    *)
        log_error "Cible inconnue : '$TARGET'"
        echo ""
        echo "Usage: [ENV_VARS] $0 [TARGET]"
        echo ""
        echo "Targets disponibles :"
        echo "  all        — build complet (défaut)"
        echo "  clean      — supprime tous les artefacts"
        echo "  fpga       — synthèse CVA6 uniquement"
        echo "  baremetal  — guests baremetal uniquement"
        echo "  linux      — noyau Linux uniquement"
        echo "  bao        — hyperviseur BAO uniquement"
        echo "  opensbi    — OpenSBI uniquement"
        echo ""
        echo "Variables d'environnement :"
        echo "  VIVADO_VERSION     (défaut: 2022.2)"
        echo "  VIVADO_DIR         (défaut: /tools/Xilinx/Vivado/\$VIVADO_VERSION)"
        echo "  CROSS_COMPILE      (défaut: riscv64-unknown-elf- toolchain)"
        echo "  RISCV_LINUX_DIR    (défaut: /home/jc/Software/riscv)"
        echo "  BUILD_DIR          (défaut: <root>/build)"
        echo "  JOBS               (défaut: nproc)"
        echo "  DRY_RUN=1          (affiche les commandes sans les exécuter)"
        exit 1
        ;;
esac