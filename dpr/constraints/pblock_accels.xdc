# =============================================================
#  DPR Pblock constraints — riscv-iommu-demo
#  Cible : Genesys2 XC7K325T-2FFG900
#  À sourcer APRÈS le XDC standard de cva6
# =============================================================

create_pblock pblock_rp_accels
resize_pblock [get_pblocks pblock_rp_accels] \
    -add {CLOCKREGION_X0Y3:CLOCKREGION_X1Y3}
set_property CONTAIN_ROUTING   true  [get_pblocks pblock_rp_accels]
set_property IS_SOFT           false [get_pblocks pblock_rp_accels]

create_pblock pblock_accel1
resize_pblock [get_pblocks pblock_accel1] \
    -add {CLOCKREGION_X0Y3:CLOCKREGION_X0Y3}
set_property PARENT pblock_rp_accels [get_pblocks pblock_accel1]

create_pblock pblock_accel2
resize_pblock [get_pblocks pblock_accel2] \
    -add {CLOCKREGION_X1Y3:CLOCKREGION_X1Y3}
set_property PARENT pblock_rp_accels [get_pblocks pblock_accel2]

add_cells_to_pblock [get_pblocks pblock_accel1] \
    [get_cells -quiet -hierarchical \
        -filter {NAME =~ *gen_dma.i_accel1*}]
add_cells_to_pblock [get_pblocks pblock_accel2] \
    [get_cells -quiet -hierarchical \
        -filter {NAME =~ *gen_dma.gen_accel2.i_accel2*}]

set_property HD.RECONFIGURABLE true \
    [get_cells -quiet -hierarchical \
        -filter {NAME =~ *gen_dma.i_accel1}]
set_property HD.RECONFIGURABLE true \
    [get_cells -quiet -hierarchical \
        -filter {NAME =~ *gen_dma.gen_accel2.i_accel2}]
