// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Xilinx Peripherals — dual autonomous DMA accelerator + security wrappers via IOMMU
//
// ============================================================
//  TOPOLOGIE DMA/IOMMU
// ============================================================
//
//  XBAR ─dma_cfg────► accel_wrap #1 ─accel1_dma─► sec_wrapper #1 ─accel1_sec─┐
//  XBAR ─wrapper_cfg1──────────────────────────────►(wrapper_cfg)              ├─►axi_mux─►IOMMU
//  XBAR ─dma_cfg2───► accel_wrap #2 ─accel2_dma─► sec_wrapper #2 ─accel2_sec─┘
//  XBAR ─wrapper_cfg2──────────────────────────────►(wrapper_cfg)
//
//  XBAR ─iommu_cfg──► IOMMU prog IF
//  IOMMU comp IF ───► XBAR (requêtes traduites → DRAM)
//  IOMMU ds IF ─────► XBAR (page-table walk → DRAM)
//
//  Bus internes :
//    accel1_dma   AXI_BUS_MMU  ID=3b  sortie accel_wrap #1
//    accel1_sec   AXI_BUS_MMU  ID=3b  sortie sec_wrapper #1 (après filtrage)
//    accel1_std   AXI_BUS      ID=3b  projection std → entrée mux port 0
//    accel2_dma   AXI_BUS_MMU  ID=3b  sortie accel_wrap #2
//    accel2_sec   AXI_BUS_MMU  ID=3b  sortie sec_wrapper #2
//    accel2_std   AXI_BUS      ID=3b  projection std → entrée mux port 1
//    dma_muxed    AXI_BUS      ID=4b  sortie axi_mux → IOMMU TR IF
//
//  Largeurs d'ID :
//    accel_wrap interne : AXI_ID_WIDTH = ariane_soc::IdWidth - 1 = 3b
//    axi_mux sortie     : MST_AXI_ID_WIDTH = ariane_soc::IdWidth = 4b
//    IOMMU ID_WIDTH     : ariane_soc::IdWidth = 4b  (inchangé)
// ============================================================

`include "axi/assign.svh"
`include "axi/typedef.svh"
`include "register_interface/assign.svh"
`include "register_interface/typedef.svh"

