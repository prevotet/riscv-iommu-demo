# Pblocks DPR generes par run_static.tcl
# pblock_accel1 : moitie gauche clock region Y5
create_pblock pblock_accel1
resize_pblock [get_pblocks pblock_accel1] -add {SLICE_X0Y250:SLICE_X71Y299}
resize_pblock [get_pblocks pblock_accel1] -add {DSP48_X0Y60:DSP48_X1Y64}
resize_pblock [get_pblocks pblock_accel1] -add {RAMB36_X0Y25:RAMB36_X1Y29}
resize_pblock [get_pblocks pblock_accel1] -add {RAMB18_X0Y50:RAMB18_X1Y59}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel1]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel1]
set_property IS_SOFT          false [get_pblocks pblock_accel1]
set_property SNAPPING_MODE    ON    [get_pblocks pblock_accel1]
# pblock_accel2 : moitie droite clock region Y5
create_pblock pblock_accel2
resize_pblock [get_pblocks pblock_accel2] -add {SLICE_X72Y250:SLICE_X145Y299}
resize_pblock [get_pblocks pblock_accel2] -add {DSP48_X2Y60:DSP48_X5Y64}
resize_pblock [get_pblocks pblock_accel2] -add {RAMB36_X2Y25:RAMB36_X4Y29}
resize_pblock [get_pblocks pblock_accel2] -add {RAMB18_X2Y50:RAMB18_X4Y59}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel2]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel2]
set_property IS_SOFT          false [get_pblocks pblock_accel2]
set_property SNAPPING_MODE    ON    [get_pblocks pblock_accel2]
set_property HD.RECONFIGURABLE true [get_cells i_ariane_peripherals/gen_dma.i_accel1]
set_property HD.RECONFIGURABLE true [get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]
add_cells_to_pblock [get_pblocks pblock_accel1] [get_cells i_ariane_peripherals/gen_dma.i_accel1]
add_cells_to_pblock [get_pblocks pblock_accel2] [get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]
