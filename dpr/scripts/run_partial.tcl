# run_partial.tcl - Implémentation d'une configuration partielle
# Usage: vivado -mode batch -source run_partial.tcl
#        -tclargs <work_dpr_dir> <rm_dir> <rm_name>

set work_dpr [lindex $argv 0]
set rm_dir   [lindex $argv 1]

set rm_name  [lindex $argv 2]

set cva6_root [file normalize [file join $work_dpr ".." ".." ".."]]
set cva6_fpga [file normalize [file join $work_dpr ".."]]
set dpr_dir [file normalize [file join $work_dpr ".." ".." ".." ".." "dpr"]]

# =============================================================
# 1. SYNTHÈSE DU RM DANS LE CONTEXTE DU PROJET ARIANE
# =============================================================
set rm_synth $work_dpr/${rm_name}_synth.dcp

if {![file exists $rm_synth]} {
    puts "==> Synthèse du RM $rm_name dans le projet ariane..."

    # Copie du RM dans le projet CVA6
    set rm_sv [lindex [glob $rm_dir/*.sv] 0]
    file copy -force $rm_sv $cva6_fpga/src/accel_wrap.sv
    puts "  -> RM copié : [file tail $rm_sv] -> accel_wrap.sv"

    open_project $cva6_fpga/ariane.xpr

    set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} \
        -value {none} -objects [get_runs synth_1]

    puts "==> Lancement synthèse..."
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
        puts "ERROR: Synthèse échouée."
        exit 1
    }

    open_run synth_1 -name synth_1

    puts "==> Extraction du checkpoint RM..."
    set cell [get_cells -quiet i_ariane_peripherals/gen_dma.i_accel1]
    if {[llength $cell] == 0} {
        puts "ERROR: cellule i_accel1 non trouvée dans le netlist"
        exit 1
    }
    write_checkpoint -force -cell $cell $rm_synth
    puts "  -> checkpoint RM : $rm_synth"

    close_project
} else {
    puts "==> RM en cache : $rm_synth"
}

# =============================================================
# 2. CHARGEMENT DU CHECKPOINT STATIQUE
# =============================================================
puts "==> Ouverture du checkpoint statique..."
open_checkpoint $work_dpr/static_routed.dcp

# Suppression des pblocks automatiques créés par Vivado
puts "==> Nettoyage des pblocks automatiques..."
foreach pb [get_pblocks -quiet] {
    puts "  -> suppression pblock : $pb"
    delete_pblocks $pb
}

# Rechargement propre du XDC des pblocks DFX
puts "==> Rechargement du XDC des pblocks DFX..."
set pblock_xdc $dpr_dir/constraints/pblock_accels_impl.xdc
if {![file exists $pblock_xdc]} {
    puts "ERROR: XDC pblock introuvable : $pblock_xdc"
    exit 1
}
read_xdc $pblock_xdc
set_property used_in_synthesis false [get_files $pblock_xdc]

# Vérification
foreach pb [get_pblocks] {
    puts "  PBLOCK: $pb -> [get_property GRID_RANGES $pb]"
}

# =============================================================
# 3. CHARGEMENT DU RM DANS LES CELLULES RECONFIGURABLES
# =============================================================
set cell1 [get_cells -quiet i_ariane_peripherals/gen_dma.i_accel1]
set cell2 [get_cells -quiet i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]

if {[llength $cell1] == 0} { puts "ERROR: i_accel1 non trouvé"; exit 1 }
if {[llength $cell2] == 0} { puts "ERROR: i_accel2 non trouvé"; exit 1 }

read_checkpoint -cell $cell1 $rm_synth
puts "  -> RM chargé dans i_accel1"

# Re-capturer cell2 après modification du design
set cell2 [get_cells -quiet i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]
if {[llength $cell2] == 0} { puts "ERROR: i_accel2 non trouvé après chargement accel1"; exit 1 }

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

# Re-capturer les cellules après implémentation
set cell1 [get_cells -quiet i_ariane_peripherals/gen_dma.i_accel1]
set cell2 [get_cells -quiet i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]

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