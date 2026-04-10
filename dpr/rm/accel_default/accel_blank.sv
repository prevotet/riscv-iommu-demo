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
    // b_id/r_id DOIVENT être pilotés par des FFs internes au pblock.
    // Un assign combinatoire depuis aw_id/ar_id crée un "feedthrough net"
    // qui entre ET sort du pblock sur le même net — Vivado ne peut pas
    // placer les PPLOCs DFX avec CONTAIN_ROUTING=true (HDPostRouteDRC-02).
    // Sink FFs : enregistrement direct (D→Q, sans LUT) de tous les signaux
    // d'entrée non utilisés. Un XOR-reduction créerait un arbre de LUTs
    // potentiellement placées hors du pblock → nets internes non routables.
    // Chaque bit va directement sur le pin D d'un FF dans le pblock → PPLOC auto.
    (* dont_touch = "true" *) logic [7:0]  sink_ar_len;
    (* dont_touch = "true" *) logic [2:0]  sink_ar_size;
    (* dont_touch = "true" *) logic [1:0]  sink_ar_burst;
    (* dont_touch = "true" *) logic        sink_ar_lock;
    (* dont_touch = "true" *) logic [3:0]  sink_ar_cache;
    (* dont_touch = "true" *) logic [2:0]  sink_ar_prot;
    (* dont_touch = "true" *) logic [3:0]  sink_ar_qos;
    (* dont_touch = "true" *) logic [3:0]  sink_ar_region;
    (* dont_touch = "true" *) logic [63:0] sink_ar_addr;
    (* dont_touch = "true" *) logic [7:0]  sink_aw_len;
    (* dont_touch = "true" *) logic [2:0]  sink_aw_size;
    (* dont_touch = "true" *) logic [1:0]  sink_aw_burst;
    (* dont_touch = "true" *) logic        sink_aw_lock;
    (* dont_touch = "true" *) logic [3:0]  sink_aw_cache;
    (* dont_touch = "true" *) logic [2:0]  sink_aw_prot;
    (* dont_touch = "true" *) logic [3:0]  sink_aw_qos;
    (* dont_touch = "true" *) logic [3:0]  sink_aw_region;
    (* dont_touch = "true" *) logic [63:0] sink_aw_addr;
    (* dont_touch = "true" *) logic [5:0]  sink_aw_atop;
    (* dont_touch = "true" *) logic [63:0] sink_w_data;
    (* dont_touch = "true" *) logic [7:0]  sink_w_strb;
    (* dont_touch = "true" *) logic        sink_w_last;
    (* dont_touch = "true" *) logic [5:0]  sink_btns;
    always_ff @(posedge clk_i) begin
        sink_ar_len    <= axi_cfg.ar_len;
        sink_ar_size   <= axi_cfg.ar_size;
        sink_ar_burst  <= axi_cfg.ar_burst;
        sink_ar_lock   <= axi_cfg.ar_lock;
        sink_ar_cache  <= axi_cfg.ar_cache;
        sink_ar_prot   <= axi_cfg.ar_prot;
        sink_ar_qos    <= axi_cfg.ar_qos;
        sink_ar_region <= axi_cfg.ar_region;
        sink_ar_addr   <= axi_cfg.ar_addr;
        sink_aw_len    <= axi_cfg.aw_len;
        sink_aw_size   <= axi_cfg.aw_size;
        sink_aw_burst  <= axi_cfg.aw_burst;
        sink_aw_lock   <= axi_cfg.aw_lock;
        sink_aw_cache  <= axi_cfg.aw_cache;
        sink_aw_prot   <= axi_cfg.aw_prot;
        sink_aw_qos    <= axi_cfg.aw_qos;
        sink_aw_region <= axi_cfg.aw_region;
        sink_aw_addr   <= axi_cfg.aw_addr;
        sink_aw_atop   <= axi_cfg.aw_atop;
        sink_w_data    <= axi_cfg.w_data;
        sink_w_strb    <= axi_cfg.w_strb;
        sink_w_last    <= axi_cfg.w_last;
        sink_btns      <= {btnu_i, btnd_i, btnl_i, btnr_i, btnc_i, testmode_i};
    end

    (* dont_touch = "true" *) logic [AXI_SLV_ID_WIDTH-1:0] b_id_ff, r_id_ff;
    (* dont_touch = "true" *) logic                    b_valid_ff, r_valid_ff;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
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
    assign axi_cfg.w_ready  = 1'b1;
    assign axi_cfg.ar_ready = 1'b1;
    assign axi_cfg.b_valid  = b_valid_ff;
    assign axi_cfg.b_id     = b_id_ff;
    assign axi_cfg.b_resp   = 2'b10;
    assign axi_cfg.b_user   = '0;
    assign axi_cfg.r_valid  = r_valid_ff;
    assign axi_cfg.r_id     = r_id_ff;
    assign axi_cfg.r_data   = '0;
    assign axi_cfg.r_resp   = 2'b10;
    assign axi_cfg.r_last   = 1'b1;
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