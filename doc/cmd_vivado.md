
## Visualisation des pblocks sous Vivado
source /tools/Xilinx/Vivado/2022.2/settings64.sh
vivado /home/jc/tmp/riscv-iommu-demo/cva6/corev_apu/fpga/work-dpr/static_routed.dcp

# dans la console TCL
foreach pb [get_pblocks] {
    puts "$pb : [get_property GRID_RANGES $pb]"
    puts "  Cells : [llength [get_cells -of_objects [get_pblocks $pb]]]"
}