module ariane_peripherals #(
    parameter int AxiAddrWidth = -1,
    parameter int AxiDataWidth = -1,
    parameter int AxiIdWidth   = -1,
    parameter int AxiUserWidth =  1,
    parameter bit InclUART     =  1,
    parameter bit InclSPI      =  0,
    parameter bit InclEthernet =  0,
    parameter bit InclGPIO     =  0,
    parameter bit InclTimer    =  1,
    parameter bit InclDMA      =  0,
    parameter bit InclDMA2     =  0,
    parameter bit InclIOMMU    =  0
) (
    input  logic       clk_i           ,
    input  logic       clk_200MHz_i    ,
    input  logic       rst_ni          ,
    AXI_BUS.Slave      plic            ,
    AXI_BUS.Slave      uart            ,
    AXI_BUS.Slave      spi             ,
    AXI_BUS.Slave      gpio            ,
    AXI_BUS.Slave      ethernet        ,
    AXI_BUS.Slave      timer           ,
    AXI_BUS.Slave      dma_cfg         , // Config MMIO Accel 1       (XBAR → accel_wrap #1)
    AXI_BUS.Slave      dma_cfg2        , // Config MMIO Accel 2       (XBAR → accel_wrap #2)
    AXI_BUS.Slave      wrapper_cfg1    , // Config sec_wrapper #1     (XBAR → sec_wrapper #1)
    AXI_BUS.Slave      wrapper_cfg2    , // Config sec_wrapper #2     (XBAR → sec_wrapper #2)
    AXI_BUS.Master     iommu_comp      , // IOMMU Completion IF       (IOMMU → XBAR)
    AXI_BUS.Master     iommu_ds        , // IOMMU Memory IF           (IOMMU → XBAR)
    AXI_BUS.Slave      iommu_cfg       , // IOMMU Programming IF      (XBAR → IOMMU)
    output logic [1:0] irq_o           ,
    input  logic       rx_i            ,
    output logic       tx_o            ,
    input  logic       eth_clk_i       ,
    input  wire        eth_rxck        ,
    input  wire        eth_rxctl       ,
    input  wire [3:0]  eth_rxd         ,
    output wire        eth_txck        ,
    output wire        eth_txctl       ,
    output wire [3:0]  eth_txd         ,
    output wire        eth_rst_n       ,
    input  logic       phy_tx_clk_i    ,
    inout  wire        eth_mdio        ,
    output logic       eth_mdc         ,
    output logic       spi_clk_o       ,
    output logic       spi_mosi        ,
    input  logic       spi_miso        ,
    output logic       spi_ss          ,
    input  logic       btnu_i          ,
    input  logic       btnd_i          ,
    input  logic       btnl_i          ,
    input  logic       btnr_i          ,
    input  logic       btnc_i          ,
    input  logic       sd_clk_i        ,
    output logic [7:0] leds_o          ,
    input  logic [7:0] dip_switches_i
);

    // -----------------------------------------------------------------------
    //  1. PLIC
    // -----------------------------------------------------------------------
    logic [ariane_soc::NumSources-1:0] irq_sources;
    assign irq_sources[ariane_soc::NumSources-1:ariane_soc::LastIntIndex+1] = '0;

    REG_BUS #(.ADDR_WIDTH(32), .DATA_WIDTH(32)) reg_bus (clk_i);

    logic [31:0] plic_paddr, plic_pwdata, plic_prdata;
    logic        plic_penable, plic_pwrite, plic_psel, plic_pready, plic_pslverr;

    axi2apb_64_32 #(
        .AXI4_ADDRESS_WIDTH(AxiAddrWidth), .AXI4_RDATA_WIDTH(AxiDataWidth),
        .AXI4_WDATA_WIDTH(AxiDataWidth),   .AXI4_ID_WIDTH(AxiIdWidth),
        .AXI4_USER_WIDTH(AxiUserWidth),    .BUFF_DEPTH_SLAVE(2),
        .APB_ADDR_WIDTH(32)
    ) i_axi2apb_64_32_plic (
        .ACLK(clk_i), .ARESETn(rst_ni), .test_en_i(1'b0),
        .AWID_i(plic.aw_id),     .AWADDR_i(plic.aw_addr),   .AWLEN_i(plic.aw_len),
        .AWSIZE_i(plic.aw_size), .AWBURST_i(plic.aw_burst), .AWLOCK_i(plic.aw_lock),
        .AWCACHE_i(plic.aw_cache),.AWPROT_i(plic.aw_prot),  .AWREGION_i(plic.aw_region),
        .AWUSER_i(plic.aw_user), .AWQOS_i(plic.aw_qos),     .AWVALID_i(plic.aw_valid),
        .AWREADY_o(plic.aw_ready),.WDATA_i(plic.w_data),    .WSTRB_i(plic.w_strb),
        .WLAST_i(plic.w_last),   .WUSER_i(plic.w_user),     .WVALID_i(plic.w_valid),
        .WREADY_o(plic.w_ready), .BID_o(plic.b_id),         .BRESP_o(plic.b_resp),
        .BVALID_o(plic.b_valid), .BUSER_o(plic.b_user),     .BREADY_i(plic.b_ready),
        .ARID_i(plic.ar_id),     .ARADDR_i(plic.ar_addr),   .ARLEN_i(plic.ar_len),
        .ARSIZE_i(plic.ar_size), .ARBURST_i(plic.ar_burst), .ARLOCK_i(plic.ar_lock),
        .ARCACHE_i(plic.ar_cache),.ARPROT_i(plic.ar_prot),  .ARREGION_i(plic.ar_region),
        .ARUSER_i(plic.ar_user), .ARQOS_i(plic.ar_qos),     .ARVALID_i(plic.ar_valid),
        .ARREADY_o(plic.ar_ready),.RID_o(plic.r_id),        .RDATA_o(plic.r_data),
        .RRESP_o(plic.r_resp),   .RLAST_o(plic.r_last),     .RUSER_o(plic.r_user),
        .RVALID_o(plic.r_valid), .RREADY_i(plic.r_ready),
        .PENABLE(plic_penable),  .PWRITE(plic_pwrite),       .PADDR(plic_paddr),
        .PSEL(plic_psel),        .PWDATA(plic_pwdata),       .PRDATA(plic_prdata),
        .PREADY(plic_pready),    .PSLVERR(plic_pslverr)
    );

    apb_to_reg i_apb_to_reg (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .penable_i(plic_penable), .pwrite_i(plic_pwrite), .paddr_i(plic_paddr),
        .psel_i(plic_psel),       .pwdata_i(plic_pwdata), .prdata_o(plic_prdata),
        .pready_o(plic_pready),   .pslverr_o(plic_pslverr), .reg_o(reg_bus)
    );

    `REG_BUS_TYPEDEF_ALL(plic, logic[31:0], logic[31:0], logic[3:0])
    plic_req_t plic_req; plic_rsp_t plic_rsp;
    `REG_BUS_ASSIGN_TO_REQ(plic_req, reg_bus)
    `REG_BUS_ASSIGN_FROM_RSP(reg_bus, plic_rsp)

    plic_top #(
        .N_SOURCE(ariane_soc::NumSources), .N_TARGET(ariane_soc::NumTargets),
        .MAX_PRIO(ariane_soc::MaxPriority), .reg_req_t(plic_req_t), .reg_rsp_t(plic_rsp_t)
    ) i_plic (
        .clk_i, .rst_ni,
        .req_i(plic_req), .resp_o(plic_rsp),
        .le_i('0), .irq_sources_i(irq_sources), .eip_targets_o(irq_o)
    );

    // -----------------------------------------------------------------------
    //  2. UART
    // -----------------------------------------------------------------------
    logic [31:0] uart_paddr, uart_pwdata, uart_prdata;
    logic        uart_penable, uart_pwrite, uart_psel, uart_pready, uart_pslverr;

    axi2apb_64_32 #(
        .AXI4_ADDRESS_WIDTH(AxiAddrWidth), .AXI4_RDATA_WIDTH(AxiDataWidth),
        .AXI4_WDATA_WIDTH(AxiDataWidth),   .AXI4_ID_WIDTH(AxiIdWidth),
        .AXI4_USER_WIDTH(AxiUserWidth),    .BUFF_DEPTH_SLAVE(2), .APB_ADDR_WIDTH(32)
    ) i_axi2apb_64_32_uart (
        .ACLK(clk_i), .ARESETn(rst_ni), .test_en_i(1'b0),
        .AWID_i(uart.aw_id),     .AWADDR_i(uart.aw_addr),   .AWLEN_i(uart.aw_len),
        .AWSIZE_i(uart.aw_size), .AWBURST_i(uart.aw_burst), .AWLOCK_i(uart.aw_lock),
        .AWCACHE_i(uart.aw_cache),.AWPROT_i(uart.aw_prot),  .AWREGION_i(uart.aw_region),
        .AWUSER_i(uart.aw_user), .AWQOS_i(uart.aw_qos),     .AWVALID_i(uart.aw_valid),
        .AWREADY_o(uart.aw_ready),.WDATA_i(uart.w_data),    .WSTRB_i(uart.w_strb),
        .WLAST_i(uart.w_last),   .WUSER_i(uart.w_user),     .WVALID_i(uart.w_valid),
        .WREADY_o(uart.w_ready), .BID_o(uart.b_id),         .BRESP_o(uart.b_resp),
        .BVALID_o(uart.b_valid), .BUSER_o(uart.b_user),     .BREADY_i(uart.b_ready),
        .ARID_i(uart.ar_id),     .ARADDR_i(uart.ar_addr),   .ARLEN_i(uart.ar_len),
        .ARSIZE_i(uart.ar_size), .ARBURST_i(uart.ar_burst), .ARLOCK_i(uart.ar_lock),
        .ARCACHE_i(uart.ar_cache),.ARPROT_i(uart.ar_prot),  .ARREGION_i(uart.ar_region),
        .ARUSER_i(uart.ar_user), .ARQOS_i(uart.ar_qos),     .ARVALID_i(uart.ar_valid),
        .ARREADY_o(uart.ar_ready),.RID_o(uart.r_id),        .RDATA_o(uart.r_data),
        .RRESP_o(uart.r_resp),   .RLAST_o(uart.r_last),     .RUSER_o(uart.r_user),
        .RVALID_o(uart.r_valid), .RREADY_i(uart.r_ready),
        .PENABLE(uart_penable),  .PWRITE(uart_pwrite),       .PADDR(uart_paddr),
        .PSEL(uart_psel),        .PWDATA(uart_pwdata),       .PRDATA(uart_prdata),
        .PREADY(uart_pready),    .PSLVERR(uart_pslverr)
    );

    if (InclUART) begin : gen_uart
        apb_uart i_apb_uart (
            .CLK(clk_i), .RSTN(rst_ni),
            .PSEL(uart_psel), .PENABLE(uart_penable), .PWRITE(uart_pwrite),
            .PADDR(uart_paddr[4:2]), .PWDATA(uart_pwdata), .PRDATA(uart_prdata),
            .PREADY(uart_pready), .PSLVERR(uart_pslverr),
            .INT(irq_sources[0]),
            .OUT1N(), .OUT2N(), .RTSN(), .DTRN(),
            .CTSN(1'b0), .DSRN(1'b0), .DCDN(1'b0), .RIN(1'b0),
            .SIN(rx_i), .SOUT(tx_o)
        );
    end else begin
        /* pragma translate_off */
        `ifndef VERILATOR
        mock_uart i_mock_uart (
            .clk_i(clk_i), .rst_ni(rst_ni),
            .penable_i(uart_penable), .pwrite_i(uart_pwrite), .paddr_i(uart_paddr),
            .psel_i(uart_psel), .pwdata_i(uart_pwdata), .prdata_o(uart_prdata),
            .pready_o(uart_pready), .pslverr_o(uart_pslverr)
        );
        `endif
        /* pragma translate_on */
    end

    // -----------------------------------------------------------------------
    //  3. SPI
    // -----------------------------------------------------------------------
    assign spi.b_user = 1'b0;
    assign spi.r_user = 1'b0;

    if (InclSPI) begin : gen_spi
        logic [31:0] s_axi_spi_awaddr, s_axi_spi_araddr, s_axi_spi_wdata, s_axi_spi_rdata;
        logic [7:0]  s_axi_spi_awlen,  s_axi_spi_arlen;
        logic [2:0]  s_axi_spi_awsize, s_axi_spi_arsize;
        logic [1:0]  s_axi_spi_awburst,s_axi_spi_arburst,s_axi_spi_bresp, s_axi_spi_rresp;
        logic [0:0]  s_axi_spi_awlock, s_axi_spi_arlock;
        logic [3:0]  s_axi_spi_awcache,s_axi_spi_arcache,s_axi_spi_awprot,s_axi_spi_awregion;
        logic [3:0]  s_axi_spi_awqos,  s_axi_spi_arqos,  s_axi_spi_arprot,s_axi_spi_arregion;
        logic [3:0]  s_axi_spi_wstrb;
        logic        s_axi_spi_awvalid,s_axi_spi_awready,s_axi_spi_wlast,s_axi_spi_wvalid;
        logic        s_axi_spi_wready, s_axi_spi_bvalid, s_axi_spi_bready,s_axi_spi_arvalid;
        logic        s_axi_spi_arready,s_axi_spi_rlast,  s_axi_spi_rvalid,s_axi_spi_rready;

        xlnx_axi_dwidth_converter i_xlnx_axi_dwidth_converter_spi (
            .s_axi_aclk(clk_i),          .s_axi_aresetn(rst_ni),
            .s_axi_awid(spi.aw_id),       .s_axi_awaddr(spi.aw_addr[31:0]),
            .s_axi_awlen(spi.aw_len),     .s_axi_awsize(spi.aw_size),
            .s_axi_awburst(spi.aw_burst), .s_axi_awlock(spi.aw_lock),
            .s_axi_awcache(spi.aw_cache), .s_axi_awprot(spi.aw_prot),
            .s_axi_awregion(spi.aw_region),.s_axi_awqos(spi.aw_qos),
            .s_axi_awvalid(spi.aw_valid), .s_axi_awready(spi.aw_ready),
            .s_axi_wdata(spi.w_data),     .s_axi_wstrb(spi.w_strb),
            .s_axi_wlast(spi.w_last),     .s_axi_wvalid(spi.w_valid),
            .s_axi_wready(spi.w_ready),   .s_axi_bid(spi.b_id),
            .s_axi_bresp(spi.b_resp),     .s_axi_bvalid(spi.b_valid),
            .s_axi_bready(spi.b_ready),   .s_axi_arid(spi.ar_id),
            .s_axi_araddr(spi.ar_addr[31:0]),.s_axi_arlen(spi.ar_len),
            .s_axi_arsize(spi.ar_size),   .s_axi_arburst(spi.ar_burst),
            .s_axi_arlock(spi.ar_lock),   .s_axi_arcache(spi.ar_cache),
            .s_axi_arprot(spi.ar_prot),   .s_axi_arregion(spi.ar_region),
            .s_axi_arqos(spi.ar_qos),     .s_axi_arvalid(spi.ar_valid),
            .s_axi_arready(spi.ar_ready), .s_axi_rid(spi.r_id),
            .s_axi_rdata(spi.r_data),     .s_axi_rresp(spi.r_resp),
            .s_axi_rlast(spi.r_last),     .s_axi_rvalid(spi.r_valid),
            .s_axi_rready(spi.r_ready),
            .m_axi_awaddr(s_axi_spi_awaddr),  .m_axi_awlen(s_axi_spi_awlen),
            .m_axi_awsize(s_axi_spi_awsize),  .m_axi_awburst(s_axi_spi_awburst),
            .m_axi_awlock(s_axi_spi_awlock),  .m_axi_awcache(s_axi_spi_awcache),
            .m_axi_awprot(s_axi_spi_awprot),  .m_axi_awregion(s_axi_spi_awregion),
            .m_axi_awqos(s_axi_spi_awqos),    .m_axi_awvalid(s_axi_spi_awvalid),
            .m_axi_awready(s_axi_spi_awready),.m_axi_wdata(s_axi_spi_wdata),
            .m_axi_wstrb(s_axi_spi_wstrb),    .m_axi_wlast(s_axi_spi_wlast),
            .m_axi_wvalid(s_axi_spi_wvalid),  .m_axi_wready(s_axi_spi_wready),
            .m_axi_bresp(s_axi_spi_bresp),    .m_axi_bvalid(s_axi_spi_bvalid),
            .m_axi_bready(s_axi_spi_bready),  .m_axi_araddr(s_axi_spi_araddr),
            .m_axi_arlen(s_axi_spi_arlen),    .m_axi_arsize(s_axi_spi_arsize),
            .m_axi_arburst(s_axi_spi_arburst),.m_axi_arlock(s_axi_spi_arlock),
            .m_axi_arcache(s_axi_spi_arcache),.m_axi_arprot(s_axi_spi_arprot),
            .m_axi_arregion(s_axi_spi_arregion),.m_axi_arqos(s_axi_spi_arqos),
            .m_axi_arvalid(s_axi_spi_arvalid),.m_axi_arready(s_axi_spi_arready),
            .m_axi_rdata(s_axi_spi_rdata),    .m_axi_rresp(s_axi_spi_rresp),
            .m_axi_rlast(s_axi_spi_rlast),    .m_axi_rvalid(s_axi_spi_rvalid),
            .m_axi_rready(s_axi_spi_rready)
        );

        xlnx_axi_quad_spi i_xlnx_axi_quad_spi (
            .ext_spi_clk(clk_i), .s_axi4_aclk(clk_i), .s_axi4_aresetn(rst_ni),
            .s_axi4_awaddr(s_axi_spi_awaddr[23:0]),
            .s_axi4_awlen(s_axi_spi_awlen),   .s_axi4_awsize(s_axi_spi_awsize),
            .s_axi4_awburst(s_axi_spi_awburst),.s_axi4_awlock(s_axi_spi_awlock),
            .s_axi4_awcache(s_axi_spi_awcache),.s_axi4_awprot(s_axi_spi_awprot),
            .s_axi4_awvalid(s_axi_spi_awvalid),.s_axi4_awready(s_axi_spi_awready),
            .s_axi4_wdata(s_axi_spi_wdata),   .s_axi4_wstrb(s_axi_spi_wstrb),
            .s_axi4_wlast(s_axi_spi_wlast),   .s_axi4_wvalid(s_axi_spi_wvalid),
            .s_axi4_wready(s_axi_spi_wready), .s_axi4_bresp(s_axi_spi_bresp),
            .s_axi4_bvalid(s_axi_spi_bvalid), .s_axi4_bready(s_axi_spi_bready),
            .s_axi4_araddr(s_axi_spi_araddr[23:0]),
            .s_axi4_arlen(s_axi_spi_arlen),   .s_axi4_arsize(s_axi_spi_arsize),
            .s_axi4_arburst(s_axi_spi_arburst),.s_axi4_arlock(s_axi_spi_arlock),
            .s_axi4_arcache(s_axi_spi_arcache),.s_axi4_arprot(s_axi_spi_arprot),
            .s_axi4_arvalid(s_axi_spi_arvalid),.s_axi4_arready(s_axi_spi_arready),
            .s_axi4_rdata(s_axi_spi_rdata),   .s_axi4_rresp(s_axi_spi_rresp),
            .s_axi4_rlast(s_axi_spi_rlast),   .s_axi4_rvalid(s_axi_spi_rvalid),
            .s_axi4_rready(s_axi_spi_rready),
            .io0_i('0), .io0_o(spi_mosi), .io0_t(),
            .io1_i(spi_miso), .io1_o(), .io1_t(),
            .ss_i('0), .ss_o(spi_ss), .ss_t(),
            .sck_o(spi_clk_o), .sck_i('0), .sck_t(),
            .ip2intc_irpt(irq_sources[1])
        );
    end else begin
        assign spi_clk_o = 1'b0; assign spi_mosi = 1'b0; assign spi_ss = 1'b0;
        assign spi.aw_ready = 1'b1; assign spi.ar_ready = 1'b1; assign spi.w_ready = 1'b1;
        assign spi.b_valid = spi.aw_valid; assign spi.b_id = spi.aw_id;
        assign spi.b_resp = axi_pkg::RESP_SLVERR; assign spi.b_user = '0;
        assign spi.r_valid = spi.ar_valid; assign spi.r_resp = axi_pkg::RESP_SLVERR;
        assign spi.r_data = 'hdeadbeef; assign spi.r_last = 1'b1;
    end

    // -----------------------------------------------------------------------
    //  4. Ethernet
    // -----------------------------------------------------------------------
    if (InclEthernet) begin : gen_ethernet
        logic eth_en, eth_we, eth_int_n, eth_pme_n, eth_mdio_i, eth_mdio_o, eth_mdio_oe;
        logic [AxiAddrWidth-1:0]   eth_addr;
        logic [AxiDataWidth-1:0]   eth_wrdata, eth_rdata;
        logic [AxiDataWidth/8-1:0] eth_be;

        axi2mem #(
            .AXI_ID_WIDTH(AxiIdWidth), .AXI_ADDR_WIDTH(AxiAddrWidth),
            .AXI_DATA_WIDTH(AxiDataWidth), .AXI_USER_WIDTH(AxiUserWidth)
        ) i_axi2rom (
            .clk_i(clk_i), .rst_ni(rst_ni), .slave(ethernet),
            .req_o(eth_en), .we_o(eth_we), .addr_o(eth_addr),
            .be_o(eth_be), .data_o(eth_wrdata), .data_i(eth_rdata)
        );

        framing_top eth_rgmii (
            .msoc_clk(clk_i),          .core_lsu_addr(eth_addr[14:0]),
            .core_lsu_wdata(eth_wrdata),.core_lsu_be(eth_be),
            .ce_d(eth_en),             .we_d(eth_en & eth_we),
            .framing_sel(eth_en),      .framing_rdata(eth_rdata),
            .rst_int(!rst_ni),         .clk_int(phy_tx_clk_i),
            .clk90_int(eth_clk_i),     .clk_200_int(clk_200MHz_i),
            .phy_rx_clk(eth_rxck),     .phy_rxd(eth_rxd),
            .phy_rx_ctl(eth_rxctl),    .phy_tx_clk(eth_txck),
            .phy_txd(eth_txd),         .phy_tx_ctl(eth_txctl),
            .phy_reset_n(eth_rst_n),   .phy_int_n(eth_int_n),
            .phy_pme_n(eth_pme_n),     .phy_mdc(eth_mdc),
            .phy_mdio_i(eth_mdio_i),   .phy_mdio_o(eth_mdio_o),
            .phy_mdio_oe(eth_mdio_oe), .eth_irq(irq_sources[2])
        );

        IOBUF #(.DRIVE(12), .IBUF_LOW_PWR("TRUE"), .IOSTANDARD("DEFAULT"), .SLEW("SLOW"))
        IOBUF_inst (.O(eth_mdio_i), .IO(eth_mdio), .I(eth_mdio_o), .T(~eth_mdio_oe));

    end else begin
        assign irq_sources[2]    = 1'b0;
        assign ethernet.aw_ready = 1'b1; assign ethernet.ar_ready = 1'b1;
        assign ethernet.w_ready  = 1'b1;
        assign ethernet.b_valid  = ethernet.aw_valid; assign ethernet.b_id = ethernet.aw_id;
        assign ethernet.b_resp   = axi_pkg::RESP_SLVERR; assign ethernet.b_user = '0;
        assign ethernet.r_valid  = ethernet.ar_valid;
        assign ethernet.r_resp   = axi_pkg::RESP_SLVERR;
        assign ethernet.r_data   = 'hdeadbeef; assign ethernet.r_last = 1'b1;
    end

    // -----------------------------------------------------------------------
    //  5. GPIO
    // -----------------------------------------------------------------------
    assign gpio.b_user = 1'b0;
    assign gpio.r_user = 1'b0;

    if (InclGPIO) begin : gen_gpio
        logic [31:0] s_axi_gpio_awaddr, s_axi_gpio_araddr, s_axi_gpio_wdata, s_axi_gpio_rdata;
        logic [7:0]  s_axi_gpio_awlen, s_axi_gpio_arlen;
        logic [2:0]  s_axi_gpio_awsize, s_axi_gpio_arsize;
        logic [1:0]  s_axi_gpio_awburst, s_axi_gpio_arburst, s_axi_gpio_bresp, s_axi_gpio_rresp;
        logic [3:0]  s_axi_gpio_awcache, s_axi_gpio_arcache, s_axi_gpio_wstrb;
        logic        s_axi_gpio_awvalid, s_axi_gpio_awready, s_axi_gpio_wvalid, s_axi_gpio_wready;
        logic        s_axi_gpio_bvalid,  s_axi_gpio_bready,  s_axi_gpio_arvalid, s_axi_gpio_arready;
        logic        s_axi_gpio_rlast,   s_axi_gpio_rvalid,  s_axi_gpio_rready;

        xlnx_axi_dwidth_converter i_xlnx_axi_dwidth_converter_gpio (
            .s_axi_aclk(clk_i),          .s_axi_aresetn(rst_ni),
            .s_axi_awid(gpio.aw_id),      .s_axi_awaddr(gpio.aw_addr[31:0]),
            .s_axi_awlen(gpio.aw_len),    .s_axi_awsize(gpio.aw_size),
            .s_axi_awburst(gpio.aw_burst),.s_axi_awlock(gpio.aw_lock),
            .s_axi_awcache(gpio.aw_cache),.s_axi_awprot(gpio.aw_prot),
            .s_axi_awregion(gpio.aw_region),.s_axi_awqos(gpio.aw_qos),
            .s_axi_awvalid(gpio.aw_valid),.s_axi_awready(gpio.aw_ready),
            .s_axi_wdata(gpio.w_data),    .s_axi_wstrb(gpio.w_strb),
            .s_axi_wlast(gpio.w_last),    .s_axi_wvalid(gpio.w_valid),
            .s_axi_wready(gpio.w_ready),  .s_axi_bid(gpio.b_id),
            .s_axi_bresp(gpio.b_resp),    .s_axi_bvalid(gpio.b_valid),
            .s_axi_bready(gpio.b_ready),  .s_axi_arid(gpio.ar_id),
            .s_axi_araddr(gpio.ar_addr[31:0]),.s_axi_arlen(gpio.ar_len),
            .s_axi_arsize(gpio.ar_size),  .s_axi_arburst(gpio.ar_burst),
            .s_axi_arlock(gpio.ar_lock),  .s_axi_arcache(gpio.ar_cache),
            .s_axi_arprot(gpio.ar_prot),  .s_axi_arregion(gpio.ar_region),
            .s_axi_arqos(gpio.ar_qos),    .s_axi_arvalid(gpio.ar_valid),
            .s_axi_arready(gpio.ar_ready),.s_axi_rid(gpio.r_id),
            .s_axi_rdata(gpio.r_data),    .s_axi_rresp(gpio.r_resp),
            .s_axi_rlast(gpio.r_last),    .s_axi_rvalid(gpio.r_valid),
            .s_axi_rready(gpio.r_ready),
            .m_axi_awaddr(s_axi_gpio_awaddr),  .m_axi_awlen(s_axi_gpio_awlen),
            .m_axi_awsize(s_axi_gpio_awsize),  .m_axi_awburst(s_axi_gpio_awburst),
            .m_axi_awlock(),                    .m_axi_awcache(s_axi_gpio_awcache),
            .m_axi_awprot(),                    .m_axi_awregion(), .m_axi_awqos(),
            .m_axi_awvalid(s_axi_gpio_awvalid),.m_axi_awready(s_axi_gpio_awready),
            .m_axi_wdata(s_axi_gpio_wdata),    .m_axi_wstrb(s_axi_gpio_wstrb),
            .m_axi_wlast(),                     .m_axi_wvalid(s_axi_gpio_wvalid),
            .m_axi_wready(s_axi_gpio_wready),  .m_axi_bresp(s_axi_gpio_bresp),
            .m_axi_bvalid(s_axi_gpio_bvalid),  .m_axi_bready(s_axi_gpio_bready),
            .m_axi_araddr(s_axi_gpio_araddr),  .m_axi_arlen(s_axi_gpio_arlen),
            .m_axi_arsize(s_axi_gpio_arsize),  .m_axi_arburst(s_axi_gpio_arburst),
            .m_axi_arlock(),                    .m_axi_arcache(s_axi_gpio_arcache),
            .m_axi_arprot(),                    .m_axi_arregion(), .m_axi_arqos(),
            .m_axi_arvalid(s_axi_gpio_arvalid),.m_axi_arready(s_axi_gpio_arready),
            .m_axi_rdata(s_axi_gpio_rdata),    .m_axi_rresp(s_axi_gpio_rresp),
            .m_axi_rlast(s_axi_gpio_rlast),    .m_axi_rvalid(s_axi_gpio_rvalid),
            .m_axi_rready(s_axi_gpio_rready)
        );

        xlnx_axi_gpio i_xlnx_axi_gpio (
            .s_axi_aclk(clk_i), .s_axi_aresetn(rst_ni),
            .s_axi_awaddr(s_axi_gpio_awaddr[8:0]), .s_axi_awvalid(s_axi_gpio_awvalid),
            .s_axi_awready(s_axi_gpio_awready),    .s_axi_wdata(s_axi_gpio_wdata),
            .s_axi_wstrb(s_axi_gpio_wstrb),        .s_axi_wvalid(s_axi_gpio_wvalid),
            .s_axi_wready(s_axi_gpio_wready),      .s_axi_bresp(s_axi_gpio_bresp),
            .s_axi_bvalid(s_axi_gpio_bvalid),      .s_axi_bready(s_axi_gpio_bready),
            .s_axi_araddr(s_axi_gpio_araddr[8:0]), .s_axi_arvalid(s_axi_gpio_arvalid),
            .s_axi_arready(s_axi_gpio_arready),    .s_axi_rdata(s_axi_gpio_rdata),
            .s_axi_rresp(s_axi_gpio_rresp),        .s_axi_rvalid(s_axi_gpio_rvalid),
            .s_axi_rready(s_axi_gpio_rready),
            .gpio_io_i('0), .gpio_io_o(leds_o), .gpio_io_t(),
            .gpio2_io_i(dip_switches_i)
        );
        assign s_axi_gpio_rlast = 1'b1;
    end

    // -----------------------------------------------------------------------
    //  6. Timer
    // -----------------------------------------------------------------------
    if (InclTimer) begin : gen_timer
        logic [31:0] timer_paddr, timer_pwdata, timer_prdata;
        logic        timer_penable, timer_pwrite, timer_psel, timer_pready, timer_pslverr;

        axi2apb_64_32 #(
            .AXI4_ADDRESS_WIDTH(AxiAddrWidth), .AXI4_RDATA_WIDTH(AxiDataWidth),
            .AXI4_WDATA_WIDTH(AxiDataWidth),   .AXI4_ID_WIDTH(AxiIdWidth),
            .AXI4_USER_WIDTH(AxiUserWidth),    .BUFF_DEPTH_SLAVE(2), .APB_ADDR_WIDTH(32)
        ) i_axi2apb_64_32_timer (
            .ACLK(clk_i), .ARESETn(rst_ni), .test_en_i(1'b0),
            .AWID_i(timer.aw_id),     .AWADDR_i(timer.aw_addr),   .AWLEN_i(timer.aw_len),
            .AWSIZE_i(timer.aw_size), .AWBURST_i(timer.aw_burst), .AWLOCK_i(timer.aw_lock),
            .AWCACHE_i(timer.aw_cache),.AWPROT_i(timer.aw_prot),  .AWREGION_i(timer.aw_region),
            .AWUSER_i(timer.aw_user), .AWQOS_i(timer.aw_qos),     .AWVALID_i(timer.aw_valid),
            .AWREADY_o(timer.aw_ready),.WDATA_i(timer.w_data),    .WSTRB_i(timer.w_strb),
            .WLAST_i(timer.w_last),   .WUSER_i(timer.w_user),     .WVALID_i(timer.w_valid),
            .WREADY_o(timer.w_ready), .BID_o(timer.b_id),         .BRESP_o(timer.b_resp),
            .BVALID_o(timer.b_valid), .BUSER_o(timer.b_user),     .BREADY_i(timer.b_ready),
            .ARID_i(timer.ar_id),     .ARADDR_i(timer.ar_addr),   .ARLEN_i(timer.ar_len),
            .ARSIZE_i(timer.ar_size), .ARBURST_i(timer.ar_burst), .ARLOCK_i(timer.ar_lock),
            .ARCACHE_i(timer.ar_cache),.ARPROT_i(timer.ar_prot),  .ARREGION_i(timer.ar_region),
            .ARUSER_i(timer.ar_user), .ARQOS_i(timer.ar_qos),     .ARVALID_i(timer.ar_valid),
            .ARREADY_o(timer.ar_ready),.RID_o(timer.r_id),        .RDATA_o(timer.r_data),
            .RRESP_o(timer.r_resp),   .RLAST_o(timer.r_last),     .RUSER_o(timer.r_user),
            .RVALID_o(timer.r_valid), .RREADY_i(timer.r_ready),
            .PENABLE(timer_penable),  .PWRITE(timer_pwrite),       .PADDR(timer_paddr),
            .PSEL(timer_psel),        .PWDATA(timer_pwdata),       .PRDATA(timer_prdata),
            .PREADY(timer_pready),    .PSLVERR(timer_pslverr)
        );

        apb_timer #(.APB_ADDR_WIDTH(32), .TIMER_CNT(2)) i_timer (
            .HCLK(clk_i), .HRESETn(rst_ni),
            .PSEL(timer_psel), .PENABLE(timer_penable), .PWRITE(timer_pwrite),
            .PADDR(timer_paddr), .PWDATA(timer_pwdata), .PRDATA(timer_prdata),
            .PREADY(timer_pready), .PSLVERR(timer_pslverr), .irq_o(irq_sources[6:3])
        );
    end

    // =======================================================================
    //  7. Accélérateurs DMA + security wrappers + IOMMU
    // =======================================================================


    // Bus entre device(s) et IOMMU TR IF
    ariane_axi_soc::req_mmu_t  axi_iommu_tr_req;
    ariane_axi_soc::resp_t     axi_iommu_tr_rsp;

    // Bus XBAR → IOMMU programming IF
    ariane_axi_soc::req_slv_t  axi_iommu_cfg_req;
    ariane_axi_soc::resp_slv_t axi_iommu_cfg_rsp;
    `AXI_ASSIGN_TO_REQ(axi_iommu_cfg_req, iommu_cfg)
    `AXI_ASSIGN_FROM_RESP(iommu_cfg, axi_iommu_cfg_rsp)

    if (InclDMA) begin : gen_dma

        // -------------------------------------------------------------------
        //  Accélérateur 1
        // -------------------------------------------------------------------
        AXI_BUS_MMU #(
            .AXI_ADDR_WIDTH ( AxiAddrWidth            ),
            .AXI_DATA_WIDTH ( AxiDataWidth            ),
            .AXI_ID_WIDTH   ( ariane_soc::IdWidth - 1 ),
            .AXI_USER_WIDTH ( AxiUserWidth            )
        ) accel1_dma (), accel1_sec ();

        // Verdicts ARMOR du sec_wrapper #1, reboucles vers le registre STATUS
        // de l'accelerateur (bits 3..7). Declare ici pour precede son usage.
        logic [4:0] armor_verdict1;

        accel_wrap #(
            .AXI_ADDR_WIDTH   ( AxiAddrWidth             ),
            .AXI_DATA_WIDTH   ( AxiDataWidth             ),
            .AXI_ID_WIDTH     ( ariane_soc::IdWidth - 1  ),
            .AXI_USER_WIDTH   ( AxiUserWidth             ),
            .AXI_SLV_ID_WIDTH ( ariane_soc::IdWidthSlave ),
            .STREAM_ID        ( 24'd1                    )
        ) i_accel1 (
            .clk_i, .rst_ni, .testmode_i(1'b0),
            .axi_cfg ( dma_cfg    ),
            .axi_dma ( accel1_dma ),
            .armor_status_i ( armor_verdict1 ),
            .btnu_i  ( btnu_i     ),
            .btnd_i  ( btnd_i     ),
            .btnl_i  ( btnl_i     ),
            .btnr_i  ( btnr_i     ),
            .btnc_i  ( btnc_i     )
        );

        // Conversion accel1_dma → structs pour le security wrapper
        ariane_axi_soc::req_mmu_t  req_accel1_in;
        ariane_axi_soc::resp_slv_t resp_accel1_in;
        ariane_axi_soc::req_mmu_t  req_accel1_out;
        // resp_slv_t, PAS resp_t : wrapper.resp_wrapper_iommu_i est declare
        // resp_slv_t (88 bits, ids sur 6 bits). Y raccorder un resp_t (84 bits,
        // ids sur 4 bits) fait completer par des zeros du cote MSB, ce qui
        // decale tous les champs : aw_ready/ar_ready/w_ready/b_valid vus par
        // ARMOR tombent a 0 en permanence et r_valid recupere b.resp[0]. ARMOR
        // ne voyait donc jamais l'aval accepter ni repondre, et aucune
        // transaction ne pouvait aboutir -- d'ou le "zero verdict DONE" de
        // toutes les campagnes. Reproduit et corrige dans armor/tb.
        ariane_axi_soc::resp_slv_t resp_accel1_out;
        ariane_axi_soc::req_slv_t  req_cpu_wrap1;
        ariane_axi_soc::resp_slv_t resp_cpu_wrap1;

            assign req_accel1_in.aw_valid        = accel1_dma.aw_valid;
            assign req_accel1_in.aw.id             = accel1_dma.aw_id;
            assign req_accel1_in.aw.addr           = accel1_dma.aw_addr;
            assign req_accel1_in.aw.len            = accel1_dma.aw_len;
            assign req_accel1_in.aw.size           = accel1_dma.aw_size;
            assign req_accel1_in.aw.burst          = accel1_dma.aw_burst;
            assign req_accel1_in.aw.lock           = accel1_dma.aw_lock;
            assign req_accel1_in.aw.cache          = accel1_dma.aw_cache;
            assign req_accel1_in.aw.prot           = accel1_dma.aw_prot;
            assign req_accel1_in.aw.qos            = accel1_dma.aw_qos;
            assign req_accel1_in.aw.region         = accel1_dma.aw_region;
            assign req_accel1_in.aw.atop           = accel1_dma.aw_atop;
            assign req_accel1_in.aw.user           = accel1_dma.aw_user;
            assign req_accel1_in.aw.stream_id      = accel1_dma.aw_stream_id;
            assign req_accel1_in.aw.ss_id_valid    = accel1_dma.aw_ss_id_valid;
            assign req_accel1_in.aw.substream_id   = accel1_dma.aw_substream_id;
            assign req_accel1_in.ar_valid        = accel1_dma.ar_valid;
            assign req_accel1_in.ar.id             = accel1_dma.ar_id;
            assign req_accel1_in.ar.addr           = accel1_dma.ar_addr;
            assign req_accel1_in.ar.len            = accel1_dma.ar_len;
            assign req_accel1_in.ar.size           = accel1_dma.ar_size;
            assign req_accel1_in.ar.burst          = accel1_dma.ar_burst;
            assign req_accel1_in.ar.lock           = accel1_dma.ar_lock;
            assign req_accel1_in.ar.cache          = accel1_dma.ar_cache;
            assign req_accel1_in.ar.prot           = accel1_dma.ar_prot;
            assign req_accel1_in.ar.qos            = accel1_dma.ar_qos;
            assign req_accel1_in.ar.region         = accel1_dma.ar_region;
            assign req_accel1_in.ar.user           = accel1_dma.ar_user;
            assign req_accel1_in.ar.stream_id      = accel1_dma.ar_stream_id;
            assign req_accel1_in.ar.ss_id_valid    = accel1_dma.ar_ss_id_valid;
            assign req_accel1_in.ar.substream_id   = accel1_dma.ar_substream_id;
            assign req_accel1_in.w_valid  = accel1_dma.w_valid;
            assign req_accel1_in.w.data   = accel1_dma.w_data;
            assign req_accel1_in.w.strb   = accel1_dma.w_strb;
            assign req_accel1_in.w.last   = accel1_dma.w_last;
            assign req_accel1_in.w.user   = accel1_dma.w_user;
            assign req_accel1_in.b_ready  = accel1_dma.b_ready;
            assign req_accel1_in.r_ready  = accel1_dma.r_ready;
            assign accel1_dma.aw_ready = resp_accel1_in.aw_ready;
            assign accel1_dma.w_ready  = resp_accel1_in.w_ready;
            assign accel1_dma.b_valid  = resp_accel1_in.b_valid;
            assign accel1_dma.b_id     = resp_accel1_in.b.id[ariane_soc::IdWidth - 2:0];
            assign accel1_dma.b_resp   = resp_accel1_in.b.resp;
            assign accel1_dma.b_user   = resp_accel1_in.b.user;
            assign accel1_dma.ar_ready = resp_accel1_in.ar_ready;
            assign accel1_dma.r_valid  = resp_accel1_in.r_valid;
            assign accel1_dma.r_id     = resp_accel1_in.r.id[ariane_soc::IdWidth - 2:0];
            assign accel1_dma.r_data   = resp_accel1_in.r.data;
            assign accel1_dma.r_resp   = resp_accel1_in.r.resp;
            assign accel1_dma.r_last   = resp_accel1_in.r.last;
            assign accel1_dma.r_user   = resp_accel1_in.r.user;
            assign accel1_sec.aw_valid          = req_accel1_out.aw_valid;
            assign accel1_sec.aw_id             = req_accel1_out.aw.id;
            assign accel1_sec.aw_addr           = req_accel1_out.aw.addr;
            assign accel1_sec.aw_len            = req_accel1_out.aw.len;
            assign accel1_sec.aw_size           = req_accel1_out.aw.size;
            assign accel1_sec.aw_burst          = req_accel1_out.aw.burst;
            assign accel1_sec.aw_lock           = req_accel1_out.aw.lock;
            assign accel1_sec.aw_cache          = req_accel1_out.aw.cache;
            assign accel1_sec.aw_prot           = req_accel1_out.aw.prot;
            assign accel1_sec.aw_qos            = req_accel1_out.aw.qos;
            assign accel1_sec.aw_region         = req_accel1_out.aw.region;
            assign accel1_sec.aw_atop           = req_accel1_out.aw.atop;
            assign accel1_sec.aw_user           = req_accel1_out.aw.user;
            assign accel1_sec.aw_stream_id      = req_accel1_out.aw.stream_id;
            assign accel1_sec.aw_ss_id_valid    = req_accel1_out.aw.ss_id_valid;
            assign accel1_sec.aw_substream_id   = req_accel1_out.aw.substream_id;
            assign accel1_sec.ar_valid          = req_accel1_out.ar_valid;
            assign accel1_sec.ar_id             = req_accel1_out.ar.id;
            assign accel1_sec.ar_addr           = req_accel1_out.ar.addr;
            assign accel1_sec.ar_len            = req_accel1_out.ar.len;
            assign accel1_sec.ar_size           = req_accel1_out.ar.size;
            assign accel1_sec.ar_burst          = req_accel1_out.ar.burst;
            assign accel1_sec.ar_lock           = req_accel1_out.ar.lock;
            assign accel1_sec.ar_cache          = req_accel1_out.ar.cache;
            assign accel1_sec.ar_prot           = req_accel1_out.ar.prot;
            assign accel1_sec.ar_qos            = req_accel1_out.ar.qos;
            assign accel1_sec.ar_region         = req_accel1_out.ar.region;
            assign accel1_sec.ar_user           = req_accel1_out.ar.user;
            assign accel1_sec.ar_stream_id      = req_accel1_out.ar.stream_id;
            assign accel1_sec.ar_ss_id_valid    = req_accel1_out.ar.ss_id_valid;
            assign accel1_sec.ar_substream_id   = req_accel1_out.ar.substream_id;
            assign accel1_sec.w_valid  = req_accel1_out.w_valid;
            assign accel1_sec.w_data   = req_accel1_out.w.data;
            assign accel1_sec.w_strb   = req_accel1_out.w.strb;
            assign accel1_sec.w_last   = req_accel1_out.w.last;
            assign accel1_sec.w_user   = req_accel1_out.w.user;
            assign accel1_sec.b_ready  = req_accel1_out.b_ready;
            assign accel1_sec.r_ready  = req_accel1_out.r_ready;
            assign resp_accel1_out.aw_ready = accel1_sec.aw_ready;
            assign resp_accel1_out.w_ready  = accel1_sec.w_ready;
            assign resp_accel1_out.ar_ready = accel1_sec.ar_ready;
            assign resp_accel1_out.b_valid  = accel1_sec.b_valid;
            assign resp_accel1_out.b.id     = accel1_sec.b_id;
            assign resp_accel1_out.b.resp   = accel1_sec.b_resp;
            assign resp_accel1_out.b.user   = accel1_sec.b_user;
            assign resp_accel1_out.r_valid  = accel1_sec.r_valid;
            assign resp_accel1_out.r.id     = accel1_sec.r_id;
            assign resp_accel1_out.r.data   = accel1_sec.r_data;
            assign resp_accel1_out.r.resp   = accel1_sec.r_resp;
            assign resp_accel1_out.r.last   = accel1_sec.r_last;
            assign resp_accel1_out.r.user   = accel1_sec.r_user;

        `AXI_ASSIGN_TO_REQ(req_cpu_wrap1, wrapper_cfg1)
        `AXI_ASSIGN_FROM_RESP(wrapper_cfg1, resp_cpu_wrap1)

        wrapper #(
            .IdWidth            ( ariane_soc::IdWidth - 1        ),
            .IdWidthSlv         ( ariane_soc::IdWidthSlave       ),
            .AddrWidth          ( AxiAddrWidth                   ),
            .UserWidth          ( AxiUserWidth                   ),
            .DevIDWidth         ( 24                             ),
            .ProcIDWidth        ( 20                             ),
            .DataWidth          ( AxiDataWidth                   ),
            .StrbWidth          ( AxiDataWidth / 8               ),
            .aw_chan_extended_t ( ariane_axi_soc::aw_chan_mmu_t  ),
            .aw_chan_slv_t      ( ariane_axi_soc::aw_chan_slv_t  ),
            .aw_chan_t          ( ariane_axi_soc::aw_chan_t       ),
            .w_chan_t           ( ariane_axi_soc::w_chan_t        ),
            .b_chan_t           ( ariane_axi_soc::b_chan_t        ),
            .b_chan_slv_t       ( ariane_axi_soc::b_chan_slv_t   ),
            .ar_chan_extended_t ( ariane_axi_soc::ar_chan_mmu_t  ),
            .ar_chan_slv_t      ( ariane_axi_soc::ar_chan_slv_t  ),
            .ar_chan_t          ( ariane_axi_soc::ar_chan_t       ),
            .r_chan_t           ( ariane_axi_soc::r_chan_t        ),
            .r_chan_slv_t       ( ariane_axi_soc::r_chan_slv_t   ),
            .req_t              ( ariane_axi_soc::req_t          ),
            .req_slv_t          ( ariane_axi_soc::req_slv_t      ),
            .resp_t             ( ariane_axi_soc::resp_t         ),
            .resp_slv_t         ( ariane_axi_soc::resp_slv_t     ),
            .req_iommu_t        ( ariane_axi_soc::req_mmu_t      )
        ) i_sec_wrap1 (
            .clk_i, .rst_ni,
            .req_IP_wrapper_i    ( req_accel1_in    ),
            .resp_IP_wrapper_o   ( resp_accel1_in   ),
            .resp_wrapper_iommu_i( resp_accel1_out  ),
            .req_wrapper_iommu_o ( req_accel1_out   ),
            .req_CPU_Wrapper__i  ( req_cpu_wrap1    ),
            .resp_CPU_Wrapper_o  ( resp_cpu_wrap1   ),
            .armor_verdict_o     ( armor_verdict1   )
        );

        // -------------------------------------------------------------------
        //  Accélérateur 2 + axi_mux 2:1
        // -------------------------------------------------------------------
        if (InclDMA2) begin : gen_accel2

            AXI_BUS_MMU #(
                .AXI_ADDR_WIDTH ( AxiAddrWidth            ),
                .AXI_DATA_WIDTH ( AxiDataWidth            ),
                .AXI_ID_WIDTH   ( ariane_soc::IdWidth - 1 ),
                .AXI_USER_WIDTH ( AxiUserWidth            )
            ) accel2_dma (), accel2_sec ();

            logic [4:0] armor_verdict2;

            accel_wrap #(
                .AXI_ADDR_WIDTH   ( AxiAddrWidth             ),
                .AXI_DATA_WIDTH   ( AxiDataWidth             ),
                .AXI_ID_WIDTH     ( ariane_soc::IdWidth - 1  ),
                .AXI_USER_WIDTH   ( AxiUserWidth             ),
                .AXI_SLV_ID_WIDTH ( ariane_soc::IdWidthSlave ),
                .STREAM_ID        ( 24'd2                    )
            ) i_accel2 (
                .clk_i, .rst_ni, .testmode_i(1'b0),
                .axi_cfg ( dma_cfg2   ),
                .axi_dma ( accel2_dma ),
                .armor_status_i ( armor_verdict2 ),
                // main.c lit BTN_STATE a MHA_BASE+0x58 = 0x5000_1058, donc sur
                // CET accelerateur : les boutons etaient cables a 1'b0 ici, la
                // demo interactive ne pouvait pas les voir.
                .btnu_i  ( btnu_i     ),
                .btnd_i  ( btnd_i     ),
                .btnl_i  ( btnl_i     ),
                .btnr_i  ( btnr_i     ),
                .btnc_i  ( btnc_i     )
            );

            ariane_axi_soc::req_mmu_t  req_accel2_in;
            ariane_axi_soc::resp_slv_t resp_accel2_in;
            ariane_axi_soc::req_mmu_t  req_accel2_out;
            // Meme correctif que pour resp_accel1_out ci-dessus.
            ariane_axi_soc::resp_slv_t resp_accel2_out;
            ariane_axi_soc::req_slv_t  req_cpu_wrap2;
            ariane_axi_soc::resp_slv_t resp_cpu_wrap2;

                assign req_accel2_in.aw_valid        = accel2_dma.aw_valid;
                assign req_accel2_in.aw.id             = accel2_dma.aw_id;
                assign req_accel2_in.aw.addr           = accel2_dma.aw_addr;
                assign req_accel2_in.aw.len            = accel2_dma.aw_len;
                assign req_accel2_in.aw.size           = accel2_dma.aw_size;
                assign req_accel2_in.aw.burst          = accel2_dma.aw_burst;
                assign req_accel2_in.aw.lock           = accel2_dma.aw_lock;
                assign req_accel2_in.aw.cache          = accel2_dma.aw_cache;
                assign req_accel2_in.aw.prot           = accel2_dma.aw_prot;
                assign req_accel2_in.aw.qos            = accel2_dma.aw_qos;
                assign req_accel2_in.aw.region         = accel2_dma.aw_region;
                assign req_accel2_in.aw.atop           = accel2_dma.aw_atop;
                assign req_accel2_in.aw.user           = accel2_dma.aw_user;
                assign req_accel2_in.aw.stream_id      = accel2_dma.aw_stream_id;
                assign req_accel2_in.aw.ss_id_valid    = accel2_dma.aw_ss_id_valid;
                assign req_accel2_in.aw.substream_id   = accel2_dma.aw_substream_id;
                assign req_accel2_in.ar_valid        = accel2_dma.ar_valid;
                assign req_accel2_in.ar.id             = accel2_dma.ar_id;
                assign req_accel2_in.ar.addr           = accel2_dma.ar_addr;
                assign req_accel2_in.ar.len            = accel2_dma.ar_len;
                assign req_accel2_in.ar.size           = accel2_dma.ar_size;
                assign req_accel2_in.ar.burst          = accel2_dma.ar_burst;
                assign req_accel2_in.ar.lock           = accel2_dma.ar_lock;
                assign req_accel2_in.ar.cache          = accel2_dma.ar_cache;
                assign req_accel2_in.ar.prot           = accel2_dma.ar_prot;
                assign req_accel2_in.ar.qos            = accel2_dma.ar_qos;
                assign req_accel2_in.ar.region         = accel2_dma.ar_region;
                assign req_accel2_in.ar.user           = accel2_dma.ar_user;
                assign req_accel2_in.ar.stream_id      = accel2_dma.ar_stream_id;
                assign req_accel2_in.ar.ss_id_valid    = accel2_dma.ar_ss_id_valid;
                assign req_accel2_in.ar.substream_id   = accel2_dma.ar_substream_id;
                assign req_accel2_in.w_valid  = accel2_dma.w_valid;
                assign req_accel2_in.w.data   = accel2_dma.w_data;
                assign req_accel2_in.w.strb   = accel2_dma.w_strb;
                assign req_accel2_in.w.last   = accel2_dma.w_last;
                assign req_accel2_in.w.user   = accel2_dma.w_user;
                assign req_accel2_in.b_ready  = accel2_dma.b_ready;
                assign req_accel2_in.r_ready  = accel2_dma.r_ready;
                assign accel2_dma.aw_ready = resp_accel2_in.aw_ready;
                assign accel2_dma.w_ready  = resp_accel2_in.w_ready;
                assign accel2_dma.b_valid  = resp_accel2_in.b_valid;
                assign accel2_dma.b_id     = resp_accel2_in.b.id[ariane_soc::IdWidth - 2:0];
                assign accel2_dma.b_resp   = resp_accel2_in.b.resp;
                assign accel2_dma.b_user   = resp_accel2_in.b.user;
                assign accel2_dma.ar_ready = resp_accel2_in.ar_ready;
                assign accel2_dma.r_valid  = resp_accel2_in.r_valid;
                assign accel2_dma.r_id     = resp_accel2_in.r.id[ariane_soc::IdWidth - 2:0];
                assign accel2_dma.r_data   = resp_accel2_in.r.data;
                assign accel2_dma.r_resp   = resp_accel2_in.r.resp;
                assign accel2_dma.r_last   = resp_accel2_in.r.last;
                assign accel2_dma.r_user   = resp_accel2_in.r.user;
                assign accel2_sec.aw_valid          = req_accel2_out.aw_valid;
                assign accel2_sec.aw_id             = req_accel2_out.aw.id;
                assign accel2_sec.aw_addr           = req_accel2_out.aw.addr;
                assign accel2_sec.aw_len            = req_accel2_out.aw.len;
                assign accel2_sec.aw_size           = req_accel2_out.aw.size;
                assign accel2_sec.aw_burst          = req_accel2_out.aw.burst;
                assign accel2_sec.aw_lock           = req_accel2_out.aw.lock;
                assign accel2_sec.aw_cache          = req_accel2_out.aw.cache;
                assign accel2_sec.aw_prot           = req_accel2_out.aw.prot;
                assign accel2_sec.aw_qos            = req_accel2_out.aw.qos;
                assign accel2_sec.aw_region         = req_accel2_out.aw.region;
                assign accel2_sec.aw_atop           = req_accel2_out.aw.atop;
                assign accel2_sec.aw_user           = req_accel2_out.aw.user;
                assign accel2_sec.aw_stream_id      = req_accel2_out.aw.stream_id;
                assign accel2_sec.aw_ss_id_valid    = req_accel2_out.aw.ss_id_valid;
                assign accel2_sec.aw_substream_id   = req_accel2_out.aw.substream_id;
                assign accel2_sec.ar_valid          = req_accel2_out.ar_valid;
                assign accel2_sec.ar_id             = req_accel2_out.ar.id;
                assign accel2_sec.ar_addr           = req_accel2_out.ar.addr;
                assign accel2_sec.ar_len            = req_accel2_out.ar.len;
                assign accel2_sec.ar_size           = req_accel2_out.ar.size;
                assign accel2_sec.ar_burst          = req_accel2_out.ar.burst;
                assign accel2_sec.ar_lock           = req_accel2_out.ar.lock;
                assign accel2_sec.ar_cache          = req_accel2_out.ar.cache;
                assign accel2_sec.ar_prot           = req_accel2_out.ar.prot;
                assign accel2_sec.ar_qos            = req_accel2_out.ar.qos;
                assign accel2_sec.ar_region         = req_accel2_out.ar.region;
                assign accel2_sec.ar_user           = req_accel2_out.ar.user;
                assign accel2_sec.ar_stream_id      = req_accel2_out.ar.stream_id;
                assign accel2_sec.ar_ss_id_valid    = req_accel2_out.ar.ss_id_valid;
                assign accel2_sec.ar_substream_id   = req_accel2_out.ar.substream_id;
                assign accel2_sec.w_valid  = req_accel2_out.w_valid;
                assign accel2_sec.w_data   = req_accel2_out.w.data;
                assign accel2_sec.w_strb   = req_accel2_out.w.strb;
                assign accel2_sec.w_last   = req_accel2_out.w.last;
                assign accel2_sec.w_user   = req_accel2_out.w.user;
                assign accel2_sec.b_ready  = req_accel2_out.b_ready;
                assign accel2_sec.r_ready  = req_accel2_out.r_ready;
                assign resp_accel2_out.aw_ready = accel2_sec.aw_ready;
                assign resp_accel2_out.w_ready  = accel2_sec.w_ready;
                assign resp_accel2_out.ar_ready = accel2_sec.ar_ready;
                assign resp_accel2_out.b_valid  = accel2_sec.b_valid;
                assign resp_accel2_out.b.id     = accel2_sec.b_id;
                assign resp_accel2_out.b.resp   = accel2_sec.b_resp;
                assign resp_accel2_out.b.user   = accel2_sec.b_user;
                assign resp_accel2_out.r_valid  = accel2_sec.r_valid;
                assign resp_accel2_out.r.id     = accel2_sec.r_id;
                assign resp_accel2_out.r.data   = accel2_sec.r_data;
                assign resp_accel2_out.r.resp   = accel2_sec.r_resp;
                assign resp_accel2_out.r.last   = accel2_sec.r_last;
                assign resp_accel2_out.r.user   = accel2_sec.r_user;

            `AXI_ASSIGN_TO_REQ(req_cpu_wrap2, wrapper_cfg2)
            `AXI_ASSIGN_FROM_RESP(wrapper_cfg2, resp_cpu_wrap2)

            wrapper #(
                .IdWidth            ( ariane_soc::IdWidth - 1        ),
                .IdWidthSlv         ( ariane_soc::IdWidthSlave       ),
                .AddrWidth          ( AxiAddrWidth                   ),
                .UserWidth          ( AxiUserWidth                   ),
                .DevIDWidth         ( 24                             ),
                .ProcIDWidth        ( 20                             ),
                .DataWidth          ( AxiDataWidth                   ),
                .StrbWidth          ( AxiDataWidth / 8               ),
                .aw_chan_extended_t ( ariane_axi_soc::aw_chan_mmu_t  ),
                .aw_chan_slv_t      ( ariane_axi_soc::aw_chan_slv_t  ),
                .aw_chan_t          ( ariane_axi_soc::aw_chan_t       ),
                .w_chan_t           ( ariane_axi_soc::w_chan_t        ),
                .b_chan_t           ( ariane_axi_soc::b_chan_t        ),
                .b_chan_slv_t       ( ariane_axi_soc::b_chan_slv_t   ),
                .ar_chan_extended_t ( ariane_axi_soc::ar_chan_mmu_t  ),
                .ar_chan_slv_t      ( ariane_axi_soc::ar_chan_slv_t  ),
                .ar_chan_t          ( ariane_axi_soc::ar_chan_t       ),
                .r_chan_t           ( ariane_axi_soc::r_chan_t        ),
                .r_chan_slv_t       ( ariane_axi_soc::r_chan_slv_t   ),
                .req_t              ( ariane_axi_soc::req_t          ),
                .req_slv_t          ( ariane_axi_soc::req_slv_t      ),
                .resp_t             ( ariane_axi_soc::resp_t         ),
                .resp_slv_t         ( ariane_axi_soc::resp_slv_t     ),
                .req_iommu_t        ( ariane_axi_soc::req_mmu_t      )
            ) i_sec_wrap2 (
                .clk_i, .rst_ni,
                .req_IP_wrapper_i    ( req_accel2_in    ),
                .resp_IP_wrapper_o   ( resp_accel2_in   ),
                .resp_wrapper_iommu_i( resp_accel2_out  ),
                .req_wrapper_iommu_o ( req_accel2_out   ),
                .req_CPU_Wrapper__i  ( req_cpu_wrap2    ),
                .resp_CPU_Wrapper_o  ( resp_cpu_wrap2   ),
                .armor_verdict_o     ( armor_verdict2   )
            );

            // axi_mux 2:1 — entrées : accel1_sec, accel2_sec (sorties des wrappers)
            AXI_BUS #(
                .AXI_ID_WIDTH   ( ariane_soc::IdWidth - 1 ),
                .AXI_ADDR_WIDTH ( AxiAddrWidth            ),
                .AXI_DATA_WIDTH ( AxiDataWidth            ),
                .AXI_USER_WIDTH ( AxiUserWidth            )
            ) accel1_std (), accel2_std ();

            `AXI_ASSIGN(accel1_std, accel1_sec)
            `AXI_ASSIGN(accel2_std, accel2_sec)

            AXI_BUS #(
                .AXI_ID_WIDTH   ( ariane_soc::IdWidth ),
                .AXI_ADDR_WIDTH ( AxiAddrWidth        ),
                .AXI_DATA_WIDTH ( AxiDataWidth        ),
                .AXI_USER_WIDTH ( AxiUserWidth        )
            ) dma_muxed ();

            axi_mux_intf #(
                .SLV_AXI_ID_WIDTH ( ariane_soc::IdWidth - 1 ),
                .MST_AXI_ID_WIDTH ( ariane_soc::IdWidth     ),
                .AXI_ADDR_WIDTH   ( AxiAddrWidth            ),
                .AXI_DATA_WIDTH   ( AxiDataWidth            ),
                .AXI_USER_WIDTH   ( AxiUserWidth            ),
                .NO_SLV_PORTS     ( 2                       ),
                .MAX_W_TRANS      ( 4                       ),
                .FALL_THROUGH     ( 1'b0                    ),
                .SPILL_AW         ( 1'b1                    ),
                .SPILL_AR         ( 1'b1                    )
            ) i_dma_mux (
                .clk_i, .rst_ni, .test_i(1'b0),
                .slv ( {accel2_std, accel1_std} ),
                .mst ( dma_muxed               )
            );

            // dma_muxed → IOMMU TR IF
            // stream_id sélectionné selon le bit MSB de l'ID (0=accel1, 1=accel2)
            assign axi_iommu_tr_req.aw_valid        = dma_muxed.aw_valid;
            assign dma_muxed.aw_ready               = axi_iommu_tr_rsp.aw_ready;
            assign axi_iommu_tr_req.aw.id           = dma_muxed.aw_id;
            assign axi_iommu_tr_req.aw.addr         = dma_muxed.aw_addr;
            assign axi_iommu_tr_req.aw.len          = dma_muxed.aw_len;
            assign axi_iommu_tr_req.aw.size         = dma_muxed.aw_size;
            assign axi_iommu_tr_req.aw.burst        = dma_muxed.aw_burst;
            assign axi_iommu_tr_req.aw.lock         = dma_muxed.aw_lock;
            assign axi_iommu_tr_req.aw.cache        = dma_muxed.aw_cache;
            assign axi_iommu_tr_req.aw.prot         = dma_muxed.aw_prot;
            assign axi_iommu_tr_req.aw.qos          = dma_muxed.aw_qos;
            assign axi_iommu_tr_req.aw.region       = dma_muxed.aw_region;
            assign axi_iommu_tr_req.aw.atop         = dma_muxed.aw_atop;
            assign axi_iommu_tr_req.aw.user         = dma_muxed.aw_user;
            assign axi_iommu_tr_req.aw.stream_id    =
                dma_muxed.aw_id[ariane_soc::IdWidth-1] ?
                    accel2_sec.aw_stream_id : accel1_sec.aw_stream_id;
            assign axi_iommu_tr_req.aw.ss_id_valid  = 1'b0;
            assign axi_iommu_tr_req.aw.substream_id = 20'd0;

            assign axi_iommu_tr_req.w_valid  = dma_muxed.w_valid;
            assign dma_muxed.w_ready         = axi_iommu_tr_rsp.w_ready;
            assign axi_iommu_tr_req.w.data   = dma_muxed.w_data;
            assign axi_iommu_tr_req.w.strb   = dma_muxed.w_strb;
            assign axi_iommu_tr_req.w.last   = dma_muxed.w_last;
            assign axi_iommu_tr_req.w.user   = dma_muxed.w_user;

            assign dma_muxed.b_valid         = axi_iommu_tr_rsp.b_valid;
            assign axi_iommu_tr_req.b_ready  = dma_muxed.b_ready;
            assign dma_muxed.b_id            = axi_iommu_tr_rsp.b.id;
            assign dma_muxed.b_resp          = axi_iommu_tr_rsp.b.resp;
            assign dma_muxed.b_user          = axi_iommu_tr_rsp.b.user;

            assign axi_iommu_tr_req.ar_valid        = dma_muxed.ar_valid;
            assign dma_muxed.ar_ready               = axi_iommu_tr_rsp.ar_ready;
            assign axi_iommu_tr_req.ar.id           = dma_muxed.ar_id;
            assign axi_iommu_tr_req.ar.addr         = dma_muxed.ar_addr;
            assign axi_iommu_tr_req.ar.len          = dma_muxed.ar_len;
            assign axi_iommu_tr_req.ar.size         = dma_muxed.ar_size;
            assign axi_iommu_tr_req.ar.burst        = dma_muxed.ar_burst;
            assign axi_iommu_tr_req.ar.lock         = dma_muxed.ar_lock;
            assign axi_iommu_tr_req.ar.cache        = dma_muxed.ar_cache;
            assign axi_iommu_tr_req.ar.prot         = dma_muxed.ar_prot;
            assign axi_iommu_tr_req.ar.qos          = dma_muxed.ar_qos;
            assign axi_iommu_tr_req.ar.region       = dma_muxed.ar_region;
            assign axi_iommu_tr_req.ar.user         = dma_muxed.ar_user;
            assign axi_iommu_tr_req.ar.stream_id    =
                dma_muxed.ar_id[ariane_soc::IdWidth-1] ?
                    accel2_sec.ar_stream_id : accel1_sec.ar_stream_id;
            assign axi_iommu_tr_req.ar.ss_id_valid  = 1'b0;
            assign axi_iommu_tr_req.ar.substream_id = 20'd0;

            assign dma_muxed.r_valid         = axi_iommu_tr_rsp.r_valid;
            assign axi_iommu_tr_req.r_ready  = dma_muxed.r_ready;
            assign dma_muxed.r_id            = axi_iommu_tr_rsp.r.id;
            assign dma_muxed.r_data          = axi_iommu_tr_rsp.r.data;
            assign dma_muxed.r_resp          = axi_iommu_tr_rsp.r.resp;
            assign dma_muxed.r_last          = axi_iommu_tr_rsp.r.last;
            assign dma_muxed.r_user          = axi_iommu_tr_rsp.r.user;

        end else begin : gen_accel2_disabled

            // Un seul accélérateur — accel1_sec → IOMMU directement
            `AXI_ASSIGN_TO_REQ(axi_iommu_tr_req, accel1_sec)
            `AXI_ASSIGN_FROM_RESP(accel1_sec, axi_iommu_tr_rsp)
            assign axi_iommu_tr_req.aw.id           = {1'b0, accel1_sec.aw_id};
            assign axi_iommu_tr_req.ar.id           = {1'b0, accel1_sec.ar_id};
            assign axi_iommu_tr_req.aw.stream_id    = accel1_sec.aw_stream_id;
            assign axi_iommu_tr_req.aw.ss_id_valid  = accel1_sec.aw_ss_id_valid;
            assign axi_iommu_tr_req.aw.substream_id = accel1_sec.aw_substream_id;
            assign axi_iommu_tr_req.ar.stream_id    = accel1_sec.ar_stream_id;
            assign axi_iommu_tr_req.ar.ss_id_valid  = accel1_sec.ar_ss_id_valid;
            assign axi_iommu_tr_req.ar.substream_id = accel1_sec.ar_substream_id;

            // dma_cfg2 et wrapper_cfg2 non utilisés → esclaves d'erreur
            for (genvar i = 0; i < 2; i++) begin : gen_disabled_err
                ariane_axi_soc::req_slv_t  q; ariane_axi_soc::resp_slv_t r;
                if (i == 0) begin
                    `AXI_ASSIGN_TO_REQ(q, dma_cfg2)
                    `AXI_ASSIGN_FROM_RESP(dma_cfg2, r)
                end else begin
                    `AXI_ASSIGN_TO_REQ(q, wrapper_cfg2)
                    `AXI_ASSIGN_FROM_RESP(wrapper_cfg2, r)
                end
                axi_err_slv #(
                    .AxiIdWidth(ariane_soc::IdWidthSlave),
                    .req_t(ariane_axi_soc::req_slv_t),
                    .resp_t(ariane_axi_soc::resp_slv_t)
                ) i_err (.clk_i, .rst_ni, .test_i(1'b0),
                         .slv_req_i(q), .slv_resp_o(r));
            end

        end // gen_accel2 / gen_accel2_disabled

    end else begin : gen_dma_disabled

        // Tous les ports → esclaves d'erreur
        ariane_axi_soc::req_slv_t  q[4]; ariane_axi_soc::resp_slv_t r[4];
        `AXI_ASSIGN_TO_REQ(q[0], dma_cfg)      `AXI_ASSIGN_FROM_RESP(dma_cfg,      r[0])
        `AXI_ASSIGN_TO_REQ(q[1], dma_cfg2)     `AXI_ASSIGN_FROM_RESP(dma_cfg2,     r[1])
        `AXI_ASSIGN_TO_REQ(q[2], wrapper_cfg1) `AXI_ASSIGN_FROM_RESP(wrapper_cfg1, r[2])
        `AXI_ASSIGN_TO_REQ(q[3], wrapper_cfg2) `AXI_ASSIGN_FROM_RESP(wrapper_cfg2, r[3])

        for (genvar i = 0; i < 4; i++) begin : gen_err
            axi_err_slv #(
                .AxiIdWidth(ariane_soc::IdWidthSlave),
                .req_t(ariane_axi_soc::req_slv_t),
                .resp_t(ariane_axi_soc::resp_slv_t)
            ) i_err (.clk_i, .rst_ni, .test_i(1'b0),
                     .slv_req_i(q[i]), .slv_resp_o(r[i]));
        end

        assign axi_iommu_tr_req.ar_valid = 1'b0;
        assign axi_iommu_tr_req.aw_valid = 1'b0;
        assign axi_iommu_tr_req.w_valid  = 1'b0;
        assign axi_iommu_tr_req.b_ready  = 1'b0;
        assign axi_iommu_tr_req.r_ready  = 1'b0;

    end // gen_dma / gen_dma_disabled

    // -----------------------------------------------------------------------
    //  8. RISC-V IOMMU
    // -----------------------------------------------------------------------
    if (InclIOMMU) begin : gen_iommu

        ariane_axi_soc::req_t  axi_iommu_ds_req;
        ariane_axi_soc::resp_t axi_iommu_ds_rsp;
        `AXI_ASSIGN_FROM_REQ(iommu_ds, axi_iommu_ds_req)
        `AXI_ASSIGN_TO_RESP(axi_iommu_ds_rsp, iommu_ds)

        ariane_axi_soc::req_t  axi_iommu_comp_req;
        ariane_axi_soc::resp_t axi_iommu_comp_rsp;
        `AXI_ASSIGN_FROM_REQ(iommu_comp, axi_iommu_comp_req)
        `AXI_ASSIGN_TO_RESP(axi_iommu_comp_rsp, iommu_comp)

        `REG_BUS_TYPEDEF_ALL(iommu_reg,
            ariane_axi_soc::addr_t,
            ariane_axi_soc::data_t,
            ariane_axi_soc::strb_t)

        riscv_iommu #(
    .IOTLB_ENTRIES   ( 8                              ),
    .DDTC_ENTRIES    ( 4                              ),
    .PDTC_ENTRIES    ( 4                              ),
    .MRIFC_ENTRIES   ( 4                              ),  // [NEW]
    .InclPC          ( 1'b0                           ),
    .InclBC          ( 1'b1                           ),
    .InclDBG         ( 1'b0                           ),  // [NEW]
    .MSITrans        ( rv_iommu::MSI_FLAT_MRIF        ),  // [CHANGED] était InclMSITrans=1
    .IGS             ( rv_iommu::BOTH                 ),
    .N_INT_VEC       ( ariane_soc::IOMMUNumWires      ),
    .N_IOHPMCTR      ( 8                              ),
    .ADDR_WIDTH      ( AxiAddrWidth                   ),
    .DATA_WIDTH      ( AxiDataWidth                   ),
    .ID_WIDTH        ( ariane_soc::IdWidth            ),
    .ID_SLV_WIDTH    ( ariane_soc::IdWidthSlave       ),
    .USER_WIDTH      ( AxiUserWidth                   ),
    .aw_chan_t       ( ariane_axi_soc::aw_chan_t      ),
    .w_chan_t        ( ariane_axi_soc::w_chan_t       ),
    .b_chan_t        ( ariane_axi_soc::b_chan_t       ),
    .ar_chan_t       ( ariane_axi_soc::ar_chan_t      ),
    .r_chan_t        ( ariane_axi_soc::r_chan_t       ),
    .axi_req_t       ( ariane_axi_soc::req_t         ),
    .axi_rsp_t       ( ariane_axi_soc::resp_t        ),
    .axi_req_slv_t   ( ariane_axi_soc::req_slv_t     ),
    .axi_rsp_slv_t   ( ariane_axi_soc::resp_slv_t    ),
    .axi_req_iommu_t ( ariane_axi_soc::req_mmu_t     ),  // [CHANGED] était axi_req_mmu_t
    .reg_req_t       ( iommu_reg_req_t                ),
    .reg_rsp_t       ( iommu_reg_rsp_t                )
) i_riscv_iommu (
    .clk_i, .rst_ni,
    .dev_tr_req_i    ( axi_iommu_tr_req   ),
    .dev_tr_resp_o   ( axi_iommu_tr_rsp   ),
    .dev_comp_resp_i ( axi_iommu_comp_rsp ),
    .dev_comp_req_o  ( axi_iommu_comp_req ),
    .ds_resp_i       ( axi_iommu_ds_rsp   ),
    .ds_req_o        ( axi_iommu_ds_req   ),
    .prog_req_i      ( axi_iommu_cfg_req  ),
    .prog_resp_o     ( axi_iommu_cfg_rsp  ),
    .wsi_wires_o     ( irq_sources[(ariane_soc::IOMMUNumWires-1)+8:8] )
);

    end else begin : gen_iommu_disabled

        axi_err_slv #(
            .AxiIdWidth(ariane_soc::IdWidthSlave),
            .req_t(ariane_axi_soc::req_slv_t),
            .resp_t(ariane_axi_soc::resp_slv_t)
        ) i_iommu_err_slv (
            .clk_i, .rst_ni, .test_i(1'b0),
            .slv_req_i(axi_iommu_cfg_req), .slv_resp_o(axi_iommu_cfg_rsp)
        );

        `AXI_ASSIGN_FROM_REQ(iommu_comp, axi_iommu_tr_req)
        `AXI_ASSIGN_TO_RESP(axi_iommu_tr_rsp, iommu_comp)

        assign iommu_ds.aw_valid = 1'b0; assign iommu_ds.w_valid  = 1'b0;
        assign iommu_ds.b_ready  = 1'b0; assign iommu_ds.ar_valid = 1'b0;
        assign iommu_ds.r_ready  = 1'b0;

        assign irq_sources[(ariane_soc::IOMMUNumWires-1)+8:8] = '0;

    end // gen_iommu / gen_iommu_disabled

endmodule