# Pblock parent
create_pblock pblock_rp_accels
resize_pblock [get_pblocks pblock_rp_accels] \
    -add {SLICE_X0Y230:SLICE_X145Y329 DSP48_X0Y55:DSP48_X5Y64 RAMB36_X0Y27:RAMB36_X4Y32 RAMB18_X0Y55:RAMB18_X4Y64}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_rp_accels]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_rp_accels]
set_property IS_SOFT          false [get_pblocks pblock_rp_accels]

# Pblock accel1 (moitié gauche)
create_pblock pblock_accel1
resize_pblock [get_pblocks pblock_accel1] \
    -add {SLICE_X0Y230:SLICE_X71Y329 DSP48_X0Y55:DSP48_X2Y64 RAMB36_X0Y27:RAMB36_X2Y32 RAMB18_X0Y55:RAMB18_X2Y64}
set_property PARENT           pblock_rp_accels [get_pblocks pblock_accel1]
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel1]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel1]
set_property IS_SOFT          false [get_pblocks pblock_accel1]

# Pblock accel2 (moitié droite)
create_pblock pblock_accel2
resize_pblock [get_pblocks pblock_accel2] \
    -add {SLICE_X72Y230:SLICE_X145Y329 DSP48_X3Y55:DSP48_X5Y64 RAMB36_X3Y27:RAMB36_X4Y32 RAMB18_X3Y55:RAMB18_X4Y64}
set_property PARENT           pblock_rp_accels [get_pblocks pblock_accel2]
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel2]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel2]
set_property IS_SOFT          false [get_pblocks pblock_accel2]