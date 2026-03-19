`timescale 1ns/1ps

module security_monitor #(
    parameter MAX_FAILURES = 3,
    parameter BLOCK_DURATION = 32'd100000 // Durée du blocage en cycles
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        legit_hit,
    input  logic        comparison_valid,
    output logic        block_ip_o,
    output logic [7:0]  failure_count,
    output logic        threat_detected
);

    logic [7:0] consecutive_failures;
    logic [31:0] block_timer;
    logic legit_hit_d, comparison_valid_d;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        legit_hit_d        <= 1'b0;
        comparison_valid_d <= 1'b0;
    end else begin
        legit_hit_d        <= legit_hit;
        comparison_valid_d <= comparison_valid;
    end
end


    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            block_ip_o           <= 1'b0;
            consecutive_failures <= 8'h0;
            failure_count        <= 8'h0;
            threat_detected      <= 1'b0;
            block_timer          <= 32'h0;
        end else begin
            // Gestion du timer de blocage
            if (block_ip_o) begin
                if (block_timer > 0) begin
                    block_timer <= block_timer - 1;
                end else begin
                    block_ip_o           <= 1'b0;
                    threat_detected      <= 1'b0;
                    consecutive_failures <= 8'h0;
                end
            end

            // Traitement des comparaisons
            if (comparison_valid_d && !block_ip_o) begin
                if (!legit_hit_d) begin
                    consecutive_failures <= consecutive_failures + 1;
                    failure_count        <= failure_count + 1;
                    
                    if ((consecutive_failures + 1) >= (MAX_FAILURES )) begin
                        block_ip_o   <= 1'b1;
                        threat_detected <= 1'b1;
                        block_timer  <= BLOCK_DURATION;
                    end
                end else begin
                    consecutive_failures <= 8'h0;
                end
            end
        end
    end

endmodule
