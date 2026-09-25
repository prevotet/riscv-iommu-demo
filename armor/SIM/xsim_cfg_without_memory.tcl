
add_wave {{/wrapper_testbench1/dut/clk_i}} 

add_wave {{/wrapper_testbench1/dut/rst_ni}} 

add_wave {{/wrapper_testbench1/dut/req_IP_wrapper_i}}
add_wave {{/wrapper_testbench1/dut/req_IP_wrapper_i.aw_valid}} 

add_wave {{/wrapper_testbench1/dut/resp_IP_wrapper_o}} 
add_wave {{/wrapper_testbench1/dut/resp_IP_wrapper_o.aw_ready}} 

add_wave {{/wrapper_testbench1/dut/resp_wrapper_iommu_i}} 
add_wave {{/wrapper_testbench1/dut/resp_wrapper_iommu_i.aw_ready}} 

add_wave {{/wrapper_testbench1/dut/req_wrapper_iommu_o}} 
add_wave {{/wrapper_testbench1/dut/req_wrapper_iommu_o.aw_valid}}

#add_wave {{/wrapper_testbench1/dut/Device_ID_o}} 

#add_wave {{/wrapper_testbench1/dut/Device_ID_write_enable_o}} 

add_wave {{/wrapper_testbench1/dut/legit_hit}} 

add_wave {{/wrapper_testbench1/dut/block_ip_o}} 

add_wave {{/wrapper_testbench1/dut/Device_ID_o}} 

add_wave {{/wrapper_testbench1/dut/Device_ID_write_enable_o}} 

add_wave {{/wrapper_testbench1/dut/fixed_ID_reg}} 

add_wave {{/wrapper_testbench1/dut/comparison_valid}} 

add_wave {{/wrapper_testbench1/dut/failure_count}} 

add_wave {{/wrapper_testbench1/dut/threat_detected}} 
add_wave {{/wrapper_testbench1/dut/storm_flag}} 
add_wave {{/wrapper_testbench1/dut/block_req_flow}} 
add_wave {{/wrapper_testbench1/dut/req_flow_mon_inst/window_cnt}} 
add_wave {{/wrapper_testbench1/dut/req_flow_mon_inst/req_cnt}} 
add_wave {{/wrapper_testbench1/dut/req_flow_mon_inst/aw_edge}} 
add_wave {{/wrapper_testbench1/dut/req_flow_mon_inst/ar_edge}} 
add_wave {{/wrapper_testbench1/dut/req_flow_mon_inst/WINDOW_CYCLES}} 
add_wave {{/wrapper_testbench1/dut/req_flow_mon_inst/MAX_REQ_PER_WINDOW}} 
add_wave {{/wrapper_testbench1/dut/block_req_i}} 





run 3000ns
