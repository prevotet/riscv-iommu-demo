# run_partial.tcl - Implémentation d'une configuration partielle
# vivado -mode batch -source run_partial.tcl
#        -tclargs <work_dpr_dir> <rm_dir> <rm_name>

set work_dpr [lindex $argv 0]
set rm_dir   [lindex $argv 1]
set rm_name  [lindex $argv 2]

# Repartir du checkpoint statique routé
open_checkpoint $work_dpr/static_routed.dcp

# Synthèse OOC du RM si pas en cache
set rm_synth $work_dpr/${rm_name}_synth.dcp
if {![file exists $rm_synth]} {
    puts "Synthèse OOC du RM $rm_name..."
    set rm_sources [glob -nocomplain $rm_dir/*.sv]
    synth_design \
        -top accel_wrap \
        -part xc7k325tffg900-2 \
        -mode out_of_context \
        -files $rm_sources
    write_checkpoint -force $rm_synth
    close_design
    open_checkpoint $work_dpr/static_routed.dcp
}

# Lier le RM aux cellules reconfigurables
set cell1 [get_cells -quiet -hierarchical \
    -filter {NAME =~ *gen_dma.i_accel1}]
if {$cell1 != ""} {
    read_checkpoint -cell $cell1 $rm_synth
}
set cell2 [get_cells -quiet -hierarchical \
    -filter {NAME =~ *gen_dma.gen_accel2.i_accel2}]
if {$cell2 != ""} {
    read_checkpoint -cell $cell2 $rm_synth
}

# Implémentation partielle
opt_design   -directive RuntimeOptimized
place_design -directive RuntimeOptimized
phys_opt_design
route_design -directive NoTimingRelaxation

# Bitstream partiel pour chaque accélérateur
if {$cell1 != ""} {
    write_bitstream -force -cell $cell1 \
        $work_dpr/partial_${rm_name}_accel1.bit
    puts "Partial bit: $work_dpr/partial_${rm_name}_accel1.bit"
}
if {$cell2 != ""} {
    write_bitstream -force -cell $cell2 \
        $work_dpr/partial_${rm_name}_accel2.bit
    puts "Partial bit: $work_dpr/partial_${rm_name}_accel2.bit"
}

write_checkpoint -force $work_dpr/${rm_name}_routed.dcp
