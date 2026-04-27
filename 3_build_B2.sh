#!/bin/bash
# =============================================================================
# 3_build_B2.sh — Script de test DPR standalone (GDB Automatisé)
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

WORK_DPR="$ROOT_DIR/cva6/corev_apu/fpga/work-dpr/3_build_B_dpr"
BAREMETAL_DIR="$ROOT_DIR/baremetal-dpr"

BAREMETAL_BIN="$BAREMETAL_DIR/build/cva6/baremetal.bin"
BAREMETAL_ELF="$BAREMETAL_DIR/build/cva6/baremetal.elf"
OPENOCD_CFG="$ROOT_DIR/cva6/corev_apu/fpga/ariane.cfg"
DPR_DIR="$ROOT_DIR/dpr"

RM_INIT="${RM_INIT:-accel_A}"
RM_TARGET="${RM_TARGET:-accel_B}"
FORCE_STATIC="${FORCE_STATIC:-0}"
FORCE_BAREMETAL="${FORCE_BAREMETAL:-0}"
FORCE_HWICAP="${FORCE_HWICAP:-0}"
DRY_RUN="${DRY_RUN:-0}"

XILINX_PART="${XILINX_PART:-xc7k325tffg900-2}"
XILINX_BOARD="${XILINX_BOARD:-digilentinc.com:genesys2:part0:1.1}"
HWICAP_IP_DIR="$ROOT_DIR/cva6/corev_apu/fpga/xilinx/xlnx_axi_hwicap"

# Adresses fixes DDR (format hex pour GDB et shell)
ADDR_BAREMETAL="0x90000000"
ADDR_BS1="0x81000000"
ADDR_BS2="0x81300000"

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

_COHERENCE_CHECKED=0

check_coherence() {
    [[ "$_COHERENCE_CHECKED" == "1" ]] && return

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
            log_warn "INCOHÉRENCE : $(basename "$f") antérieur au checkpoint statique"
            log_warn "  static_routed.dcp : $static_ts"
            log_warn "  $(basename "$f") : $(stat -c%y "$f" | cut -d'.' -f1)"
            log_warn "  → Relancer : RM=$RM_TARGET ./2_build_HB.sh fpga-dpr"
            warn=1
            _log_summary "check_coherence" "WARN" "$(basename "$f") obsolète"
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

    _COHERENCE_CHECKED=1
}

# =============================================================================
# Régénération de l'IP AXI HWICAP
# =============================================================================

do_hwicap_ip() {
    local tcl="$HWICAP_IP_DIR/tcl/run.tcl"
    local xci="$HWICAP_IP_DIR/xlnx_axi_hwicap.srcs/sources_1/ip/xlnx_axi_hwicap/xlnx_axi_hwicap.xci"

    if [[ -f "$xci" ]] && [[ "$xci" -nt "$tcl" ]] && [[ "$FORCE_HWICAP" != "1" ]]; then
        log_skip "IP HWICAP à jour — FORCE_HWICAP=1 pour forcer"
        _log_summary "hwicap_ip" "SKIP" "(xci plus récent que run.tcl)"
        return
    fi

    log_step "Régénération IP AXI HWICAP (DEVICE_ID=$XILINX_PART)"
    source "$VIVADO_DIR/settings64.sh"

    local logfile
    logfile=$(_logfile "hwicap_ip")
    log_step "  → Log : $logfile"

    if _run_logged "$logfile" bash -c "
        cd '$HWICAP_IP_DIR' && \
        export XILINX_PART='$XILINX_PART' && \
        export XILINX_BOARD='$XILINX_BOARD' && \
        make clean && make
    "; then
        log_ok "IP HWICAP régénérée"
        _log_summary "hwicap_ip" "OK" "$logfile"
    else
        log_error "Régénération IP HWICAP échouée — voir $logfile"
        _log_summary "hwicap_ip" "FAIL" "$logfile"
        exit 1
    fi
}

# =============================================================================
# Flow DPR — génération des bitstreams
# =============================================================================

