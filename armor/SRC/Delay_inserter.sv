`timescale 1ns/1ps






module response_delayer #(
    parameter int unsigned MAX_DELAY = 16,
    parameter type resp_slv_t = logic
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  resp_slv_t   resp_in_i,
    output resp_slv_t   resp_out_o
);

    // Buffer pour toute la réponse
    resp_slv_t resp_buf;
    
    // Flag busy et compteur
    logic busy;
    logic [$clog2(MAX_DELAY+1):0] cnt;
    
    // Logique séquentielle
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            busy     <= 1'b0;
            cnt      <= '0;
            resp_buf <= '0;
        end else begin
            if (!busy && (resp_in_i.b_valid || resp_in_i.r_valid)) begin
                // Capturer nouvelle réponse
                busy     <= 1'b1;
                resp_buf <= resp_in_i;
                cnt      <= $urandom_range(1, MAX_DELAY);
            end else if (busy && cnt > 0) begin
                // Décompter
                cnt <= cnt - 1;
            end else if (busy && cnt == 0) begin
                // Délai terminé, libérer
                busy <= 1'b0;
            end
        end
    end
    
    // Sortie combinatoire
    always_comb begin
        if (busy && cnt == 0) begin
            // Envoyer la réponse bufferisée après le délai
            resp_out_o = resp_buf;
        end else begin
            // Bloquer pendant le délai
            resp_out_o = '0;
        end
    end

endmodule