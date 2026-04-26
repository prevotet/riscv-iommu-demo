# run_static.tcl - Implémentation DPR
set cva6_fpga [lindex $argv 0]
set dpr_dir   [lindex $argv 1]
set work_dpr  [lindex $argv 2]

open_project $cva6_fpga/ariane.xpr

# Désactiver la synthèse incrémentale (évite segfault dans run_partial)
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]
file delete -force [file join $cva6_fpga ariane.srcs utils_1 imports synth_1 ariane_xilinx.dcp]

# 0. NETTOYAGE COMPLET DE TOUS LES ANCIENS XDC PBLOCK
puts "==> Nettoyage des anciens XDC pblock..."
foreach f [get_files -quiet -filter {NAME =~ *pblock*}] {
    remove_files -fileset constrs_1 $f
    puts "  -> retiré : [file tail $f]"
}

# 1. SOURCES DPR (ajout si absent)
puts "==> Vérification des sources DPR..."
foreach f [list \
    $dpr_dir/src/rp_boundary_regs.sv \
    $dpr_dir/src/rp_boundary_regs_mmu.sv \
    $cva6_fpga/src/accel_wrap.sv \
    $cva6_fpga/src/apb_to_axilite.sv \
] {
    if {[llength [get_files -quiet $f]] == 0} {
        add_files -fileset sources_1 -norecurse $f
        puts "  -> ajouté : [file tail $f]"
    } else {
        puts "  -> déjà présent : [file tail $f]"
    }
}
update_compile_order -fileset sources_1

# 1b. AJOUT DE L'IP HWICAP AU PROJET
puts "==> Vérification de l'IP HWICAP..."
set hwicap_xci $cva6_fpga/xilinx/xlnx_axi_hwicap/xlnx_axi_hwicap.srcs/sources_1/ip/xlnx_axi_hwicap/xlnx_axi_hwicap.xci
if {[llength [get_files -quiet $hwicap_xci]] == 0} {
    add_files -norecurse $hwicap_xci
    puts "  -> ajoutée : xlnx_axi_hwicap.xci"
} else {
    puts "  -> déjà présente : xlnx_axi_hwicap.xci"
}

# 2. FORÇAGE DU TOP ET OPTIONS SYNTHÈSE
set_property top ariane_xilinx [get_filesets sources_1]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY} \
    -value {none} -objects [get_runs synth_1]

# 3. SYNTHÈSE OOC DES IPs dm_master et dm_slave
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

# 3b. RÉGÉNÉRATION GPIO IP (C_GPIO_WIDTH peut avoir changé)
puts "==> Régénération GPIO IP..."
set gpio_ip [get_ips -quiet xlnx_axi_gpio]
if {[llength $gpio_ip] > 0} {
    generate_target all [get_ips xlnx_axi_gpio]
    set gpio_run [get_runs -quiet xlnx_axi_gpio_synth_1]
    if {[llength $gpio_run] > 0} {
        reset_run xlnx_axi_gpio_synth_1
    }
    synth_ip [get_ips xlnx_axi_gpio]
    puts "  -> regenere : xlnx_axi_gpio"
} else {
    puts "  WARNING: xlnx_axi_gpio non trouvee dans le projet"
}

# 3c. GÉNÉRATION DES CIBLES HWICAP (generate_target au lieu de synth_ip)
puts "==> Génération des cibles HWICAP..."
set hwicap_ip [get_ips -quiet xlnx_axi_hwicap]
if {[llength $hwicap_ip] > 0} {
    generate_target all [get_ips xlnx_axi_hwicap]
    set hwicap_run [get_runs -quiet xlnx_axi_hwicap_synth_1]
    if {[llength $hwicap_run] > 0} {
        reset_run xlnx_axi_hwicap_synth_1
    }
    synth_ip [get_ips xlnx_axi_hwicap]
    puts "  -> generate_target OK : xlnx_axi_hwicap"
} else {
    puts "  WARNING: xlnx_axi_hwicap non trouvée dans le projet"
}

# 4. SYNTHÈSE
puts "==> Lancement de la synthèse synth_1..."
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: Synthèse échouée."
    exit 1
}

# 5. OUVERTURE DU NETLIST POST-SYNTHÈSE
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

# 6. APPLICATION DES PBLOCKS DIRECTEMENT EN MÉMOIRE
# Règle HDPR-25 : colonnes RAMB/DSP strictement séparées entre les deux RPs.
# SNAPPING_MODE ON : Vivado ajuste les bords aux limites d'interconnexion.
#
#   pblock_accel1 : SLICEs X30-X45,  RAMB X1, DSP X1  (zone restreinte gauche)
#   pblock_accel2 : SLICEs X100-X115, RAMB X4, DSP X4  (zone restreinte droite)
#
puts "==> Création des pblocks DFX en mémoire (tailles réduites)..."

