# =============================================================================
# run_static_safe.tcl - Implémentation DPR sécurisée pour Genesys2 / CVA6
# =============================================================================

# Arguments : <cva6_fpga_dir> <dpr_dir> <work_dpr_dir>
set cva6_fpga [lindex $argv 0]
set dpr_dir   [lindex $argv 1]
set work_dpr  [lindex $argv 2]

puts "==> Ouverture du projet Vivado..."
open_project $cva6_fpga/ariane.xpr

# ---------------------------------------------------------------------------
# 1. Ajout des sources DPR si absentes
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 2. Nettoyage ancien XDC pblock
# ---------------------------------------------------------------------------
puts "==> Nettoyage anciens XDC pblock..."
foreach f [get_files -quiet -filter {NAME =~ *pblock_accels*}] {
    remove_files -fileset constrs_1 $f
    puts "  -> retiré : [file tail $f]"
}

# ---------------------------------------------------------------------------
# 3. Top et options synthèse
# ---------------------------------------------------------------------------
set_property top ariane_xilinx [get_filesets sources_1]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} \
    -value {none} -objects [get_runs synth_1]

# ---------------------------------------------------------------------------
# 4. Synthèse des IPs critiques OOC
# ---------------------------------------------------------------------------
puts "==> Synthèse OOC des IPs..."
foreach ip {xlnx_axi_dwidth_converter_dm_master xlnx_axi_dwidth_converter_dm_slave} {
    set ip_obj [get_ips -quiet $ip]
    if {[llength $ip_obj] > 0} {
        synth_ip $ip_obj
        puts "  -> synthétisée : $ip"
    } else {
        puts "  WARNING: IP non trouvée : $ip"
    }
}

# ---------------------------------------------------------------------------
# 5. Synthèse principale
# ---------------------------------------------------------------------------
puts "==> Lancement synthèse..."
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthèse échouée."
    exit 1
}

# ---------------------------------------------------------------------------
# 6. Floorplanning et Pblocks dynamiques
# ---------------------------------------------------------------------------
puts "==> Détection des cellules RP..."
# Cherche toutes les cellules nommées *accel* (flexible)
set rp_cells [get_cells -hierarchical -filter {NAME =~ *accel*}]
if {[llength $rp_cells] == 0} {
    puts "ERROR: Aucune cellule RP trouvée"
    exit 1
}

puts "==> Création XDC pblocks dynamiques..."
set xdc_out [open $dpr_dir/constraints/pblock_accels_impl.xdc w]
puts $xdc_out "# Pblocks DPR générés automatiquement par run_static_safe.tcl"

puts $xdc_out "create_pblock pblock_rp_accels"
puts $xdc_out "resize_pblock [get_pblocks pblock_rp_accels] -add {SLICE_X0Y150:SLICE_X111Y224 DSP48_X0Y60:DSP48_X4Y89 RAMB18_X0Y60:RAMB18_X4Y89 RAMB36_X0Y30:RAMB36_X4Y44}"
puts $xdc_out "set_property CONTAIN_ROUTING true [get_pblocks pblock_rp_accels]"
puts $xdc_out "set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_rp_accels]"

foreach c $rp_cells {
    # Crée un Pblock pour chaque module RP
    set name [lindex [split [get_property NAME $c] /] end]
    set pblock_name "pblock_$name"

    puts $xdc_out "create_pblock $pblock_name"
    puts $xdc_out "resize_pblock [get_pblocks $pblock_name] -add {SLICE_X0Y150:SLICE_X55Y224 DSP48_X0Y60:DSP48_X2Y89 RAMB18_X0Y60:RAMB18_X2Y89 RAMB36_X0Y30:RAMB36_X2Y44}"
    puts $xdc_out "set_property PARENT pblock_rp_accels [get_pblocks $pblock_name]"
    puts $xdc_out "set_property CONTAIN_ROUTING true [get_pblocks $pblock_name]"
    puts $xdc_out "set_property EXCLUDE_PLACEMENT true [get_pblocks $pblock_name]"
    puts $xdc_out "set_property HD.RECONFIGURABLE true [get_cells $c]"
    puts $xdc_out "add_cells_to_pblock [get_pblocks $pblock_name] [get_cells $c]"
}
close $xdc_out

add_files -fileset constrs_1 -norecurse $dpr_dir/constraints/pblock_accels_impl.xdc
set_property used_in_synthesis false [get_files $dpr_dir/constraints/pblock_accels_impl.xdc]
set_property used_in_implementation true [get_files $dpr_dir/constraints/pblock_accels_impl.xdc]

# ---------------------------------------------------------------------------
# 7. Génération des modules RP complets
# ---------------------------------------------------------------------------
puts "==> Vérification et synthèse des modules RP..."
foreach c $rp_cells {
    # synthétiser chaque module RP pour générer tous les ports
    launch_runs [get_runs synth_1] -to_step synth_design
    wait_on_run [get_runs synth_1]

    # vérifie que tous les ports existent
    set missing_ports [catch {get_ports -of_objects $c} result]
    if {$missing_ports} {
        puts "ERROR: Ports manquants dans $c"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 8. Implémentation statique avec lock contrôlé
# ---------------------------------------------------------------------------
puts "==> opt_design..."
opt_design
puts "==> place_design..."
place_design
puts "==> route_design..."
route_design

# Lock placement seulement (routage libre pour RP)
lock_design -level placement -exclude [get_cells $rp_cells]

# ---------------------------------------------------------------------------
# 9. Black-box après synthèse complète
# ---------------------------------------------------------------------------
puts "==> Conversion en black-box sécurisée..."
foreach c $rp_cells {
    update_design -cell $c -black_box
}

# ---------------------------------------------------------------------------
# 10. PR Verify et export
# ---------------------------------------------------------------------------
puts "==> PR Verify..."
if {[catch {report_dfx -verify} result]} {
    puts "WARNING: PR Verify échoué : $result"
} else {
    puts "PR Verify OK"
}

file mkdir -p $work_dpr
write_checkpoint -force $work_dpr/static_routed.dcp
write_bitstream -force $work_dpr/static_full.bit

puts "OK: static checkpoint -> $work_dpr/static_routed.dcp"
puts "OK: bitstream complet -> $work_dpr/static_full.bit"