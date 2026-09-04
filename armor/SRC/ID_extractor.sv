`timescale 1ns/1ps




module ID_extractor #(
    parameter int unsigned DevIDWidth = 24,
    parameter type req_iommu_t = logic
)(
    input  logic                   clk_i,
    input  logic                   rst_ni,
    input  req_iommu_t             req_i,
    output logic [DevIDWidth-1:0]  Device_ID_o,
    output logic                   Device_ID_write_enable_o
);

    // Detection de front sur AxVALID — meme motif que ADDR_extractor : le
    // declenchement sur niveau relancait la comparaison d'identifiant a chaque
    // cycle d'attente, gonflant artificiellement failure_count du
    // security_monitor sur une simple requete calee.
    logic aw_prev, ar_prev;
    logic aw_edge, ar_edge;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_prev <= 1'b0;
            ar_prev <= 1'b0;
        end else begin
            aw_prev <= req_i.aw_valid;
            ar_prev <= req_i.ar_valid;
        end
    end

    assign aw_edge = req_i.aw_valid & ~aw_prev;
    assign ar_edge = req_i.ar_valid & ~ar_prev;

    // Sequential capture of Device ID based on AXI request validity
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            Device_ID_o              <= '0;
            Device_ID_write_enable_o <= 1'b0;
        end else begin
            Device_ID_write_enable_o <= 1'b0; // default

            if (aw_edge) begin
                Device_ID_o              <= req_i.aw.stream_id;
                Device_ID_write_enable_o <= 1'b1;
            end else if (ar_edge) 
            begin
                Device_ID_o              <= req_i.ar.stream_id;
                Device_ID_write_enable_o <= 1'b1;
            
            end
        end
    end

endmodule
