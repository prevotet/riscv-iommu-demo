// accel_blank.sv - RM vide (configuration de base DPR)
// Interface AXI tirée à idle / SLVERR.
// Remplacer par accel_A_wrap.sv ou accel_B_wrap.sv.
// Ce module a la même interface que accel_wrap dans ariane_peripherals.

(* keep_hierarchy = "yes" *)
module accel_wrap #(
    parameter int unsigned AXI_ADDR_WIDTH   = 64,
    parameter int unsigned AXI_DATA_WIDTH   = 64,
    parameter int unsigned AXI_ID_WIDTH     = 3,
    parameter int unsigned AXI_USER_WIDTH   = 1,
    parameter int unsigned AXI_SLV_ID_WIDTH = 6,
    parameter logic [23:0] STREAM_ID        = 24'd0
) (
    input  logic clk_i, rst_ni, testmode_i,
    input  logic btnu_i, btnd_i, btnl_i, btnr_i, btnc_i,
    AXI_BUS.Slave      axi_cfg,
    AXI_BUS_MMU.Master axi_dma
);
    // cfg slave : SLVERR
    // b_id/r_id pilotés par FFs internes (évite feedthrough nets → HDPostRouteDRC-02).
    // Les autres inputs AXI (ar_len, aw_len, etc.) sont ignorés et non capturés :
    // sans load interne, Vivado ne crée pas de boundary net → pas de PPLOC à router.
    (* dont_touch = "true" *) logic [AXI_SLV_ID_WIDTH-1:0] b_id_ff, r_id_ff;
    (* dont_touch = "true" *) logic                    b_valid_ff, r_valid_ff;
    (* dont_touch = "true" *) logic [AXI_DATA_WIDTH-1:0] r_data_ff;
    (* dont_touch = "true" *) logic                    r_last_ff, r_resp0_ff, r_resp1_ff;
    (* dont_touch = "true" *) logic                    b_resp0_ff, b_resp1_ff;

    always_ff @(posedge clk_i) begin
        b_id_ff    <= axi_cfg.aw_id;
        r_id_ff    <= axi_cfg.ar_id;
        b_valid_ff <= axi_cfg.aw_valid;
        r_valid_ff <= axi_cfg.ar_valid;
        r_data_ff  <= '0;
        r_last_ff  <= 1'b1;
        r_resp0_ff <= 1'b0;
        r_resp1_ff <= 1'b1;  /* SLVERR = 2'b10 */
        b_resp0_ff <= 1'b0;
        b_resp1_ff <= 1'b1;  /* SLVERR = 2'b10 */
    end

    assign axi_cfg.aw_ready = 1'b1;
    assign axi_cfg.w_ready  = 1'b1;
    assign axi_cfg.ar_ready = 1'b1;
    assign axi_cfg.b_valid  = b_valid_ff;
    assign axi_cfg.b_id     = b_id_ff;
    assign axi_cfg.b_resp   = {b_resp1_ff, b_resp0_ff};
    assign axi_cfg.b_user   = '0;
    assign axi_cfg.r_valid  = r_valid_ff;
    assign axi_cfg.r_id     = r_id_ff;
    assign axi_cfg.r_data   = r_data_ff;
    assign axi_cfg.r_resp   = {r_resp1_ff, r_resp0_ff};
    assign axi_cfg.r_last   = r_last_ff;
    assign axi_cfg.r_user   = '0;

    // DMA master : idle
    assign axi_dma.aw_valid        = 1'b0;
    assign axi_dma.aw_id           = '0;
    assign axi_dma.aw_addr         = '0;
    assign axi_dma.aw_len          = '0;
    assign axi_dma.aw_size         = '0;
    assign axi_dma.aw_burst        = '0;
    assign axi_dma.aw_lock         = '0;
    assign axi_dma.aw_cache        = '0;
    assign axi_dma.aw_prot         = '0;
    assign axi_dma.aw_qos          = '0;
    assign axi_dma.aw_region       = '0;
    assign axi_dma.aw_atop         = '0;
    assign axi_dma.aw_user         = '0;
    assign axi_dma.aw_stream_id    = '0;
    assign axi_dma.aw_ss_id_valid  = 1'b0;
    assign axi_dma.aw_substream_id = '0;
    assign axi_dma.w_valid         = 1'b0;
    assign axi_dma.w_data          = '0;
    assign axi_dma.w_strb          = '0;
    assign axi_dma.w_last          = 1'b0;
    assign axi_dma.w_user          = '0;
    assign axi_dma.b_ready         = 1'b0;
    assign axi_dma.ar_valid        = 1'b0;
    assign axi_dma.ar_id           = '0;
    assign axi_dma.ar_addr         = '0;
    assign axi_dma.ar_len          = '0;
    assign axi_dma.ar_size         = '0;
    assign axi_dma.ar_burst        = '0;
    assign axi_dma.ar_lock         = '0;
    assign axi_dma.ar_cache        = '0;
    assign axi_dma.ar_prot         = '0;
    assign axi_dma.ar_qos          = '0;
    assign axi_dma.ar_region       = '0;
    assign axi_dma.ar_user         = '0;
    assign axi_dma.ar_stream_id    = '0;
    assign axi_dma.ar_ss_id_valid  = 1'b0;
    assign axi_dma.ar_substream_id = '0;
    assign axi_dma.r_ready         = 1'b0;
endmodule