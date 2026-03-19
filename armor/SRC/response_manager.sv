`timescale 1ns/1ps




module response_manager #(
    parameter type resp_slv_t = logic
)(
    input  logic    clk_i,
    input  logic    rst_ni,
    input  logic    block_ip_i,
    input  logic    block_req_i,
    input  resp_slv_t   resp_wrapper_iommu_i,   //change it to resp_t when integration of the iommu 
    output resp_slv_t   resp_IP_wrapper_o       //change it to resp_t when integration of the iommu 
);

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            resp_IP_wrapper_o <= '0;
        end else begin


            if (block_ip_i ) begin //|| block_req_i
                resp_IP_wrapper_o <= '0; // bloquer tout
            end else begin
                // Copier l'IOMMU vers l'IP
                resp_IP_wrapper_o <= resp_wrapper_iommu_i;
            end
        end
    end

endmodule
