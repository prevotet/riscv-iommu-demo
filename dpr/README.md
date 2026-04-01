source /tools/Xilinx/Vivado/2022.2/settings64.sh

cat > /tmp/program.tcl << 'EOF'
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7k*] 0]
current_hw_device $dev
set_property PROGRAM.FILE {/home/jc/tmp/riscv-iommu-demo/cva6/corev_apu/fpga/work-dpr/full_accel_A.bit} $dev
program_hw_devices $dev
puts "FPGA programmé"
close_hw_target
disconnect_hw_server
close_hw_manager
EOF

vivado -mode batch -nojournal -nolog -source /tmp/program.tcl

openocd -f /home/jc/tmp/riscv-iommu-demo/cva6/corev_apu/fpga/ariane.cfg

telnet localhost 4444
halt

load_image /home/jc/tmp/riscv-iommu-demo/bao-baremetal-guest/build/cva6/baremetal.bin 0x90000000 bin

mww 0x81000000 0x82AA2
mww 0x81000004 0xFB97A

load_image /home/jc/tmp/riscv-iommu-demo/cva6/corev_apu/fpga/work-dpr/partial_accel_B_accel1.bin 0x81000008 bin

load_image /home/jc/tmp/riscv-iommu-demo/cva6/corev_apu/fpga/work-dpr/partial_accel_B_accel2.bin 0x81200A90 bin

reg pc 0x90000000

resume

