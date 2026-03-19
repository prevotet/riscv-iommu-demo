`timescale 1ns/1ps

module msi_detector #(
    parameter int unsigned AddrWidth = 64
)(
    input  logic                   clk_i,
    input  logic                   rst_ni,
    
    // Adresse MSI configurée par le CPU
    input  logic [AddrWidth-1:0]   msi_address_config,
    
    // Adresse extraite de la requête
    input  logic [AddrWidth-1:0]   extracted_address,
    
    // Signal de validation de la comparaison
    input  logic                   compare_enable,
    // Type de transaction (MSI = toujours write)
    input  logic                   is_write_req,
    
    // Outputs
    output logic                   is_msi_interrupt,
    output logic                   is_dma,
    output logic                   comparison_valid
);

    logic addr_match_reg;
    logic is_dma_reg;

    
    // Sequential comparison
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            addr_match_reg      <= 1'b0;
            is_dma_reg          <= 1'b0;
            comparison_valid    <= 1'b0;
        end else begin
            if (compare_enable && is_write_req) begin
                // Comparer UNIQUEMENT si c'est une écriture
                addr_match_reg   <= (msi_address_config == extracted_address) && (msi_address_config != '0);
                // DMA = écriture vers une adresse NON-MSI
                is_dma_reg       <= (msi_address_config != extracted_address) || (msi_address_config == '0);

                comparison_valid <= 1'b1;
            end else if (compare_enable && !is_write_req) begin
                // Si c'est une lecture, ni MSI ni DMA write
                addr_match_reg   <= 1'b0;
                is_dma_reg       <= 1'b0;
                comparison_valid <= 1'b1;
            end else begin
                comparison_valid <= 1'b0;
            end
             
        end
    end
    
    assign is_msi_interrupt = addr_match_reg;
    assign is_dma = is_dma_reg;


endmodule