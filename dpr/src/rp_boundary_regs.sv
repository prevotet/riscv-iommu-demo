
// rp_boundary_regs.sv
// Registres pipeline à la frontière statique/RP.
// Vivado DPR exige que tous les signaux traversant la frontière
// soient enregistrés (Partition Pins).
// PASS_THROUGH=1 pour simulation, =0 pour DPR réel.

module rp_boundary_regs #(
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 3,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter bit          PASS_THROUGH   = 0
) (
    input  logic clk_i,
    input  logic rst_ni,
    AXI_BUS.Slave  s,
    AXI_BUS.Master m
);

    if (PASS_THROUGH) begin : gen_bypass
        // Bypass combinatoire (simulation)
        assign m.aw_valid = s.aw_valid; assign m.aw_id     = s.aw_id;
        assign m.aw_addr  = s.aw_addr;  assign m.aw_len    = s.aw_len;
        assign m.aw_size  = s.aw_size;  assign m.aw_burst  = s.aw_burst;
        assign m.aw_lock  = s.aw_lock;  assign m.aw_cache  = s.aw_cache;
        assign m.aw_prot  = s.aw_prot;  assign m.aw_qos    = s.aw_qos;
        assign m.aw_region= s.aw_region;assign m.aw_atop   = s.aw_atop;
        assign m.aw_user  = s.aw_user;
        assign s.aw_ready = m.aw_ready;

        assign m.ar_valid = s.ar_valid; assign m.ar_id     = s.ar_id;
        assign m.ar_addr  = s.ar_addr;  assign m.ar_len    = s.ar_len;
        assign m.ar_size  = s.ar_size;  assign m.ar_burst  = s.ar_burst;
        assign m.ar_lock  = s.ar_lock;  assign m.ar_cache  = s.ar_cache;
        assign m.ar_prot  = s.ar_prot;  assign m.ar_qos    = s.ar_qos;
        assign m.ar_region= s.ar_region;assign m.ar_user   = s.ar_user;
        assign s.ar_ready = m.ar_ready;

        assign m.w_valid  = s.w_valid;  assign m.w_data    = s.w_data;
        assign m.w_strb   = s.w_strb;   assign m.w_last    = s.w_last;
        assign m.w_user   = s.w_user;   assign s.w_ready   = m.w_ready;

        assign s.b_valid  = m.b_valid;  assign s.b_id      = m.b_id;
        assign s.b_resp   = m.b_resp;   assign s.b_user    = m.b_user;
        assign m.b_ready  = s.b_ready;

        assign s.r_valid  = m.r_valid;  assign s.r_id      = m.r_id;
        assign s.r_data   = m.r_data;   assign s.r_resp    = m.r_resp;
        assign s.r_last   = m.r_last;   assign s.r_user    = m.r_user;
        assign m.r_ready  = s.r_ready;

    end else begin : gen_registered

        // AW : statique → RP (skid buffer)
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                m.aw_valid <= 1'b0;
            end else if (!m.aw_valid || m.aw_ready) begin
                m.aw_valid  <= s.aw_valid;
                m.aw_id     <= s.aw_id;
                m.aw_addr   <= s.aw_addr;
                m.aw_len    <= s.aw_len;
                m.aw_size   <= s.aw_size;
                m.aw_burst  <= s.aw_burst;
                m.aw_lock   <= s.aw_lock;
                m.aw_cache  <= s.aw_cache;
                m.aw_prot   <= s.aw_prot;
                m.aw_qos    <= s.aw_qos;
                m.aw_region <= s.aw_region;
                m.aw_atop   <= s.aw_atop;
                m.aw_user   <= s.aw_user;
            end
        end
        assign s.aw_ready = !m.aw_valid || m.aw_ready;

        // AR : statique → RP (skid buffer)
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                m.ar_valid <= 1'b0;
            end else if (!m.ar_valid || m.ar_ready) begin
                m.ar_valid  <= s.ar_valid;
                m.ar_id     <= s.ar_id;
                m.ar_addr   <= s.ar_addr;
                m.ar_len    <= s.ar_len;
                m.ar_size   <= s.ar_size;
                m.ar_burst  <= s.ar_burst;
                m.ar_lock   <= s.ar_lock;
                m.ar_cache  <= s.ar_cache;
                m.ar_prot   <= s.ar_prot;
                m.ar_qos    <= s.ar_qos;
                m.ar_region <= s.ar_region;
                m.ar_user   <= s.ar_user;
            end
        end
        assign s.ar_ready = !m.ar_valid || m.ar_ready;

        // W : statique → RP
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                m.w_valid <= 1'b0;
            end else begin
                m.w_valid <= s.w_valid;
                m.w_data  <= s.w_data;
                m.w_strb  <= s.w_strb;
                m.w_last  <= s.w_last;
                m.w_user  <= s.w_user;
            end
        end
        assign s.w_ready = m.w_ready;

        // B : RP → statique
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                s.b_valid <= 1'b0;
            end else begin
                s.b_valid <= m.b_valid;
                s.b_id    <= m.b_id;
                s.b_resp  <= m.b_resp;
                s.b_user  <= m.b_user;
            end
        end
        assign m.b_ready = s.b_ready;

        // R : RP → statique
        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                s.r_valid <= 1'b0;
            end else begin
                s.r_valid <= m.r_valid;
                s.r_id    <= m.r_id;
                s.r_data  <= m.r_data;
                s.r_resp  <= m.r_resp;
                s.r_last  <= m.r_last;
                s.r_user  <= m.r_user;
            end
        end
        assign m.r_ready = s.r_ready;

    end

endmodule
