#!/bin/bash
# =============================================================================
# 2_BUILD_HB.sh — Build et chargement DPR dans une VM BAO
#
# Pile : Guest DPR Manager → BAO (cva6-dpr-baremetal) → OpenSBI → fw_payload.bin
#
# Les bitstreams FPGA (.bin) sont partagés avec 3_build_B2.sh :
#   WORK_DPR = cva6/corev_apu/fpga/work-dpr/3_build_B_dpr
# Prérequis : avoir lancé "./3_build_B2.sh dpr" au préalable.
#
# Targets :
#   dpr-manager — Compile le guest DPR Manager (bao-baremetal-guest)
#   bao         — Compile BAO hypervisor (config cva6-dpr-baremetal)
#   opensbi     — Compile OpenSBI avec payload bao.bin
#   baremetal   — Enchaîne dpr-manager + bao + opensbi
#   program     — Programme le FPGA via Vivado JTAG
#   openocd     — Lance OpenOCD (terminal dédié)
#   load        — Charge fw_payload.bin + 4 bitstreams via GDB
#   bitstreams  — Vérifie les 4 bitstreams DDR (issus de 3_build_B2.sh dpr)
#   logs        — Historique des sessions
#   help        — Affiche cette aide
#
# Variables d'environnement surchargeables :
#   RISCV_BARE        (préfixe toolchain baremetal, ex: riscv64-unknown-elf-)
#   RISCV_LINUX_DIR   (répertoire toolchain Linux)
#   JOBS              (parallélisme make, défaut: nproc)
#   DRY_RUN=1         (affiche les commandes sans les exécuter)
#   FORCE_BAREMETAL=1 (recompile guest+BAO+OpenSBI)
#   RM_INIT           (RM au boot FPGA, défaut: accel_A)
#   RM_TARGET         (RM reconfigurable en DDR, défaut: accel_B)
#   BAO_CONFIG        (config BAO, défaut: cva6-dpr-baremetal)
#   LOGLEVEL          (niveau de log BAO, défaut: TRACE)
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

JOBS="${JOBS:-$(nproc)}"
DRY_RUN="${DRY_RUN:-0}"

# DPR — modules reconfigurables
RM_INIT="${RM_INIT:-accel_A}"
RM_TARGET="${RM_TARGET:-accel_B}"

# BAO
BAO_SRCS="${BAO_SRCS:-$ROOT_DIR/bao-hypervisor}"
BAO_CONFIG="${BAO_CONFIG:-cva6-dpr-baremetal}"
LOGLEVEL="${LOGLEVEL:-TRACE}"

# Répertoires de build
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
BUILD_GUESTS_DIR="$BUILD_DIR/guests"
BUILD_BAO_DIR="$BUILD_DIR/bao"

# Guest DPR Manager (bao-baremetal-guest)
GUEST_DIR="$ROOT_DIR/bao-baremetal-guest"
DPR_MANAGER_BIN="$BUILD_GUESTS_DIR/dpr_manager.bin"

# OpenSBI
OPENSBI_DIR="$ROOT_DIR/opensbi"
FW_PAYLOAD="$OPENSBI_DIR/build/platform/fpga/ariane/firmware/fw_payload.bin"

# DPR hardware
CVA6_FPGA="$ROOT_DIR/cva6/corev_apu/fpga"
HWICAP_IP_DIR="$CVA6_FPGA/xilinx/xlnx_axi_hwicap"
WORK_DPR="$CVA6_FPGA/work-dpr/3_build_B_dpr"
DPR_DIR="$ROOT_DIR/dpr"

# JTAG / OpenOCD
OPENOCD_CFG="${OPENOCD_CFG:-$CVA6_FPGA/ariane.cfg}"
OPENOCD_PORT="${OPENOCD_PORT:-3333}"
GDB="${GDB:-${RISCV_BARE}gdb}"

# Fichier de constantes bitstream (mis à jour automatiquement)
DPR_IPC_H="$GUEST_DIR/src/dpr_ipc.h"

