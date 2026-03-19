`timescale 1ns/1ps

`include "../Include/axi_types.sv"
import axi_types::*;

module ID_extractor #(
    parameter int unsigned DevIDWidth = 24,
    parameter type req_iommu_t = axi_types::req_iommu_t
)(
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  req_iommu_t             req_i,
    output logic [DevIDWidth-1:0]  Device_ID_o,
    output logic                   Device_ID_write_enable_o
);

    // Sequential capture of Device ID based on AXI request validity
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            Device_ID_o              <= '0;
            Device_ID_write_enable_o <= 1'b0;
        end else begin
            Device_ID_write_enable_o <= 1'b0; // default

            if (req_i.aw_valid) begin
                Device_ID_o              <= req_i.aw.aw_stream_id_o;
                Device_ID_write_enable_o <= 1'b1;
            end else if (req_i.ar_valid) 
            begin
                Device_ID_o              <= req_i.ar.ar_stream_id;
                Device_ID_write_enable_o <= 1'b1;
            
            end
        end
    end

endmodule
