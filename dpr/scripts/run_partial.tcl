# run_partial.tcl - Implémentation d'une configuration partielle
set work_dpr [lindex $argv 0]
set rm_dir   [lindex $argv 1]
set rm_name  [lindex $argv 2]

# Repartir du checkpoint statique routé
open_checkpoint $work_dpr/static_routed.dcp

# Synthèse OOC du RM si pas en cache
set rm_synth $work_dpr/${rm_name}_synth.dcp
if {![file exists $rm_synth]} {
    puts "==> Synthèse OOC du RM $rm_name..."

    set cva6_root [file normalize [file join $work_dpr ".." ".." ".."]]

    synth_design \
        -top accel_wrap \
        -part xc7k325tffg900-2 \
        -mode out_of_context \
        -include_dirs [list \
            [file join $cva6_root "vendor" "pulp-platform" "axi" "include"] \
            [file join $cva6_root "vendor" "pulp-platform" "common_cells" "include"] \
            [file join $cva6_root "core" "include"] \
        ] \
        -files [concat \
            [list [file join $cva6_root "vendor" "pulp-platform" "axi" "src" "axi_pkg.sv"]] \
            [glob -nocomplain $rm_dir/*.sv] \
        ]

    write_checkpoint -force $rm_synth
    puts "  -> checkpoint RM : $rm_synth"

    # Rouvrir le checkpoint statique pour la suite
    open_checkpoint $work_dpr/static_routed.dcp
}

# Lier le RM aux cellules reconfigurables (black-box dans static_routed.dcp)
set cell1 [get_cells -quiet i_ariane_peripherals/gen_dma.i_accel1]
set cell2 [get_cells -quiet i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]

if {[llength $cell1] > 0} {
    read_checkpoint -cell $cell1 $rm_synth
    puts "  -> RM chargé dans i_accel1"
}
if {[llength $cell2] > 0} {
    read_checkpoint -cell $cell2 $rm_synth
    puts "  -> RM chargé dans i_accel2"
}

# Implémentation partielle
puts "==> opt_design..."
opt_design   -directive RuntimeOptimized
puts "==> place_design..."
place_design -directive RuntimeOptimized
puts "==> phys_opt_design..."
phys_opt_design
puts "==> route_design..."
route_design -directive NoTimingRelaxation

# Bitstreams partiels
if {[llength $cell1] > 0} {
    write_bitstream -force -cell $cell1 \
        $work_dpr/partial_${rm_name}_accel1.bit
    puts "OK: $work_dpr/partial_${rm_name}_accel1.bit"
}
if {[llength $cell2] > 0} {
    write_bitstream -force -cell $cell2 \
        $work_dpr/partial_${rm_name}_accel2.bit
    puts "OK: $work_dpr/partial_${rm_name}_accel2.bit"
}

write_checkpoint -force $work_dpr/${rm_name}_routed.dcp
puts "OK: checkpoint -> $work_dpr/${rm_name}_routed.dcp"