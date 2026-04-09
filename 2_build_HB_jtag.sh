#!/bin/bash
# =============================================================================
# 2_build_HB_jtag.sh — Build DPR + déploiement via JTAG
# =============================================================================
# Scénario : VM baremetal unique sous BAO (DPR Manager + test ping-pong fusionné)
# Cible    : Genesys2 XC7K325T-2FFG900 / CVA6 RISC-V 64 bits
#
# Targets (build) :
#   all-dpr-bm     — build complet (défaut) : dpr-full + bao-dpr-bm + opensbi-dpr-bm
#   dpr-full       — compile dpr_manager.bin (service + test fusionné, VARIANT=dpr_full)
#   bao-dpr-bm     — compile BAO (config cva6-dpr-baremetal)
#   opensbi-dpr-bm — compile OpenSBI avec payload bao-dpr-bm.bin
#   fpga-dpr       — synthèse DPR (DPR_MODE=static|clean|all, RM=accel_A|accel_B)
#   clean          — supprime tous les artefacts firmware
#
# Targets (déploiement) :
#   program          — programme static_full.bit via Vivado JTAG
#   openocd          — lance OpenOCD (bloquant, terminal dédié)
#   jtag-load-dpr-bm — charge fw_payload_dpr_bm.bin + 4 bitstreams ping-pong A↔B
#   jtag-dpr-bm      — OpenOCD bg + jtag-load-dpr-bm (tout-en-un)
#
# Layout DDR après jtag-load-dpr-bm :
#   0x80000000 : fw_payload_dpr_bm.bin      (OpenSBI + BAO + VM DPR)
#   0x81000000 : partial_accel_A_accel1.bin (slot 3 Mo)
#   0x81300000 : partial_accel_B_accel1.bin (slot 3 Mo)
#   0x81600000 : partial_accel_A_accel2.bin (slot 5 Mo)
#   0x81B00000 : partial_accel_B_accel2.bin (slot 5 Mo)
#
# Variables d'environnement :
#   VIVADO_VERSION  (défaut: 2022.2)
#   VIVADO_DIR      (défaut: /tools/Xilinx/Vivado/$VIVADO_VERSION)
#   CROSS_COMPILE   (défaut: riscv64-unknown-elf-, doit être dans PATH)
#   BAO_SRCS        (défaut: <root>/bao-hypervisor)
#   BUILD_DIR       (défaut: <root>/build)
#   JOBS            (défaut: nproc)
#   DRY_RUN=1       (affiche les commandes sans les exécuter)
#   FORCE_FPGA=1    (force la re-synthèse du checkpoint statique DPR)
#   OPENOCD_CFG     (défaut: cva6/corev_apu/fpga/ariane.cfg)
#   OPENOCD_PORT    (défaut: 3333)
#   GDB             (défaut: ${CROSS_COMPILE}gdb)
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VIVADO_VERSION="${VIVADO_VERSION:-2022.2}"
VIVADO_DIR="${VIVADO_DIR:-/tools/Xilinx/Vivado/${VIVADO_VERSION}}"

export CROSS_COMPILE="${CROSS_COMPILE:-riscv64-unknown-elf-}"

BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
JOBS="${JOBS:-$(nproc)}"
DRY_RUN="${DRY_RUN:-0}"

BUILD_GUESTS_DIR="$BUILD_DIR/guests"
BUILD_BAO_DIR="$BUILD_DIR/bao"
BUILD_FIRMWARE_DIR="$BUILD_DIR/firmware"
BUILD_CVA6_DIR="$BUILD_DIR/hw"
BAO_SRCS="${BAO_SRCS:-$ROOT_DIR/bao-hypervisor}"

CVA6_FPGA="$ROOT_DIR/cva6/corev_apu/fpga"
WORK_DPR="$CVA6_FPGA/work-dpr/2_build_HB"

OPENOCD_CFG="${OPENOCD_CFG:-$CVA6_FPGA/ariane.cfg}"
OPENOCD_PORT="${OPENOCD_PORT:-3333}"
GDB="${GDB:-${CROSS_COMPILE}gdb}"

