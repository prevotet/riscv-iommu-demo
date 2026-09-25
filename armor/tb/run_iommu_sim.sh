#!/usr/bin/env bash
# =============================================================================
#  Banc xsim : riscv_iommu (mode Bare) + aval a outstanding borne, pilote par le
#  motif mode 7 (N AW en vol PUIS N W). Confirme le gel SC09 hors carte.
#
#    ./run_iommu_sim.sh              # balaie N in {2,4,8,16}, MAXOPEN=4
#    MAXOPEN=8 ./run_iommu_sim.sh    # aval plus profond
#    N=8 ./run_iommu_sim.sh one      # un seul point
#
#  xsim (xvlog/xelab/xsim) est le seul simulateur dispo (cf. armor/tb/run_sim.sh).
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CVA6="$ROOT/cva6"
IOMMU="$CVA6/corev_apu/rv_iommu"
VENDOR="$CVA6/vendor/pulp-platform"
WORK="$HERE/work_iommu"

VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}"
if ! command -v xvlog >/dev/null 2>&1; then
    [[ -f "$VIVADO_SETTINGS" ]] && source "$VIVADO_SETTINGS" || {
        echo "xvlog introuvable et $VIVADO_SETTINGS absent." >&2; exit 1; }
fi

PKGS=(
    "$CVA6/core/include/cv64a6_imafdc_sv39_config_pkg.sv"
    "$CVA6/core/include/riscv_pkg.sv"
    "$CVA6/core/include/ariane_dm_pkg.sv"
    "$CVA6/core/include/ariane_pkg.sv"
    "$VENDOR/axi/src/axi_pkg.sv"
    "$VENDOR/common_cells/src/cf_math_pkg.sv"
    "$CVA6/corev_apu/riscv-dbg/src/dm_pkg.sv"
    "$CVA6/corev_apu/tb/ariane_soc_pkg.sv"
    "$CVA6/corev_apu/tb/ariane_axi_soc_pkg.sv"
    "$IOMMU/packages/rv_iommu/rv_iommu_field_pkg.sv"
    "$IOMMU/packages/rv_iommu/rv_iommu_pkg.sv"
    "$IOMMU/packages/rv_iommu/rv_iommu_reg_pkg.sv"
)

# Toutes les dependances viennent de rv_iommu/vendor (jeu auto-suffisant :
# common_cells + axi + REG_BUS + axi2apb). NE PAS melanger avec cva6/vendor
# (doublons de modules -> "overwriting definition"). Seuls axi_pkg et
# cf_math_pkg (packages) viennent de cva6/vendor, dans PKGS.
VENDOR_IOMMU=( "$IOMMU/vendor/REG_BUS.sv" )
for f in "$IOMMU"/vendor/*.sv; do
    [[ "$f" == *"/REG_BUS.sv" ]] && continue
    VENDOR_IOMMU+=("$f")
done

IOMMU_RTL=(
    "$IOMMU/rtl/software_interface/regmap/rv_iommu_field.sv"
    "$IOMMU/rtl/software_interface/regmap/rv_iommu_field_arb.sv"
    "$IOMMU/rtl/software_interface/regmap/rv_iommu_regmap.sv"
    "$IOMMU/rtl/software_interface/rv_iommu_cq_handler.sv"
    "$IOMMU/rtl/software_interface/rv_iommu_fq_handler.sv"
    "$IOMMU/rtl/software_interface/rv_iommu_hpm.sv"
    "$IOMMU/rtl/software_interface/rv_iommu_msi_ig.sv"
    "$IOMMU/rtl/software_interface/rv_iommu_wsi_ig.sv"
    "$IOMMU/rtl/software_interface/wrapper/rv_iommu_sw_if_wrapper.sv"
    "$IOMMU/rtl/translation_logic/rv_iommu_ddtc.sv"
    "$IOMMU/rtl/translation_logic/rv_iommu_pdtc.sv"
    "$IOMMU/rtl/translation_logic/rv_iommu_iotlb_sv39x4.sv"
    "$IOMMU/rtl/translation_logic/rv_iommu_mrifc.sv"
    "$IOMMU/rtl/translation_logic/rv_iommu_mrif_handler.sv"
    "$IOMMU/rtl/translation_logic/rv_iommu_msiptw.sv"
    "$IOMMU/rtl/translation_logic/ptw/rv_iommu_ptw_sv39x4.sv"
    "$IOMMU/rtl/translation_logic/ptw/rv_iommu_ptw_sv39x4_pc.sv"
    "$IOMMU/rtl/translation_logic/cdw/rv_iommu_cdw.sv"
    "$IOMMU/rtl/translation_logic/cdw/rv_iommu_cdw_pc.sv"
    "$IOMMU/rtl/translation_logic/wrapper/rv_iommu_tw_sv39x4.sv"
    "$IOMMU/rtl/translation_logic/wrapper/rv_iommu_tw_sv39x4_pc.sv"
    "$IOMMU/rtl/translation_logic/wrapper/rv_iommu_translation_wrapper.sv"
    "$IOMMU/rtl/ext_interfaces/rv_iommu_axi4_bc.sv"
    "$IOMMU/rtl/ext_interfaces/rv_iommu_ds_if.sv"
    "$IOMMU/rtl/ext_interfaces/rv_iommu_ign_slv.sv"
    "$IOMMU/rtl/ext_interfaces/rv_iommu_prog_if.sv"
    "$IOMMU/rtl/riscv_iommu.sv"
)

INCDIRS=(
    "-i" "$HERE/stub_inc"
    "-i" "$CVA6/core/include"
    "-i" "$VENDOR/axi/include"
    "-i" "$VENDOR/common_cells/include"
    "-i" "$IOMMU/include"
    "-i" "$CVA6/corev_apu/register_interface/include"
)

rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

echo "=== xvlog ==="
xvlog -sv --nolog -d XSIM "${INCDIRS[@]}" \
    "${PKGS[@]}" "${VENDOR_IOMMU[@]}" "${IOMMU_RTL[@]}" \
    "$HERE/tb_iommu_pipe.sv" || { echo "ECHEC xvlog"; exit 1; }

echo "=== xelab ==="
xelab -debug typical --nolog -timescale 1ns/1ps -s tb_iommu_snap tb_iommu_pipe \
    || { echo "ECHEC xelab"; exit 1; }

run_one() { echo "--- N=$1 MAXOPEN=${MAXOPEN:-4} ---"
    xsim tb_iommu_snap --nolog --runall \
        -testplusarg "N=$1" -testplusarg "MAXOPEN=${MAXOPEN:-4}" \
        -testplusarg "WLAT=${WLAT:-8}" | grep -E "^###"; }

if [[ "${1:-}" == "one" ]]; then run_one "${N:-8}"
else for n in 2 4 8 16; do run_one "$n"; done; fi