do_dpr() {
    log_step "Flow DPR (statique + partiels)"
    source "$VIVADO_DIR/settings64.sh"

    # --- Étape 0 : IP HWICAP ---
    do_hwicap_ip

    # --- Étape 1 : Checkpoint statique ---
    local static_dcp="$WORK_DPR/static_routed.dcp"
    local logfile_static
    logfile_static=$(_logfile "dpr_static")

    # Forcer rebuild statique si l'IP HWICAP vient d'être régénérée
    local hwicap_xci="$HWICAP_IP_DIR/xlnx_axi_hwicap.srcs/sources_1/ip/xlnx_axi_hwicap/xlnx_axi_hwicap.xci"
    if [[ -f "$static_dcp" ]] && [[ -f "$hwicap_xci" ]] && [[ "$hwicap_xci" -nt "$static_dcp" ]]; then
        log_warn "IP HWICAP plus récente que le checkpoint statique → rebuild forcé"
        FORCE_STATIC=1
    fi

    if [[ -f "$static_dcp" ]] && [[ "$FORCE_STATIC" != "1" ]]; then
        log_skip "Checkpoint statique déjà présent — FORCE_STATIC=1 pour forcer"
        _log_summary "dpr_static" "SKIP" "(checkpoint existant)"
    else
        log_step "  → Génération du checkpoint statique..."
        log_step "  → Log : $logfile_static"
        if _run_logged "$logfile_static" make -C "$DPR_DIR" dpr-static FORCE_STATIC=1 WORK_DPR="$WORK_DPR"; then
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
            if _run_logged "$logfile_rm" make -C "$DPR_DIR" dpr-partial RM="$rm" WORK_DPR="$WORK_DPR"; then
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

    # --- Étape 4 : Mise à jour des constantes dans dpr_test.c ---
    do_update_bs_constants

    # --- Étape 5 : Vérification finale ---
    check_coherence
}

# =============================================================================
# Mise à jour automatique des constantes BS_ACCEL*_WORDS dans dpr_test.c
# =============================================================================

DPR_TEST_C="$ROOT_DIR/baremetal-dpr/src/dpr_test.c"

