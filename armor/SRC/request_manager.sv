`timescale 1ns/1ps

`include "../Include/axi_types.sv"
import axi_types::*;

module request_manager #(
    parameter type req_iommu_t = logic
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        legit_hit,
    input  logic        block_req_i,   // nouveau signal de blocage global
    input  req_iommu_t  req_IP_wrapper_i,
    output req_iommu_t  req_wrapper_iommu_o
);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            req_wrapper_iommu_o <= '0;
        end else begin
            if (block_req_i) begin
                // Bloquer la requête : hold ou invalider les signaux
                req_wrapper_iommu_o <= req_wrapper_iommu_o; // hold previous
                req_wrapper_iommu_o.aw_valid <= 1'b0;
                req_wrapper_iommu_o.w_valid  <= 1'b0;
                //req_wrapper_iommu_o.b_ready  <= 1'b0;
                req_wrapper_iommu_o.ar_valid <= 1'b0;
                req_wrapper_iommu_o.r_ready  <= 1'b0;
            // Default: hold previous value unless updated
            //req_wrapper_iommu_o <= req_wrapper_iommu_o;
            
            end else if (legit_hit) begin
                req_wrapper_iommu_o <= req_IP_wrapper_i;
            end else begin
                req_wrapper_iommu_o <= req_IP_wrapper_i;

                // Invalidate AXI4-Lite/AXI4 signals
                req_wrapper_iommu_o.aw_valid <= 1'b0;
                req_wrapper_iommu_o.w_valid  <= 1'b0;
                //req_wrapper_iommu_o.b_ready  <= 1'b0;
                req_wrapper_iommu_o.ar_valid <= 1'b0;
                req_wrapper_iommu_o.r_ready  <= 1'b0;
            end
        end
    end

endmodule
