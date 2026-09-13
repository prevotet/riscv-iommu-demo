#!/usr/bin/env bash
# Valide axi_wr_pacer : maitre mode 7 -> [pacer si PACER=1] -> aval borne.
#   ./run_pacer.sh          # SANS pacer : gel a N>MAXOPEN
#   PACER=1 ./run_pacer.sh  # AVEC pacer : tout passe
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
CVA6="$ROOT/cva6"; VENDOR="$CVA6/vendor/pulp-platform"
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}"
command -v xvlog >/dev/null 2>&1 || source "$VIVADO_SETTINGS"
W="$HERE/work_pacer"; rm -rf "$W"; mkdir -p "$W"; cd "$W"
xvlog -sv --nolog ${PACER:+-d PACER} \
  "$CVA6/core/include/cv64a6_imafdc_sv39_config_pkg.sv" \
  "$CVA6/core/include/riscv_pkg.sv" "$CVA6/core/include/ariane_dm_pkg.sv" \
  "$CVA6/core/include/ariane_pkg.sv" "$VENDOR/axi/src/axi_pkg.sv" \
  "$CVA6/corev_apu/riscv-dbg/src/dm_pkg.sv" \
  "$CVA6/corev_apu/tb/ariane_soc_pkg.sv" "$CVA6/corev_apu/tb/ariane_axi_soc_pkg.sv" \
  "$ROOT/cva6-overlay/corev_apu/fpga/src/axi_wr_pacer.sv" \
  "$HERE/tb_pacer.sv" || { echo ECHEC_xvlog; exit 1; }
xelab --nolog -timescale 1ns/1ps -s pacer_snap tb_pacer || { echo ECHEC_xelab; exit 1; }
for n in 2 4 8 16; do
  xsim pacer_snap --nolog --runall -testplusarg "N=$n" -testplusarg "MAXOPEN=${MAXOPEN:-4}" | grep -E "^###"
done