do_update_bs_constants() {
    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    local bs2="$WORK_DPR/partial_${RM_TARGET}_accel2.bin"

    [[ -f "$bs1" ]] || return
    [[ -f "$bs2" ]] || return
    [[ -f "$DPR_TEST_C" ]] || return

    local sz1=$(( $(stat -c%s "$bs1") / 4 ))
    local sz2=$(( $(stat -c%s "$bs2") / 4 ))

    local cur1 cur2
    cur1=$(grep -oP '(?<=BS1_NWORDS\s{3})\d+' "$DPR_TEST_C" || echo 0)
    cur2=$(grep -oP '(?<=BS2_NWORDS\s{3})\d+' "$DPR_TEST_C" || echo 0)

    if [[ "$cur1" != "$sz1" ]] || [[ "$cur2" != "$sz2" ]]; then
        log_warn "Mise à jour BS1_NWORDS/BS2_NWORDS dans dpr_test.c"
        log_warn "  accel1 : $cur1 → $sz1"
        log_warn "  accel2 : $cur2 → $sz2"
        sed -i "s/#define BS1_NWORDS   [0-9]*UL/#define BS1_NWORDS   ${sz1}UL/" "$DPR_TEST_C"
        sed -i "s/#define BS2_NWORDS   [0-9]*UL/#define BS2_NWORDS   ${sz2}UL/" "$DPR_TEST_C"
        FORCE_BAREMETAL=1
        log_ok "dpr_test.c mis à jour → rebuild baremetal forcé"
        _log_summary "update_bs_constants" "UPDATED" "accel1=$sz1 accel2=$sz2"
    else
        log_ok "BS1_NWORDS/BS2_NWORDS à jour (accel1=$sz1 accel2=$sz2)"
        _log_summary "update_bs_constants" "OK" ""
    fi
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
    if [[ "$FORCE_BAREMETAL" == "1" ]]; then
        make -C "$BAREMETAL_DIR" CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 SINGLE_CORE=y clean 2>/dev/null || true
    fi
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

    # Convertir tous les RMs disponibles (RM_INIT, RM_TARGET, accel_default)
    local rms_to_convert=()
    for rm in accel_default "$RM_INIT" "$RM_TARGET"; do
        [[ " ${rms_to_convert[*]} " == *" $rm "* ]] || rms_to_convert+=("$rm")
    done

    for rm in "${rms_to_convert[@]}"; do
    for accel in accel1 accel2; do
        local bit="$WORK_DPR/partial_${rm}_${accel}.bit"
        local bin="$WORK_DPR/partial_${rm}_${accel}.bin"

        # Ignorer silencieusement si le .bit n'existe pas pour ce RM
        [[ -f "$bit" ]] || continue

        check_file "$bit"

        if [[ -f "$bin" ]] && [[ "$bin" -nt "$bit" ]]; then
            log_skip "$(basename "$bin") déjà à jour"
            _log_summary "convert_${rm}_${accel}" "SKIP" ""
            continue
        fi

        local offset
        offset=$(python3 -c "
data = open('$bit','rb').read()
idx = data.find(bytes.fromhex('000000BB'))
if idx >= 4: idx -= 4  # Inclure les 4 octets de padding avant
print(idx if idx >= 0 else -1)
")
        if [[ "$offset" -lt 0 ]]; then
            log_error "Sync word non trouvé dans $bit"
            _log_summary "convert_${rm}_${accel}" "FAIL" "sync word manquant"
            exit 1
        fi

        log_step "  → ${rm}/${accel} : header = $offset octets"
        RUN dd if="$bit" of="$bin" bs=1 skip="$offset" status=none
        check_file "$bin"
        log_ok "  → $(basename "$bin") : $(( $(stat -c%s "$bin") / 1024 )) KB"
        _log_summary "convert_${rm}_${accel}" "OK" "$(( $(stat -c%s "$bin") / 1024 )) KB"
    done
    done
}

# =============================================================================
# Vérification des bitstreams
# =============================================================================

do_check_bitstreams() {
    log_step "Vérification des bitstreams DPR"

    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    local bs2="$WORK_DPR/partial_${RM_TARGET}_accel2.bin"

    check_file "$bs1"
    check_file "$bs2"

    local sz1=$(( $(stat -c%s "$bs1") / 4 ))
    local sz2=$(( $(stat -c%s "$bs2") / 4 ))

    check_coherence

    log_ok "Bitstreams présents :"
    log_ok "  partial1: $bs1 ($sz1 mots)"
    log_ok "  partial2: $bs2 ($sz2 mots)"
    echo ""
    log_ok "Constantes pour dpr_test.c :"
    log_ok "  #define BS_ACCEL1_ADDR  ${ADDR_BS1}ULL"
    log_ok "  #define BS_ACCEL2_ADDR  ${ADDR_BS2}ULL"
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
# Chargement automatisé GDB
# =============================================================================

do_load() {
    log_step "Chargement via GDB"

    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    local bs2="$WORK_DPR/partial_${RM_TARGET}_accel2.bin"

    check_file "$bs1"
    check_file "$bs2"
    check_file "$BAREMETAL_BIN"
    check_file "$BAREMETAL_ELF"

    check_coherence

    local sz1=$(( $(stat -c%s "$bs1") / 4 ))
    local sz2=$(( $(stat -c%s "$bs2") / 4 ))

    # Calcul de taille max
    local addr_bs1=$(( ADDR_BS1 ))
    local addr_bs2=$(( ADDR_BS2 ))
    local max_sz1=$(( addr_bs2 - addr_bs1 ))
    if [[ $(( sz1 * 4 )) -gt $max_sz1 ]]; then
        log_error "Bitstream accel1 trop grand : $(( sz1*4 )) > $max_sz1"
        exit 1
    fi

    log_ok "Bitstream accel1 : $sz1 mots ($(( sz1*4 )) octets) @ $ADDR_BS1"
    log_ok "Bitstream accel2 : $sz2 mots ($(( sz2*4 )) octets) @ $ADDR_BS2"
    log_ok "Baremetal        : $(stat -c%s "$BAREMETAL_BIN") octets @ $ADDR_BAREMETAL"

    # Vérification OpenOCD
    if ! pgrep -x "openocd" > /dev/null; then
        log_warn "OpenOCD ne semble pas tourner. Lancement recommandé : ./3_build_B2.sh openocd"
        echo -n "Voulez-vous tenter de lancer GDB quand même ? [y/N] "
        read -r resp
        [[ "$resp" != "y" ]] && exit 1
    fi

    local gdb_script
    gdb_script=$(mktemp /tmp/riscv_load_XXXXXX.gdb)
    trap "rm -f '$gdb_script'" EXIT INT TERM

    # 'restore file binary addr' : commande GDB native, charge un binaire brut
    # en mémoire cible via le protocole GDB/OpenOCD. Pas besoin de Python ni de
    # 'monitor' (non supporté par ce target).
    cat > "$gdb_script" << EOF
target remote localhost:3333
set confirm off
echo \\n[GDB] Chargement bitstream accel1 @ $ADDR_BS1\\n
restore $bs1 binary $ADDR_BS1
echo \\n[GDB] Chargement bitstream accel2 @ $ADDR_BS2\\n
restore $bs2 binary $ADDR_BS2
echo \\n[GDB] Chargement ELF baremetal...\\n
load
set \$pc = $ADDR_BAREMETAL
echo \\n[GDB] Demarrage firmware (UART pour les traces)...\\n
continue
EOF

    echo ""
    log_step "Lancement GDB..."
    ${RISCV_BARE}gdb -x "$gdb_script" "$BAREMETAL_ELF"
    rm -f "$gdb_script"
    trap - EXIT INT TERM

    echo ""
    echo "=== Constantes pour dpr_test.c (si nécessaire) ==="
    echo "  #define BS_ACCEL1_ADDR  ${ADDR_BS1}ULL"
    echo "  #define BS_ACCEL2_ADDR  ${ADDR_BS2}ULL"
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
    log_warn "Lance OpenOCD dans un terminal dédié AVANT de continuer :"
    log_warn "  ./3_build_B2.sh openocd"
    echo -n "OpenOCD est-il lancé ? Appuyer sur Entrée pour continuer avec GDB... "
    read -r _
    do_load
}

# =============================================================================
# Suite de tests unitaires HWICAP/ICAP/DPR
# =============================================================================

# Met à jour TEST_SELECT dans dpr_test.c avant compilation
_set_test_select() {
    local n="$1"
    if ! grep -q "^#define TEST_SELECT" "$DPR_TEST_C"; then
        log_error "TEST_SELECT introuvable dans $DPR_TEST_C"
        exit 1
    fi
    local cur
    cur=$(grep -oP '(?<=^#define TEST_SELECT )\d+' "$DPR_TEST_C")
    if [[ "$cur" != "$n" ]]; then
        log_step "TEST_SELECT $cur → $n"
        sed -i "s/^#define TEST_SELECT [0-9]*/#define TEST_SELECT $n/" "$DPR_TEST_C"
        FORCE_BAREMETAL=1
    fi
}

# Lance le test N via GDB.
# $1 = numéro du test
# $2..$N = paires "ADDR BIN" de bitstreams à charger (optionnel)
_run_test() {
    local n="$1"
    shift

    check_file "$BAREMETAL_ELF"

    if ! pgrep -x "openocd" > /dev/null; then
        log_warn "OpenOCD ne semble pas tourner."
        log_warn "Lancer dans un autre terminal : ./3_build_B2.sh openocd"
        echo -n "Continuer quand même ? [y/N] "
        read -r resp; [[ "$resp" != "y" ]] && exit 1
    fi

    local gdb_script
    gdb_script=$(mktemp /tmp/riscv_test_XXXXXX.gdb)
    trap "rm -f '$gdb_script'" EXIT INT TERM

    {
        echo "target remote localhost:3333"
        echo "set confirm off"
        # Charger les bitstreams passés en arguments (paires addr bin)
        while [[ $# -ge 2 ]]; do
            local addr="$1" bin="$2"; shift 2
            echo "echo \\n[TEST$n] restore $bin @ $addr\\n"
            echo "restore $bin binary $addr"
        done
        echo "echo \\n[TEST$n] Chargement ELF...\\n"
        echo "load"
        echo "set \$pc = $ADDR_BAREMETAL"
        echo "echo \\n[TEST$n] Demarrage (UART pour traces)...\\n"
        echo "continue"
    } > "$gdb_script"

    log_step "GDB → Test $n (UART pour résultats)..."
    ${RISCV_BARE}gdb -x "$gdb_script" "$BAREMETAL_ELF"
    rm -f "$gdb_script"
    trap - EXIT INT TERM
}

# ---------------------------------------------------------------------------
# Test 1 : Infrastructure HWICAP + lecture registres ICAP
#   - Pas de bitstream nécessaire (lecture ICAP registres seulement)
#   - Valide : IDCODE, STAT, MASK
# ---------------------------------------------------------------------------
do_test1() {
    log_step "Test 1 — Infrastructure HWICAP + registres ICAP"
    _set_test_select 1
    do_baremetal
    _run_test 1
    _log_summary "test1" "RUN" ""
}

# ---------------------------------------------------------------------------
# Test 2 : IDCODE / MASK — validation complète avant DPR
#   - Charge le bitstream partiel pour analyser son header
# ---------------------------------------------------------------------------
do_test2() {
    log_step "Test 2 — IDCODE / MASK"
    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    check_file "$bs1"
    do_update_bs_constants
    _set_test_select 2
    do_baremetal
    _run_test 2 "$ADDR_BS1" "$bs1"
    _log_summary "test2" "RUN" ""
}

# ---------------------------------------------------------------------------
# Test 3 : Écriture chunk-by-chunk + détection abort ICAP
# ---------------------------------------------------------------------------
do_test3() {
    log_step "Test 3 — Chunk-by-chunk write"
    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    check_file "$bs1"
    do_update_bs_constants
    _set_test_select 3
    do_baremetal
    _run_test 3 "$ADDR_BS1" "$bs1"
    _log_summary "test3" "RUN" ""
}

# ---------------------------------------------------------------------------
# Test 4 : DPR complet accel1 (accel_A → accel_B)
# ---------------------------------------------------------------------------
do_test4() {
    log_step "Test 4 — DPR complet accel1"
    local bs1="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    check_file "$bs1"
    check_coherence
    do_update_bs_constants
    _set_test_select 4
    do_baremetal
    _run_test 4 "$ADDR_BS1" "$bs1"
    _log_summary "test4" "RUN" ""
}

# ---------------------------------------------------------------------------
# Test 5 : Ping-pong accel_A ↔ accel_B
#   BS1_ADDR (0x81000000) ← partial_accel_B_accel1.bin  (RM_TARGET)
#   BS2_ADDR (0x81300000) ← partial_accel_A_accel1.bin  (RM_INIT)
# ---------------------------------------------------------------------------
do_test5() {
    log_step "Test 5 — Ping-pong accel_A ↔ accel_B"
    local bs_b="$WORK_DPR/partial_${RM_TARGET}_accel1.bin"
    local bs_a="$WORK_DPR/partial_${RM_INIT}_accel1.bin"
    check_file "$bs_b"
    check_file "$bs_a"
    check_coherence

    local sz_b=$(( $(stat -c%s "$bs_b") / 4 ))
    local sz_a=$(( $(stat -c%s "$bs_a") / 4 ))
    log_ok "accel_B (BS1) : $sz_b mots @ $ADDR_BS1"
    log_ok "accel_A (BS2) : $sz_a mots @ $ADDR_BS2"

    # Mettre à jour BS2_NWORDS dans dpr_test.c
    local cur2
    cur2=$(grep -oP '(?<=BS2_NWORDS\s{3})\d+' "$DPR_TEST_C" || echo 0)
    if [[ "$cur2" != "$sz_a" ]]; then
        sed -i "s/#define BS2_NWORDS   [0-9]*UL/#define BS2_NWORDS   ${sz_a}UL/" "$DPR_TEST_C"
        log_ok "BS2_NWORDS : $cur2 → $sz_a"
        FORCE_BAREMETAL=1
    fi

    _set_test_select 5
    do_baremetal
    _run_test 5 "$ADDR_BS1" "$bs_b" "$ADDR_BS2" "$bs_a"
    _log_summary "test5" "RUN" ""
}

# ---------------------------------------------------------------------------
# Ancienne cible 'test' — conservée pour compatibilité, alias test4
# ---------------------------------------------------------------------------
do_test() {
    log_warn "'test' est un alias de 'test4'. Utiliser 'test1'..'test5' directement."
    do_test4
}

# =============================================================================
# Dispatch
# =============================================================================

TARGET=""
for arg in "$@"; do
    case "$arg" in
        --force)           FORCE_STATIC=1; FORCE_BAREMETAL=1; FORCE_HWICAP=1 ;;
        --force-static)    FORCE_STATIC=1 ;;
        --force-baremetal) FORCE_BAREMETAL=1 ;;
        --force-hwicap)    FORCE_HWICAP=1 ;;
        *)                 [[ -z "$TARGET" ]] && TARGET="$arg" ;;
    esac
