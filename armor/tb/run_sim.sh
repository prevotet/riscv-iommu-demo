#!/usr/bin/env bash
# =============================================================================
#  Banc xsim : accel_wrap + wrapper ARMOR + aval comportemental
#
#  Usage :   ./run_sim.sh [scenario]     scenario = 0 | 1 | 2 (defaut : 1)
#            ./run_sim.sh all            joue les trois
#            WAVES=1 ./run_sim.sh 1      genere en plus tb_accel_armor.vcd
#            BUG=1   ./run_sim.sh 0      rejoue le defaut resp_t/resp_slv_t
#
#  Scenarios :
#    0  aval sain                       -- controle, doit atteindre DONE
#    1  aval qui accepte mais ne repond jamais  -- le cas observe sur carte
#    2  aval qui n'accepte rien
#
#  Ni verilator ni iverilog ne sont installes sur cette machine : xsim
#  (xvlog / xelab / xsim) est le seul simulateur disponible.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CVA6="$ROOT/cva6"
ARMOR="$ROOT/armor"
WORK="$HERE/work"

VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}"

if ! command -v xvlog >/dev/null 2>&1; then
    if [[ -f "$VIVADO_SETTINGS" ]]; then
        # shellcheck disable=SC1090
        source "$VIVADO_SETTINGS"
    else
        echo "xvlog introuvable et $VIVADO_SETTINGS absent." >&2
        echo "Definir VIVADO_SETTINGS=<chemin de settings64.sh>." >&2
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
#  Sources.
#
#  L'ordre des paquets compte en mode non-projet : il reprend celui deja valide
#  a l'elaboration Vivado (add_sources.tcl).
#
#  On prend axi_intf.sv et axi_pkg.sv cote cva6, PAS ceux de armor/SRC : ils
#  definissent les memes noms (AXI_BUS, axi_pkg) et xvlog refuserait le
#  doublon. Seul cva6/core/include/axi_intf.sv definit AXI_BUS_MMU, dont
#  accel_wrap a besoin.
# -----------------------------------------------------------------------------
PKGS=(
    "$CVA6/core/include/cv64a6_imafdc_sv39_config_pkg.sv"
    "$CVA6/core/include/riscv_pkg.sv"
    "$CVA6/core/include/ariane_dm_pkg.sv"
    "$CVA6/core/include/ariane_pkg.sv"
    "$CVA6/vendor/pulp-platform/axi/src/axi_pkg.sv"
    "$CVA6/corev_apu/riscv-dbg/src/dm_pkg.sv"
    "$CVA6/corev_apu/tb/ariane_soc_pkg.sv"
    "$CVA6/corev_apu/tb/ariane_axi_soc_pkg.sv"
    "$CVA6/core/include/axi_intf.sv"
)

# Modules ARMOR instancies par wrapper.sv (celui-ci est plat : tous les
# moniteurs et managers sont des feuilles directes).
ARMOR_SRC=(
    "$ARMOR/SRC/ADDR_extractor.sv"
    "$ARMOR/SRC/ID_extractor.sv"
    "$ARMOR/SRC/Interrupt_detector.sv"
    "$ARMOR/SRC/Delay_inserter.sv"
    "$ARMOR/SRC/id_comparator.sv"
    "$ARMOR/SRC/interrupt_monitor.sv"
    "$ARMOR/SRC/outs_req_flow_monitor.sv"
    "$ARMOR/SRC/request_flow_monitor.sv"
    "$ARMOR/SRC/request_manager.sv"
    "$ARMOR/SRC/response_manager.sv"
    "$ARMOR/SRC/security_monitor.sv"
    "$ARMOR/SRC/wrapper.sv"
)

DUT=(
    "$ROOT/cva6-overlay/corev_apu/fpga/src/accel_wrap.sv"
)

TB=( "$HERE/tb_accel_armor.sv" )

INCDIRS=(
    "-i" "$CVA6/core/include"
    "-i" "$ARMOR/Include"
    "-i" "$CVA6/vendor/pulp-platform/axi/include"
    "-i" "$CVA6/vendor/pulp-platform/common_cells/include"
)

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

DEFINES=()
# BUG=1 : rejoue le defaut de largeur resp_t / resp_slv_t sur la reponse aval
# (cf. le grand commentaire dans tb_accel_armor.sv). Sert de non-regression.
[[ "${BUG:-0}" == "1" ]] && DEFINES+=("-d" "BUG_RESP_T")

echo "=== xvlog ==="
xvlog -sv --nolog \
      "${DEFINES[@]+"${DEFINES[@]}"}" \
      "${INCDIRS[@]}" \
      "${PKGS[@]}" "${ARMOR_SRC[@]}" "${DUT[@]}" "${TB[@]}"

echo "=== xelab ==="
xelab -debug typical --nolog -timescale 1ns/1ps -s tb_snap tb_accel_armor

run_one() {
    local sc="$1"
    local args=("-testplusarg" "SCENARIO=$sc")
    [[ "${WAVES:-0}" == "1" ]] && args+=("-testplusarg" "WAVES")
    echo
    echo "############### SCENARIO $sc ###############"
    xsim tb_snap --nolog --runall "${args[@]}"
}

case "${1:-1}" in
    all) run_one 0; run_one 1; run_one 2 ;;
    *)   run_one "${1:-1}" ;;
esac
