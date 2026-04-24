set W /home/jc/tmp/riscv-iommu-demo/cva6/corev_apu/fpga/work-dpr/3_build_B_dpr

puts "==> pr_verify: static vs accel_A / accel_B / accel_default"
pr_verify \
    -initial  $W/static_routed.dcp \
    -additional [list \
        $W/accel_A_routed.dcp \
        $W/accel_B_routed.dcp \
        $W/accel_default_routed.dcp \
    ]
puts "==> pr_verify done"