done
TARGET="${TARGET:-all}"

_session_start

echo "Logs : $LOG_DIR/"

case "$TARGET" in
    all)          do_all ;;
    dpr)          source "$VIVADO_DIR/settings64.sh"; do_dpr ;;
    hwicap-ip)    source "$VIVADO_DIR/settings64.sh"; do_hwicap_ip ;;
    baremetal)    do_baremetal ;;
    convert-bin)  do_convert_bin ;;
    bitstreams)   do_check_bitstreams ;;
    program)      do_program ;;
    openocd)      do_openocd ;;
    load)         do_load ;;
    test1)        do_test1 ;;
    test2)        do_test2 ;;
    test3)        do_test3 ;;
    test4)        do_test4 ;;
    test5)        do_test5 ;;
    test)         do_test ;;
    logs)
        log_step "Historique des sessions"
        cat "$SUMMARY_LOG" 2>/dev/null || log_warn "Aucun log disponible"
        ;;
    help)
        echo "Usage: $0 [TARGET] [OPTIONS]"
        echo ""
        echo "Tests unitaires (valider dans l'ordre) :"
        echo "  test1   Infrastructure HWICAP + registres ICAP (IDCODE, STAT, MASK)"
        echo "  test2   IDCODE / MASK — validation complète avant DPR"
        echo "  test3   Écriture chunk-by-chunk + détection abort ICAP"
        echo "  test4   DPR complet accel1 (accel_A → accel_B)"
        echo "  test5   Ping-pong accel_A ↔ accel_B"
        echo ""
        echo "Workflow de base :"
        echo "  1. Dans un terminal dédié : ./3_build_B2.sh openocd"
        echo "  2. Dans un autre terminal : ./3_build_B2.sh program"
        echo "  3. ./3_build_B2.sh test1   # valider"
        echo "  4. ./3_build_B2.sh test2   # etc."
        echo ""
        echo "Autres cibles :"
        echo "  all          dpr + baremetal + program + load (défaut)"
        echo "  hwicap-ip    Régénère l'IP AXI HWICAP (Vivado batch)"
        echo "  dpr          Régénère l'IP HWICAP si besoin + bitstreams"
        echo "  baremetal    Compile le firmware baremetal"
        echo "  convert-bin  Convertit .bit → .bin"
        echo "  bitstreams   Vérifie les bitstreams"
        echo "  program      Programme le FPGA via Vivado JTAG"
        echo "  openocd      Lance OpenOCD"
        echo "  load         Charge via GDB"
        echo "  logs         Historique des sessions"
        echo ""
        echo "Options :"
        echo "  --force            Force rebuild HWICAP IP + bitstreams + baremetal"
        echo "  --force-hwicap     Force rebuild IP HWICAP seulement"
        echo "  --force-static     Force rebuild checkpoint statique"
        echo "  --force-baremetal  Force rebuild baremetal"
        ;;
    *)
        log_error "Cible inconnue : '$TARGET'"
        log_error "Utiliser '$0 help' pour la liste des cibles disponibles."
        exit 1
        ;;
esac

echo ""
log_ok "Session terminée — résumé : $SUMMARY_LOG"
