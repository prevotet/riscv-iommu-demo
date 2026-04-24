open_checkpoint cva6/corev_apu/fpga/work-dpr/3_build_B_dpr/static_routed.dcp
set icap [get_cells -hierarchical -filter {REF_NAME == ICAPE2}]
puts "==> ICAP cell : $icap"
puts "==> ICAP LOC  : [get_property LOC $icap]"
close_design