# Chemin de sortie fixé par le build system OpenSBI
_FW_OPENSBI="$ROOT_DIR/opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin"
FW_PAYLOAD_DPR_BM="$BUILD_FIRMWARE_DIR/fw_payload_dpr_bm.bin"
ADDR_FW="0x80000000"
ADDR_BS_A1="0x81000000"
ADDR_BS_B1="0x81300000"
ADDR_BS_A2="0x81600000"
ADDR_BS_B2="0x81B00000"

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

    for tool in make git; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Outil manquant : $tool"
            missing=1
        fi
    done

    if [[ ! -d "$VIVADO_DIR" ]]; then
        log_error "Vivado introuvable : $VIVADO_DIR (surcharger VIVADO_DIR)"
        missing=1
    fi

    if ! command -v "${CROSS_COMPILE}gcc" &>/dev/null && [[ "$DRY_RUN" != "1" ]]; then
        log_error "Compilateur introuvable : ${CROSS_COMPILE}gcc (surcharger CROSS_COMPILE)"
        missing=1
    fi

    [[ $missing -eq 1 ]] && { log_error "Prérequis manquants. Abandon."; exit 1; }
    log_ok "Tous les prérequis sont satisfaits"
}

# =============================================================================
# Synthèse DPR
# =============================================================================

do_fpga_dpr() {
    log_step "Synthèse FPGA DPR"
    source "$VIVADO_DIR/settings64.sh"

    local rm_to_build="${RM:-accel_default}"
    local dpr_log="$ROOT_DIR/dpr/dpr_build.log"
    local make_dpr="make -C $ROOT_DIR/dpr WORK_DPR=$WORK_DPR"

    if [[ "${DPR_MODE:-}" == "clean" ]]; then
        RUN $make_dpr dpr-clean 2>&1 | tee "$dpr_log"
        log_ok "Nettoyage DPR terminé"
        return
    elif [[ "${DPR_MODE:-}" == "all" ]]; then
        RUN $make_dpr dpr-all 2>&1 | tee "$dpr_log"
    elif [[ "${DPR_MODE:-}" == "static" ]]; then
        local force_flag=""
        [[ "${FORCE_FPGA:-0}" == "1" ]] && force_flag="FORCE_STATIC=1"
        RUN $make_dpr dpr-static $force_flag 2>&1 | tee "$dpr_log"
    else
        RUN $make_dpr dpr-partial RM="$rm_to_build" 2>&1 | tee "$dpr_log"
    fi

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Flux DPR échoué. Voir $dpr_log"
        grep "^ERROR:\|^CRITICAL" "$dpr_log" | tail -20
        exit 1
    fi

    if [[ -d "$WORK_DPR" ]]; then
        RUN mkdir -p "$BUILD_CVA6_DIR/dpr"
        find "$WORK_DPR" -maxdepth 1 -name "*.bit" -exec cp {} "$BUILD_CVA6_DIR/dpr/" \;
    fi

    # Conversion .bit → .bin pour les bitstreams partiels existants
    [[ "${DPR_MODE:-}" != "static" ]] && do_convert_bin
    log_ok "Flux DPR terminé"
}

