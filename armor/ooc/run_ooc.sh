#!/usr/bin/env bash
#  Synthese hors contexte du wrapper ARMOR. ~2 min. Exige la licence (xc7k325t).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export XILINXD_LICENSE_FILE="${XILINXD_LICENSE_FILE:-/home/jc/Xilinx.lic}"
source "${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}"
cd "$ROOT/armor/ooc"
vivado -mode batch -nojournal -nolog -source run_ooc.tcl -tclargs "$ROOT"
