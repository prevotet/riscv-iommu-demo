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

    // Detection de front sur AxVALID.
    //
    // Cette logique declenchait sur le NIVEAU de aw_valid/ar_valid. Or AXI
    // impose au maitre de maintenir valid jusqu'au ready : une requete qui
    // attend 200 cycles produisait 200 "detections". Le msi_detector en aval
    // saturait alors sa fenetre (MAX_MSI_PER_WINDOW=32) des la premiere
    // requete calee, block_msi restait arme en permanence, et comme le blocage
    // empeche le ready d'arriver, le faux positif s'auto-entretenait.
    // Mesure sur carte avant correction : 1 024 012 evenements MSI pour 1000
    // transactions. Un front = une requete, quelle que soit la duree du stall.
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
            
            if (aw_edge) begin
                Address_o               <= req_i.aw.addr;
                Address_write_enable_o  <= 1'b1;
                is_write_o              <= 1'b1;
            end else if (ar_edge) begin
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

