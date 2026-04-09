# =============================================================================
#  DPR Makefile - riscv-iommu-demo/dpr/
# =============================================================================
ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

CVA6_REPO_DIR   ?= $(ROOT)/cva6
CVA6_FPGA       := $(ROOT)/cva6/corev_apu/fpga
DPR_DIR         := $(ROOT)/dpr
WORK_DPR        := $(CVA6_FPGA)/work-dpr
VIVADO          := vivado -mode batch -nojournal -nolog

XILINX_PART     ?= xc7k325tffg900-2
XILINX_BOARD    ?= digilentinc.com:genesys2:part0:1.1
export XILINX_PART
export XILINX_BOARD

RM              ?= accel_default
RMS             := accel_default accel_A accel_B
FORCE_STATIC    ?= 0

RISCV           ?= $(shell echo $$RISCV)
export RISCV
export CVA6_REPO_DIR

.PHONY: dpr-static dpr-partial dpr-all dpr-clean dpr-prepare dpr-ips dpr-project

# --- Étape 0a : Injection des fichiers DPR ---
dpr-prepare:
	@echo "==> Préparation des sources DPR..."
	mkdir -p $(CVA6_FPGA)/src
	cp $(DPR_DIR)/src/rp_boundary_regs.sv $(CVA6_FPGA)/src/
	cp $(DPR_DIR)/src/rp_boundary_regs_mmu.sv $(CVA6_FPGA)/src/
	cp $(DPR_DIR)/rm/accel_default/accel_blank.sv $(CVA6_FPGA)/src/accel_wrap.sv
	

# --- Étape 0b : Génération des IPs Xilinx ---
dpr-ips:
	@echo "==> Génération des IPs Xilinx..."
	$(MAKE) -C $(CVA6_FPGA) \
		work-fpga/xlnx_axi_clock_converter.xci \
		work-fpga/xlnx_axi_dwidth_converter.xci \
		work-fpga/xlnx_axi_dwidth_converter_dm_master.xci \
		work-fpga/xlnx_axi_dwidth_converter_dm_slave.xci \
		work-fpga/xlnx_axi_quad_spi.xci \
		work-fpga/xlnx_axi_gpio.xci \
		work-fpga/xlnx_clk_gen.xci \
		work-fpga/xlnx_mig_7_ddr3.xci \
		work-fpga/xlnx_axi_hwicap.xci

# --- Étape 0c : Création du projet Vivado (ariane.xpr) ---
# Nécessaire seulement si le projet n'existe pas encore
$(CVA6_FPGA)/ariane.xpr:
	@echo "==> Création du projet Vivado (ariane.xpr)..."
	cd $(CVA6_FPGA) && BOARD=genesys2 XILINX_PART=xc7k325tffg900-2 XILINX_BOARD=digilentinc.com:genesys2:part0:1.1 vivado -nojournal -nolog -mode batch -source scripts/prologue.tcl -source scripts/run.tcl || true
	@if [ ! -f $(CVA6_FPGA)/ariane.xpr ]; then \
		echo "ERROR: ariane.xpr non créé, vérifiez scripts/run.tcl"; \
		exit 1; \
	fi

dpr-project: dpr-ips $(CVA6_FPGA)/ariane.xpr

# --- Étape 1 : Implémentation Statique ---
dpr-static: dpr-prepare dpr-project
	@if [ -f $(WORK_DPR)/static_routed.dcp ] && [ "$(FORCE_STATIC)" != "1" ]; then \
		echo "-----------------------------------------------------------"; \
		echo " SKIP : checkpoint statique existe déjà."; \
		echo " Pour forcer : FORCE_STATIC=1"; \
		echo "-----------------------------------------------------------"; \
	else \
		echo "==> Lancement de la synthèse STATIQUE (Vivado)..."; \
		mkdir -p $(WORK_DPR); \
		$(VIVADO) -source $(DPR_DIR)/scripts/run_static.tcl \
			-tclargs $(CVA6_FPGA) $(DPR_DIR) $(WORK_DPR); \
	fi

# --- Étape 2 : Implémentation Partielle ---
dpr-partial:
	@if [ ! -f $(WORK_DPR)/static_routed.dcp ]; then \
		echo "ERREUR : checkpoint statique manquant. Lancez 'make dpr-static' d'abord."; \
		exit 1; \
	fi
	@echo "==> Implémentation du module PARTIEL : $(RM)"
	cp $(DPR_DIR)/rm/$(RM)/accel_*.sv $(CVA6_FPGA)/src/accel_wrap.sv
	$(VIVADO) -source $(DPR_DIR)/scripts/run_partial.tcl \
		-tclargs $(WORK_DPR) $(DPR_DIR)/rm/$(RM) $(RM) $(DPR_DIR)

# --- Utilitaires ---
dpr-all: dpr-static
	@for rm in $(RMS); do \
		$(MAKE) dpr-partial RM=$$rm; \
	done

dpr-clean:
	@echo "==> Nettoyage..."
	rm -rf $(WORK_DPR)
	rm -f $(DPR_DIR)/constraints/pblock_accels_impl.xdc