#!/usr/bin/env bash
# =============================================================================
#  Chargement du bitstream sur la Genesys2 via JTAG.
#
#   ./tools/program_fpga.sh [chemin/vers/ariane_xilinx.bit]
#
#  Par défaut : build/hw/ariane_xilinx.bit, comme 2_build_HB.sh program.
#
#  Existe parce que le `do_program` de 2_build_HB.sh appelle `open_hw_target`
#  sans avoir sélectionné de cible. Vivado en devine alors une, se trompe de
#  nom, et sort « No devices detected on target » alors que le JTAG répond
#  parfaitement. Le `current_hw_target` ci-dessous est toute la différence.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIT="${1:-$ROOT/build/hw/ariane_xilinx.bit}"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}"

[[ -f "$BIT" ]] || { echo "Bitstream introuvable : $BIT" >&2; exit 1; }

if ! command -v vivado >/dev/null 2>&1; then
    if [[ -f "$VIVADO_SETTINGS" ]]; then
        # shellcheck disable=SC1090
        source "$VIVADO_SETTINGS"
    else
        echo "vivado introuvable et $VIVADO_SETTINGS absent." >&2
        exit 1
    fi
fi

# Provenance du bitstream, quand elle existe : un .bit sans le bon RTL produit
# des campagnes qu'on peut passer des heures à réinterpréter.
if [[ -x "$ROOT/tools/bitstream.sh" ]]; then
    "$ROOT/tools/bitstream.sh" check bench 2>/dev/null || true
fi

tcl=$(mktemp /tmp/program_fpga_XXXXXX.tcl)
trap 'rm -f "$tcl"' EXIT

cat > "$tcl" <<EOF
open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
if {[llength \$targets] == 0} {
    puts "ERREUR : aucune cible JTAG. Carte alimentée ? Câble branché ?"
    exit 1
}
current_hw_target [lindex \$targets 0]
open_hw_target
set devs [get_hw_devices xc7k* -quiet]
if {[llength \$devs] == 0} {
    puts "ERREUR : cible ouverte mais aucun device xc7k détecté."
    exit 1
}
set dev [lindex \$devs 0]
current_hw_device \$dev
set_property PROGRAM.FILE {$BIT} \$dev
program_hw_devices \$dev
close_hw_target
disconnect_hw_server
close_hw_manager
EOF

echo "Bitstream : $BIT"
vivado -mode batch -nojournal -nolog -notrace -source "$tcl"
echo "Bitstream chargé."
