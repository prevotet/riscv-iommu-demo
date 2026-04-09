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

    // -------------------------------------------------------------------------
    // rst_n_local : capture rst_ni via pin D (FDRE sans pin CLR/R).
    // Évite le LUT1 ~rst_ni externe au pblock qui cause Route 35-54.
    // rst_ni entre dans le pblock comme donnée (PPLOC auto).
    // L'inverseur ~rst_n_local pour les FDRE internes est dans le pblock. ✓
    // -------------------------------------------------------------------------
    (* dont_touch = "true" *) logic rst_n_local;
    always_ff @(posedge clk_i) begin
        rst_n_local <= rst_ni;
    end

    // -------------------------------------------------------------------------
    // CFG slave — SLVERR
    // b_id/r_id DOIVENT être pilotés par des FFs internes au pblock
    // (HDPostRouteDRC-02). Reset synchrone → pas de LUT hors pblock.
    // -------------------------------------------------------------------------
    (* dont_touch = "true" *) logic [AXI_SLV_ID_WIDTH-1:0] b_id_ff, r_id_ff;
    (* dont_touch = "true" *) logic b_valid_ff, r_valid_ff;

    always_ff @(posedge clk_i) begin
        if (!rst_n_local) begin
            b_id_ff    <= '0;
            r_id_ff    <= '0;
            b_valid_ff <= 1'b0;
            r_valid_ff <= 1'b0;
        end else begin
            b_id_ff    <= axi_cfg.aw_id;
            r_id_ff    <= axi_cfg.ar_id;
            b_valid_ff <= axi_cfg.aw_valid;
            r_valid_ff <= axi_cfg.ar_valid;
        end
    end

    assign axi_cfg.aw_ready = 1'b1;
    assign axi_cfg.ar_ready = 1'b1;
    assign axi_cfg.w_ready  = 1'b1;
    assign axi_cfg.b_valid  = b_valid_ff;
    assign axi_cfg.b_id     = b_id_ff;
    assign axi_cfg.b_resp   = 2'b10; // SLVERR
    assign axi_cfg.b_user   = '0;
    assign axi_cfg.r_valid  = r_valid_ff;
    assign axi_cfg.r_id     = r_id_ff;
    assign axi_cfg.r_data   = '0;
    assign axi_cfg.r_resp   = 2'b10; // SLVERR
    assign axi_cfg.r_last   = 1'b1;
    assign axi_cfg.r_user   = '0;

    // -------------------------------------------------------------------------
    // DMA master — idle (constantes, pas de FF)
    // -------------------------------------------------------------------------
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
    assign axi_dma.aw_stream_id    = STREAM_ID;
    assign axi_dma.aw_ss_id_valid  = 1'b0;
    assign axi_dma.aw_substream_id = '0;

    assign axi_dma.w_valid         = 1'b0;
    assign axi_dma.w_data          = '0;
    assign axi_dma.w_strb          = '0;
    assign axi_dma.w_last          = 1'b0;
    assign axi_dma.w_user          = '0;

    assign axi_dma.b_ready         = 1'b1;

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
    assign axi_dma.ar_stream_id    = STREAM_ID;
    assign axi_dma.ar_ss_id_valid  = 1'b0;
    assign axi_dma.ar_substream_id = '0;

    assign axi_dma.r_ready         = 1'b1;

endmodule
