# run_static.tcl - Implémentation DPR
set cva6_fpga [lindex $argv 0]
set dpr_dir   [lindex $argv 1]
set work_dpr  [lindex $argv 2]

open_project $cva6_fpga/ariane.xpr

# 1. SOURCES DPR (ajout si absent)
# Enregistrement des IPs dm_master et dm_slave dans le projet
foreach ip_xci [list \
    $cva6_fpga/xilinx/xlnx_axi_dwidth_converter_dm_master/xlnx_axi_dwidth_converter_dm_master.srcs/sources_1/ip/xlnx_axi_dwidth_converter_dm_master/xlnx_axi_dwidth_converter_dm_master.xci \
    $cva6_fpga/xilinx/xlnx_axi_dwidth_converter_dm_slave/xlnx_axi_dwidth_converter_dm_slave.srcs/sources_1/ip/xlnx_axi_dwidth_converter_dm_slave/xlnx_axi_dwidth_converter_dm_slave.xci \
] {
    if {[llength [get_files -quiet $ip_xci]] == 0} {
        read_ip $ip_xci
        puts "  -> IP ajoutée : [file tail $ip_xci]"
    } else {
        puts "  -> IP déjà présente : [file tail $ip_xci]"
    }
}

puts "==> Vérification des sources DPR..."
foreach f [list \
    $dpr_dir/src/rp_boundary_regs.sv \
    $dpr_dir/src/rp_boundary_regs_mmu.sv \
    $cva6_fpga/src/accel_wrap.sv \
] {
    if {[llength [get_files -quiet $f]] == 0} {
        add_files -fileset sources_1 -norecurse $f
        puts "  -> ajouté : [file tail $f]"
    } else {
        puts "  -> déjà présent : [file tail $f]"
    }
}
update_compile_order -fileset sources_1

# 2. RETRAIT DE TOUT ANCIEN XDC PBLOCK
puts "==> Nettoyage des anciens XDC pblock..."
foreach f [get_files -quiet -filter {NAME =~ *pblock_accels*}] {
    remove_files -fileset constrs_1 $f
    puts "  -> retiré : [file tail $f]"
}

# 3. FORÇAGE DU TOP ET OPTIONS SYNTHÈSE
set_property top ariane_xilinx [get_filesets sources_1]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} \
    -value {none} -objects [get_runs synth_1]

# 4. SYNTHÈSE
puts "==> Lancement de la synthèse synth_1..."
# Synthèse OOC des IPs dm si pas encore faite
puts "==> Synthèse OOC des IPs dm_master et dm_slave..."
foreach ip {xlnx_axi_dwidth_converter_dm_master xlnx_axi_dwidth_converter_dm_slave} {
    set ip_obj [get_ips -quiet $ip]
    if {[llength $ip_obj] > 0} {
        synth_ip $ip_obj
        puts "  -> synthétisée : $ip"
    } else {
        puts "  WARNING: IP non trouvée : $ip"
    }
}
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthèse échouée."
    exit 1
}

# 5. VÉRIFICATION DES CELLULES ET GÉNÉRATION DU XDC DPR
open_run synth_1 -name synth_1

puts "==> Cellules accel trouvées :"
foreach cell [get_cells -hierarchical -filter {NAME =~ *accel*}] {
    puts "  $cell"
}

puts "==> Vérification des cellules reconfigurables..."
set cell_accel1 [get_cells i_ariane_peripherals/gen_dma.i_accel1]
set cell_accel2 [get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]

if {[llength $cell_accel1] == 0} { puts "ERROR: i_accel1 non trouvé"; exit 1 }
if {[llength $cell_accel2] == 0} { puts "ERROR: i_accel2 non trouvé"; exit 1 }

