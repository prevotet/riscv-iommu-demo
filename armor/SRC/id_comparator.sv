`timescale 1ns/1ps

module id_comparator #(
    parameter int unsigned DevIDWidth = 24
    )
(
    input  logic                 clk_i,
    input  logic                 rst_ni,
    input  logic [DevIDWidth-1:0]  fixed_id,
    input  logic [DevIDWidth-1:0]  dynamic_id,
    input  logic                 compare_enable,
    output logic                 legit_hit,
    output logic                 comparison_valid
);

    logic ids_match_reg;

    // Sequential comparison
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ids_match_reg       <= 1'b0;
            comparison_valid    <= 1'b0;
        end else begin
            if (compare_enable) begin
                ids_match_reg    <= (fixed_id == dynamic_id) && (fixed_id != '0);
                comparison_valid <= 1'b1;
            end else begin
                comparison_valid <= 1'b0;
            end
        end
    end

    assign legit_hit = ids_match_reg;

endmodule

