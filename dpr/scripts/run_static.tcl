# run_static.tcl - Implémentation DPR (Utilisation du projet existant)
set cva6_fpga [lindex $argv 0]
set dpr_dir   [lindex $argv 1]
set work_dpr  [lindex $argv 2]

open_project $cva6_fpga/ariane.xpr
set_property incremental_checkpoint {} [get_runs synth_1]

# 1. AJOUT DES SOURCES DPR
puts "==> Injection des sources DPR..."
add_files -fileset sources_1 -norecurse [list \
    $dpr_dir/src/rp_boundary_regs.sv \
    $cva6_fpga/src/accel_wrap.sv \
]
update_compile_order -fileset sources_1

# 2. AJOUT DES CONTRAINTES DE PLACEMENT (Pblocks)
puts "==> Application des contraintes de Pblocks..."
add_files -fileset constrs_1 -norecurse $dpr_dir/constraints/pblock_accels.xdc
set_property used_in_synthesis true  [get_files pblock_accels.xdc]
set_property used_in_implementation true [get_files pblock_accels.xdc]

# 3. FORÇAGE DU TOP
set_property top ariane_xilinx [current_fileset]

# 4. SYNTHÈSE
puts "==> Lancement de la synthèse synth_1..."
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthèse échouée."
    exit 1
}

# 5. IMPLÉMENTATION
puts "==> Lancement de l'implémentation impl_1..."
reset_run impl_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: Implémentation échouée."
    exit 1
}

# 6. EXPORTATION DU CHECKPOINT POUR DPR
open_run impl_1
file mkdir $work_dpr
write_checkpoint -force $work_dpr/static_routed.dcp
write_bitstream  -force $work_dpr/static_full.bit
puts "OK: static checkpoint -> $work_dpr/static_routed.dcp"