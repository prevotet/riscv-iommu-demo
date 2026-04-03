// accel_A — registre identifiant
// r_data = { 0xDEAD, STREAM_ID[23:0], 0xAAAAAA }
// accel1 (STREAM_ID=1) -> 0xDEAD_000001_AAAAAA
// accel2 (STREAM_ID=2) -> 0xDEAD_000002_AAAAAA
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
    // Constante identifiant : RM=A, instance identifiée par STREAM_ID
    localparam logic [63:0] ACCEL_ID = {16'hDEAD, STREAM_ID, 24'hAAAAAA};

    // ----------------------------------------------------------------
    // CFG slave — registre en lecture seule
    // r_id, r_valid, b_id, b_valid sont registrés DANS le RP pour éviter
    // les feedthrough nets (HDPostRouteDRC-02 / PPLOC manquant).
    // ----------------------------------------------------------------
    (* dont_touch = "true" *) logic [AXI_ID_WIDTH-1:0] r_id_ff, b_id_ff;
    (* dont_touch = "true" *) logic                    r_valid_ff, b_valid_ff;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            r_id_ff    <= '0;
            b_id_ff    <= '0;
            r_valid_ff <= 1'b0;
            b_valid_ff <= 1'b0;
        end else begin
            r_id_ff    <= axi_cfg.ar_id;
            r_valid_ff <= axi_cfg.ar_valid;
            b_id_ff    <= axi_cfg.aw_id;
            b_valid_ff <= axi_cfg.aw_valid;
        end
    end

    assign axi_cfg.ar_ready = 1'b1;
    assign axi_cfg.r_valid  = r_valid_ff;
    assign axi_cfg.r_id     = r_id_ff;
    assign axi_cfg.r_data   = ACCEL_ID;
    assign axi_cfg.r_resp   = 2'b00;
    assign axi_cfg.r_last   = 1'b1;
    assign axi_cfg.r_user   = '0;

    // Écriture : acceptée mais ignorée
    assign axi_cfg.aw_ready = 1'b1;
    assign axi_cfg.w_ready  = 1'b1;
    assign axi_cfg.b_valid  = b_valid_ff;
    assign axi_cfg.b_id     = b_id_ff;
    assign axi_cfg.b_resp   = 2'b00;
    assign axi_cfg.b_user   = '0;

    // ----------------------------------------------------------------
    // DMA master — idle
    // ----------------------------------------------------------------
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