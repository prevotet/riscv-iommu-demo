#!/bin/bash
# =============================================================================
# 3_build_B.sh — Script de test DPR standalone (sans BAO, sans Linux)
# Usage: [ENV_VARS] ./3_build_B.sh [TARGET] [FLAGS]
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
# Logging
# =============================================================================

LOG_DIR="$ROOT_DIR/logs"
SUMMARY_LOG="$LOG_DIR/summary.log"
SESSION_TS="$(date +"%Y%m%d_%H%M%S")"

mkdir -p "$LOG_DIR"

_session_start() {
    echo "" >> "$SUMMARY_LOG"
    echo "════════════════════════════════════════════════════════" >> "$SUMMARY_LOG"
    echo "Session : $SESSION_TS — cible : ${TARGET:-?} — RM_INIT=$RM_INIT RM_TARGET=$RM_TARGET" >> "$SUMMARY_LOG"
    echo "════════════════════════════════════════════════════════" >> "$SUMMARY_LOG"
}

_log_summary() {
    local step="$1"
    local status="$2"
    local detail="${3:-}"
    local ts="$(date +"%H:%M:%S")"
    printf "  [%s] %-35s %s %s\n" "$ts" "$step" "$status" "$detail" >> "$SUMMARY_LOG"
}

_run_logged() {
    local logfile="$1"
    shift
    echo "CMD: $*" > "$logfile"
    echo "DATE: $(date)" >> "$logfile"
    echo "---" >> "$logfile"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m $*"
        echo "[DRY-RUN] $*" >> "$logfile"
        return 0
    fi
    "$@" 2>&1 | tee -a "$logfile"
    return ${PIPESTATUS[0]}
}

_logfile() {
    echo "$LOG_DIR/${SESSION_TS}_${1}.log"
}

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
# Vérification de cohérence des bitstreams
# =============================================================================

