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
    // SINK DFX : Pour forcer la création de PPLOCs sur TOUTES les pins d'entrée.
    // Chaque signal d'entrée doit contribuer à un fanout interne au pblock.
    // -------------------------------------------------------------------------
    (* dont_touch = "true" *) logic dfx_sink_ff;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) dfx_sink_ff <= 1'b0;
        else dfx_sink_ff <= ^{
            // Entrées Config Slave (axi_cfg)
            axi_cfg.aw_id, axi_cfg.aw_addr, axi_cfg.aw_len, axi_cfg.aw_size, axi_cfg.aw_burst,
            axi_cfg.aw_lock, axi_cfg.aw_cache, axi_cfg.aw_prot, axi_cfg.aw_qos,
            axi_cfg.aw_region, axi_cfg.aw_atop, axi_cfg.aw_user, axi_cfg.aw_valid,
            axi_cfg.ar_id, axi_cfg.ar_addr, axi_cfg.ar_len, axi_cfg.ar_size, axi_cfg.ar_burst,
            axi_cfg.ar_lock, axi_cfg.ar_cache, axi_cfg.ar_prot, axi_cfg.ar_qos,
            axi_cfg.ar_region, axi_cfg.ar_user, axi_cfg.ar_valid,
            axi_cfg.w_valid, axi_cfg.w_data, axi_cfg.w_strb, axi_cfg.w_last, axi_cfg.w_user,
            axi_cfg.b_ready, axi_cfg.r_ready,

            // Entrées DMA Master (axi_dma)
            axi_dma.aw_ready, axi_dma.w_ready, axi_dma.ar_ready,
            axi_dma.b_id, axi_dma.b_resp, axi_dma.b_user, axi_dma.b_valid,
            axi_dma.r_id, axi_dma.r_data, axi_dma.r_resp, axi_dma.r_last, axi_dma.r_user, axi_dma.r_valid,
            
            // Autres
            testmode_i, btnu_i, btnd_i, btnl_i, btnr_i, btnc_i
        };
    end

    // -------------------------------------------------------------------------
    // DRIVE DFX : Pour forcer la création de PPLOCs sur TOUTES les pins de sortie.
    // Utilisation de registres dont_touch pour éviter l'élagage constant.
    // -------------------------------------------------------------------------
    
    // Pilotage Config Slave (axi_cfg)
    (* dont_touch = "true" *) logic [AXI_SLV_ID_WIDTH-1:0] cfg_b_id_ff, cfg_r_id_ff;
    (* dont_touch = "true" *) logic                    cfg_b_valid_ff, cfg_r_valid_ff;
    (* dont_touch = "true" *) logic                    cfg_aw_ready_ff, cfg_ar_ready_ff, cfg_w_ready_ff;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cfg_b_id_ff     <= '0;
            cfg_r_id_ff     <= '0;
            cfg_b_valid_ff  <= 1'b0;
            cfg_r_valid_ff  <= 1'b0;
            cfg_aw_ready_ff <= 1'b1;
            cfg_ar_ready_ff <= 1'b1;
            cfg_w_ready_ff  <= 1'b1;
        end else begin
            // On répond SLVERR à toute transaction
            cfg_b_id_ff    <= axi_cfg.aw_id;
            cfg_r_id_ff    <= axi_cfg.ar_id;
            cfg_b_valid_ff <= axi_cfg.aw_valid;
            cfg_r_valid_ff <= axi_cfg.ar_valid;
            cfg_aw_ready_ff <= 1'b1;
            cfg_ar_ready_ff <= 1'b1;
            cfg_w_ready_ff  <= 1'b1;
        end
    end

    assign axi_cfg.aw_ready = cfg_aw_ready_ff;
    assign axi_cfg.ar_ready = cfg_ar_ready_ff;
    assign axi_cfg.w_ready  = cfg_w_ready_ff;
    assign axi_cfg.b_valid  = cfg_b_valid_ff;
    assign axi_cfg.b_id     = cfg_b_id_ff;
    assign axi_cfg.b_resp   = 2'b10; // SLVERR
    assign axi_cfg.b_user   = '0;
    assign axi_cfg.r_valid  = cfg_r_valid_ff;
    assign axi_cfg.r_id     = cfg_r_id_ff;
    assign axi_cfg.r_data   = '0;
    assign axi_cfg.r_resp   = 2'b10; // SLVERR
    assign axi_cfg.r_last   = 1'b1;
    assign axi_cfg.r_user   = '0;

    // Pilotage DMA Master (axi_dma) - Toujours IDLE
    (* dont_touch = "true" *) logic dma_aw_valid_ff, dma_ar_valid_ff, dma_w_valid_ff;
    (* dont_touch = "true" *) logic dma_b_ready_ff, dma_r_ready_ff;
    (* dont_touch = "true" *) logic [7:0] dma_ar_len_ff;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dma_aw_valid_ff <= 1'b0;
            dma_ar_valid_ff <= 1'b0;
            dma_w_valid_ff  <= 1'b0;
            dma_b_ready_ff  <= 1'b1;
            dma_r_ready_ff  <= 1'b1;
            dma_ar_len_ff   <= 8'h00;
        end else begin
            dma_aw_valid_ff <= 1'b0;
            dma_ar_valid_ff <= 1'b0;
            dma_w_valid_ff  <= 1'b0;
            dma_b_ready_ff  <= 1'b1;
            dma_r_ready_ff  <= 1'b1;
            dma_ar_len_ff   <= 8'h00;
        end
    end

    assign axi_dma.aw_valid        = dma_aw_valid_ff;
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

    assign axi_dma.w_valid         = dma_w_valid_ff;
    assign axi_dma.w_data          = '0;
    assign axi_dma.w_strb          = '0;
    assign axi_dma.w_last          = 1'b0;
    assign axi_dma.w_user          = '0;

    assign axi_dma.b_ready         = dma_b_ready_ff;

    assign axi_dma.ar_valid        = dma_ar_valid_ff;
    assign axi_dma.ar_id           = '0;
    assign axi_dma.ar_addr         = '0;
    assign axi_dma.ar_len          = dma_ar_len_ff;
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

    assign axi_dma.r_ready         = dma_r_ready_ff;

endmodule
