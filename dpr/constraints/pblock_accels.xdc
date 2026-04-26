# =============================================================
#  DPR Pblock constraints — géométrie réduite
#  Cible : Genesys2 XC7K325T-2FFG900
# =============================================================

# pblock_accel1 (X32-X47)
create_pblock pblock_accel1
resize_pblock [get_pblocks pblock_accel1] \
    -add {SLICE_X32Y250:SLICE_X47Y299 DSP48_X1Y60:DSP48_X1Y64 RAMB18_X1Y50:RAMB18_X1Y59 RAMB36_X1Y25:RAMB36_X1Y29}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel1]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel1]
set_property IS_SOFT          false [get_pblocks pblock_accel1]

# pblock_accel2 (X100-X115)
create_pblock pblock_accel2
resize_pblock [get_pblocks pblock_accel2] \
    -add {SLICE_X100Y250:SLICE_X115Y299 DSP48_X4Y60:DSP48_X4Y64 RAMB18_X4Y50:RAMB18_X4Y59 RAMB36_X4Y25:RAMB36_X4Y29}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel2]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel2]
set_property IS_SOFT          false [get_pblocks pblock_accel2]