# Adresses DDR — 4 slots : A/B × accel1/accel2 (layout dpr_ipc.h)
#
#   Slot          | Adresse    | Taille max | Contenu
#   --------------|------------|------------|----------------------------
#   accel1 accel_A| 0x81000000 | 3 Mo       | partial_accel_A_accel1.bin
#   accel1 accel_B| 0x81300000 | 3 Mo       | partial_accel_B_accel1.bin
#   accel2 accel_A| 0x81600000 | 5 Mo       | partial_accel_A_accel2.bin
#   accel2 accel_B| 0x81B00000 | 5 Mo       | partial_accel_B_accel2.bin
#                                fin 0x82000000 < Linux@0x82400000

ADDR_FW="0x80000000"
ADDR_BS_A1_A="0x81000000"
ADDR_BS_A1_B="0x81300000"
ADDR_BS_A2_A="0x81600000"
ADDR_BS_A2_B="0x81B00000"

# Vivado (utilisé uniquement pour program)
VIVADO_VERSION="${VIVADO_VERSION:-2022.2}"
VIVADO_DIR="${VIVADO_DIR:-/tools/Xilinx/Vivado/${VIVADO_VERSION}}"
XILINX_PART="${XILINX_PART:-xc7k325tffg900-2}"
XILINX_BOARD="${XILINX_BOARD:-digilentinc.com:genesys2:part0:1.1}"

# Flags de forçage
FORCE_BAREMETAL="${FORCE_BAREMETAL:-0}"

# Logging
LOG_DIR="$ROOT_DIR/logs/bao-dpr"
SUMMARY_LOG="$LOG_DIR/summary.log"
SESSION_TS="$(date +"%Y%m%d_%H%M%S")"

# =============================================================================
# Logging
# =============================================================================

log_step()  { echo -e "\e[34m==>\e[0m \e[1m$*\e[0m"; }
log_ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
log_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
log_skip()  { echo -e "\e[90m[SKIP]\e[0m $*"; }

_log_summary() {
    local step="$1" status="$2" detail="${3:-}"
    local ts
    ts="$(date +"%H:%M:%S")"
    printf "  [%s] %-35s %s %s\n" "$ts" "$step" "$status" "$detail" >> "$SUMMARY_LOG"
}

