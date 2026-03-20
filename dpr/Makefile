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

.PHONY: dpr-static dpr-partial dpr-all dpr-clean dpr-prepare

# --- Étape 0 : Prérequis ---

# Dépendance sur le bitstream standard de CVA6
$(CVA6_FPGA)/work-fpga/ariane_xilinx.bit: dpr-prepare
	@echo "==> Vérification du build standard CVA6..."
	$(MAKE) -C $(ROOT)/cva6 fpga

# Injection des fichiers DPR dans l'arborescence CVA6
dpr-prepare:
	@echo "==> Préparation des sources DPR..."
	mkdir -p $(CVA6_FPGA)/src
	cp $(DPR_DIR)/src/rp_boundary_regs.sv $(CVA6_FPGA)/src/
	cp $(DPR_DIR)/rm/accel_default/accel_blank.sv $(CVA6_FPGA)/src/accel_wrap.sv

# --- Étape 1 : Implémentation Statique (La base fixe) ---

dpr-static: $(WORK_DPR)/static_routed.dcp

$(WORK_DPR)/static_routed.dcp: $(CVA6_FPGA)/work-fpga/ariane_xilinx.bit
	@if [ -f $@ ] && [ "$(FORCE_STATIC)" != "1" ]; then \
		echo "--------------------------------------------------------------------------"; \
		echo " SKIP : Le checkpoint statique existe déjà : $@"; \
		echo " Pour forcer la régénération (long), utilisez : FORCE_STATIC=1"; \
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

# Génère toutes les configurations RMS
dpr-all: dpr-static
	@for rm in $(RMS); do \
		$(MAKE) dpr-partial RM=$$rm; \
	done

# Nettoyage
dpr-clean:
	@echo "==> Nettoyage des dossiers de travail DPR..."
	rm -rf $(WORK_DPR)