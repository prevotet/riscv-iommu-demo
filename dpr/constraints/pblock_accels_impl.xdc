# Pblocks DPR generes par run_static.tcl
# pblock_accel1 : zone restreinte clock region Y5
create_pblock pblock_accel1
resize_pblock [get_pblocks pblock_accel1] -add {SLICE_X32Y250:SLICE_X47Y299}
resize_pblock [get_pblocks pblock_accel1] -add {DSP48_X1Y60:DSP48_X1Y64}
resize_pblock [get_pblocks pblock_accel1] -add {RAMB36_X1Y25:RAMB36_X1Y29}
resize_pblock [get_pblocks pblock_accel1] -add {RAMB18_X1Y50:RAMB18_X1Y59}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel1]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel1]
set_property IS_SOFT          false [get_pblocks pblock_accel1]
set_property SNAPPING_MODE    ON    [get_pblocks pblock_accel1]
# pblock_accel2 : zone restreinte clock region Y5
create_pblock pblock_accel2
resize_pblock [get_pblocks pblock_accel2] -add {SLICE_X100Y250:SLICE_X115Y299}
resize_pblock [get_pblocks pblock_accel2] -add {DSP48_X4Y60:DSP48_X4Y64}
resize_pblock [get_pblocks pblock_accel2] -add {RAMB36_X4Y25:RAMB36_X4Y29}
resize_pblock [get_pblocks pblock_accel2] -add {RAMB18_X4Y50:RAMB18_X4Y59}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel2]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel2]
set_property IS_SOFT          false [get_pblocks pblock_accel2]
set_property SNAPPING_MODE    ON    [get_pblocks pblock_accel2]
set_property HD.RECONFIGURABLE true [get_cells i_ariane_peripherals/gen_dma.i_accel1]
set_property HD.RECONFIGURABLE true [get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]
add_cells_to_pblock [get_pblocks pblock_accel1] [get_cells i_ariane_peripherals/gen_dma.i_accel1]
add_cells_to_pblock [get_pblocks pblock_accel2] [get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]
# Forcer ICAP en CR Y0 — evite disruption horloge CR Y5 pendant reconfig
set_property LOC ICAP_X0Y0 [get_cells -hierarchical -filter {REF_NAME == ICAPE2}]
# HWICAP IP hors CR Y5 — evite freeze AXI pendant DPR
create_pblock pblock_hwicap
resize_pblock [get_pblocks pblock_hwicap] -add {SLICE_X0Y0:SLICE_X167Y249}
set_property IS_SOFT true [get_pblocks pblock_hwicap]
add_cells_to_pblock [get_pblocks pblock_hwicap] [get_cells -hierarchical -filter {NAME =~ *gen_hwicap*}]