_run_logged() {
    local logfile="$1"; shift
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

_logfile() { echo "$LOG_DIR/${SESSION_TS}_${1}.log"; }

RUN() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\e[90m[DRY-RUN]\e[0m $*"
    else
        "$@"
    fi
}

# =============================================================================
# Utilitaires
# =============================================================================

check_file() {
    if [[ ! -f "$1" ]]; then
        log_error "Fichier manquant : $1"
        exit 1
    fi
}

create_dirs() {
    mkdir -p "$BUILD_GUESTS_DIR" "$BUILD_BAO_DIR" "$LOG_DIR"
    mkdir -p "$(dirname "$SUMMARY_LOG")"
    echo "" >> "$SUMMARY_LOG"
    echo "════════════════════════════════════════════════════════" >> "$SUMMARY_LOG"
    echo "Session : $SESSION_TS — BAO_CONFIG=$BAO_CONFIG — RM_INIT=$RM_INIT RM_TARGET=$RM_TARGET" >> "$SUMMARY_LOG"
    echo "════════════════════════════════════════════════════════" >> "$SUMMARY_LOG"
}

# =============================================================================
# Vérification de présence des 4 bitstreams (générés par 3_build_B2.sh dpr)
# =============================================================================

check_bitstreams_present() {
    local missing=0
    for rm in accel_A accel_B; do
        for accel in accel1 accel2; do
            local bin="$WORK_DPR/partial_${rm}_${accel}.bin"
            if [[ ! -f "$bin" ]]; then
                log_error "Bitstream manquant : $bin"
                missing=1
            fi
        done
    done
    if [[ $missing -eq 1 ]]; then
        log_error "Lancer d'abord : ./3_build_B2.sh dpr"
        exit 1
    fi
}

# =============================================================================
# Mise à jour des constantes bitstream dans dpr_ipc.h
#
# Dans le contexte BAO, les tailles vivent dans dpr_ipc.h (pas dpr_test.c).
# DPR_BS_ACCEL1_WORDS = taille de partial_accel_{A,B}_accel1.bin (identique A=B)
# DPR_BS_ACCEL2_WORDS = taille de partial_accel_{A,B}_accel2.bin (identique A=B)
# =============================================================================

do_update_bs_constants() {
    local bs_a1_a="$WORK_DPR/partial_accel_A_accel1.bin"
    local bs_a2_a="$WORK_DPR/partial_accel_A_accel2.bin"

    [[ -f "$bs_a1_a" ]] || { log_warn "partial_accel_A_accel1.bin manquant — do_update_bs_constants ignoré"; return; }
    [[ -f "$bs_a2_a" ]] || { log_warn "partial_accel_A_accel2.bin manquant — do_update_bs_constants ignoré"; return; }

    local sz1=$(( $(stat -c%s "$bs_a1_a") / 4 ))
    local sz2=$(( $(stat -c%s "$bs_a2_a") / 4 ))

    local cur1 cur2
    cur1=$(grep -oP '(?<=DPR_BS_ACCEL1_WORDS\s{2})\d+' "$DPR_IPC_H" || echo 0)
    cur2=$(grep -oP '(?<=DPR_BS_ACCEL2_WORDS\s{2})\d+' "$DPR_IPC_H" || echo 0)

    if [[ "$cur1" != "$sz1" ]] || [[ "$cur2" != "$sz2" ]]; then
        log_warn "Mise à jour DPR_BS_ACCEL1/2_WORDS dans dpr_ipc.h"
        log_warn "  accel1 : $cur1 → $sz1 mots"
        log_warn "  accel2 : $cur2 → $sz2 mots"
        sed -i "s/#define DPR_BS_ACCEL1_WORDS  [0-9]*u/#define DPR_BS_ACCEL1_WORDS  ${sz1}u/" "$DPR_IPC_H"
        sed -i "s/#define DPR_BS_ACCEL2_WORDS  [0-9]*u/#define DPR_BS_ACCEL2_WORDS  ${sz2}u/" "$DPR_IPC_H"
        FORCE_BAREMETAL=1
        _log_summary "update_bs_constants" "UPDATED" "accel1=$sz1 accel2=$sz2"
    else
        log_ok "DPR_BS_ACCEL1/2_WORDS à jour (accel1=$sz1 accel2=$sz2)"
        _log_summary "update_bs_constants" "OK" "accel1=$sz1 accel2=$sz2"
    fi
}

# =============================================================================
# Compilation du guest DPR Manager
# =============================================================================

do_dpr_manager() {
    log_step "Compilation guest DPR Manager (PLATFORM=cva6 VARIANT=dpr_manager)"

    local logfile; logfile=$(_logfile "dpr_manager")

    if [[ -f "$DPR_MANAGER_BIN" ]] && [[ "$FORCE_BAREMETAL" != "1" ]]; then
        log_skip "dpr_manager.bin déjà compilé — FORCE_BAREMETAL=1 pour forcer"
        _log_summary "dpr_manager" "SKIP" "(binaire existant)"
        return
    fi

    if [[ "$FORCE_BAREMETAL" == "1" ]]; then
        make -C "$GUEST_DIR" CROSS_COMPILE="$CROSS_COMPILE" PLATFORM=cva6 \
            VARIANT=dpr_manager NAME=dpr_manager clean 2>/dev/null || true
    fi

    log_step "  → Log : $logfile"
    if _run_logged "$logfile" make -C "$GUEST_DIR" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        VARIANT=dpr_manager \
        NAME=dpr_manager \
        -j"$JOBS"; then
        local bin_src="$GUEST_DIR/build/cva6/dpr_manager.bin"
        check_file "$bin_src"
        mkdir -p "$BUILD_GUESTS_DIR"
        cp "$bin_src" "$DPR_MANAGER_BIN"
        log_ok "DPR Manager compilé : $DPR_MANAGER_BIN ($(( $(stat -c%s "$DPR_MANAGER_BIN") / 1024 )) KB)"
        _log_summary "dpr_manager" "OK" "$logfile"
    else
        log_error "Compilation DPR Manager échouée — voir $logfile"
        _log_summary "dpr_manager" "FAIL" "$logfile"
        exit 1
    fi
}

# =============================================================================
# Compilation de BAO hypervisor (config cva6-dpr-baremetal)
#
# Config : 1 VM unique (DPR Manager), pas de Linux.
# La config expose HWICAP, accel1/2, et la région DDR des bitstreams.
# =============================================================================

do_bao() {
    log_step "Compilation BAO (CONFIG=$BAO_CONFIG)"

    local bao_bin="$BAO_SRCS/bin/cva6/${BAO_CONFIG}/bao.bin"
    local dst="$BUILD_BAO_DIR/bao.bin"
    local logfile; logfile=$(_logfile "bao")

    if [[ -f "$dst" ]] && [[ "$FORCE_BAREMETAL" != "1" ]]; then
        log_skip "bao.bin déjà compilé — FORCE_BAREMETAL=1 pour forcer"
        _log_summary "bao" "SKIP" "(binaire existant)"
        return
    fi

    check_file "$DPR_MANAGER_BIN"

    # Synchroniser configs et platform
    RUN cp -R "$ROOT_DIR/vm-configs/"*   "$BAO_SRCS/configs/"
    RUN cp -R "$ROOT_DIR/plat-configs/"* "$BAO_SRCS/src/platform/"

    log_step "  → Log : $logfile"
    if _run_logged "$logfile" make -C "$BAO_SRCS" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=cva6 \
        CONFIG="$BAO_CONFIG" \
        CPPFLAGS="-DBAO_WRKDIR_IMGS=$BUILD_GUESTS_DIR -DLOGLEVEL=$LOGLEVEL" \
        -j"$JOBS"; then
        check_file "$bao_bin"
        mkdir -p "$BUILD_BAO_DIR"
        cp "$bao_bin" "$dst"
        log_ok "BAO compilé : $dst ($(( $(stat -c%s "$dst") / 1024 )) KB)"
        _log_summary "bao" "OK" "$logfile"
    else
        log_error "Compilation BAO échouée — voir $logfile"
        _log_summary "bao" "FAIL" "$logfile"
        exit 1
    fi
}

# =============================================================================
# Compilation d'OpenSBI (payload = bao.bin)
# =============================================================================

do_opensbi() {
    log_step "Compilation OpenSBI (payload = bao.bin)"

    local bao_bin="$BUILD_BAO_DIR/bao.bin"
    local logfile; logfile=$(_logfile "opensbi")

    check_file "$bao_bin"

    if [[ -f "$FW_PAYLOAD" ]] && [[ "$FW_PAYLOAD" -nt "$bao_bin" ]] && [[ "$FORCE_BAREMETAL" != "1" ]]; then
        log_skip "fw_payload.bin plus récent que bao.bin — FORCE_BAREMETAL=1 pour forcer"
        _log_summary "opensbi" "SKIP" "(fw_payload à jour)"
        return
    fi

    log_step "  → Log : $logfile"
    if _run_logged "$logfile" make -C "$ROOT_DIR/opensbi" \
        CROSS_COMPILE="$CROSS_COMPILE" \
        PLATFORM=fpga/ariane \
        FW_PAYLOAD=y \
        FW_PAYLOAD_PATH="$bao_bin" \
        -j"$JOBS"; then
        check_file "$FW_PAYLOAD"
        log_ok "fw_payload.bin généré : $FW_PAYLOAD ($(( $(stat -c%s "$FW_PAYLOAD") / 1024 )) KB)"
        _log_summary "opensbi" "OK" "$logfile"
    else
        log_error "Compilation OpenSBI échouée — voir $logfile"
        _log_summary "opensbi" "FAIL" "$logfile"
        exit 1
    fi
}

# =============================================================================
# Build complet du stack guest
# =============================================================================

do_baremetal() {
    log_step "Build stack BAO complet (DPR Manager → BAO → OpenSBI)"
    # Vérifie que les bitstreams existent (issus de 3_build_B2.sh dpr)
    check_bitstreams_present
    # Met à jour DPR_BS_ACCEL1/2_WORDS dans dpr_ipc.h si les tailles ont changé
    do_update_bs_constants
    do_dpr_manager
    do_bao
    do_opensbi
    log_ok "Stack BAO prêt : $FW_PAYLOAD"
    _log_summary "baremetal" "OK" "fw_payload=$(stat -c%s "$FW_PAYLOAD") octets"
}

# =============================================================================
# Cohérence : partial .bin présents et tailles == dpr_ipc.h
# =============================================================================

check_coherence() {
    local ok=1

    for rm in accel_A accel_B; do
        for accel in accel1 accel2; do
            local bin="$WORK_DPR/partial_${rm}_${accel}.bin"
            if [[ ! -f "$bin" ]]; then
                log_error "Bitstream partiel manquant : $bin"
                ok=0
            fi
        done
    done

    local bs_a1="$WORK_DPR/partial_accel_A_accel1.bin"
    local bs_a2="$WORK_DPR/partial_accel_A_accel2.bin"
    if [[ -f "$bs_a1" ]] && [[ -f "$DPR_IPC_H" ]]; then
        local sz1=$(( $(stat -c%s "$bs_a1") / 4 ))
        local sz2=$(( $(stat -c%s "$bs_a2") / 4 ))
        local h1 h2
        h1=$(grep -oP '(?<=DPR_BS_ACCEL1_WORDS\s{2})\d+' "$DPR_IPC_H" || echo 0)
        h2=$(grep -oP '(?<=DPR_BS_ACCEL2_WORDS\s{2})\d+' "$DPR_IPC_H" || echo 0)
        if [[ "$h1" != "$sz1" ]] || [[ "$h2" != "$sz2" ]]; then
            log_warn "dpr_ipc.h désynchronisé (accel1: h=$h1 vs bin=$sz1, accel2: h=$h2 vs bin=$sz2)"
            log_warn "Lancer './2_BUILD_HB.sh baremetal' pour resynchroniser"
        fi
    fi

    [[ $ok -eq 1 ]] || exit 1
}

# =============================================================================
# Programmation du FPGA via Vivado JTAG (identique à 3_build_B2.sh)
# =============================================================================

do_program() {
    log_step "Programmation du FPGA — full_${RM_INIT}.bit"

    local full_bit="$WORK_DPR/full_${RM_INIT}.bit"
    check_file "$full_bit"
    check_coherence
    source "$VIVADO_DIR/settings64.sh"

    local logfile; logfile=$(_logfile "program")
    local tcl_script; tcl_script=$(mktemp /tmp/program_XXXXXX.tcl)
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
        log_ok "FPGA programmé avec full_${RM_INIT}.bit"
        _log_summary "program" "OK" "$logfile"
    else
        log_error "Programmation FPGA échouée — voir $logfile"
        _log_summary "program" "FAIL" "$logfile"
        exit 1
    fi
}

# =============================================================================
# Lancement d'OpenOCD (identique à 3_build_B2.sh)
# =============================================================================

do_openocd() {
    log_step "Lancement OpenOCD"
    check_file "$OPENOCD_CFG"

    local logfile; logfile=$(_logfile "openocd")
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
# Chargement via GDB — fw_payload.bin + 4 bitstreams DDR
#
# Différence clé avec 3_build_B2.sh :
#   - Pas d'ELF direct : fw_payload.bin (OpenSBI+BAO+guest) en binaire @ 0x80000000
#   - 4 bitstreams chargés (A/B × accel1/accel2) pour le ping-pong complet
#   - PC initial = 0x80000000 (entrée OpenSBI)
# =============================================================================

do_load() {
    log_step "Chargement via GDB (fw_payload.bin + 4 bitstreams DDR)"

    local bs_a1_a="$WORK_DPR/partial_accel_A_accel1.bin"
    local bs_a1_b="$WORK_DPR/partial_accel_B_accel1.bin"
    local bs_a2_a="$WORK_DPR/partial_accel_A_accel2.bin"
    local bs_a2_b="$WORK_DPR/partial_accel_B_accel2.bin"

    check_file "$bs_a1_a"
    check_file "$bs_a1_b"
    check_file "$bs_a2_a"
    check_file "$bs_a2_b"
    check_file "$FW_PAYLOAD"
    check_coherence

    # Vérification des tailles vs slots DDR
    local sz_a1=$(( $(stat -c%s "$bs_a1_a") / 4 ))
    local sz_a2=$(( $(stat -c%s "$bs_a2_a") / 4 ))
    local slot_a1=$(( 0x81300000 - 0x81000000 ))   # 3 Mo
    local slot_a2=$(( 0x82000000 - 0x81600000 ))   # 5 Mo (fin avant Linux@0x82400000)

    if [[ $(( sz_a1 * 4 )) -gt $slot_a1 ]]; then
        log_error "Bitstream accel1 trop grand : $(( sz_a1*4 )) octets > slot $slot_a1 octets"
        exit 1
    fi
    if [[ $(( sz_a2 * 4 )) -gt $slot_a2 ]]; then
        log_error "Bitstream accel2 trop grand : $(( sz_a2*4 )) octets > slot $slot_a2 octets"
        exit 1
    fi

    log_ok "fw_payload.bin  : $(( $(stat -c%s "$FW_PAYLOAD") / 1024 )) KB @ $ADDR_FW"
    log_ok "accel1 accel_A  : $sz_a1 mots @ $ADDR_BS_A1_A"
    log_ok "accel1 accel_B  : $sz_a1 mots @ $ADDR_BS_A1_B"
    log_ok "accel2 accel_A  : $sz_a2 mots @ $ADDR_BS_A2_A"
    log_ok "accel2 accel_B  : $sz_a2 mots @ $ADDR_BS_A2_B"

    if ! pgrep -x "openocd" > /dev/null; then
        log_warn "OpenOCD ne semble pas tourner — lancer : ./2_BUILD_HB.sh openocd"
        echo -n "Continuer quand même ? [y/N] "
        read -r resp
        [[ "$resp" != "y" ]] && exit 1
    fi

    local gdb_script; gdb_script=$(mktemp /tmp/riscv_bao_load_XXXXXX.gdb)
    trap "rm -f '$gdb_script'" EXIT INT TERM

    cat > "$gdb_script" << EOF
target remote localhost:${OPENOCD_PORT}
set confirm off
set remote memory-write-packet-size 4096
set remote memory-write-packet-size fixed

echo \\n[GDB] Chargement bitstreams partiels en DDR...\\n

echo \\n[GDB] accel1 accel_A @ $ADDR_BS_A1_A\\n
restore $bs_a1_a binary $ADDR_BS_A1_A

echo \\n[GDB] accel1 accel_B @ $ADDR_BS_A1_B\\n
restore $bs_a1_b binary $ADDR_BS_A1_B

echo \\n[GDB] accel2 accel_A @ $ADDR_BS_A2_A\\n
restore $bs_a2_a binary $ADDR_BS_A2_A

echo \\n[GDB] accel2 accel_B @ $ADDR_BS_A2_B\\n
restore $bs_a2_b binary $ADDR_BS_A2_B

echo \\n[GDB] Chargement fw_payload.bin (OpenSBI + BAO + DPR Manager) @ $ADDR_FW\\n
restore $FW_PAYLOAD binary $ADDR_FW

set \$pc = $ADDR_FW
echo \\n[GDB] Demarrage OpenSBI + BAO (UART pour traces DPR Manager)...\\n
continue
EOF

    echo ""
    log_step "Lancement GDB..."
    "$GDB" -x "$gdb_script" --batch 2>&1
    rm -f "$gdb_script"
    trap - EXIT INT TERM
}

# =============================================================================
# Vérification des 4 bitstreams DDR
# =============================================================================

do_check_bitstreams() {
    log_step "Vérification des 4 bitstreams DDR"

    for rm in accel_A accel_B; do
        for accel in accel1 accel2; do
            local bin="$WORK_DPR/partial_${rm}_${accel}.bin"
            if [[ -f "$bin" ]]; then
                local sz=$(( $(stat -c%s "$bin") / 4 ))
                log_ok "  partial_${rm}_${accel}.bin : $sz mots ($(( sz*4/1024 )) KB)"
            else
                log_warn "  MANQUANT : partial_${rm}_${accel}.bin"
            fi
        done
    done

    echo ""
    log_ok "Layout DDR (dpr_ipc.h) :"
    log_ok "  $ADDR_BS_A1_A ← partial_accel_A_accel1.bin"
    log_ok "  $ADDR_BS_A1_B ← partial_accel_B_accel1.bin"
    log_ok "  $ADDR_BS_A2_A ← partial_accel_A_accel2.bin"
    log_ok "  $ADDR_BS_A2_B ← partial_accel_B_accel2.bin"
    echo ""
    log_ok "Constantes actuelles dans dpr_ipc.h :"
    grep "DPR_BS_ACCEL[12]_WORDS" "$DPR_IPC_H" | sed 's/^/  /'
}

# =============================================================================
# Dispatch
# =============================================================================

TARGET=""
for arg in "$@"; do
    case "$arg" in
        --force)           FORCE_BAREMETAL=1 ;;
        --force-baremetal) FORCE_BAREMETAL=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --*)              log_warn "Option inconnue : $arg" ;;
        *)                TARGET="$arg" ;;
    esac
