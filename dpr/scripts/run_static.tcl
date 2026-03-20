# run_static.tcl - Implémentation DPR configuration de base
# vivado -mode batch -source run_static.tcl
#        -tclargs <cva6_fpga_dir> <dpr_dir> <work_dpr_dir>

set cva6_fpga [lindex $argv 0]
set dpr_dir   [lindex $argv 1]
set work_dpr  [lindex $argv 2]

open_project $cva6_fpga/ariane.xpr

# Ajouter contraintes Pblock et source frontière RP
add_files -fileset constrs_1 $dpr_dir/constraints/pblock_accels.xdc
add_files -fileset sources_1 $dpr_dir/src/rp_boundary_regs.sv
set_property USED_IN_SYNTHESIS true \
    [get_files $dpr_dir/src/rp_boundary_regs.sv]

# Reset et synthèse
set synth_status [get_property STATUS [get_runs synth_1]]
if {$synth_status != "synth_design Complete!"} {
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
}
open_run synth_1

# Implémentation avec Pblocks
opt_design
place_design
phys_opt_design
route_design

# Vérifications DPR
report_drc -checks {HDPR-*} -file $work_dpr/drc_dpr.rpt -quiet
set viol [llength [get_drc_violations -quiet -filter {CHECK =~ HDPR-*}]]
if {$viol > 0} {
    puts "WARNING: $viol DPR DRC violations - voir $work_dpr/drc_dpr.rpt"
}

file mkdir $work_dpr
write_checkpoint -force $work_dpr/static_routed.dcp
write_bitstream  -force $work_dpr/static_full.bit
puts "OK: static checkpoint -> $work_dpr/static_routed.dcp"