check_coherence() {
    local static_dcp="$WORK_DPR/static_routed.dcp"
    local full_init="$WORK_DPR/full_${RM_INIT}.bit"
    local partial_b1="$WORK_DPR/partial_${RM_TARGET}_accel1.bit"
    local partial_b2="$WORK_DPR/partial_${RM_TARGET}_accel2.bit"
    local warn=0

    if [[ ! -f "$static_dcp" ]]; then
        log_warn "Checkpoint statique manquant — lancer 'dpr' d'abord"
        return
    fi

    log_step "Vérification cohérence des bitstreams..."

    local static_ts
    static_ts=$(stat -c%y "$static_dcp" | cut -d'.' -f1)

    # Vérifier full_init
    if [[ -f "$full_init" ]] && [[ "$full_init" -ot "$static_dcp" ]]; then
        log_warn "INCOHÉRENCE : full_${RM_INIT}.bit antérieur au checkpoint statique"
        log_warn "  static_routed.dcp : $static_ts"
        log_warn "  full_${RM_INIT}.bit : $(stat -c%y "$full_init" | cut -d'.' -f1)"
        log_warn "  → Relancer : RM=$RM_INIT ./2_build_HB.sh fpga-dpr"
        warn=1
        _log_summary "check_coherence" "WARN" "full_${RM_INIT}.bit obsolète"
    fi

    # Vérifier partiels
    for f in "$partial_b1" "$partial_b2"; do
        if [[ -f "$f" ]] && [[ "$f" -ot "$static_dcp" ]]; then
            log_warn "INCOHÉRENCE : $(basename $f) antérieur au checkpoint statique"
            log_warn "  static_routed.dcp : $static_ts"
            log_warn "  $(basename $f) : $(stat -c%y "$f" | cut -d'.' -f1)"
            log_warn "  → Relancer : RM=$RM_TARGET ./2_build_HB.sh fpga-dpr"
            warn=1
            _log_summary "check_coherence" "WARN" "$(basename $f) obsolète"
        fi
    done

    if [[ $warn -eq 1 ]]; then
        echo ""
        log_warn "Des bitstreams sont incohérents avec le checkpoint statique."
        log_warn "La reconfiguration dynamique risque d'échouer silencieusement."
        echo ""
        read -rp "Continuer quand même ? (o/N) : " confirm
        if [[ "$confirm" != "o" && "$confirm" != "O" ]]; then
            log_error "Annulé. Régénère les bitstreams avant de continuer."
            exit 1
        fi
        _log_summary "check_coherence" "WARN" "utilisateur a choisi de continuer"
    else
        log_ok "Bitstreams cohérents avec le checkpoint statique"
        _log_summary "check_coherence" "OK" ""
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
    local logfile_static
    logfile_static=$(_logfile "dpr_static")

    if [[ -f "$static_dcp" ]] && [[ "$FORCE_STATIC" != "1" ]]; then
        log_skip "Checkpoint statique déjà présent — FORCE_STATIC=1 pour forcer"
        _log_summary "dpr_static" "SKIP" "(checkpoint existant)"
    else
        log_step "  → Génération du checkpoint statique..."
        log_step "  → Log : $logfile_static"
        if _run_logged "$logfile_static" make -C "$DPR_DIR" dpr-static FORCE_STATIC=1; then
            log_ok "  → Checkpoint statique généré"
            _log_summary "dpr_static" "OK" "$logfile_static"
        else
            log_error "Checkpoint statique échoué — voir $logfile_static"
            grep "^ERROR\|^CRITICAL" "$logfile_static" | tail -10
            _log_summary "dpr_static" "FAIL" "$logfile_static"
            exit 1
        fi
    fi

    # --- Étape 2 : Bitstreams partiels par RM ---
    local static_dcp_time
    static_dcp_time=$(stat -c%Y "$static_dcp")

    for rm in accel_default "$RM_INIT" "$RM_TARGET"; do
        local full_bit="$WORK_DPR/full_${rm}.bit"
        local logfile_rm
        logfile_rm=$(_logfile "dpr_partial_${rm}")

        # Vérifier si le bitstream existe ET est plus récent que le checkpoint
        if [[ -f "$full_bit" ]] && [[ $(stat -c%Y "$full_bit") -ge $static_dcp_time ]]; then
            log_skip "Bitstream full_${rm}.bit déjà à jour"
            _log_summary "dpr_partial_${rm}" "SKIP" "(bitstream à jour)"
        else
            if [[ -f "$full_bit" ]]; then
                log_warn "full_${rm}.bit obsolète — régénération forcée"
            fi
            log_step "  → Génération RM : $rm"
            log_step "  → Log : $logfile_rm"
            if _run_logged "$logfile_rm" make -C "$DPR_DIR" dpr-partial RM="$rm"; then
                log_ok "  → Bitstreams $rm générés"
                _log_summary "dpr_partial_${rm}" "OK" "$logfile_rm"
            else
                log_error "RM $rm échoué — voir $logfile_rm"
                grep "^ERROR\|^CRITICAL" "$logfile_rm" | tail -10
                _log_summary "dpr_partial_${rm}" "FAIL" "$logfile_rm"
                exit 1
            fi
        fi
    done

    # --- Étape 3 : Conversion .bit → .bin ---
    do_convert_bin

    # --- Étape 4 : Vérification finale ---
    check_coherence
}

# =============================================================================
# Compilation du baremetal standalone
# =============================================================================

