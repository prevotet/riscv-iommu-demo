`timescale 1ns/1ps
`include "axi_types.sv"
import axi_types::*;

module request_generator #(
    parameter int NUM_REQS = 15, // Nombre de requêtes à envoyer
    parameter int DEV_ID_WIDTH = 24, // Largeur du stream_id
    parameter AddrWidth    = 64,

    //parameter int WAIT_CYCLES = 0,
    parameter type req_iommu_t = axi_types::req_iommu_t
)(
    input  logic clk_i,
    input  logic rst_ni,

    // AXI handshake venant du wrapper/IOMMU
    input  logic aw_ready_i,
    input  logic w_ready_i,
    input  logic b_valid_i,

    output req_iommu_t req_o
);

    // === Paramètres des requêtes ===
    logic [DEV_ID_WIDTH-1:0] ids[NUM_REQS-1:0];
    logic [AddrWidth-1:0]   addrs[NUM_REQS-1:0];


    initial begin
        for (int i = 0; i < NUM_REQS; i++) begin
            if (i % 4 == 0) begin
                ids[i] = 24'h123456; // tous les 4, on envoie un ID légitime
                //addrs[i] = 64'h00000000FEE00000;
            end else begin 
                ids[i] = 24'h123456; //$urandom_range(0, (1<<DEV_ID_WIDTH)-1); // aléatoire
                //addrs[i] = 64'h11111111FFFFFFFF + i;
            end 
        end
    end

    // FSM états très simples : on génère AW (1 cycle), W (1 cycle) puis on avance
    typedef enum logic [1:0] {
        IDLE,
        SEND_AW_ONE,
        SEND_W_ONE
        //WAIT
    } state_t;

    state_t state, next_state;
    int current_req;
    //int wait_cnt;


    // Registre interne pour la requête
    req_iommu_t req_reg;

    // On expose req_reg en sortie
    assign req_o = req_reg;

    // Séquentiel

   

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state <= IDLE;
            current_req <= 0;
            //wait_cnt    <= 0;
            req_reg <= '0;
        end else begin
            state <= next_state;

            // Par défaut on nettoie les signaux "valid" pour n'envoyer AW/W qu'1 cycle.
            // (On construit la requête pour la request courante juste avant de sortir AW/W)
            req_reg.aw_valid <= 0;
            req_reg.w_valid  <= 0;
            // On garde b_ready = 0 par défaut ; si on veux rester toujours prêt, mets à 1.
            req_reg.b_ready  <= 1;
            req_reg.w.w_last <= 0;


            case (state)
                IDLE: begin
                    // initialise la requête courante (ne met pas valid, juste champs)
                    if (current_req < NUM_REQS) begin
                        // nothing else, combinatoire préparera fields
                    end
                end

                SEND_AW_ONE: begin
                    // On produit un AW valide pendant un cycle (même si aw_ready_i = 0).
                    if (current_req < NUM_REQS) begin

                        req_reg.aw_valid <= 1;
                        req_reg.aw.aw_stream_id_o <= ids[current_req];
                        req_reg.aw.aw_ss_id_valid_o <= 1;
                        req_reg.aw.addr <= addrs[current_req]; //64'h11111111FFFFFFFF + current_req;
                        req_reg.aw.id <= current_req[3:0];
                        req_reg.aw.len <= 8'd0;
                        req_reg.aw.size <= 3'b010;
                        req_reg.aw.burst <= 2'b01;
                        req_reg.aw.lock <= 0;
                        req_reg.aw.cache <= 4'b0011;
                        req_reg.aw.prot <= 3'b000;
                        req_reg.aw.qos <= 4'b0000;
                        req_reg.aw.region <= 4'b0000;
                        req_reg.aw.atop <= 6'b000000;
                        req_reg.aw.user <= 1'b0;
                    end
                end

                SEND_W_ONE: begin
                    if (current_req < NUM_REQS) begin
                        // On produit W valide pendant un cycle (même si w_ready_i = 0).
                        req_reg.w_valid <= 1;
                        req_reg.w.w_data <= 64'hCAFEBABECAFEBABE + current_req;
                        req_reg.w.w_strb <= 8'hFF;
                        req_reg.w.w_last <= 1;
                        req_reg.w.w_user <= 0;
                        // Optionnel : on peut également signaler b_ready pour dire qu'on veut
                        // recevoir la réponse, mais on ne bloque pas sur elle.
                        req_reg.b_ready <= 1; // prêt à recevoir B si elle arrive
                    end
                    // on avance de requête ici
                    if (current_req < NUM_REQS-1)
                        current_req <= current_req + 1;
                end

                //WAIT: begin
                //    if (wait_cnt < WAIT_CYCLES)
                //        wait_cnt <= wait_cnt + 1;
                //    else
                //        wait_cnt <= 0;
                //end

                default:;

            endcase

            // Avancement du compteur seulement après l'envoi W (on avance même si pas d'ack)
            //if (state == SEND_W_ONE) begin
            //    if (current_req < NUM_REQS-1)
            //        current_req <= current_req + 1;
            //    else
            //        current_req <= current_req; // on reste sur la dernière si on veut
            //end
        end
    end

    // Combinaison FSM : cycle through states to generate AW (1 cycle) then W (1 cycle)
    always_comb begin
        next_state = state;
        case (state)
            IDLE: begin
                if (current_req < NUM_REQS)
                    next_state = SEND_AW_ONE;
                //else
                    //next_state = IDLE;
            end
            SEND_AW_ONE: begin
                if (aw_ready_i)
                    next_state = SEND_W_ONE;
                else
                    next_state = SEND_AW_ONE;
            end 
            
            //SEND_W_ONE: next_state = SEND_AW_ONE; // passe à la req suivante (courant incrémenté dans séquentiel)
            SEND_W_ONE: begin
                if (current_req < NUM_REQS-1)
                    next_state = SEND_AW_ONE; //WAIT; 
                else
                    next_state = IDLE;   // STOP après la 15e requête
            end
            //////////////
            //WAIT: begin
            //    if (wait_cnt == WAIT_CYCLES)
            //        next_state = SEND_AW_ONE;
            //    else
            //        next_state = WAIT;
            //end
            /////////////////////
            default: next_state = IDLE;
        endcase
    end

    // --- Non bloquant : on capte les réponses B mais on ne bloque pas ---
    // Si tu veux logger quand la réponse B arrive :
    always_ff @(posedge clk_i) begin
        if (b_valid_i && req_reg.b_ready) begin
            // événement de retour (B). Tu peux ajouter un $display si utile.
            // $display("t=%0t: B reçu pour aw.id=%0d", $time, req_reg.aw.id);
        end
    end

endmodule