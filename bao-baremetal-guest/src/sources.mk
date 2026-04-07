ifeq ($(VARIANT),dpr_manager)
src_c_srcs := dpr_manager.c
else ifeq ($(VARIANT),dpr_client)
src_c_srcs := dpr_client.c
else
src_c_srcs := main.c dpr_test_full.c
endif
