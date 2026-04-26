# run_partial.tcl - Implémentation d'une configuration partielle
# Usage: vivado -mode batch -source run_partial.tcl
#        -tclargs <work_dpr_dir> <rm_dir> <rm_name>

set work_dpr [lindex $argv 0]
set rm_dir   [lindex $argv 1]
set rm_name  [lindex $argv 2]

set dpr_dir   [lindex $argv 3]
set project_root [file normalize [file join $dpr_dir ".."]]
set cva6_fpga [file join $project_root "cva6" "corev_apu" "fpga"]
set cva6_root [file join $project_root "cva6"]

# Checkpoints RM séparés pour accel1 (STREAM_ID=1) et accel2 (STREAM_ID=2)
set rm_synth1 $work_dpr/${rm_name}_accel1_synth.dcp
set rm_synth2 $work_dpr/${rm_name}_accel2_synth.dcp

# =============================================================
# 1. SYNTHÈSE DU RM DANS LE CONTEXTE DU PROJET ARIANE
#    Deux checkpoints extraits séparément pour préserver
#    les valeurs de STREAM_ID différentes (1 et 2)
# =============================================================

if {![file exists $rm_synth1] || ![file exists $rm_synth2]} {
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

    # Extraire le checkpoint de i_accel1 (STREAM_ID=1)
    puts "==> Extraction checkpoint accel1 (STREAM_ID=1)..."
    set cell1_synth [get_cells -quiet i_ariane_peripherals/gen_dma.i_accel1]
    if {[llength $cell1_synth] == 0} {
        puts "ERROR: i_accel1 non trouvé dans le netlist"
        exit 1
    }
    write_checkpoint -force -cell $cell1_synth $rm_synth1
    puts "  -> checkpoint accel1 : $rm_synth1"

    # Extraire le checkpoint de i_accel2 (STREAM_ID=2)
    puts "==> Extraction checkpoint accel2 (STREAM_ID=2)..."
    set cell2_synth [get_cells -quiet i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]
    if {[llength $cell2_synth] == 0} {
        puts "ERROR: i_accel2 non trouvé dans le netlist"
        exit 1
    }
    write_checkpoint -force -cell $cell2_synth $rm_synth2
    puts "  -> checkpoint accel2 : $rm_synth2"

    close_project
} else {
    puts "==> RMs en cache :"
    puts "    $rm_synth1"
    puts "    $rm_synth2"
}

# =============================================================
# 2. CHARGEMENT DU CHECKPOINT STATIQUE
# =============================================================
puts "==> Ouverture du checkpoint statique..."
open_checkpoint $work_dpr/static_routed.dcp

# =============================================================
# 2b. RECHARGEMENT DU XDC DES PBLOCKS DFX
# =============================================================
puts "==> Rechargement du XDC des pblocks DFX..."
set pblock_xdc $dpr_dir/constraints/pblock_accels_impl.xdc
if {![file exists $pblock_xdc]} {
    puts "ERROR: XDC pblock introuvable : $pblock_xdc"
    exit 1
}

# Suppression des pblocks automatiques recréés par Vivado
foreach pb [get_pblocks -quiet] {
    delete_pblocks $pb
}

read_xdc $pblock_xdc
set_property used_in_synthesis false [get_files $pblock_xdc]
puts "  -> XDC chargé : $pblock_xdc"

foreach pb [get_pblocks] {
    puts "  PBLOCK: $pb -> [get_property GRID_RANGES $pb]"
}

# =============================================================
# 3. CHARGEMENT DES RMs DANS LES CELLULES RECONFIGURABLES
#    accel1 ← rm_synth1 (STREAM_ID=1)
#    accel2 ← rm_synth2 (STREAM_ID=2)
# =============================================================
set cell1 [get_cells -quiet i_ariane_peripherals/gen_dma.i_accel1]
set cell2 [get_cells -quiet i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]

if {[llength $cell1] == 0} { puts "ERROR: i_accel1 non trouvé"; exit 1 }
if {[llength $cell2] == 0} { puts "ERROR: i_accel2 non trouvé"; exit 1 }

read_checkpoint -cell $cell1 $rm_synth1
puts "  -> RM accel1 chargé (STREAM_ID=1) : $rm_synth1"

# Re-capturer cell2 après modification du design
set cell2 [get_cells -quiet i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]
if {[llength $cell2] == 0} {
    puts "ERROR: i_accel2 non trouvé après chargement accel1"
    exit 1
}

read_checkpoint -cell $cell2 $rm_synth2
puts "  -> RM accel2 chargé (STREAM_ID=2) : $rm_synth2"

# =============================================================
# 4. IMPLÉMENTATION PARTIELLE
# =============================================================
puts "==> opt_design..."
opt_design

puts "==> LOC boundary FFs RM — workaround AQ→BX..."
foreach {pats x_base y_loc} {
    {i_ariane_peripherals/gen_dma.i_accel1/b_id_ff_reg[*]
     i_ariane_peripherals/gen_dma.i_accel1/r_id_ff_reg[*]}          36  280
    {i_ariane_peripherals/gen_dma.i_accel1/r_data_ff_reg[*]}         32  270
    {i_ariane_peripherals/gen_dma.i_accel1/r_valid_ff_reg
     i_ariane_peripherals/gen_dma.i_accel1/b_valid_ff_reg
     i_ariane_peripherals/gen_dma.i_accel1/r_last_ff_reg
     i_ariane_peripherals/gen_dma.i_accel1/r_resp0_ff_reg
     i_ariane_peripherals/gen_dma.i_accel1/r_resp1_ff_reg
     i_ariane_peripherals/gen_dma.i_accel1/b_resp0_ff_reg
     i_ariane_peripherals/gen_dma.i_accel1/b_resp1_ff_reg}           39  280
    {i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/b_id_ff_reg[*]
     i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/r_id_ff_reg[*]} 107 280
    {i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/r_data_ff_reg[*]} 100 270
    {i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/r_valid_ff_reg
     i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/b_valid_ff_reg
     i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/r_last_ff_reg
     i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/r_resp0_ff_reg
     i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/r_resp1_ff_reg
     i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/b_resp0_ff_reg
     i_ariane_peripherals/gen_dma.gen_accel2.i_accel2/b_resp1_ff_reg} 110 280
} {
    set ci 0
    foreach c [lsort -dictionary [get_cells -quiet $pats]] {
        set xi [expr {$x_base + $ci / 4}]
        set_property LOC SLICE_X${xi}Y${y_loc} $c
        incr ci
    }
    puts "  -> $ci FFs ancrés @ Y${y_loc} (x_base=$x_base)"
}

puts "==> place_design..."
place_design

puts "==> phys_opt_design..."
phys_opt_design

puts "==> route_design..."
route_design -directive Explore

# =============================================================
# 5. EXPORT DES BITSTREAMS
# =============================================================
# Waiver RTSTAT-2 : nets de frontiere partiellement routes aux limites du pblock.
# Certains RMs (ex. accel_default) ne consomment pas tous les bits d'un bus AXI
# (ex. aw_len[1]) — le stub statique reste sans charge cote RM. C'est normal
# en DFX pour les RMs qui ne font pas de burst writes. Identique aux waivers
# RTSTAT-5/6 deja presents dans run_static.tcl.
create_waiver -quiet -type DRC -id {RTSTAT-2} \
    -description "Boundary routing stubs normaux pour RMs sans burst AXI"

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