do_baremetal() {
    log_step "Compilation baremetal standalone (PLATFORM=cva6)"

    local logfile
    logfile=$(_logfile "baremetal")

    if [[ -f "$BAREMETAL_BIN" ]] && [[ "$FORCE_BAREMETAL" != "1" ]]; then
        log_skip "Baremetal déjà compilé — FORCE_BAREMETAL=1 pour forcer"
        _log_summary "baremetal" "SKIP" "(binaire existant)"
        return
    fi

    log_step "  → Log : $logfile"
    if _run_logged "$logfile" make -C "$BAREMETAL_DIR" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        SINGLE_CORE=y \
        -j"$(nproc)"; then
        check_file "$BAREMETAL_BIN"
        log_ok "Baremetal compilé : $BAREMETAL_BIN ($(( $(stat -c%s "$BAREMETAL_BIN") / 1024 )) KB)"
        _log_summary "baremetal" "OK" "$logfile"
    else
        log_error "Compilation baremetal échouée — voir $logfile"
        _log_summary "baremetal" "FAIL" "$logfile"
        exit 1
    fi
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

        if [[ -f "$bin" ]] && [[ "$bin" -nt "$bit" ]]; then
            log_skip "$(basename $bin) déjà à jour"
            _log_summary "convert_${accel}" "SKIP" ""
            continue
        fi

        local offset
        offset=$(python3 -c "
data = open('$bit','rb').read()
idx = data.find(bytes.fromhex('AA995566'))
print(idx if idx >= 0 else -1)
")
        if [[ "$offset" -lt 0 ]]; then
            log_error "Sync word non trouvé dans $bit"
            _log_summary "convert_${accel}" "FAIL" "sync word manquant"
            exit 1
        fi

        log_step "  → $accel : header = $offset octets"
        RUN dd if="$bit" of="$bin" bs=1 skip="$offset" status=none
        check_file "$bin"
        log_ok "  → $(basename $bin) : $(( $(stat -c%s "$bin") / 1024 )) KB"
        _log_summary "convert_${accel}" "OK" "$(( $(stat -c%s "$bin") / 1024 )) KB"
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

    check_coherence

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

    check_coherence

    source "$VIVADO_DIR/settings64.sh"

    local logfile
    logfile=$(_logfile "program")
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

    log_step "  → Log : $logfile"
    if _run_logged "$logfile" vivado -mode batch -nojournal -nolog -source "$tcl_script"; then
        log_ok "FPGA programmé"
        _log_summary "program" "OK" "$logfile"
    else
        log_error "Programmation FPGA échouée — voir $logfile"
        _log_summary "program" "FAIL" "$logfile"
        exit 1
    fi
}

# =============================================================================
# Lancement d'OpenOCD
# =============================================================================

do_openocd() {
    log_step "Lancement OpenOCD"
    check_file "$OPENOCD_CFG"

    local logfile
    logfile=$(_logfile "openocd")
    log_ok "Config : $OPENOCD_CFG"
    log_ok "Log    : $logfile"
    log_ok "Ports  : telnet=4444  gdb=3333"
    log_warn "Ctrl+C pour arrêter OpenOCD"
    echo ""

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m openocd -f $OPENOCD_CFG"
    else
        openocd -f "$OPENOCD_CFG" 2>&1 | tee "$logfile"
    fi
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

    check_coherence

    local sz1=$(( $(stat -c%s "$bs1") / 4 ))
    local sz2=$(( $(stat -c%s "$bs2") / 4 ))

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

for arg in "$@"; do
    case "$arg" in
        --force)           FORCE_STATIC=1; FORCE_BAREMETAL=1 ;;
        --force-static)    FORCE_STATIC=1 ;;
        --force-baremetal) FORCE_BAREMETAL=1 ;;
    esac
done

_session_start

echo "Logs : $LOG_DIR/"

case "$TARGET" in
    all)          do_all ;;
    dpr)          source "$VIVADO_DIR/settings64.sh"; do_dpr ;;
    baremetal)    do_baremetal ;;
    convert-bin)  do_convert_bin ;;
    bitstreams)   do_check_bitstreams ;;
    program)      do_program ;;
    openocd)      do_openocd ;;
    load)         do_load ;;
    logs)
        log_step "Historique des sessions"
        cat "$SUMMARY_LOG" 2>/dev/null || log_warn "Aucun log disponible"
        ;;
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
        echo "  5. ./3_build_B.sh load          # commandes GDB"
        echo "  Ou tout d'un coup :"
        echo "  ./3_build_B.sh all"
        echo ""
        echo "Targets :"
        echo "  all          — dpr + baremetal + program + load"
        echo "  dpr          — générer les bitstreams (détecte les obsolètes)"
        echo "  baremetal    — compiler le baremetal (skip si existant)"
        echo "  convert-bin  — convertir .bit → .bin (skip si à jour)"
        echo "  bitstreams   — vérifier et afficher les constantes C"
        echo "  program      — programmer le FPGA"
        echo "  openocd      — lancer OpenOCD (bloquant)"
        echo "  load         — afficher les commandes GDB"
        echo "  logs         — afficher le résumé de toutes les sessions"
        echo ""
        echo "Flags :"
        echo "  --force           tout régénérer"
        echo "  --force-static    forcer le checkpoint statique"
        echo "  --force-baremetal forcer la recompilation baremetal"
        echo ""
        echo "Variables :"
        echo "  RM_INIT=accel_A      RM_TARGET=accel_B"
        echo "  VIVADO_VERSION=2022.2"
        echo "  DRY_RUN=1"
        exit 1
        ;;
esac

echo ""
log_ok "Session terminée — résumé : $SUMMARY_LOG"