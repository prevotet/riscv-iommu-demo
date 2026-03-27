# run_partial.tcl - Implémentation d'une configuration partielle
# Usage: vivado -mode batch -source run_partial.tcl
#        -tclargs <work_dpr_dir> <rm_dir> <rm_name>

set work_dpr [lindex $argv 0]
set rm_dir   [lindex $argv 1]
set rm_name  [lindex $argv 2]

set cva6_root [file normalize [file join $work_dpr ".." ".." ".."]]

# =============================================================
# 1. SYNTHÈSE OOC DU RM (si pas en cache)
# =============================================================
set rm_synth $work_dpr/${rm_name}_synth.dcp

if {![file exists $rm_synth]} {
    puts "==> Synthèse OOC du RM $rm_name..."

    set tmp_dir [file join $work_dpr "tmp_synth_${rm_name}"]
    file mkdir $tmp_dir
   create_project -force tmp_synth $tmp_dir -part xc7k325tffg900-2

# Ajout dans l'ordre strict de dépendance
read_verilog -sv [file join $cva6_root "vendor" "pulp-platform" "axi" "src" "axi_pkg.sv"]
read_verilog -sv [file join $cva6_root "vendor" "pulp-platform" "axi" "src" "axi_intf.sv"]
read_verilog -sv [file join $cva6_root "core" "include" "axi_intf.sv"]
foreach f [glob -nocomplain $rm_dir/*.sv] {
    read_verilog -sv $f
}

set_property include_dirs [list \
    [file join $cva6_root "vendor" "pulp-platform" "axi" "include"] \
    [file join $cva6_root "vendor" "pulp-platform" "common_cells" "include"] \
    [file join $cva6_root "core" "include"] \
] [current_fileset]

set_property top accel_wrap [current_fileset]
    set_property top accel_wrap [current_fileset]
    update_compile_order -fileset sources_1

    set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
        -value {-mode out_of_context} -objects [get_runs synth_1]
    set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} \
        -value {none} -objects [get_runs synth_1]

    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
        puts "ERROR: Synthèse OOC du RM échouée."
        exit 1
    }

    open_run synth_1
    write_checkpoint -force $rm_synth
    puts "  -> checkpoint RM : $rm_synth"

    close_project
    file delete -force $tmp_dir
} else {
    puts "==> RM en cache : $rm_synth"
}

# =============================================================
# 2. CHARGEMENT DU CHECKPOINT STATIQUE
# =============================================================
puts "==> Ouverture du checkpoint statique..."
open_checkpoint $work_dpr/static_routed.dcp

# =============================================================
# 3. CHARGEMENT DU RM DANS LES CELLULES RECONFIGURABLES
# =============================================================
set cell1 [get_cells -quiet i_ariane_peripherals/gen_dma.i_accel1]
set cell2 [get_cells -quiet i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]

if {[llength $cell1] == 0} { puts "ERROR: i_accel1 non trouvé"; exit 1 }
if {[llength $cell2] == 0} { puts "ERROR: i_accel2 non trouvé"; exit 1 }

read_checkpoint -cell $cell1 $rm_synth
puts "  -> RM chargé dans i_accel1"
read_checkpoint -cell $cell2 $rm_synth
puts "  -> RM chargé dans i_accel2"

# =============================================================
# 4. IMPLÉMENTATION PARTIELLE
# =============================================================
puts "==> opt_design..."
opt_design -directive RuntimeOptimized

puts "==> place_design..."
place_design -directive RuntimeOptimized

puts "==> phys_opt_design..."
phys_opt_design

puts "==> route_design..."
route_design -directive NoTimingRelaxation

# =============================================================
# 5. EXPORT DES BITSTREAMS
# =============================================================
# Bitstream complet (statique + RM) — pour le premier chargement
write_bitstream -force $work_dpr/full_${rm_name}.bit
puts "OK: $work_dpr/full_${rm_name}.bit"

# Bitstreams partiels — pour le rechargement dynamique
write_bitstream -force -cell $cell1 \
    $work_dpr/partial_${rm_name}_accel1.bit
puts "OK: $work_dpr/partial_${rm_name}_accel1.bit"

write_bitstream -force -cell $cell2 \
    $work_dpr/partial_${rm_name}_accel2.bit
puts "OK: $work_dpr/partial_${rm_name}_accel2.bit"

# Checkpoint du run partiel (utile pour pr_verify)
write_checkpoint -force $work_dpr/${rm_name}_routed.dcp
puts "OK: checkpoint -> $work_dpr/${rm_name}_routed.dcp"