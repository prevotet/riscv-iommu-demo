# Add HW accelerarator to IOMMU

- modification of cva6/corev_apu/fpga/src/ariane_peripherals.sv
- modification of cva6/corev_apu/tb/ariane_axi_soc_pkg.sv
- modification of cva6/corev_apu/tb/ariane_soc_pkg.sv
- ariane_xilinx.sv



## commandes à effectuer
cd /home/jc/tmp/riscv-iommu-demo
DPR_MODE=clean ./2_build_HB.sh fpga-dpr
FORCE_FPGA=1 DPR_MODE=static ./2_build_HB.sh fpga-dpr
RM=accel_A ./2_build_HB.sh fpga-dpr
RM=accel_B ./2_build_HB.sh fpga-dpr
./3_build_B.sh convert-bin

