# =============================================================
#  DPR Pblock constraints — géométrie uniquement
#  Cible : Genesys2 XC7K325T-2FFG900
# =============================================================
create_pblock pblock_rp_accels
resize_pblock [get_pblocks pblock_rp_accels] \
    -add {SLICE_X0Y150:SLICE_X111Y224 DSP48_X0Y60:DSP48_X4Y89 RAMB18_X0Y60:RAMB18_X4Y89 RAMB36_X0Y30:RAMB36_X4Y44}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_rp_accels]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_rp_accels]
set_property IS_SOFT          false [get_pblocks pblock_rp_accels]

create_pblock pblock_accel1
resize_pblock [get_pblocks pblock_accel1] \
    -add {SLICE_X0Y150:SLICE_X55Y224 DSP48_X0Y60:DSP48_X2Y89 RAMB18_X0Y60:RAMB18_X2Y89 RAMB36_X0Y30:RAMB36_X2Y44}
set_property PARENT           pblock_rp_accels [get_pblocks pblock_accel1]
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel1]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel1]
set_property IS_SOFT          false [get_pblocks pblock_accel1]

create_pblock pblock_accel2
resize_pblock [get_pblocks pblock_accel2] \
    -add {SLICE_X56Y150:SLICE_X111Y224 DSP48_X3Y60:DSP48_X4Y89 RAMB18_X3Y60:RAMB18_X4Y89 RAMB36_X3Y30:RAMB36_X4Y44}
set_property PARENT           pblock_rp_accels [get_pblocks pblock_accel2]
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel2]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel2]
set_property IS_SOFT          false [get_pblocks pblock_accel2]
