# make BENCH_IOMMU=1 BENCH_ARMOR=1 -> bench_iommu (latences, tag ARMOR)
# make BENCH=1                -> bench_runner (detection ARMOR)
ifeq ($(BENCH_IOMMU),1)
  src_c_srcs := bench_iommu.c
else ifeq ($(BENCH),1)
  src_c_srcs := bench_runner.c
else
  src_c_srcs := main.c
endif