# pblock_accel1 — zone réduite clock region Y5
create_pblock pblock_accel1
resize_pblock [get_pblocks pblock_accel1] -add {SLICE_X32Y250:SLICE_X47Y299}
resize_pblock [get_pblocks pblock_accel1] -add {DSP48_X1Y60:DSP48_X1Y64}
resize_pblock [get_pblocks pblock_accel1] -add {RAMB36_X1Y25:RAMB36_X1Y29}
resize_pblock [get_pblocks pblock_accel1] -add {RAMB18_X1Y50:RAMB18_X1Y59}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel1]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel1]
set_property IS_SOFT          false [get_pblocks pblock_accel1]
set_property SNAPPING_MODE    ON    [get_pblocks pblock_accel1]

# pblock_accel2 — zone réduite clock region Y5
create_pblock pblock_accel2
resize_pblock [get_pblocks pblock_accel2] -add {SLICE_X100Y250:SLICE_X115Y299}
resize_pblock [get_pblocks pblock_accel2] -add {DSP48_X4Y60:DSP48_X4Y64}
resize_pblock [get_pblocks pblock_accel2] -add {RAMB36_X4Y25:RAMB36_X4Y29}
resize_pblock [get_pblocks pblock_accel2] -add {RAMB18_X4Y50:RAMB18_X4Y59}
set_property CONTAIN_ROUTING  true  [get_pblocks pblock_accel2]
set_property EXCLUDE_PLACEMENT true [get_pblocks pblock_accel2]
set_property IS_SOFT          false [get_pblocks pblock_accel2]
set_property SNAPPING_MODE    ON    [get_pblocks pblock_accel2]

# Assignation des cellules reconfigurables
set_property HD.RECONFIGURABLE true [get_cells i_ariane_peripherals/gen_dma.i_accel1]
set_property HD.RECONFIGURABLE true [get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]
add_cells_to_pblock [get_pblocks pblock_accel1] \
    [get_cells i_ariane_peripherals/gen_dma.i_accel1]
add_cells_to_pblock [get_pblocks pblock_accel2] \
    [get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2]

# Forcer ICAP en CR Y0 (ICAP_X0Y0) pour eviter la disruption horloge CR Y5.
# Sans cette contrainte Vivado place ICAP_X0Y1 en CR Y5, meme clock region
# que les pblocks : pendant la reconfig le HCLK de CR Y5 est reinitialise,
# ce qui fige le FSM AXI du HWICAP IP (RVALID=0 jamais reasserte).
puts "==> Contrainte ICAP : forçage sur ICAP_X0Y0..."
set_property LOC ICAP_X0Y0 [get_cells -hierarchical -filter {REF_NAME == ICAPE2}]
puts "  -> LOC ICAP_X0Y0 applique"

puts "  -> pblocks actifs en mémoire :"
foreach pb [get_pblocks] {
    puts "     $pb -> [get_property GRID_RANGES $pb]"
}

