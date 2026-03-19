module outs_req_monitor #(
    parameter MAX_OUTSTANDING = 16,
    parameter BLOCK_CYCLES = 10,
    parameter type resp_slv_t = logic,
    parameter type req_iommu_t = logic

)(
    input  logic        clk_i,
    input  logic        rst_ni,
    
    // Signal réutilisé du request_flow_monitor
    input  logic        req_fire,
    
    // Response interface (depuis IOMMU)
    input  resp_slv_t   resp_wrapper_iommu_i,
    input  req_iommu_t  req_IP_wrapper_i,

    
    // Outputs
    output logic        overflow_flag,
    output logic        block_req
);

    // Détection des handshakes de réponses
    logic b_handshake, r_handshake;
    logic resp_complete;
    
    assign b_handshake  = resp_wrapper_iommu_i.b_valid && req_IP_wrapper_i.b_ready;
    assign r_handshake  = resp_wrapper_iommu_i.r_valid && req_IP_wrapper_i.r_ready && resp_wrapper_iommu_i.r.last;
    assign resp_complete = b_handshake | r_handshake;
    
    // Compteur de requêtes outstanding
    logic [$clog2(MAX_OUTSTANDING+1):0] outstanding;
    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            outstanding <= 0;
        end else begin
            case ({req_fire, resp_complete})
                2'b10:   outstanding <= outstanding + 1;  // nouvelle requête
                2'b01:   outstanding <= outstanding - 1;  // réponse reçue
                default: outstanding <= outstanding;       // 00 ou 11
            endcase
        end
    end
    
    // Détection de l'overflow
    assign overflow_flag = (outstanding >= MAX_OUTSTANDING);
    
    // Mécanisme de blocage temporaire
    logic [$clog2(BLOCK_CYCLES):0] block_cnt;
    logic blocking;
    
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            block_cnt <= 0;
            blocking  <= 1'b0;
        end else begin
            if (overflow_flag && !blocking) begin
                blocking  <= 1'b1;
                block_cnt <= 0;
            end else if (blocking) begin
                if (block_cnt == BLOCK_CYCLES-1) begin
                    blocking  <= 1'b0;
                    block_cnt <= 0;
                end else begin
                    block_cnt <= block_cnt + 1;
                end
            end
        end
    end
    
    assign block_req = blocking;

endmodule