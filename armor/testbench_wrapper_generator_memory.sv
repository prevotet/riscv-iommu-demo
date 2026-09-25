`timescale 1ns/1ps
`include "./Include/axi_types.sv"
`include "./Include/typedef.svh"
import axi_types::*;

module testbench_wrapper_generator_memory;

  // ----------------------------
  // Parameters
  // ----------------------------
  localparam int AddrWidth  = 64;
  localparam int DataWidth  = 64;
  localparam int StrbWidth  = DataWidth / 8;
  localparam int IdWidth    = 4;
  localparam int IdWidthSlv = 6;
  localparam int UserWidth  = 1;
  localparam int DevIDWidth = 24;
  localparam int ProcIDWidth = 20;
  localparam int N_REQUESTS = 100;

  // ----------------------------
  // Clock & Reset
  // ----------------------------
  logic clk;
  logic rst_ni;

  always #5 clk = ~clk;

  initial begin
    clk   = 0;
    rst_ni = 0;
    #20 rst_ni = 1;
  end

  // ----------------------------
  // AXI Interfaces
  // ----------------------------
  axi_types::req_iommu_t     req_ip_to_wrapper;
  axi_types::resp_slv_t      resp_ip_from_wrapper;

  axi_types::req_iommu_t     req_wrapper_to_mem;
  axi_types::resp_slv_t      resp_mem_to_wrapper;

  // Memory expects req_slv_t
  axi_types::req_slv_t       req_mem;

  // CPU interface (unused)
  axi_types::req_slv_t       req_cpu_to_wrapper;
  axi_types::resp_slv_t      resp_cpu_from_wrapper;

  // ----------------------------
  // IP Generator
  // ----------------------------
  request_generator_for_mem #(
    .NUM_REQS(N_REQUESTS),
    .DEV_ID_WIDTH(DevIDWidth)
  ) gen (
    .clk_i      (clk),
    .rst_ni     (rst_ni),
    .aw_ready_i (resp_ip_from_wrapper.aw_ready),
    .w_ready_i  (resp_ip_from_wrapper.w_ready),
    .b_valid_i  (resp_ip_from_wrapper.b_valid),
    .req_o      (req_ip_to_wrapper)
  );

  // ----------------------------
  // Wrapper
  // ----------------------------
  wrapper #(
    .IdWidth     (IdWidth),
    .IdWidthSlv  (IdWidthSlv),
    .AddrWidth   (AddrWidth),
    .UserWidth   (UserWidth),
    .DevIDWidth  (DevIDWidth),
    .ProcIDWidth (ProcIDWidth),
    .DataWidth   (DataWidth),
    .StrbWidth   (StrbWidth)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst_ni),

    // IP <-> Wrapper
    .req_IP_wrapper_i   (req_ip_to_wrapper),
    .resp_IP_wrapper_o  (resp_ip_from_wrapper),

    // Wrapper <-> Memory
    .req_wrapper_iommu_o(req_wrapper_to_mem),
    .resp_wrapper_iommu_i(resp_mem_to_wrapper),

    // CPU <-> Wrapper (unused)
    .req_CPU_Wrapper__i (req_cpu_to_wrapper),
    .resp_CPU_Wrapper_o(resp_cpu_from_wrapper)
  );

  // Fixed ID configuration (same as old TB)
  initial dut.fixed_ID_reg = 24'h123456;
  initial dut.msi_address_config = 64'h0000_0000_FEE0_0000;  // Adresse MSI typique x86


  // ----------------------------
  // Adapter: req_iommu_t → req_slv_t
  // ----------------------------
  always_comb begin
    req_mem = '0;

    // AW
    req_mem.aw_valid = req_wrapper_to_mem.aw_valid;
    req_mem.aw.addr  = req_wrapper_to_mem.aw.addr;
    req_mem.aw.id    = req_wrapper_to_mem.aw.id;
    req_mem.aw.len   = req_wrapper_to_mem.aw.len;
    req_mem.aw.size  = req_wrapper_to_mem.aw.size;
    req_mem.aw.burst = req_wrapper_to_mem.aw.burst;
    req_mem.aw.lock  = req_wrapper_to_mem.aw.lock;
    req_mem.aw.cache = req_wrapper_to_mem.aw.cache;
    req_mem.aw.prot  = req_wrapper_to_mem.aw.prot;
    req_mem.aw.qos   = req_wrapper_to_mem.aw.qos;
    req_mem.aw.region = req_wrapper_to_mem.aw.region;
    req_mem.aw.user  = req_wrapper_to_mem.aw.user;
    // W
    req_mem.w_valid = req_wrapper_to_mem.w_valid;
    req_mem.w.w_data = req_wrapper_to_mem.w.w_data;
    req_mem.w.w_strb = req_wrapper_to_mem.w.w_strb;
    req_mem.w.w_last = req_wrapper_to_mem.w.w_last;
    req_mem.w.w_user = req_wrapper_to_mem.w.w_user;

    // B
    req_mem.b_ready = req_wrapper_to_mem.b_ready;
  end

  // ----------------------------
  // AXI simulated memory
  // ----------------------------
  axi_sim_mem #(
    .AddrWidth (AddrWidth),
    .DataWidth (DataWidth),
    .IdWidth   (IdWidth),
    .UserWidth (UserWidth),
    .axi_req_t (req_slv_t),
    .axi_rsp_t (resp_slv_t)
  ) mem (
    .clk_i     (clk),
    .rst_ni    (rst_ni),
    .axi_req_i (req_mem),
    .axi_rsp_o (resp_mem_to_wrapper)
  );

  // ----------------------------
  // Observability (optional)
  // ----------------------------
  always_ff @(posedge clk) begin
    if (req_mem.aw_valid && resp_mem_to_wrapper.aw_ready)
      $display("[%0t] AW accepted addr=0x%h id=%0d",
               $time, req_mem.aw.addr, req_mem.aw.id);

    if (req_mem.w_valid && resp_mem_to_wrapper.w_ready)
      $display("[%0t] W accepted data=0x%h",
               $time, req_mem.w.w_data);

    if (resp_mem_to_wrapper.b_valid && req_mem.b_ready)
      $display("[%0t] B response received", $time);
  end

endmodule
