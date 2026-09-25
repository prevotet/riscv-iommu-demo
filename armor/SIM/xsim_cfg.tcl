
add_wave {{/testbench_wrapper_generator_memory/clk}}
add_wave {{/testbench_wrapper_generator_memory/rst_ni}}


add_wave {{/testbench_wrapper_generator_memory/req_ip_to_wrapper}}


add_wave {{/testbench_wrapper_generator_memory/req_wrapper_to_mem}}

add_wave {{/testbench_wrapper_generator_memory/resp_mem_to_wrapper}}
add_wave {{/testbench_wrapper_generator_memory/resp_ip_from_wrapper}}
add_wave {{/testbench_wrapper_generator_memory/dut/legit_hit}}
add_wave {{/testbench_wrapper_generator_memory/dut/block_ip_o}}
add_wave {{/testbench_wrapper_generator_memory/dut/block_req_flow}}
add_wave {{/testbench_wrapper_generator_memory/dut/comparison_valid}}
add_wave {{/testbench_wrapper_generator_memory/dut/failure_count}}
add_wave {{/testbench_wrapper_generator_memory/dut/threat_detected}}
add_wave {{/testbench_wrapper_generator_memory/dut/storm_flag}}
add_wave {{/testbench_wrapper_generator_memory/dut/req_fire_signal}}
add_wave {{/testbench_wrapper_generator_memory/dut/overflow_flag_outs}}
add_wave {{/testbench_wrapper_generator_memory/dut/block_req_outs}}
add_wave {{/testbench_wrapper_generator_memory/dut/extracted_address}}
add_wave {{/testbench_wrapper_generator_memory/dut/address_valid}}
add_wave {{/testbench_wrapper_generator_memory/dut/is_write_req}}
add_wave {{/testbench_wrapper_generator_memory/dut/is_read_req}}
add_wave {{/testbench_wrapper_generator_memory/dut/msi_address_config}}  
add_wave {{/testbench_wrapper_generator_memory/dut/is_msi_interrupt}}
add_wave {{/testbench_wrapper_generator_memory/dut/msi_comparison_valid}}
add_wave {{/testbench_wrapper_generator_memory/dut/msi_storm}}
add_wave {{/testbench_wrapper_generator_memory/dut/block_msi}}




#signals for monitoring flow manager

add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/window_cnt}} 
add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/block_cnt}} 
add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/req_cnt}} 
add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/blocking}} 
add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/WINDOW_CYCLES}} 
add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/MAX_REQ_PER_WINDOW}} 
add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/BLOCK_CYCLES}} 
add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/req_fire}} 
add_wave {{/testbench_wrapper_generator_memory/dut/req_flow_mon_inst/block_req}}


#signals for outs req manager

add_wave {{/testbench_wrapper_generator_memory/dut/outs_monitor_inst/b_handshake}} 
add_wave {{/testbench_wrapper_generator_memory/dut/outs_monitor_inst/r_handshake}} 
add_wave {{/testbench_wrapper_generator_memory/dut/outs_monitor_inst/resp_complete}} 
add_wave {{/testbench_wrapper_generator_memory/dut/outs_monitor_inst/MAX_OUTSTANDING}} 
add_wave {{/testbench_wrapper_generator_memory/dut/outs_monitor_inst/outstanding}} 
add_wave {{/testbench_wrapper_generator_memory/dut/outs_monitor_inst/blocking}} 
add_wave {{/testbench_wrapper_generator_memory/dut/outs_monitor_inst/block_req}} 


#signals for interrupts



run 3000ns

