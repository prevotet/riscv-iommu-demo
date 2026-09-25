#==================================================
# Makefile pour simulation Vivado depuis SIM
#==================================================

# Répertoires
SRC_DIR     := ../SRC
INC_DIR     := ../Include

# Fichiers SystemVerilog (packages/types sont dans Include)
SOURCES_SV := \
    $(SRC_DIR)/axi_pkg.sv \
    $(SRC_DIR)/ID_extractor.sv \
    $(SRC_DIR)/id_comparator.sv \
    $(SRC_DIR)/request_manager.sv \
    $(SRC_DIR)/response_manager.sv \
    $(SRC_DIR)/security_monitor.sv \
    $(SRC_DIR)/wrapper.sv \
    $(SRC_DIR)/axi_sim_mem.sv \
    $(SRC_DIR)/request_flow_monitor.sv \
    $(SRC_DIR)/request_generator.sv\
    $(SRC_DIR)/Request_generator_for_axi_sim_mem.sv \
    $(SRC_DIR)/outs_req_flow_monitor.sv \
    $(SRC_DIR)/ADDR_extractor.sv \
    $(SRC_DIR)/Interrupt_detector.sv \
    $(SRC_DIR)/interrupt_monitor.sv \
    $(SRC_DIR)/Delay_inserter.sv \
    ../top_wrapper_tb.sv \
    ../testbench_wrapper_generator.sv \
    ../testbench_wrapper_generator_memory.sv \
    

# Include paths
INC := -i $(INC_DIR)

# Options de compilation
COMP_OPTS_SV := --incr --relax
DEFINES_SV := -d VERILATOR

# Top module
TB_TOP := testbench_wrapper_generator_memory

#==================================================
# Cibles Makefile
#==================================================

.PHONY: all compile elaborate simulate gui clean

all: gui

# Compilation SystemVerilog
.comp_sv.timestamp: $(SOURCES_SV)
	@echo "### COMPILING SYSTEMVERILOG ###"
	xvlog $(INC) --sv $(COMP_OPTS_SV) $(DEFINES_SV) $(SOURCES_SV)
	touch .comp_sv.timestamp

# Élaboration
.elab.timestamp: .comp_sv.timestamp
	@echo "### ELABORATING ###"
	xelab $(INC) -debug all $(TB_TOP) -s $(TB_TOP)_snapshot
	touch .elab.timestamp

# Simulation batch
simulate: .elab.timestamp
	@echo "### RUNNING SIMULATION ###"
	xsim $(TB_TOP)_snapshot

# Simulation GUI
gui: .elab.timestamp
	@echo "### RUNNING SIMULATION (GUI) ###"
	xsim -gui $(TB_TOP)_snapshot -tclbatch xsim_cfg.tcl

# Nettoyage
clean:
	rm -rf *.jou *.log *.pb *.wdb xsim.dir
	rm -rf .*.timestamp

