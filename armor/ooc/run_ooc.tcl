#  Synthese hors contexte du wrapper ARMOR seul. Voir ooc_wrapper.sv.
set root [lindex $argv 0]
#  Deuxieme argument, optionnel : une etiquette qui suffixe les rapports ET,
#  si elle vaut « noobs », ajoute ARMOR_NO_OBSERVE aux defines. Sert a chiffrer
#  ce que l'instrumentation d'evaluation coute, en comparant deux synthetiques
#  du MEME RTL. Sans argument, comportement d'avant : wrapper complet.
set tag  [expr {$argc > 1 ? [lindex $argv 1] : ""}]
set defs BENCH_PROFILE
if {$tag eq "noobs"} { lappend defs ARMOR_NO_OBSERVE }
set sfx  [expr {$tag eq "" ? "" : "_$tag"}]
set part xc7k325tffg900-2
set cva6 $root/cva6

#  UN SEUL read_verilog, dans l'ordre des dependances : Vivado traite chaque
#  appel comme une unite de compilation separee, et un package declare dans
#  l'une n'est pas visible depuis l'autre -- d'ou « 'ariane_axi_soc' is not
#  declared » si on les lit un par un. L'ordre reprend celui de armor/tb/run_sim.sh,
#  qui est valide.
read_verilog -sv [list \
    $cva6/core/include/cv64a6_imafdc_sv39_config_pkg.sv \
    $cva6/core/include/riscv_pkg.sv \
    $cva6/core/include/ariane_dm_pkg.sv \
    $cva6/core/include/ariane_pkg.sv \
    $cva6/vendor/pulp-platform/axi/src/axi_pkg.sv \
    $cva6/corev_apu/riscv-dbg/src/dm_pkg.sv \
    $cva6/corev_apu/tb/ariane_soc_pkg.sv \
    $cva6/corev_apu/tb/ariane_axi_soc_pkg.sv \
    $root/armor/SRC/ADDR_extractor.sv \
    $root/armor/SRC/ID_extractor.sv \
    $root/armor/SRC/Interrupt_detector.sv \
    $root/armor/SRC/Delay_inserter.sv \
    $root/armor/SRC/id_comparator.sv \
    $root/armor/SRC/interrupt_monitor.sv \
    $root/armor/SRC/outs_req_flow_monitor.sv \
    $root/armor/SRC/request_flow_monitor.sv \
    $root/armor/SRC/w_skid_buffer.sv \
    $root/armor/SRC/request_manager.sv \
    $root/armor/SRC/response_manager.sv \
    $root/armor/SRC/security_monitor.sv \
    $root/armor/SRC/wrapper.sv \
    $root/armor/ooc/ooc_wrapper.sv ]

#  50 MHz, la frequence de la plateforme evaluee.
synth_design -top ooc_wrapper -part $part -mode out_of_context \
             -verilog_define $defs \
             -include_dirs [list $cva6/core/include $root/armor/Include]
create_clock -period 20.000 -name clk_i [get_ports clk_i]
opt_design

report_utilization      -file $root/armor/ooc/ooc_utilization$sfx.rpt
report_timing_summary   -file $root/armor/ooc/ooc_timing$sfx.rpt
puts "=== OOC$sfx : [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]] LUT, [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]] bascules"
