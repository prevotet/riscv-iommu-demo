`timescale 1ns/1ps
`include "axi_types.sv"
import axi_types::*;

module request_generator_for_mem #(
    parameter int NUM_REQS = 100,
    parameter int DEV_ID_WIDTH = 24,
    parameter int AW_VALID_HOLD_CYCLES = 3,  // ← Nouveau paramètre: cycles à maintenir aw_valid

    parameter type req_iommu_t = axi_types::req_iommu_t
)(
    input  logic clk_i,
    input  logic rst_ni,

    // AXI handshake venant du wrapper / mémoire
    input  logic aw_ready_i,
    input  logic w_ready_i,
    input  logic b_valid_i,

    output req_iommu_t req_o
);

    // ----------------------------
    // IDs
    // ----------------------------
    logic [DEV_ID_WIDTH-1:0] ids[NUM_REQS-1:0];
    logic [AddrWidth-1:0]   addrs[NUM_REQS-1:0];

    initial begin
        for (int i = 0; i < NUM_REQS; i++) begin
            if (i % 4 == 0) begin
                ids[i] = 24'h123456; //$urandom_range(0, (1<<DEV_ID_WIDTH)-1);
                addrs[i] = 64'h00000000FEE00000;  // Adresse MSI

            end else begin 
                ids[i] = 24'h123456;
                addrs[i] = 64'h11111111FFFFFFFF + i;
            end 
        end
    end

    // ----------------------------
    // FSM
    // ----------------------------
    typedef enum logic [1:0] {
        IDLE,
        SEND_AW,
        SEND_W
    } state_t;

    state_t state, next_state;
    int current_req;
    int aw_hold_counter;  // ← Compteur pour maintenir aw_valid


    req_iommu_t req_reg;
    assign req_o = req_reg;

    // ----------------------------
    // Séquentiel
    // ----------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state       <= IDLE;
            current_req <= 0;
            req_reg     <= '0;
            aw_hold_counter <= 0;

        end else begin
            state <= next_state;

            // valeurs par défaut
            req_reg.aw_valid <= 1'b0;
            req_reg.w_valid  <= 1'b0;
            req_reg.b_ready  <= 1'b1; // toujours prêt pour simplifier

            case (state)

                IDLE: begin
                    // rien à faire, les champs sont préparés avant AW
                end

                SEND_AW: begin
                    req_reg.aw_valid <= 1'b1;

                    // champs AW stables tant que aw_ready_i = 0
                    req_reg.aw.aw_stream_id_o    <= ids[current_req];
                    req_reg.aw.aw_ss_id_valid_o  <= 1'b1;
                    req_reg.aw.addr              <= addrs[current_req];
                    req_reg.aw.id                <= current_req[3:0];
                    req_reg.aw.len               <= 8'd0;
                    req_reg.aw.size              <= 3'b010;
                    req_reg.aw.burst             <= 2'b01;
                    req_reg.aw.lock              <= 1'b0;
                    req_reg.aw.cache             <= 4'b0011;
                    req_reg.aw.prot              <= 3'b000;
                    req_reg.aw.qos               <= 4'b0000;
                    req_reg.aw.region            <= 4'b0000;
                    req_reg.aw.atop              <= 6'b000000;
                    req_reg.aw.user              <= 1'b0;





                    // ✅ Logique de maintien de aw_valid après handshake
                    if (aw_ready_i && aw_hold_counter == 0) begin
                        // Handshake détecté, commencer à compter
                        aw_hold_counter <= 1;
                        $display("[%0t] AW handshake détecté, maintien de aw_valid pendant %0d cycles", 
                                 $time, AW_VALID_HOLD_CYCLES);
                    end else if (aw_hold_counter > 0) begin
                        // On est en train de maintenir aw_valid
                        if (aw_hold_counter < AW_VALID_HOLD_CYCLES) begin
                            aw_hold_counter <= aw_hold_counter + 1;
                            $display("[%0t] Maintien aw_valid (%0d/%0d)", 
                                     $time, aw_hold_counter, AW_VALID_HOLD_CYCLES);
                        end else begin
                            // Délai terminé, on peut désactiver aw_valid
                            req_reg.aw_valid <= 1'b0;
                            aw_hold_counter  <= 0;
                            $display("[%0t] aw_valid désactivé après maintien", $time);
                        end
                    end
                end

                SEND_W: begin
                    req_reg.w_valid <= 1'b1;

                    // champs W stables tant que w_ready_i = 0
                    req_reg.w.w_data <= 64'hCAFEBABECAFEBABE + current_req;
                    req_reg.w.w_strb <= 8'hFF;
                    req_reg.w.w_last <= 1'b1;
                    req_reg.w.w_user <= 1'b0;
                end

            endcase

            // Avancer le compteur seulement après handshake W
            if (state == SEND_W && w_ready_i) begin
                if (current_req < NUM_REQS-1)
                    current_req <= current_req + 1;
            end
        end
    end

    // ----------------------------
    // FSM combinatoire
    // ----------------------------
    always_comb begin
        next_state = state;

        case (state)
            IDLE: begin
                if (current_req < NUM_REQS)
                    next_state = SEND_AW;
            end

            SEND_AW: begin
                // ✅ Attendre que le compteur de maintien soit terminé
                if (aw_hold_counter >= AW_VALID_HOLD_CYCLES)
                    next_state = SEND_W;
            end

            SEND_W: begin
                if (w_ready_i)
                    next_state = SEND_AW;
            end

            default: next_state = IDLE;
        endcase
    end

    // ----------------------------
    // Observation des réponses B
    // ----------------------------
    always_ff @(posedge clk_i) begin
        if (b_valid_i && req_reg.b_ready) begin
            // $display("B reçu pour id=%0d", req_reg.aw.id);
        end
    end

endmodule