# Conversion .bit → .bin (strip du header Xilinx, sync word AA995566)
# Traite tous les partiels présents dans WORK_DPR
do_convert_bin() {
    log_step "Conversion bitstreams partiels .bit → .bin"
    local converted=0
    for bit in "$WORK_DPR"/partial_*.bit; do
        [[ -f "$bit" ]] || continue
        local bin="${bit%.bit}.bin"
        if [[ -f "$bin" ]] && [[ "$bin" -nt "$bit" ]]; then
            log_ok "  → $(basename "$bin") déjà à jour"
            continue
        fi
        local offset
        offset=$(python3 -c "
data = open('$bit','rb').read()
idx = data.find(bytes.fromhex('AA995566'))
print(idx if idx >= 0 else -1)
")
        if [[ "$offset" -lt 0 ]]; then
            log_error "Sync word AA995566 non trouvé dans $(basename "$bit")"
            exit 1
        fi
        RUN dd if="$bit" of="$bin" bs=1 skip="$offset" status=none
        if [[ "$DRY_RUN" != "1" ]]; then
            log_ok "  → $(basename "$bin") : $(( $(stat -c%s "$bin") / 1024 )) KB"
        else
            log_ok "  → $(basename "$bin") [DRY-RUN]"
        fi
        (( converted++ )) || true
    done
    [[ $converted -eq 0 ]] && log_ok "  → Tous les .bin sont à jour"
}

# =============================================================================
# Build firmware
# =============================================================================

create_dirs() {
    RUN mkdir -p "$BUILD_DIR" "$BUILD_GUESTS_DIR" "$BUILD_BAO_DIR" "$BUILD_FIRMWARE_DIR" "$BUILD_CVA6_DIR"
}

do_clean() {
    log_step "Nettoyage des artefacts firmware"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" clean
    RUN make -C "$ROOT_DIR/bao-hypervisor"      clean
    RUN make -C "$ROOT_DIR/opensbi"             clean
    log_ok "Nettoyage terminé"
}

_bao_build() {
    local config="$1" output="$2"
    RUN cp -R "$ROOT_DIR/vm-configs/"*   "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"
    RUN make -C "$BAO_SRCS" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 CONFIG="$config" \
        CPPFLAGS="-DBAO_WRKDIR_IMGS=$BUILD_GUESTS_DIR -DLOGLEVEL=TRACE" \
        -j"$JOBS"
    copy_if_changed "$BAO_SRCS/bin/cva6/$config/bao.bin" "$output"
    log_ok "BAO ($config) → $output"
}

_opensbi_build() {
    local payload="$1" output="$2"
    RUN make -C "$ROOT_DIR/opensbi" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=fpga/ariane \
        FW_PAYLOAD=y FW_PAYLOAD_PATH="$payload" \
        -j"$JOBS"
    copy_if_changed "$_FW_OPENSBI" "$output"
    log_ok "OpenSBI → $output"
}

_build_guest() {
    local variant="$1" name="$2" platform="${3:-cva6}"
    RUN make -C "$ROOT_DIR/bao-baremetal-guest" \
        CROSS_COMPILE="$CROSS_COMPILE" PLATFORM="$platform" \
        VARIANT="$variant" NAME="$name" -j"$JOBS"
    copy_if_changed \
        "$ROOT_DIR/bao-baremetal-guest/build/${platform}/${name}.bin" \
        "$BUILD_GUESTS_DIR/${name}.bin"
    log_ok "Guest $name ($variant) → $BUILD_GUESTS_DIR/${name}.bin"
}

do_dpr_full() {
    log_step "Compilation DPR Full (VARIANT=dpr_full)"
    _build_guest dpr_full dpr_manager
}

do_bao_dpr_bm() {
    log_step "Compilation BAO (config cva6-dpr-baremetal)"
    _bao_build cva6-dpr-baremetal "$BUILD_BAO_DIR/bao-dpr-bm.bin"
}

do_opensbi_dpr_bm() {
    log_step "Compilation OpenSBI (payload bao-dpr-bm.bin)"
    _opensbi_build "$BUILD_BAO_DIR/bao-dpr-bm.bin" "$FW_PAYLOAD_DPR_BM"
}

do_all_dpr_bm() {
    create_dirs
    do_dpr_full
    do_bao_dpr_bm
    do_opensbi_dpr_bm
    log_ok "Build DPR complet terminé."
    log_ok "  Firmware : $FW_PAYLOAD_DPR_BM"
}

# =============================================================================
# Déploiement JTAG
# =============================================================================

do_program() {
    log_step "Chargement du bitstream sur Genesys2"
    local bit="$BUILD_CVA6_DIR/dpr/static_full.bit"
    if [[ ! -f "$bit" ]]; then
        log_error "Bitstream DPR introuvable : $bit"
        log_error "  → Lancer 'fpga-dpr' avec DPR_MODE=static d'abord"
        exit 1
    fi
    log_ok "Bitstream : $bit"

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

do_openocd() {
    log_step "Lancement OpenOCD (port GDB=$OPENOCD_PORT)"
    if [[ ! -f "$OPENOCD_CFG" ]]; then
        log_error "Config OpenOCD introuvable : $OPENOCD_CFG (surcharger OPENOCD_CFG)"
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

_openocd_start_bg() {
    # Toutes les sorties log vont sur stderr — seul le PID va sur stdout
    # pour que ocd_pid=$(_openocd_start_bg) ne capture que le PID.
    if [[ ! -f "$OPENOCD_CFG" ]]; then
        log_error "Config OpenOCD introuvable : $OPENOCD_CFG" >&2
        exit 1
    fi

    log_step "  → Démarrage OpenOCD en arrière-plan..." >&2

    local old_pid
    old_pid=$(lsof -ti tcp:"$OPENOCD_PORT" 2>/dev/null || true)
    if [[ -n "$old_pid" ]]; then
        log_warn "  → OpenOCD résiduel détecté (PID $old_pid) — arrêt..." >&2
        kill "$old_pid" 2>/dev/null || true
        sleep 1
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m openocd -f $OPENOCD_CFG &" >&2
        echo "0"
        return
    fi

    openocd -f "$OPENOCD_CFG" &>/tmp/openocd_bg.log &
    local ocd_pid=$!

    local retries=20
    while ! nc -z localhost "$OPENOCD_PORT" 2>/dev/null; do
        sleep 0.5
        retries=$(( retries - 1 ))
        if [[ $retries -le 0 ]]; then
            log_error "OpenOCD ne répond pas sur le port $OPENOCD_PORT après 10 s" >&2
            log_error "  → Log : /tmp/openocd_bg.log" >&2
            kill "$ocd_pid" 2>/dev/null || true
            exit 1
        fi
    done
    sleep 0.5
    if grep -q "examination failed\|Fatal:\|unable to halt" /tmp/openocd_bg.log 2>/dev/null; then
        log_error "OpenOCD a démarré mais l'examen du target a échoué :" >&2
        grep "Error\|Fatal\|Warn.*fail\|unable" /tmp/openocd_bg.log >&2 || true
        log_error "  → Vérifiez que le FPGA est bien programmé et power-cyclé" >&2
        kill "$ocd_pid" 2>/dev/null || true
        exit 1
    fi
    log_ok "  → OpenOCD prêt (PID $ocd_pid, port $OPENOCD_PORT)" >&2
    echo "$ocd_pid"
}

_gdb_run() {
    local gdb_script="$1"
    if ! command -v "$GDB" &>/dev/null && [[ ! -f "$GDB" ]]; then
        log_error "GDB introuvable : $GDB (surcharger GDB)"
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

do_jtag_load_dpr_bm() {
    log_step "Chargement firmware DPR + 4 bitstreams (ping-pong A↔B) via JTAG"

    local bs_a1="$WORK_DPR/partial_accel_A_accel1.bin"
    local bs_b1="$WORK_DPR/partial_accel_B_accel1.bin"
    local bs_a2="$WORK_DPR/partial_accel_A_accel2.bin"
    local bs_b2="$WORK_DPR/partial_accel_B_accel2.bin"

    local err=0
    [[ ! -f "$FW_PAYLOAD_DPR_BM" ]] && {
        log_error "Firmware introuvable : $FW_PAYLOAD_DPR_BM"
        log_error "  → Lancer 'all-dpr-bm' d'abord"
        err=1
    }
    for bs in "$bs_a1" "$bs_b1" "$bs_a2" "$bs_b2"; do
        [[ ! -f "$bs" ]] && { log_error "Introuvable : $bs"; err=1; }
    done
    [[ $err -ne 0 ]] && { log_error "  → Générer les bitstreams avec 'fpga-dpr'"; exit 1; }

    local sz_a1 sz_b1 sz_a2 sz_b2
    sz_a1=$(stat -c%s "$bs_a1"); sz_b1=$(stat -c%s "$bs_b1")
    sz_a2=$(stat -c%s "$bs_a2"); sz_b2=$(stat -c%s "$bs_b2")
    local slot1=$(( 3 * 1024 * 1024 )) slot2=$(( 5 * 1024 * 1024 ))
    [[ $sz_a1 -gt $slot1 ]] && log_warn "partial_accel_A_accel1.bin ($sz_a1 o) dépasse le slot de $slot1 o !"
    [[ $sz_b1 -gt $slot1 ]] && log_warn "partial_accel_B_accel1.bin ($sz_b1 o) dépasse le slot de $slot1 o !"
    [[ $sz_a2 -gt $slot2 ]] && log_warn "partial_accel_A_accel2.bin ($sz_a2 o) dépasse le slot de $slot2 o !"
    [[ $sz_b2 -gt $slot2 ]] && log_warn "partial_accel_B_accel2.bin ($sz_b2 o) dépasse le slot de $slot2 o !"

    log_ok "Firmware : $FW_PAYLOAD_DPR_BM ($(stat -c%s "$FW_PAYLOAD_DPR_BM") o)"
    log_ok "Slot A1  : $bs_a1 ($(( sz_a1 / 4 )) mots) → $ADDR_BS_A1"
    log_ok "Slot B1  : $bs_b1 ($(( sz_b1 / 4 )) mots) → $ADDR_BS_B1"
    log_ok "Slot A2  : $bs_a2 ($(( sz_a2 / 4 )) mots) → $ADDR_BS_A2"
    log_ok "Slot B2  : $bs_b2 ($(( sz_b2 / 4 )) mots) → $ADDR_BS_B2"

    local gdb_script
    gdb_script=$(mktemp /tmp/jtag_dpr_bm_XXXXXX.gdb)
    trap "rm -f $gdb_script" EXIT

    cat > "$gdb_script" << EOF
set arch riscv:rv64
set remotetimeout 30
target remote localhost:${OPENOCD_PORT}
monitor reset halt
monitor sleep 200

restore ${FW_PAYLOAD_DPR_BM} binary ${ADDR_FW}
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
    log_ok "  VM DPR (manager + test ping-pong) démarrée automatiquement"
}

_jtag_sequence() {
    local load_fn="$1"
    local ocd_pid
    ocd_pid=$(_openocd_start_bg)
    if [[ "$DRY_RUN" != "1" ]] && [[ -n "$ocd_pid" ]] && [[ "$ocd_pid" != "0" ]]; then
        trap "kill $ocd_pid 2>/dev/null || true" EXIT
    fi
    "$load_fn"
    if [[ "$DRY_RUN" != "1" ]] && [[ -n "$ocd_pid" ]] && [[ "$ocd_pid" != "0" ]]; then
        kill "$ocd_pid" 2>/dev/null || true
        trap - EXIT
        log_ok "OpenOCD arrêté (PID $ocd_pid)"
    fi
}

do_jtag_dpr_bm() { _jtag_sequence do_jtag_load_dpr_bm; }

# =============================================================================
# Dispatch
# =============================================================================

TARGET="${1:-all-dpr-bm}"
FORCE_FPGA=0
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE_FPGA=1; done
export FORCE_FPGA

[[ "$TARGET" != "clean" ]] && check_deps

case "$TARGET" in
    all-dpr-bm)      do_all_dpr_bm ;;
    dpr-full)        create_dirs; do_dpr_full ;;
    bao-dpr-bm)      create_dirs; do_bao_dpr_bm ;;
    opensbi-dpr-bm)  create_dirs; do_opensbi_dpr_bm ;;
    fpga-dpr)        create_dirs; do_fpga_dpr ;;
    clean)           do_clean ;;
    program)         do_program ;;
    openocd)         do_openocd ;;
    jtag-load-dpr-bm) do_jtag_load_dpr_bm ;;
    jtag-dpr-bm)     do_jtag_dpr_bm ;;
    *)
        log_error "Cible inconnue : '$TARGET'"
        echo ""
        echo "Usage: [ENV_VARS] $0 [TARGET]"
        echo ""
        echo "Targets de build :"
        echo "  all-dpr-bm     — build complet (défaut) : dpr-full + bao + opensbi"
        echo "  dpr-full       — compile dpr_manager.bin (service + test ping-pong fusionné)"
        echo "  bao-dpr-bm     — compile BAO (config cva6-dpr-baremetal)"
        echo "  opensbi-dpr-bm — compile OpenSBI (payload bao-dpr-bm.bin)"
        echo "  fpga-dpr       — synthèse DPR (DPR_MODE=static|clean|all, RM=accel_A|accel_B)"
        echo "  clean          — supprime les artefacts firmware"
        echo ""
        echo "Targets de déploiement JTAG :"
        echo "  program          — programme static_full.bit sur Genesys2"
        echo "  openocd          — lance OpenOCD (bloquant, terminal dédié)"
        echo "  jtag-load-dpr-bm — charge fw + 4 bitstreams DPR via GDB"
        echo "  jtag-dpr-bm      — OpenOCD bg + jtag-load-dpr-bm (tout-en-un)"
        echo ""
        echo "Workflow complet :"
        echo "  DPR_MODE=static ./$(basename "$0") fpga-dpr   # checkpoint statique"
        echo "  RM=accel_A ./$(basename "$0") fpga-dpr        # bitstreams accel_A"
        echo "  RM=accel_B ./$(basename "$0") fpga-dpr        # bitstreams accel_B"
        echo "  ./$(basename "$0") all-dpr-bm                 # firmware"
        echo "  ./$(basename "$0") program                    # programmer FPGA"
        echo "  ./$(basename "$0") jtag-dpr-bm                # charger et démarrer"
        echo ""
        echo "Variables :"
        echo "  VIVADO_DIR    (défaut: /tools/Xilinx/Vivado/2022.2)"
        echo "  CROSS_COMPILE (défaut: riscv64-unknown-elf-)"
        echo "  BAO_SRCS      (défaut: <root>/bao-hypervisor)"
        echo "  BUILD_DIR     (défaut: <root>/build)"
        echo "  DRY_RUN=1     (affiche sans exécuter)"
        echo "  OPENOCD_CFG   (défaut: cva6/corev_apu/fpga/ariane.cfg)"
        echo "  OPENOCD_PORT  (défaut: 3333)"
        echo "  GDB           (défaut: \${CROSS_COMPILE}gdb)"
        exit 1
        ;;
esac
