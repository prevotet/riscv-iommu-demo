`timescale 1ns/1ps




module address_extractor #(
    parameter int unsigned AddrWidth = 64,
    parameter type req_iommu_t = logic
)(
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  req_iommu_t             req_i,
    
    output logic [AddrWidth-1:0]   Address_o,
    output logic                   Address_write_enable_o,
    output logic                   is_write_o,  // 1 = write, 0 = read
    output logic                   is_read_o
);

    // Sequential capture of Address based on AXI request validity
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            Address_o               <= '0;
            Address_write_enable_o  <= 1'b0;
            is_write_o              <= 1'b0;
            is_read_o               <= 1'b0;
        end else begin
            Address_write_enable_o <= 1'b0;  // default
            is_write_o             <= 1'b0;
            is_read_o              <= 1'b0;
            
            if (req_i.aw_valid) begin
                Address_o               <= req_i.aw.addr;
                Address_write_enable_o  <= 1'b1;
                is_write_o              <= 1'b1;
            end else if (req_i.ar_valid) begin
                Address_o               <= req_i.ar.addr;
                Address_write_enable_o  <= 1'b1;
                is_read_o               <= 1'b1;
            end else begin
                // Hold previous Address_o
                Address_o <= Address_o;
            end
        end
    end

endmodule