done

case "${TARGET:-help}" in
    dpr-manager) create_dirs; do_dpr_manager ;;
    bao)         create_dirs; do_bao ;;
    opensbi)     create_dirs; do_opensbi ;;
    baremetal)   create_dirs; do_baremetal ;;
    program)     create_dirs; do_program ;;
    openocd)     create_dirs; do_openocd ;;
    load)        create_dirs; do_load ;;
    bitstreams)  create_dirs; do_check_bitstreams ;;
    logs)
        log_step "Historique des sessions (BAO DPR)"
        cat "$SUMMARY_LOG" 2>/dev/null || log_warn "Aucun log disponible ($SUMMARY_LOG)"
        ;;
    help | --help | -h)
        echo "Usage: $0 [TARGET] [OPTIONS]"
        echo ""
        echo "Prérequis : avoir lancé './3_build_B2.sh dpr' (bitstreams partagés)"
        echo ""
        echo "Targets (ordre de démarrage) :"
        echo "  1. baremetal   — Compile DPR Manager + BAO + OpenSBI → fw_payload.bin"
        echo "  2. program     — Programme le FPGA (full_accel_A.bit via Vivado JTAG)"
        echo "  3. openocd     — Lance OpenOCD (terminal dédié)"
        echo "  4. load        — Charge fw_payload.bin + 4 bitstreams via GDB"
        echo ""
        echo "Targets unitaires :"
        echo "  dpr-manager   — Compile le guest DPR Manager seul"
        echo "  bao           — Compile BAO seul (CONFIG=$BAO_CONFIG)"
        echo "  opensbi       — Compile OpenSBI seul (payload = bao.bin)"
        echo "  bitstreams    — Vérifie les 4 bitstreams DDR (issus de 3_build_B2.sh dpr)"
        echo "  logs          — Historique des sessions"
        echo ""
        echo "Options :"
        echo "  --force           — Force recompilation DPR Manager + BAO + OpenSBI"
        echo "  --force-baremetal — Idem"
        echo "  --dry-run         — Affiche les commandes sans les exécuter"
        echo ""
        echo "Variables d'environnement clés :"
        echo "  RM_INIT=$RM_INIT  RM_TARGET=$RM_TARGET"
        echo "  BAO_CONFIG=$BAO_CONFIG"
        echo "  LOGLEVEL=$LOGLEVEL"
        echo ""
        echo "Layout DDR (4 bitstreams chargés par GDB) :"
        echo "  $ADDR_BS_A1_A ← partial_accel_A_accel1.bin  (3 Mo slot)"
        echo "  $ADDR_BS_A1_B ← partial_accel_B_accel1.bin  (3 Mo slot)"
        echo "  $ADDR_BS_A2_A ← partial_accel_A_accel2.bin  (5 Mo slot)"
        echo "  $ADDR_BS_A2_B ← partial_accel_B_accel2.bin  (5 Mo slot)"
        echo ""
        echo "Pile de boot :"
        echo "  fw_payload.bin @ $ADDR_FW  (OpenSBI + BAO + DPR Manager)"
        ;;
    *)
        log_error "Cible inconnue : $TARGET"
        echo "Lancer : $0 help"
        exit 1
        ;;
esac