# 7. EXPORT DU XDC POUR run_partial.tcl
# Ce fichier est utilisé par run_partial.tcl pour recharger les pblocks
# après open_checkpoint. Il n'est PAS injecté dans le projet ici.
puts "==> Export du XDC DFX pour run_partial..."
file mkdir $dpr_dir/constraints
set xdc_out [open $dpr_dir/constraints/pblock_accels_impl.xdc w]
puts $xdc_out "# Pblocks DPR generes par run_static.tcl"
puts $xdc_out "# pblock_accel1 : zone restreinte clock region Y5"
puts $xdc_out "create_pblock pblock_accel1"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel1\] -add {SLICE_X30Y250:SLICE_X45Y299}"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel1\] -add {DSP48_X1Y60:DSP48_X1Y64}"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel1\] -add {RAMB36_X1Y25:RAMB36_X1Y29}"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel1\] -add {RAMB18_X1Y50:RAMB18_X1Y59}"
puts $xdc_out "set_property CONTAIN_ROUTING  true  \[get_pblocks pblock_accel1\]"
puts $xdc_out "set_property EXCLUDE_PLACEMENT true \[get_pblocks pblock_accel1\]"
puts $xdc_out "set_property IS_SOFT          false \[get_pblocks pblock_accel1\]"
puts $xdc_out "set_property SNAPPING_MODE    ON    \[get_pblocks pblock_accel1\]"
puts $xdc_out "# pblock_accel2 : zone restreinte clock region Y5"
puts $xdc_out "create_pblock pblock_accel2"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel2\] -add {SLICE_X100Y250:SLICE_X115Y299}"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel2\] -add {DSP48_X4Y60:DSP48_X4Y64}"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel2\] -add {RAMB36_X4Y25:RAMB36_X4Y29}"
puts $xdc_out "resize_pblock \[get_pblocks pblock_accel2\] -add {RAMB18_X4Y50:RAMB18_X4Y59}"
puts $xdc_out "set_property CONTAIN_ROUTING  true  \[get_pblocks pblock_accel2\]"
puts $xdc_out "set_property EXCLUDE_PLACEMENT true \[get_pblocks pblock_accel2\]"
puts $xdc_out "set_property IS_SOFT          false \[get_pblocks pblock_accel2\]"
puts $xdc_out "set_property SNAPPING_MODE    ON    \[get_pblocks pblock_accel2\]"
puts $xdc_out "set_property HD.RECONFIGURABLE true \[get_cells i_ariane_peripherals/gen_dma.i_accel1\]"
puts $xdc_out "set_property HD.RECONFIGURABLE true \[get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2\]"
puts $xdc_out "add_cells_to_pblock \[get_pblocks pblock_accel1\] \[get_cells i_ariane_peripherals/gen_dma.i_accel1\]"
puts $xdc_out "add_cells_to_pblock \[get_pblocks pblock_accel2\] \[get_cells i_ariane_peripherals/gen_dma.gen_accel2.i_accel2\]"
puts $xdc_out "# Forcer ICAP en CR Y0 — evite disruption horloge CR Y5 pendant reconfig"
puts $xdc_out "set_property LOC ICAP_X0Y0 \[get_cells -hierarchical -filter {REF_NAME == ICAPE2}\]"
close $xdc_out
puts "  -> $dpr_dir/constraints/pblock_accels_impl.xdc"

# 8. IMPLÉMENTATION
puts "==> opt_design..."
opt_design

# Workaround HDPostRouteDRC-02: b_id_ff_reg/r_id_ff_reg placés en Y250
# (bord inférieur pblock) génèrent un net frontière SLICEL.AQ→SLICEM.BX
# non-routable dans la fabric 7-series. Un sous-pblock overlay viole HDPR-66.
# Solution : LOC sur ces FFs à l'intérieur du pblock (Y280), 30 rangées
# au-dessus du bord. Le routage intra-RP de Y280→Y250 (pin partition)
# utilise les ressources standard et évite la contrainte AQ→BX.
# 6 b_id + 6 r_id = 12 FFs par RP → 3 slices de 4 FFs (LOC sans BEL).
puts "==> LOC boundary FFs — workaround AQ→BX..."
# Ancrages pour accel1 (pblock X32-X47Y250-Y299)
#   b_id/r_id (12 FFs)  → X36/37/38 Y280
#   r_data_ff (64 FFs)  → X32..X47  Y270  (16 SLICEs × 4 FFs = 64)
#   r_last/r_resp/b_resp (5 FFs) → X39/40 Y280
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
puts "==> route_design..."
route_design

# 9. CONVERSION EN BLACK-BOX (avant lock_design !)
# lock_design verrouille les nœuds de routage GND/VCC/clock —
# update_design -black_box doit être fait avant pour pouvoir les dé-router.
puts "==> Conversion des cellules reconfigurables en black-box..."
update_design -cell i_ariane_peripherals/gen_dma.i_accel1 -black_box
update_design -cell i_ariane_peripherals/gen_dma.gen_accel2.i_accel2 -black_box
puts "  -> black-box appliqué"

# 10. VERROUILLAGE DU ROUTAGE STATIQUE (après black-box)
puts "==> Verrouillage du routage statique..."
lock_design -level routing

# 11. EXPORTATION DU CHECKPOINT
file mkdir $work_dpr
write_checkpoint -force $work_dpr/static_routed.dcp
puts "OK: static checkpoint -> $work_dpr/static_routed.dcp"

# 12. WAIVERS DFX ET BITSTREAM
create_waiver -quiet -type DRC -id {INBB-1} \
    -description "Black-boxes intentionnelles DFX"
create_waiver -quiet -type DRC -id {RTSTAT-5} \
    -description "Antennes partielles normales aux frontieres RP"
create_waiver -quiet -type DRC -id {RTSTAT-6} \
    -description "Conflits partiels normaux aux frontieres RP"
create_waiver -quiet -type DRC -id {CFGBVS-1} \
    -description "Tension config non critique"
puts "==> Waivers DFX créés"

if {[catch {write_bitstream -force $work_dpr/static_full.bit} err]} {
    puts "WARNING: write_bitstream échoué (normal en DFX) : $err"
    puts "  -> Le bitstream complet sera généré lors du dpr-partial"
} else {
    puts "OK: bitstream statique -> $work_dpr/static_full.bit"
}