puts "==> Génération du XDC DPR complet..."
set xdc_out [open $dpr_dir/constraints/pblock_accels_impl.xdc w]
puts $xdc_out "# Pblocks DPR generes par run_static.tcl"
puts $xdc_out "create_pblock pblock_rp_accels"
puts $xdc_out "resize_pblock \[get_pblocks pblock_rp_accels\] -add {SLICE_X0Y150:SLICE_X111Y224 DSP48_X0Y60:DSP48_X4Y89 RAMB18_X0Y60:RAMB18_X4Y89 RAMB36_X0Y30:RAMB36_X4Y44}"
puts $xdc_out "set_property CONTAIN_ROUTING  true  \[get_pblocks pblock_rp_accels\]"
puts $xdc_out "set_property EXCLUDE_PLACEMENT true \[get_pblocks pblock_rp_accels\]"
puts $xdc_out "set_property IS_SOFT          false \[get_pblocks pblock_rp_accels\]"
puts $xdc_out "create_pblock pblock_accel1"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel1\] -add {SLICE_X0Y150:SLICE_X55Y224 DSP48_X0Y60:DSP48_X2Y89 RAMB18_X0Y60:RAMB18_X2Y89 RAMB36_X0Y30:RAMB36_X2Y44}"
puts $xdc_out "set_property PARENT           pblock_rp_accels \[get_pblocks pblock_accel1\]"
puts $xdc_out "set_property CONTAIN_ROUTING  true  \[get_pblocks pblock_accel1\]"
puts $xdc_out "set_property EXCLUDE_PLACEMENT true \[get_pblocks pblock_accel1\]"
puts $xdc_out "set_property IS_SOFT          false \[get_pblocks pblock_accel1\]"
puts $xdc_out "create_pblock pblock_accel2"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel2\] -add {SLICE_X56Y150:SLICE_X111Y224 DSP48_X3Y60:DSP48_X4Y89 RAMB18_X3Y60:RAMB18_X4Y89 RAMB36_X3Y30:RAMB36_X4Y44}"
puts $xdc_out "set_property PARENT           pblock_rp_accels \[get_pblocks pblock_accel2\]"
puts $xdc_out "set_property CONTAIN_ROUTING  true  \[get_pblocks pblock_accel2\]"
puts $xdc_out "set_property EXCLUDE_PLACEMENT true \[get_pblocks pblock_accel2\]"
puts $xdc_out "set_property IS_SOFT          false \[get_pblocks pblock_accel2\]"
puts $xdc_out "set_property HD.RECONFIGURABLE true \[get_cells i_ariane_peripherals/gen_dma.i_accel1\]"
puts $xdc_out "set_property HD.RECONFIGURABLE true \[get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2\]"
puts $xdc_out "add_cells_to_pblock \[get_pblocks pblock_accel1\] \[get_cells i_ariane_peripherals/gen_dma.i_accel1\]"
puts $xdc_out "add_cells_to_pblock \[get_pblocks pblock_accel2\] \[get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2\]"
close $xdc_out
puts "  -> pblock_accels_impl.xdc généré"

add_files -fileset constrs_1 -norecurse \
    $dpr_dir/constraints/pblock_accels_impl.xdc
set_property used_in_synthesis    false \
    [get_files $dpr_dir/constraints/pblock_accels_impl.xdc]
set_property used_in_implementation true \
    [get_files $dpr_dir/constraints/pblock_accels_impl.xdc]
puts "==> XDC DPR injecté dans constrs_1"

# Après add_files et set_property used_in_implementation...
puts "==> Sauvegarde du projet..."
save_project_as -force $cva6_fpga/ariane.xp



# 6. IMPLÉMENTATION MANUELLE
puts "==> Ouverture du netlist post-synthèse..."
# Le design synth_1 est déjà ouvert depuis l'étape 5, on continue directement
puts "==> opt_design..."
opt_design
puts "==> place_design..."
place_design
puts "==> route_design..."
route_design

# 7. EXPORTATION DU CHECKPOINT
file mkdir $work_dpr
write_checkpoint -force $work_dpr/static_routed.dcp
write_bitstream  -force $work_dpr/static_full.bit
puts "OK: static checkpoint -> $work_dpr/static_routed.dcp"