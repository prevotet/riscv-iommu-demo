# =============================================================================
#  DPR Makefile - riscv-iommu-demo/dpr/
#  Optimisé avec sécurité anti-écrasement (Static Checkpoint)
# =============================================================================
ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

# Variables de configuration
RISCV           ?= $(shell echo $$RISCV)
CVA6_REPO_DIR   ?= $(ROOT)/cva6
CVA6_FPGA       := $(ROOT)/cva6/corev_apu/fpga
DPR_DIR         := $(ROOT)/dpr
WORK_DPR        := $(CVA6_FPGA)/work-dpr
VIVADO          := vivado -mode batch -nojournal -nolog

# Variables pour la reconfiguration
RM              ?= accel_default
RMS             := accel_default accel_A accel_B

# Sécurité : Positionner à 1 pour forcer la régénération du statique
FORCE_STATIC    ?= 0

export RISCV
export CVA6_REPO_DIR

.PHONY: dpr-static dpr-partial dpr-all dpr-clean dpr-prepare dpr-ips

# --- Étape 0a : Injection des fichiers DPR dans l'arborescence CVA6 ---
dpr-prepare:
	@echo "==> Préparation des sources DPR..."
	mkdir -p $(CVA6_FPGA)/src
	cp $(DPR_DIR)/src/rp_boundary_regs.sv $(CVA6_FPGA)/src/
	cp $(DPR_DIR)/rm/accel_default/accel_blank.sv $(CVA6_FPGA)/src/accel_wrap.sv

# --- Étape 0b : Génération des IPs Xilinx (obligatoire avant synthèse) ---
dpr-ips:
	@echo "==> Génération des IPs Xilinx (si pas déjà faites)..."
	$(MAKE) -C $(CVA6_FPGA) \
		work-fpga/xlnx_axi_clock_converter.xci \
		work-fpga/xlnx_axi_dwidth_converter.xci \
		work-fpga/xlnx_axi_dwidth_converter_dm_master.xci \
		work-fpga/xlnx_axi_dwidth_converter_dm_slave.xci \
		work-fpga/xlnx_axi_quad_spi.xci \
		work-fpga/xlnx_axi_gpio.xci \
		work-fpga/xlnx_clk_gen.xci \
		work-fpga/xlnx_mig_7_ddr3.xci

# --- Étape 1 : Implémentation Statique (La base fixe) ---
dpr-static: dpr-prepare dpr-ips
	@if [ -f $(WORK_DPR)/static_routed.dcp ] && [ "$(FORCE_STATIC)" != "1" ]; then \
		echo "--------------------------------------------------------------------------"; \
		echo " SKIP : Le checkpoint statique existe déjà : $(WORK_DPR)/static_routed.dcp"; \
		echo " Pour forcer la régénération, utilisez : FORCE_STATIC=1"; \
		echo "--------------------------------------------------------------------------"; \
	else \
		echo "==> Lancement de la synthèse STATIQUE (Vivado)..."; \
		mkdir -p $(WORK_DPR); \
		$(VIVADO) -source $(DPR_DIR)/scripts/run_static.tcl \
			-tclargs $(CVA6_FPGA) $(DPR_DIR) $(WORK_DPR); \
	fi

# --- Étape 2 : Implémentation Partielle (Les modules) ---
dpr-partial:
	@if [ ! -f $(WORK_DPR)/static_routed.dcp ]; then \
		echo "ERREUR : Le fichier statique est manquant. Lancez 'make dpr-static' d'abord."; \
		exit 1; \
	fi
	@echo "==> Implémentation du module PARTIEL : $(RM)"
	cp $(DPR_DIR)/rm/$(RM)/accel_*.sv $(CVA6_FPGA)/src/accel_wrap.sv
	$(VIVADO) -source $(DPR_DIR)/scripts/run_partial.tcl \
		-tclargs $(WORK_DPR) $(DPR_DIR)/rm/$(RM) $(RM)

# --- Utilitaires ---
dpr-all: dpr-static
	@for rm in $(RMS); do \
		$(MAKE) dpr-partial RM=$$rm; \
	done

# Nettoyage
dpr-clean:
	@echo "==> Nettoyage des dossiers de travail DPR..."
	rm -rf $(WORK_DPR)